`timescale 1ns/1ps

module backing_memory_model #(
    parameter ADDR_WIDTH           = 32,
    parameter MEMORY_LINES         = 256,
    parameter MIN_RESPONSE_LATENCY = 1,
    parameter MAX_RESPONSE_LATENCY = 4,
    parameter MAX_REQUEST_STALL    = 2
) (
    input  wire                  clk,
    input  wire                  reset_n,

    input  wire                  mem_req_valid,
    output reg                   mem_req_ready,
    input  wire                  mem_req_write,
    input  wire [ADDR_WIDTH-1:0] mem_req_addr,
    input  wire [255:0]          mem_req_wdata,

    output reg                   mem_resp_valid,
    input  wire                  mem_resp_ready,
    output reg  [255:0]          mem_resp_rdata,
    output reg                   mem_resp_error,

    input  wire                  inject_error,
    input  wire [31:0]           random_seed
);

    localparam STATE_IDLE     = 2'd0;
    localparam STATE_WAIT     = 2'd1;
    localparam STATE_RESPONSE = 2'd2;

    reg [255:0] memory [0:MEMORY_LINES-1];

    reg [1:0] state;
    reg [31:0] random_state;
    integer request_stall_count;
    integer response_delay_count;

    reg pending_write;
    reg pending_error;
    integer pending_index;
    reg [255:0] pending_write_data;

    function [31:0] normalized_seed;
        input [31:0] seed_value;
        begin
            if (seed_value == 32'b0) begin
                normalized_seed = 32'h1;
            end else begin
                normalized_seed = seed_value;
            end
        end
    endfunction

    function [31:0] next_random;
        input [31:0] current_value;
        reg [31:0] mixed_value;
        begin
            mixed_value = current_value;
            mixed_value = mixed_value ^ (mixed_value << 13);
            mixed_value = mixed_value ^ (mixed_value >> 17);
            mixed_value = mixed_value ^ (mixed_value << 5);
            next_random = mixed_value;
            if (next_random == 32'b0) begin
                next_random = 32'h1;
            end
        end
    endfunction

    function integer address_to_index;
        input [ADDR_WIDTH-1:0] address_value;
        begin
            address_to_index = (address_value >> 5) % MEMORY_LINES;
        end
    endfunction

    task preload_line;
        input [ADDR_WIDTH-1:0] address_value;
        input [255:0] data_value;
        begin
            if (address_value[4:0] != 5'b0) begin
                $fatal(1, "Unaligned preload address: %h", address_value);
            end
            memory[address_to_index(address_value)] = data_value;
        end
    endtask

    task inspect_line;
        input  [ADDR_WIDTH-1:0] address_value;
        output [255:0] data_value;
        begin
            if (address_value[4:0] != 5'b0) begin
                $fatal(1, "Unaligned inspect address: %h", address_value);
            end
            data_value = memory[address_to_index(address_value)];
        end
    endtask

    initial begin
        if (MEMORY_LINES <= 0) begin
            $fatal(1, "MEMORY_LINES must be positive");
        end
        if (MIN_RESPONSE_LATENCY < 1 ||
            MAX_RESPONSE_LATENCY < MIN_RESPONSE_LATENCY) begin
            $fatal(1, "Invalid response latency bounds");
        end
        if (MAX_REQUEST_STALL < 0) begin
            $fatal(1, "MAX_REQUEST_STALL cannot be negative");
        end
    end

    always @(*) begin
        mem_req_ready = 1'b0;
        if (reset_n && state == STATE_IDLE &&
            request_stall_count == 0) begin
            mem_req_ready = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            state <= STATE_IDLE;
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= 256'b0;
            mem_resp_error <= 1'b0;
            random_state <= normalized_seed(random_seed);
            request_stall_count <= normalized_seed(random_seed) %
                (MAX_REQUEST_STALL + 1);
            response_delay_count <= 0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    mem_resp_valid <= 1'b0;
                    mem_resp_error <= 1'b0;

                    if (mem_req_valid && request_stall_count > 0) begin
                        request_stall_count <= request_stall_count - 1;
                    end else if (mem_req_valid && mem_req_ready) begin
                        if (mem_req_addr[4:0] != 5'b0) begin
                            $fatal(1,
                                "Unaligned lower-memory request: %h",
                                mem_req_addr);
                        end

                        pending_write <= mem_req_write;
                        pending_error <= inject_error;
                        pending_index <= address_to_index(mem_req_addr);
                        pending_write_data <= mem_req_wdata;
                        random_state <= next_random(random_state);
                        response_delay_count <=
                            MIN_RESPONSE_LATENCY +
                            (next_random(random_state) %
                            (MAX_RESPONSE_LATENCY -
                            MIN_RESPONSE_LATENCY + 1));
                        state <= STATE_WAIT;
                    end
                end

                STATE_WAIT: begin
                    if (response_delay_count > 1) begin
                        response_delay_count <= response_delay_count - 1;
                    end else begin
                        mem_resp_valid <= 1'b1;
                        mem_resp_error <= pending_error;
                        if (pending_write || pending_error) begin
                            mem_resp_rdata <= 256'b0;
                        end else begin
                            mem_resp_rdata <= memory[pending_index];
                        end
                        state <= STATE_RESPONSE;
                    end
                end

                STATE_RESPONSE: begin
                    if (mem_resp_valid && mem_resp_ready) begin
                        if (pending_write && !mem_resp_error) begin
                            memory[pending_index] <= pending_write_data;
                        end
                        mem_resp_valid <= 1'b0;
                        random_state <= next_random(random_state);
                        request_stall_count <= next_random(random_state) %
                            (MAX_REQUEST_STALL + 1);
                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                    mem_resp_valid <= 1'b0;
                    mem_resp_error <= 1'b0;
                end
            endcase
        end
    end

endmodule
