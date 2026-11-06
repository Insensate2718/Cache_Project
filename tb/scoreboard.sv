`timescale 1ns/1ps

module cache_scoreboard #(
    parameter ADDR_WIDTH   = 32,
    parameter MEMORY_WORDS = 2048,
    parameter [ADDR_WIDTH-1:0] BASE_ADDR = 0,
    parameter FAIL_FAST    = 1
) (
    input  wire                  clk,
    input  wire                  reset_n,

    input  wire                  req_valid,
    input  wire                  req_ready,
    input  wire                  req_write,
    input  wire [ADDR_WIDTH-1:0] req_addr,
    input  wire [31:0]           req_wdata,

    input  wire                  resp_valid,
    input  wire                  resp_ready,
    input  wire [31:0]           resp_rdata,
    input  wire                  resp_tag_parity_err,
    input  wire                  resp_fatal_err,

    output reg                   pending_request,
    output reg [31:0]            request_count,
    output reg [31:0]            response_count,
    output reg [31:0]            read_check_count,
    output reg [31:0]            write_commit_count,
    output reg [31:0]            error_response_count,
    output reg [31:0]            mismatch_count
);

    reg [31:0] reference_memory [0:MEMORY_WORDS-1];
    reg        reference_valid  [0:MEMORY_WORDS-1];

    reg                   pending_write;
    reg                   pending_address_valid;
    reg [ADDR_WIDTH-1:0]  pending_addr;
    reg [31:0]            pending_wdata;
    integer               pending_index;

    integer word_index;
    integer request_index;
    reg     request_address_valid;
    reg     hard_error;

    function integer address_in_range;
        input [ADDR_WIDTH-1:0] address_value;
        begin
            address_in_range =
                (address_value >= BASE_ADDR) &&
                (((address_value - BASE_ADDR) >> 2) < MEMORY_WORDS);
        end
    endfunction

    function integer address_to_index;
        input [ADDR_WIDTH-1:0] address_value;
        begin
            address_to_index = (address_value - BASE_ADDR) >> 2;
        end
    endfunction

    task report_mismatch;
        input [8*96-1:0] message;
        begin
            mismatch_count = mismatch_count + 1;
            if (FAIL_FAST != 0) begin
                $fatal(1, "SCOREBOARD_MISMATCH: %0s", message);
            end else begin
                $display("SCOREBOARD_MISMATCH: %0s", message);
            end
        end
    endtask

    task clear_reference;
        begin
            for (word_index = 0; word_index < MEMORY_WORDS;
                 word_index = word_index + 1) begin
                reference_memory[word_index] = 32'b0;
                reference_valid[word_index] = 1'b0;
            end
        end
    endtask

    task preload_word;
        input [ADDR_WIDTH-1:0] address_value;
        input [31:0]           data_value;
        integer               preload_index;
        begin
            if (address_value[1:0] != 2'b00 ||
                !address_in_range(address_value)) begin
                $fatal(1,
                    "Invalid scoreboard preload address: %h",
                    address_value);
            end
            preload_index = address_to_index(address_value);
            reference_memory[preload_index] = data_value;
            reference_valid[preload_index] = 1'b1;
        end
    endtask

    task inspect_word;
        input  [ADDR_WIDTH-1:0] address_value;
        output [31:0]           data_value;
        output                  data_valid;
        integer                inspect_index;
        begin
            if (address_value[1:0] != 2'b00 ||
                !address_in_range(address_value)) begin
                $fatal(1,
                    "Invalid scoreboard inspect address: %h",
                    address_value);
            end
            inspect_index = address_to_index(address_value);
            data_value = reference_memory[inspect_index];
            data_valid = reference_valid[inspect_index];
        end
    endtask

    initial begin
        if (MEMORY_WORDS <= 0) begin
            $fatal(1, "MEMORY_WORDS must be positive");
        end
        for (word_index = 0; word_index < MEMORY_WORDS;
             word_index = word_index + 1) begin
            reference_memory[word_index] = 32'b0;
            reference_valid[word_index] = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            pending_request     <= 1'b0;
            pending_write       <= 1'b0;
            pending_address_valid <= 1'b0;
            pending_addr        <= {ADDR_WIDTH{1'b0}};
            pending_wdata       <= 32'b0;
            pending_index       <= 0;
            request_count       <= 32'b0;
            response_count      <= 32'b0;
            read_check_count    <= 32'b0;
            write_commit_count  <= 32'b0;
            error_response_count <= 32'b0;
            mismatch_count      <= 32'b0;
        end else begin
            if (req_valid && req_ready) begin
                request_count <= request_count + 1'b1;
                request_address_valid =
                    (req_addr[1:0] == 2'b00) &&
                    address_in_range(req_addr);

                if (pending_request) begin
                    report_mismatch(
                        "accepted request while another request was pending");
                end else begin
                    pending_request <= 1'b1;
                    pending_write <= req_write;
                    pending_address_valid <= request_address_valid;
                    pending_addr <= req_addr;
                    pending_wdata <= req_wdata;

                    if (!request_address_valid) begin
                        pending_index <= 0;
                        report_mismatch(
                            "accepted request had invalid word address");
                    end else begin
                        request_index = address_to_index(req_addr);
                        pending_index <= request_index;
                    end
                end
            end

            if (resp_valid && resp_ready) begin
                response_count <= response_count + 1'b1;

                if (!pending_request) begin
                    report_mismatch(
                        "response completed without a pending request");
                end else begin
                    hard_error = resp_tag_parity_err | resp_fatal_err;

                    if (pending_address_valid) begin
                        if (hard_error) begin
                            error_response_count <=
                                error_response_count + 1'b1;
                        end else if (pending_write) begin
                            reference_memory[pending_index] <= pending_wdata;
                            reference_valid[pending_index] <= 1'b1;
                            write_commit_count <= write_commit_count + 1'b1;
                        end else begin
                            read_check_count <= read_check_count + 1'b1;
                            if (!reference_valid[pending_index]) begin
                                report_mismatch(
                                    "successful read used an unknown reference word");
                            end else if (resp_rdata !==
                                         reference_memory[pending_index]) begin
                                $display(
                                    "SCOREBOARD_READ address=%h expected=%h actual=%h",
                                    pending_addr,
                                    reference_memory[pending_index],
                                    resp_rdata);
                                report_mismatch(
                                    "read data did not match reference");
                            end
                        end
                    end

                    pending_request <= 1'b0;
                end
            end
        end
    end

endmodule
