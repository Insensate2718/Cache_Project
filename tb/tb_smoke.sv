`timescale 1ns/1ps

module tb_smoke #(
    parameter WAYS              = 4,
    parameter TAG_PARITY_ENABLE = 1,
    parameter CACHE_BYTES       = 4 * WAYS * 32,
    parameter MEMORY_LINES      = 64
);

    localparam ADDR_WIDTH      = 16;
    localparam LINE_BYTES      = 32;
    localparam SETS            = CACHE_BYTES / (WAYS * LINE_BYTES);
    localparam WORDS_PER_LINE  = 8;
    localparam MEMORY_WORDS    = MEMORY_LINES * WORDS_PER_LINE;
    localparam RANDOM_REQUESTS = 300;
    localparam CACHE_ENTRIES   = SETS * WAYS;

    reg clk;
    reg reset_n;

    reg                   req_valid;
    wire                  req_ready;
    reg                   req_write;
    reg  [ADDR_WIDTH-1:0] req_addr;
    reg  [31:0]           req_wdata;
    wire                  resp_valid;
    reg                   resp_ready;
    wire [31:0]           resp_rdata;
    wire                  resp_tag_parity_err;
    wire                  resp_fatal_err;

    wire                  mem_req_valid;
    wire                  mem_req_ready;
    wire                  mem_req_write;
    wire [ADDR_WIDTH-1:0] mem_req_addr;
    wire [255:0]          mem_req_wdata;
    wire                  mem_resp_valid;
    wire                  mem_resp_ready;
    wire [255:0]          mem_resp_rdata;
    wire                  mem_resp_error;

    reg                   inject_error;
    reg  [31:0]           memory_seed;

    wire                  scoreboard_pending;
    wire [31:0]           scoreboard_requests;
    wire [31:0]           scoreboard_responses;
    wire [31:0]           scoreboard_reads;
    wire [31:0]           scoreboard_writes;
    wire [31:0]           scoreboard_errors;
    wire [31:0]           scoreboard_mismatches;

    reg [31:0] architectural_memory [0:MEMORY_WORDS-1];
    reg [255:0] inspected_line;
    reg [255:0] initialization_line;

    integer seed;
    integer random_state;
    integer ignored_random;
    integer line_index;
    integer word_index;
    integer metadata_entry;
    integer random_request;
    integer random_word_address;
    integer random_response_stall;
    integer memory_read_count;
    integer memory_write_count;
    integer reads_before;
    integer writes_before;
    integer conflict_index;
    reg     random_write;
    reg [31:0] random_wdata;
    reg [1023:0] vcd_path;

    reg                   held_mem_request;
    reg                   held_mem_write;
    reg  [ADDR_WIDTH-1:0] held_mem_addr;
    reg  [255:0]          held_mem_wdata;
    reg                   held_response;
    reg  [31:0]           held_resp_rdata;
    reg  [1:0]            held_resp_errors;

    cache_top #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .CACHE_BYTES(CACHE_BYTES),
        .LINE_BYTES(LINE_BYTES),
        .WAYS(WAYS),
        .TAG_PARITY_ENABLE(TAG_PARITY_ENABLE)
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
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_ready(mem_resp_ready),
        .mem_resp_rdata(mem_resp_rdata),
        .mem_resp_error(mem_resp_error)
    );

    backing_memory_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEMORY_LINES(MEMORY_LINES),
        .MIN_RESPONSE_LATENCY(1),
        .MAX_RESPONSE_LATENCY(5),
        .MAX_REQUEST_STALL(3)
    ) memory_model (
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
        .random_seed(memory_seed)
    );

    cache_scoreboard #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEMORY_WORDS(MEMORY_WORDS),
        .BASE_ADDR(0),
        .FAIL_FAST(1)
    ) scoreboard (
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
        .pending_request(scoreboard_pending),
        .request_count(scoreboard_requests),
        .response_count(scoreboard_responses),
        .read_check_count(scoreboard_reads),
        .write_commit_count(scoreboard_writes),
        .error_response_count(scoreboard_errors),
        .mismatch_count(scoreboard_mismatches)
    );

    always #5 clk = ~clk;

    function integer address_word_index;
        input [ADDR_WIDTH-1:0] address_value;
        begin
            address_word_index = address_value >> 2;
        end
    endfunction

    function [255:0] make_line;
        input integer line_number;
        integer make_word;
        reg [255:0] line_value;
        begin
            line_value = 256'b0;
            for (make_word = 0; make_word < WORDS_PER_LINE;
                 make_word = make_word + 1) begin
                line_value[(make_word*32) +: 32] =
                    32'h60000000 | (line_number << 8) | make_word;
            end
            make_line = line_value;
        end
    endfunction

    function [ADDR_WIDTH-1:0] conflict_address;
        input integer tag_number;
        input integer set_number;
        input integer byte_offset;
        begin
            conflict_address =
                (tag_number * SETS * LINE_BYTES) +
                (set_number * LINE_BYTES) + byte_offset;
        end
    endfunction

    always @(posedge clk) begin
        if (!reset_n) begin
            memory_read_count <= 0;
            memory_write_count <= 0;
            held_mem_request <= 1'b0;
            held_response <= 1'b0;
        end else begin
            if (mem_req_valid) begin
                if (!held_mem_request) begin
                    held_mem_request <= 1'b1;
                    held_mem_write <= mem_req_write;
                    held_mem_addr <= mem_req_addr;
                    held_mem_wdata <= mem_req_wdata;
                end else if (mem_req_write !== held_mem_write ||
                             mem_req_addr !== held_mem_addr ||
                             mem_req_wdata !== held_mem_wdata) begin
                    $fatal(1, "Memory request changed under backpressure");
                end

                if (mem_req_addr[4:0] != 5'b0) begin
                    $fatal(1, "Cache issued an unaligned memory request");
                end

                if (mem_req_ready) begin
                    held_mem_request <= 1'b0;
                    if (mem_req_write) begin
                        memory_write_count <= memory_write_count + 1;
                    end else begin
                        memory_read_count <= memory_read_count + 1;
                    end
                end
            end else begin
                held_mem_request <= 1'b0;
            end

            if (resp_valid && !resp_ready) begin
                if (!held_response) begin
                    held_response <= 1'b1;
                    held_resp_rdata <= resp_rdata;
                    held_resp_errors <= {
                        resp_fatal_err,
                        resp_tag_parity_err
                    };
                end else if (resp_rdata !== held_resp_rdata ||
                    {resp_fatal_err, resp_tag_parity_err} !==
                    held_resp_errors) begin
                    $fatal(1, "Processor response changed under backpressure");
                end
            end else begin
                held_response <= 1'b0;
            end
        end
    end

    always @(negedge clk) begin
        if (reset_n) begin
            for (metadata_entry = 0; metadata_entry < CACHE_ENTRIES;
                 metadata_entry = metadata_entry + 1) begin
                if (dut.tag_array_inst.dirty_mem[metadata_entry] &&
                    !dut.tag_array_inst.valid_mem[metadata_entry]) begin
                    $fatal(1,
                        "Integrated cache contains dirty invalid entry=%0d",
                        metadata_entry);
                end
            end
        end
    end

    task apply_reset;
        begin
            @(negedge clk);
            reset_n = 1'b0;
            req_valid = 1'b0;
            resp_ready = 1'b0;
            repeat (2) @(posedge clk);
            #1;
            if (resp_valid || mem_req_valid || !req_ready) begin
                $fatal(1, "Integrated cache reset outputs are invalid");
            end
            @(negedge clk);
            reset_n = 1'b1;
        end
    endtask

    task abort_request_with_reset;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b0;
            req_addr = 16'h0000;
            req_wdata = 32'b0;
            while (!req_ready) begin
                @(posedge clk);
                #1;
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            req_valid = 1'b0;
            reset_n = 1'b0;
            @(posedge clk);
            #1;
            if (resp_valid || mem_req_valid || !req_ready ||
                scoreboard_pending) begin
                $fatal(1, "Reset failed to abort integrated request");
            end
            @(negedge clk);
            reset_n = 1'b1;
        end
    endtask

    task run_request_with_flags;
        input                  request_write_value;
        input [ADDR_WIDTH-1:0] request_address_value;
        input [31:0]           request_data_value;
        input [31:0]           expected_read_data;
        input                  expected_tag_error;
        input                  expected_fatal_error;
        input integer          response_stall_cycles;
        integer                timeout_cycles;
        integer                stall_cycle;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = request_write_value;
            req_addr = request_address_value;
            req_wdata = request_data_value;
            resp_ready = 1'b0;

            timeout_cycles = 0;
            while (!req_ready) begin
                @(posedge clk);
                #1;
                timeout_cycles = timeout_cycles + 1;
                if (timeout_cycles > 20) begin
                    $fatal(1, "Timeout waiting for req_ready");
                end
            end
            @(posedge clk);
            #1;
            @(negedge clk);
            req_valid = 1'b0;

            timeout_cycles = 0;
            while (!resp_valid) begin
                @(posedge clk);
                #1;
                if (req_ready) begin
                    $fatal(1, "req_ready asserted with an outstanding request");
                end
                timeout_cycles = timeout_cycles + 1;
                if (timeout_cycles > 400) begin
                    $fatal(1,
                        "Timeout waiting for response addr=%h",
                        request_address_value);
                end
            end

            if (resp_tag_parity_err !== expected_tag_error ||
                resp_fatal_err !== expected_fatal_error) begin
                $fatal(1,
                    "Response flags mismatch addr=%h tag=%b/%b fatal=%b/%b",
                    request_address_value,
                    resp_tag_parity_err,
                    expected_tag_error,
                    resp_fatal_err,
                    expected_fatal_error);
            end
            if (!request_write_value && !expected_tag_error &&
                !expected_fatal_error &&
                resp_rdata !== expected_read_data) begin
                $fatal(1,
                    "Read mismatch addr=%h expected=%h actual=%h",
                    request_address_value,
                    expected_read_data,
                    resp_rdata);
            end

            for (stall_cycle = 0; stall_cycle < response_stall_cycles;
                 stall_cycle = stall_cycle + 1) begin
                @(posedge clk);
                #1;
                if (!resp_valid) begin
                    $fatal(1, "Response dropped under backpressure");
                end
            end

            @(negedge clk);
            resp_ready = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            resp_ready = 1'b0;

            if (request_write_value && !expected_tag_error &&
                !expected_fatal_error) begin
                architectural_memory[
                    address_word_index(request_address_value)
                ] = request_data_value;
            end
        end
    endtask

    task run_request;
        input                  request_write_value;
        input [ADDR_WIDTH-1:0] request_address_value;
        input [31:0]           request_data_value;
        input [31:0]           expected_read_data;
        input                  expected_fatal_error;
        input integer          response_stall_cycles;
        begin
            run_request_with_flags(
                request_write_value,
                request_address_value,
                request_data_value,
                expected_read_data,
                1'b0,
                expected_fatal_error,
                response_stall_cycles
            );
        end
    endtask

    task flip_tag_parity;
        input integer set_number;
        input integer way_number;
        integer       entry_number;
        begin
            entry_number = (set_number * WAYS) + way_number;
            @(negedge clk);
            dut.tag_array_inst.parity_mem[entry_number] =
                ~dut.tag_array_inst.parity_mem[entry_number];
            #1;
        end
    endtask

    task run_request_with_memory_error;
        input                  request_write_value;
        input [ADDR_WIDTH-1:0] request_address_value;
        input [31:0]           request_data_value;
        begin
            inject_error = 1'b1;
            fork
                begin
                    wait (mem_req_valid && mem_req_ready);
                    @(posedge clk);
                    #1;
                    inject_error = 1'b0;
                end
                begin
                    run_request(
                        request_write_value,
                        request_address_value,
                        request_data_value,
                        32'b0,
                        1'b1,
                        2
                    );
                end
            join
        end
    endtask

    initial begin
        #2000000;
        $fatal(1, "Timeout waiting for integrated smoke test completion");
    end

    initial begin
        clk = 1'b0;
        reset_n = 1'b1;
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr = {ADDR_WIDTH{1'b0}};
        req_wdata = 32'b0;
        resp_ready = 1'b0;
        inject_error = 1'b0;
        memory_seed = 32'h1;
        held_mem_request = 1'b0;
        held_response = 1'b0;

        if (!$value$plusargs("SEED=%d", seed)) begin
            seed = 1;
        end
        random_state = seed;
        ignored_random = $urandom(random_state);
        if (seed == 0) begin
            memory_seed = 32'h1;
        end else begin
            memory_seed = seed;
        end

        if ($value$plusargs("VCD=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(0, tb_smoke);
        end

        if (SETS < 3) begin
            $fatal(1, "tb_smoke requires at least three cache sets");
        end
        if (MEMORY_LINES * LINE_BYTES < CACHE_BYTES * 2) begin
            $fatal(1,
                "tb_smoke backing memory must be at least twice cache size");
        end

        scoreboard.clear_reference();
        for (line_index = 0; line_index < MEMORY_LINES;
             line_index = line_index + 1) begin
            initialization_line = make_line(line_index);
            memory_model.preload_line(
                line_index << 5,
                initialization_line
            );
            for (word_index = 0; word_index < WORDS_PER_LINE;
                 word_index = word_index + 1) begin
                architectural_memory[
                    (line_index*WORDS_PER_LINE) + word_index
                ] = initialization_line[(word_index*32) +: 32];
                scoreboard.preload_word(
                    ((line_index*WORDS_PER_LINE) + word_index) << 2,
                    architectural_memory[
                        (line_index*WORDS_PER_LINE) + word_index
                    ]
                );
            end
        end

        apply_reset();
        apply_reset();
        abort_request_with_reset();

        run_request(1'b0, 16'h000c, 32'b0,
            architectural_memory[address_word_index(16'h000c)],
            1'b0, 3);
        if (memory_read_count != 1 || memory_write_count != 0) begin
            $fatal(1, "Cold miss did not issue exactly one refill");
        end

        run_request(1'b0, 16'h000c, 32'b0,
            architectural_memory[address_word_index(16'h000c)],
            1'b0, 1);
        if (memory_read_count != 1) begin
            $fatal(1, "Read hit accessed lower memory");
        end

        if (!dut.tag_array_inst.valid_mem[0] ||
            dut.tag_array_inst.dirty_mem[0]) begin
            $fatal(1, "Clean tag-parity setup metadata was incorrect");
        end
        reads_before = memory_read_count;
        writes_before = memory_write_count;
        flip_tag_parity(0, 0);
        if (TAG_PARITY_ENABLE != 0) begin
            run_request_with_flags(1'b0, 16'h000c, 32'b0, 32'b0,
                1'b1, 1'b0, 2);
        end else begin
            run_request(1'b0, 16'h000c, 32'b0,
                architectural_memory[address_word_index(16'h000c)],
                1'b0, 2);
        end
        if (memory_read_count != reads_before ||
            memory_write_count != writes_before) begin
            $fatal(1, "Clean tag-parity fault accessed lower memory");
        end
        if (TAG_PARITY_ENABLE != 0) begin
            if (dut.tag_array_inst.valid_mem[0] ||
                dut.tag_array_inst.dirty_mem[0]) begin
                $fatal(1, "Clean tag-parity fault was not invalidated");
            end
            run_request(1'b0, 16'h000c, 32'b0,
                architectural_memory[address_word_index(16'h000c)],
                1'b0, 0);
            if (memory_read_count != reads_before + 1) begin
                $fatal(1,
                    "Read after clean tag fault did not refill the line");
            end
        end else begin
            if (!dut.tag_array_inst.valid_mem[0] ||
                dut.tag_array_inst.dirty_mem[0]) begin
                $fatal(1,
                    "Parity-disabled clean line metadata changed");
            end
            flip_tag_parity(0, 0);
        end

        run_request(1'b1, 16'h000c, 32'ha5a55a5a,
            32'b0, 1'b0, 2);
        if (!dut.tag_array_inst.valid_mem[0] ||
            !dut.tag_array_inst.dirty_mem[0]) begin
            $fatal(1, "Dirty tag-parity setup metadata was incorrect");
        end
        reads_before = memory_read_count;
        writes_before = memory_write_count;
        flip_tag_parity(0, 0);
        if (TAG_PARITY_ENABLE != 0) begin
            run_request_with_flags(1'b0, 16'h000c, 32'b0, 32'b0,
                1'b1, 1'b1, 3);
        end else begin
            run_request(1'b0, 16'h000c, 32'b0, 32'ha5a55a5a,
                1'b0, 3);
        end
        if (memory_read_count != reads_before ||
            memory_write_count != writes_before) begin
            $fatal(1, "Dirty tag-parity fault accessed lower memory");
        end
        if (!dut.tag_array_inst.valid_mem[0] ||
            !dut.tag_array_inst.dirty_mem[0]) begin
            $fatal(1, "Dirty tag-parity fault did not preserve the line");
        end
        flip_tag_parity(0, 0);

        run_request(1'b0, 16'h000c, 32'b0,
            32'ha5a55a5a, 1'b0, 0);

        reads_before = memory_read_count;
        writes_before = memory_write_count;
        for (conflict_index = 0; conflict_index <= WAYS;
             conflict_index = conflict_index + 1) begin
            run_request(
                1'b0,
                conflict_address(conflict_index, 1, 0),
                32'b0,
                architectural_memory[address_word_index(
                    conflict_address(conflict_index, 1, 0))],
                1'b0,
                conflict_index % 2
            );
        end
        if (memory_read_count != reads_before + WAYS + 1 ||
            memory_write_count != writes_before) begin
            $fatal(1,
                "Real-set clean conflict sequence did not evict cleanly");
        end

        run_request(
            1'b0,
            conflict_address(0, 2, 12),
            32'b0,
            architectural_memory[address_word_index(
                conflict_address(0, 2, 12))],
            1'b0,
            0
        );
        run_request(
            1'b1,
            conflict_address(0, 2, 12),
            32'hd17e0000 | WAYS,
            32'b0,
            1'b0,
            1
        );
        for (conflict_index = 1; conflict_index < WAYS;
             conflict_index = conflict_index + 1) begin
            run_request(
                1'b0,
                conflict_address(conflict_index, 2, 0),
                32'b0,
                architectural_memory[address_word_index(
                    conflict_address(conflict_index, 2, 0))],
                1'b0,
                0
            );
        end
        reads_before = memory_read_count;
        writes_before = memory_write_count;
        run_request(
            1'b0,
            conflict_address(WAYS, 2, 0),
            32'b0,
            architectural_memory[address_word_index(
                conflict_address(WAYS, 2, 0))],
            1'b0,
            2
        );
        if (memory_read_count != reads_before + 1 ||
            memory_write_count != writes_before + 1) begin
            $fatal(1,
                "Real-set dirty conflict did not write back then refill");
        end
        memory_model.inspect_line(
            conflict_address(0, 2, 0),
            inspected_line
        );
        if (inspected_line[3*32 +: 32] !== (32'hd17e0000 | WAYS)) begin
            $fatal(1, "Real-set dirty writeback data mismatch");
        end

        if (WAYS == 4) begin
            run_request(1'b1, conflict_address(1, 0, 8), 32'h11223344,
                32'b0, 1'b0, 1);
            run_request(1'b0, conflict_address(2, 0, 4), 32'b0,
                architectural_memory[address_word_index(
                    conflict_address(2, 0, 4))],
                1'b0, 0);
            run_request(1'b0, conflict_address(3, 0, 0), 32'b0,
                architectural_memory[address_word_index(
                    conflict_address(3, 0, 0))],
                1'b0, 0);

            reads_before = memory_read_count;
            writes_before = memory_write_count;
            run_request(1'b0, conflict_address(4, 0, 12), 32'b0,
                architectural_memory[address_word_index(
                    conflict_address(4, 0, 12))],
                1'b0, 2);
            if (memory_read_count != reads_before + 1 ||
                memory_write_count != writes_before + 1) begin
                $fatal(1,
                    "Dirty eviction did not issue writeback then refill");
            end
            memory_model.inspect_line(
                conflict_address(0, 0, 0),
                inspected_line
            );
            for (word_index = 0; word_index < WORDS_PER_LINE;
                 word_index = word_index + 1) begin
                if (inspected_line[(word_index*32) +: 32] !==
                    architectural_memory[word_index]) begin
                    $fatal(1,
                        "Integrated dirty writeback mismatch word=%0d",
                        word_index);
                end
            end

            reads_before = memory_read_count;
            writes_before = memory_write_count;
            run_request_with_memory_error(
                1'b0,
                conflict_address(5, 0, 0),
                32'b0
            );
            if (memory_read_count != reads_before + 1 ||
                memory_write_count != writes_before) begin
                $fatal(1, "Refill error issued unexpected memory traffic");
            end

            run_request(1'b1, conflict_address(2, 0, 4), 32'h55667788,
                32'b0, 1'b0, 0);
            if (memory_read_count != reads_before + 1) begin
                $fatal(1, "Failed refill overwrote its clean victim");
            end

            reads_before = memory_read_count;
            writes_before = memory_write_count;
            run_request_with_memory_error(
                1'b0,
                conflict_address(6, 0, 0),
                32'b0
            );
            if (memory_write_count != writes_before + 1 ||
                memory_read_count != reads_before) begin
                $fatal(1, "Writeback error did not abort before refill");
            end
            memory_model.inspect_line(
                conflict_address(1, 0, 0),
                inspected_line
            );
            if (inspected_line[2*32 +: 32] === 32'h11223344) begin
                $fatal(1, "Failed writeback modified backing memory");
            end

            run_request(1'b0, conflict_address(6, 0, 0), 32'b0,
                architectural_memory[address_word_index(
                    conflict_address(6, 0, 0))],
                1'b0, 1);
            memory_model.inspect_line(
                conflict_address(1, 0, 0),
                inspected_line
            );
            if (inspected_line[2*32 +: 32] !== 32'h11223344) begin
                $fatal(1, "Writeback retry did not preserve dirty data");
            end
            run_request(1'b0, conflict_address(1, 0, 8), 32'b0,
                32'h11223344, 1'b0, 0);
        end

        for (random_request = 0; random_request < RANDOM_REQUESTS;
             random_request = random_request + 1) begin
            random_word_address = $urandom_range(0, MEMORY_WORDS-1);
            random_write = $urandom_range(0, 1);
            random_wdata = $urandom;
            random_response_stall = $urandom_range(0, 3);
            run_request(
                random_write,
                random_word_address << 2,
                random_wdata,
                architectural_memory[random_word_address],
                1'b0,
                random_response_stall
            );
        end

        if (scoreboard_mismatches != 0 || scoreboard_pending ||
            scoreboard_requests != scoreboard_responses) begin
            $fatal(1,
                "Integrated scoreboard failed req=%0d resp=%0d mismatches=%0d pending=%b",
                scoreboard_requests,
                scoreboard_responses,
                scoreboard_mismatches,
                scoreboard_pending);
        end
        if (memory_read_count == 0 || memory_write_count == 0) begin
            $fatal(1, "Integrated test did not exercise lower memory");
        end

        $display(
            "TEST_PASS tb_smoke seed=%0d ways=%0d tag_parity=%0d cache_bytes=%0d sets=%0d requests=%0d reads=%0d writes=%0d errors=%0d mem_reads=%0d mem_writes=%0d",
            seed,
            WAYS,
            TAG_PARITY_ENABLE,
            CACHE_BYTES,
            SETS,
            scoreboard_requests,
            scoreboard_reads,
            scoreboard_writes,
            scoreboard_errors,
            memory_read_count,
            memory_write_count);
        $finish;
    end

endmodule
