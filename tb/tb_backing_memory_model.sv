`timescale 1ns/1ps

module tb_backing_memory_model;

    localparam ADDR_WIDTH           = 16;
    localparam MEMORY_LINES         = 64;
    localparam MIN_RESPONSE_LATENCY = 1;
    localparam MAX_RESPONSE_LATENCY = 4;
    localparam MAX_REQUEST_STALL    = 2;
    localparam RANDOM_TRANSACTIONS  = 300;

    reg                   clk;
    reg                   reset_n;
    reg                   mem_req_valid;
    wire                  mem_req_ready;
    reg                   mem_req_write;
    reg  [ADDR_WIDTH-1:0] mem_req_addr;
    reg  [255:0]          mem_req_wdata;
    wire                  mem_resp_valid;
    reg                   mem_resp_ready;
    wire [255:0]          mem_resp_rdata;
    wire                  mem_resp_error;
    reg                   inject_error;
    reg  [31:0]           random_seed;

    reg [255:0] ref_memory [0:MEMORY_LINES-1];
    reg [MAX_REQUEST_STALL:0] request_wait_seen;
    reg [MAX_RESPONSE_LATENCY:0] response_latency_seen;

    integer seed;
    integer random_state;
    integer ignored_random;
    integer line_index;
    integer word_index;
    integer transaction_index;
    integer random_line;
    integer random_hold_cycles;
    integer random_write;
    integer random_error;
    integer transaction_count;
    integer error_count;
    integer write_count;
    integer read_count;
    integer reset_abort_count;
    reg [255:0] random_line_data;
    reg [255:0] inspected_line;
    reg [1023:0] vcd_path;

    backing_memory_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEMORY_LINES(MEMORY_LINES),
        .MIN_RESPONSE_LATENCY(MIN_RESPONSE_LATENCY),
        .MAX_RESPONSE_LATENCY(MAX_RESPONSE_LATENCY),
        .MAX_REQUEST_STALL(MAX_REQUEST_STALL)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_ready(mem_resp_ready),
        .mem_resp_rdata(mem_resp_rdata),
        .mem_resp_error(mem_resp_error),
        .inject_error(inject_error),
        .random_seed(random_seed)
    );

    always #5 clk = ~clk;

    function [255:0] make_initial_line;
        input integer selected_line;
        integer selected_word;
        begin
            make_initial_line = 256'b0;
            for (selected_word = 0; selected_word < 8;
                 selected_word = selected_word + 1) begin
                make_initial_line[(selected_word*32) +: 32]
                    = 32'h10000000 |
                    (selected_line << 8) | selected_word;
            end
        end
    endfunction

    function integer address_to_index;
        input [ADDR_WIDTH-1:0] address_value;
        begin
            address_to_index = (address_value >> 5) % MEMORY_LINES;
        end
    endfunction

    task apply_reset;
        begin
            @(negedge clk);
            reset_n        = 1'b0;
            mem_req_valid  = 1'b0;
            mem_resp_ready = 1'b0;
            inject_error   = 1'b0;
            @(posedge clk);
            #1;
            if (mem_req_ready !== 1'b0 ||
                mem_resp_valid !== 1'b0) begin
                $fatal(1, "Protocol outputs active during reset");
            end
            @(posedge clk);
            #1;
            if (mem_resp_valid !== 1'b0) begin
                $fatal(1, "Response remained valid during repeated reset");
            end
            @(negedge clk);
            reset_n = 1'b1;
        end
    endtask

    task run_transaction;
        input                         request_write;
        input [ADDR_WIDTH-1:0]        request_addr;
        input [255:0]                 request_wdata;
        input                         request_error;
        input integer                 response_hold_cycles;
        integer                       request_wait;
        integer                       response_latency;
        integer                       hold_cycle;
        integer                       selected_index;
        reg                           request_accepted;
        reg                           response_transfer;
        reg [255:0]                   held_response_data;
        reg                           held_response_error;
        begin
            selected_index = address_to_index(request_addr);
            request_wait = 0;
            request_accepted = 1'b0;

            @(negedge clk);
            mem_req_valid = 1'b1;
            mem_req_write = request_write;
            mem_req_addr  = request_addr;
            mem_req_wdata = request_wdata;
            inject_error  = request_error;
            mem_resp_ready = 1'b0;

            while (!request_accepted) begin
                @(posedge clk);
                request_accepted = mem_req_valid && mem_req_ready;
                #1;
                if (!request_accepted) begin
                    request_wait = request_wait + 1;
                    if (mem_req_write !== request_write ||
                        mem_req_addr !== request_addr ||
                        mem_req_wdata !== request_wdata ||
                        inject_error !== request_error) begin
                        $fatal(1,
                            "Request fields changed during backpressure");
                    end
                    if (request_wait > MAX_REQUEST_STALL) begin
                        $fatal(1,
                            "Request stall exceeded bound: %0d",
                            request_wait);
                    end
                end
            end

            request_wait_seen[request_wait] = 1'b1;

            @(negedge clk);
            mem_req_valid = 1'b0;
            inject_error  = 1'b0;

            response_latency = 0;
            while (!mem_resp_valid) begin
                @(posedge clk);
                response_latency = response_latency + 1;
                #1;
                if (!mem_resp_valid && mem_req_ready) begin
                    $fatal(1,
                        "Model accepted another request while one was pending");
                end
                if (response_latency > MAX_RESPONSE_LATENCY) begin
                    $fatal(1,
                        "Response latency exceeded bound: %0d",
                        response_latency);
                end
            end

            if (response_latency < MIN_RESPONSE_LATENCY ||
                response_latency > MAX_RESPONSE_LATENCY) begin
                $fatal(1, "Response latency outside configured bounds");
            end
            response_latency_seen[response_latency] = 1'b1;

            held_response_data = mem_resp_rdata;
            held_response_error = mem_resp_error;

            if (mem_resp_error !== request_error) begin
                $fatal(1,
                    "Response error mismatch expected=%b actual=%b",
                    request_error, mem_resp_error);
            end
            if (!request_write && !request_error &&
                mem_resp_rdata !== ref_memory[selected_index]) begin
                $fatal(1,
                    "Read mismatch index=%0d expected=%h actual=%h",
                    selected_index, ref_memory[selected_index],
                    mem_resp_rdata);
            end

            for (hold_cycle = 0; hold_cycle < response_hold_cycles;
                 hold_cycle = hold_cycle + 1) begin
                @(posedge clk);
                #1;
                if (!mem_resp_valid ||
                    mem_resp_rdata !== held_response_data ||
                    mem_resp_error !== held_response_error) begin
                    $fatal(1,
                        "Response fields changed under backpressure");
                end
                if (mem_req_ready) begin
                    $fatal(1,
                        "Request ready asserted while response was pending");
                end
            end

            @(negedge clk);
            mem_resp_ready = 1'b1;
            @(posedge clk);
            response_transfer = mem_resp_valid && mem_resp_ready;
            #1;
            if (!response_transfer || mem_resp_valid) begin
                $fatal(1, "Response handshake did not complete");
            end
            @(negedge clk);
            mem_resp_ready = 1'b0;

            if (request_error) begin
                error_count = error_count + 1;
            end else if (request_write) begin
                ref_memory[selected_index] = request_wdata;
            end

            dut.inspect_line(request_addr, inspected_line);
            if (inspected_line !== ref_memory[selected_index]) begin
                $fatal(1,
                    "Backing memory mismatch after transaction index=%0d",
                    selected_index);
            end

            if (request_write) begin
                write_count = write_count + 1;
            end else begin
                read_count = read_count + 1;
            end
            transaction_count = transaction_count + 1;
        end
    endtask

    task abort_write_with_reset;
        input [ADDR_WIDTH-1:0] request_addr;
        input [255:0] request_wdata;
        integer selected_index;
        reg request_accepted;
        begin
            selected_index = address_to_index(request_addr);
            request_accepted = 1'b0;

            @(negedge clk);
            mem_req_valid = 1'b1;
            mem_req_write = 1'b1;
            mem_req_addr  = request_addr;
            mem_req_wdata = request_wdata;
            inject_error  = 1'b0;
            mem_resp_ready = 1'b0;

            while (!request_accepted) begin
                @(posedge clk);
                request_accepted = mem_req_valid && mem_req_ready;
                #1;
            end

            @(negedge clk);
            mem_req_valid = 1'b0;

            while (!mem_resp_valid) begin
                @(posedge clk);
                #1;
            end

            @(negedge clk);
            reset_n = 1'b0;
            @(posedge clk);
            #1;
            if (mem_resp_valid || mem_req_ready) begin
                $fatal(1, "Reset did not abort pending response");
            end

            dut.inspect_line(request_addr, inspected_line);
            if (inspected_line !== ref_memory[selected_index]) begin
                $fatal(1, "Reset-aborted write modified memory");
            end

            @(posedge clk);
            #1;
            @(negedge clk);
            reset_n = 1'b1;
            reset_abort_count = reset_abort_count + 1;
        end
    endtask

    initial begin
        clk                    = 1'b0;
        reset_n                = 1'b1;
        mem_req_valid          = 1'b0;
        mem_req_write          = 1'b0;
        mem_req_addr           = {ADDR_WIDTH{1'b0}};
        mem_req_wdata          = 256'b0;
        mem_resp_ready         = 1'b0;
        inject_error           = 1'b0;
        random_seed            = 32'h1;
        request_wait_seen      = {(MAX_REQUEST_STALL+1){1'b0}};
        response_latency_seen  = {(MAX_RESPONSE_LATENCY+1){1'b0}};
        transaction_count      = 0;
        error_count            = 0;
        write_count            = 0;
        read_count             = 0;
        reset_abort_count      = 0;

        if (!$value$plusargs("SEED=%d", seed)) begin
            seed = 1;
        end
        random_state = seed;
        ignored_random = $urandom(random_state);
        if (seed == 0) begin
            random_seed = 32'h1;
        end else begin
            random_seed = seed;
        end

        if ($value$plusargs("VCD=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(0, tb_backing_memory_model);
        end

        for (line_index = 0; line_index < MEMORY_LINES;
             line_index = line_index + 1) begin
            ref_memory[line_index] = make_initial_line(line_index);
            dut.preload_line(
                line_index << 5,
                ref_memory[line_index]
            );
        end

        apply_reset();

        run_transaction(
            1'b0, 16'h0000, 256'b0, 1'b0, 2
        );
        run_transaction(
            1'b1, 16'h0020, {8{32'hcafebabe}}, 1'b0, 3
        );
        run_transaction(
            1'b0, 16'h0020, 256'b0, 1'b0, 0
        );
        run_transaction(
            1'b0, 16'h0040, 256'b0, 1'b1, 1
        );
        run_transaction(
            1'b1, 16'h0060, {8{32'hdeadbeef}}, 1'b1, 2
        );
        run_transaction(
            1'b0, 16'h0060, 256'b0, 1'b0, 0
        );

        abort_write_with_reset(
            16'h0080, {8{32'h12345678}}
        );
        run_transaction(
            1'b0, 16'h0080, 256'b0, 1'b0, 0
        );

        for (transaction_index = 0;
             transaction_index < RANDOM_TRANSACTIONS;
             transaction_index = transaction_index + 1) begin
            random_line = $urandom_range(0, MEMORY_LINES-1);
            random_write = $urandom_range(0, 1);
            random_error = ($urandom_range(0, 7) == 0);
            random_hold_cycles = $urandom_range(0, 3);
            for (word_index = 0; word_index < 8;
                 word_index = word_index + 1) begin
                random_line_data[(word_index*32) +: 32] = $urandom;
            end

            run_transaction(
                random_write,
                random_line << 5,
                random_line_data,
                random_error,
                random_hold_cycles
            );
        end

        if (request_wait_seen !==
            {(MAX_REQUEST_STALL+1){1'b1}}) begin
            $fatal(1,
                "Request-stall coverage incomplete: %b",
                request_wait_seen);
        end
        for (line_index = MIN_RESPONSE_LATENCY;
             line_index <= MAX_RESPONSE_LATENCY;
             line_index = line_index + 1) begin
            if (!response_latency_seen[line_index]) begin
                $fatal(1,
                    "Response latency %0d was not observed",
                    line_index);
            end
        end
        if (read_count == 0 || write_count == 0 ||
            error_count == 0 || reset_abort_count == 0) begin
            $fatal(1,
                "Functional coverage incomplete reads=%0d writes=%0d errors=%0d aborts=%0d",
                read_count, write_count, error_count, reset_abort_count);
        end

        $display(
            "TEST_PASS tb_backing_memory_model seed=%0d transactions=%0d errors=%0d",
            seed, transaction_count, error_count
        );
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Simulation timeout");
    end

endmodule
