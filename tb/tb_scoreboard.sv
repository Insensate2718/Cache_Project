`timescale 1ns/1ps

module tb_scoreboard;

    localparam ADDR_WIDTH          = 16;
    localparam MEMORY_WORDS        = 64;
    localparam RANDOM_TRANSACTIONS = 300;

    reg                   clk;
    reg                   reset_n;
    reg                   bad_reset_n;

    reg                   req_valid;
    reg                   req_ready;
    reg                   req_write;
    reg  [ADDR_WIDTH-1:0] req_addr;
    reg  [31:0]           req_wdata;
    reg                   resp_valid;
    reg                   resp_ready;
    reg  [31:0]           resp_rdata;
    reg                   resp_tag_parity_err;
    reg                   resp_fatal_err;

    wire                  pending_request;
    wire [31:0]           request_count;
    wire [31:0]           response_count;
    wire [31:0]           read_check_count;
    wire [31:0]           write_commit_count;
    wire [31:0]           error_response_count;
    wire [31:0]           mismatch_count;

    reg                   bad_req_valid;
    reg                   bad_req_ready;
    reg                   bad_req_write;
    reg  [ADDR_WIDTH-1:0] bad_req_addr;
    reg  [31:0]           bad_req_wdata;
    reg                   bad_resp_valid;
    reg                   bad_resp_ready;
    reg  [31:0]           bad_resp_rdata;
    reg                   bad_resp_tag_parity_err;
    reg                   bad_resp_fatal_err;

    wire [31:0] bad_mismatch_count;

    reg [31:0] reference_memory [0:MEMORY_WORDS-1];
    integer seed;
    integer random_state;
    integer ignored_random;
    integer transaction_index;
    integer word_index;
    integer selected_word;
    integer request_stall;
    integer response_stall;
    integer expected_requests;
    integer expected_responses;
    integer expected_reads;
    integer expected_writes;
    integer expected_errors;
    reg     selected_write;
    reg     selected_error;
    reg [31:0] selected_data;
    reg [31:0] inspected_data;
    reg        inspected_valid;
    reg [1023:0] vcd_path;

    cache_scoreboard #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEMORY_WORDS(MEMORY_WORDS),
        .BASE_ADDR(0),
        .FAIL_FAST(1)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_write(req_write),
        .req_addr(req_addr),
        .req_wdata(req_wdata),
        .resp_valid(resp_valid),
        .resp_ready(resp_ready),
        .resp_rdata(resp_rdata),
        .resp_tag_parity_err(resp_tag_parity_err),
        .resp_fatal_err(resp_fatal_err),
        .pending_request(pending_request),
        .request_count(request_count),
        .response_count(response_count),
        .read_check_count(read_check_count),
        .write_commit_count(write_commit_count),
        .error_response_count(error_response_count),
        .mismatch_count(mismatch_count)
    );

    cache_scoreboard #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEMORY_WORDS(MEMORY_WORDS),
        .BASE_ADDR(0),
        .FAIL_FAST(0)
    ) violation_dut (
        .clk(clk),
        .reset_n(bad_reset_n),
        .req_valid(bad_req_valid),
        .req_ready(bad_req_ready),
        .req_write(bad_req_write),
        .req_addr(bad_req_addr),
        .req_wdata(bad_req_wdata),
        .resp_valid(bad_resp_valid),
        .resp_ready(bad_resp_ready),
        .resp_rdata(bad_resp_rdata),
        .resp_tag_parity_err(bad_resp_tag_parity_err),
        .resp_fatal_err(bad_resp_fatal_err),
        .pending_request(),
        .request_count(),
        .response_count(),
        .read_check_count(),
        .write_commit_count(),
        .error_response_count(),
        .mismatch_count(bad_mismatch_count)
    );

    always #5 clk = ~clk;

    task clear_inputs;
        begin
            req_valid                  = 1'b0;
            req_ready                  = 1'b0;
            req_write                  = 1'b0;
            req_addr                   = {ADDR_WIDTH{1'b0}};
            req_wdata                  = 32'b0;
            resp_valid                 = 1'b0;
            resp_ready                 = 1'b0;
            resp_rdata                 = 32'b0;
            resp_tag_parity_err        = 1'b0;
            resp_fatal_err             = 1'b0;
            bad_req_valid              = 1'b0;
            bad_req_ready              = 1'b0;
            bad_req_write              = 1'b0;
            bad_req_addr               = {ADDR_WIDTH{1'b0}};
            bad_req_wdata              = 32'b0;
            bad_resp_valid             = 1'b0;
            bad_resp_ready             = 1'b0;
            bad_resp_rdata             = 32'b0;
            bad_resp_tag_parity_err    = 1'b0;
            bad_resp_fatal_err         = 1'b0;
        end
    endtask

    task apply_reset;
        begin
            @(negedge clk);
            reset_n = 1'b0;
            @(posedge clk);
            #1;
            @(negedge clk);
            reset_n = 1'b1;
        end
    endtask

    task run_transaction;
        input                  request_write;
        input [ADDR_WIDTH-1:0] request_address;
        input [31:0]           request_data;
        input                  response_error;
        input [31:0]           response_data;
        input integer          request_wait_cycles;
        input integer          response_wait_cycles;
        integer                wait_index;
        reg [31:0]             previous_reference_data;
        reg                    previous_reference_valid;
        begin
            if (request_write) begin
                dut.inspect_word(
                    request_address,
                    previous_reference_data,
                    previous_reference_valid
                );
            end

            @(negedge clk);
            req_valid = 1'b1;
            req_ready = 1'b0;
            req_write = request_write;
            req_addr = request_address;
            req_wdata = request_data;

            for (wait_index = 0; wait_index < request_wait_cycles;
                 wait_index = wait_index + 1) begin
                @(posedge clk);
                #1;
                if (pending_request) begin
                    $fatal(1, "Request was recorded before its handshake");
                end
            end

            @(negedge clk);
            req_ready = 1'b1;
            @(posedge clk);
            #1;
            if (!pending_request) begin
                $fatal(1, "Request handshake was not recorded");
            end

            @(negedge clk);
            req_valid = 1'b0;
            req_ready = 1'b0;
            resp_valid = 1'b1;
            resp_ready = 1'b0;
            resp_rdata = response_data;
            resp_tag_parity_err = 1'b0;
            resp_fatal_err = response_error;

            if (request_write) begin
                dut.inspect_word(
                    request_address,
                    inspected_data,
                    inspected_valid
                );
                if (inspected_valid !== previous_reference_valid ||
                    (inspected_valid &&
                     inspected_data !== previous_reference_data)) begin
                    $fatal(1,
                        "Write changed reference memory before response handshake");
                end
            end

            for (wait_index = 0; wait_index < response_wait_cycles;
                 wait_index = wait_index + 1) begin
                @(posedge clk);
                #1;
                if (!pending_request) begin
                    $fatal(1, "Response completed without its handshake");
                end
            end

            @(negedge clk);
            resp_ready = 1'b1;
            @(posedge clk);
            #1;
            if (pending_request) begin
                $fatal(1, "Completed response did not retire request");
            end

            if (request_write) begin
                dut.inspect_word(
                    request_address,
                    inspected_data,
                    inspected_valid
                );
                if (!response_error &&
                    (!inspected_valid || inspected_data !== request_data)) begin
                    $fatal(1,
                        "Successful write response did not commit reference data");
                end
                if (response_error &&
                    (inspected_valid !== previous_reference_valid ||
                     (inspected_valid &&
                      inspected_data !== previous_reference_data))) begin
                    $fatal(1,
                        "Failed write response modified reference data");
                end
            end

            @(negedge clk);
            resp_valid = 1'b0;
            resp_ready = 1'b0;
            resp_fatal_err = 1'b0;
        end
    endtask

    task test_reset_abort;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_ready = 1'b1;
            req_write = 1'b0;
            req_addr = 16'h0000;
            @(posedge clk);
            #1;
            if (!pending_request) begin
                $fatal(1, "Reset-abort request was not recorded");
            end
            @(negedge clk);
            req_valid = 1'b0;
            req_ready = 1'b0;
            reset_n = 1'b0;
            @(posedge clk);
            #1;
            if (pending_request || request_count != 0 ||
                response_count != 0) begin
                $fatal(1, "Reset did not abort and clear scoreboard state");
            end
            @(negedge clk);
            reset_n = 1'b1;

            dut.inspect_word(16'h0000, inspected_data, inspected_valid);
            if (!inspected_valid || inspected_data !== reference_memory[0]) begin
                $fatal(1, "Reset unexpectedly cleared reference memory");
            end
        end
    endtask

    task test_violation_detection;
        integer expected_mismatches;
        begin
            expected_mismatches = 0;
            violation_dut.clear_reference();
            violation_dut.preload_word(16'h0000, 32'h10203040);

            @(negedge clk);
            bad_resp_valid = 1'b1;
            bad_resp_ready = 1'b1;
            @(posedge clk);
            #1;
            expected_mismatches = expected_mismatches + 1;
            if (bad_mismatch_count != expected_mismatches) begin
                $fatal(1, "Unsolicited response was not detected");
            end

            @(negedge clk);
            bad_resp_valid = 1'b0;
            bad_resp_ready = 1'b0;
            bad_req_valid = 1'b1;
            bad_req_ready = 1'b1;
            bad_req_addr = 16'h0000;
            @(posedge clk);
            #1;
            @(negedge clk);
            bad_req_valid = 1'b0;
            bad_req_ready = 1'b0;
            bad_resp_valid = 1'b1;
            bad_resp_ready = 1'b1;
            bad_resp_rdata = 32'hffffffff;
            @(posedge clk);
            #1;
            expected_mismatches = expected_mismatches + 1;
            if (bad_mismatch_count != expected_mismatches) begin
                $fatal(1, "Incorrect read data was not detected");
            end

            @(negedge clk);
            bad_resp_valid = 1'b0;
            bad_resp_ready = 1'b0;
            bad_req_valid = 1'b1;
            bad_req_ready = 1'b1;
            bad_req_addr = 16'h0002;
            @(posedge clk);
            #1;
            expected_mismatches = expected_mismatches + 1;
            if (bad_mismatch_count != expected_mismatches) begin
                $fatal(1, "Unaligned request was not detected");
            end

            @(negedge clk);
            bad_req_valid = 1'b0;
            bad_req_ready = 1'b0;
            bad_reset_n = 1'b0;
            @(posedge clk);
            #1;
            @(negedge clk);
            bad_reset_n = 1'b1;
        end
    endtask

    initial begin
        #200000;
        $fatal(1, "Timeout waiting for scoreboard test completion");
    end

    initial begin
        clk = 1'b0;
        reset_n = 1'b1;
        bad_reset_n = 1'b1;
        clear_inputs();
        expected_requests = 0;
        expected_responses = 0;
        expected_reads = 0;
        expected_writes = 0;
        expected_errors = 0;

        if (!$value$plusargs("SEED=%d", seed)) begin
            seed = 1;
        end
        random_state = seed;
        ignored_random = $urandom(random_state);

        if ($value$plusargs("VCD=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(0, tb_scoreboard);
        end

        dut.clear_reference();
        for (word_index = 0; word_index < MEMORY_WORDS;
             word_index = word_index + 1) begin
            reference_memory[word_index] = 32'h50000000 | word_index;
            dut.preload_word(
                word_index << 2,
                reference_memory[word_index]
            );
        end

        apply_reset();
        @(negedge clk);
        bad_reset_n = 1'b0;
        @(posedge clk);
        #1;
        @(negedge clk);
        bad_reset_n = 1'b1;
        test_reset_abort();

        run_transaction(1'b0, 16'h0000, 32'b0, 1'b0,
            reference_memory[0], 2, 3);
        expected_requests = expected_requests + 1;
        expected_responses = expected_responses + 1;
        expected_reads = expected_reads + 1;

        run_transaction(1'b1, 16'h0004, 32'hcafebabe, 1'b0,
            32'b0, 1, 2);
        reference_memory[1] = 32'hcafebabe;
        expected_requests = expected_requests + 1;
        expected_responses = expected_responses + 1;
        expected_writes = expected_writes + 1;

        dut.inspect_word(16'h0004, inspected_data, inspected_valid);
        if (!inspected_valid || inspected_data !== 32'hcafebabe) begin
            $fatal(1, "Successful write did not update reference memory");
        end

        run_transaction(1'b0, 16'h0004, 32'b0, 1'b0,
            32'hcafebabe, 0, 0);
        expected_requests = expected_requests + 1;
        expected_responses = expected_responses + 1;
        expected_reads = expected_reads + 1;

        run_transaction(1'b1, 16'h0008, 32'hdeadbeef, 1'b1,
            32'b0, 0, 1);
        expected_requests = expected_requests + 1;
        expected_responses = expected_responses + 1;
        expected_errors = expected_errors + 1;
        dut.inspect_word(16'h0008, inspected_data, inspected_valid);
        if (!inspected_valid || inspected_data !== reference_memory[2]) begin
            $fatal(1, "Failed write modified reference memory");
        end

        run_transaction(1'b0, 16'h000c, 32'b0, 1'b1,
            32'hffffffff, 0, 0);
        expected_requests = expected_requests + 1;
        expected_responses = expected_responses + 1;
        expected_errors = expected_errors + 1;

        for (transaction_index = 0;
             transaction_index < RANDOM_TRANSACTIONS;
             transaction_index = transaction_index + 1) begin
            selected_word = $urandom_range(0, MEMORY_WORDS-1);
            selected_write = $urandom_range(0, 1);
            selected_error = ($urandom_range(0, 9) == 0);
            selected_data = $urandom;
            request_stall = $urandom_range(0, 3);
            response_stall = $urandom_range(0, 3);

            run_transaction(
                selected_write,
                selected_word << 2,
                selected_data,
                selected_error,
                selected_write ? 32'b0 :
                    reference_memory[selected_word],
                request_stall,
                response_stall
            );

            expected_requests = expected_requests + 1;
            expected_responses = expected_responses + 1;
            if (selected_error) begin
                expected_errors = expected_errors + 1;
            end else if (selected_write) begin
                reference_memory[selected_word] = selected_data;
                expected_writes = expected_writes + 1;
            end else begin
                expected_reads = expected_reads + 1;
            end
        end

        if (mismatch_count != 0) begin
            $fatal(1, "Unexpected scoreboard mismatches: %0d",
                mismatch_count);
        end
        if (request_count != expected_requests ||
            response_count != expected_responses ||
            read_check_count != expected_reads ||
            write_commit_count != expected_writes ||
            error_response_count != expected_errors) begin
            $fatal(1,
                "Counter mismatch req=%0d/%0d resp=%0d/%0d read=%0d/%0d write=%0d/%0d error=%0d/%0d",
                request_count, expected_requests,
                response_count, expected_responses,
                read_check_count, expected_reads,
                write_commit_count, expected_writes,
                error_response_count, expected_errors);
        end

        test_violation_detection();

        $display(
            "TEST_PASS tb_scoreboard seed=%0d transactions=%0d reads=%0d writes=%0d errors=%0d",
            seed, response_count, read_check_count,
            write_commit_count, error_response_count);
        $finish;
    end

endmodule
