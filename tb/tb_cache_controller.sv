`timescale 1ns/1ps

module tb_cache_controller;

    localparam ADDR_WIDTH         = 16;
    localparam LINE_BYTES        = 32;
    localparam LINE_WIDTH        = 256;
    localparam WAYS              = 4;
    localparam SETS              = 4;
    localparam TAG_WIDTH         = 9;
    localparam SET_INDEX_WIDTH   = 2;
    localparam WORD_INDEX_WIDTH  = 3;
    localparam WORDS_PER_LINE    = 8;
    localparam MEMORY_LINES      = 64;
    localparam MEMORY_WORDS      = MEMORY_LINES * WORDS_PER_LINE;
    localparam RANDOM_REQUESTS   = 200;

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
    reg                   mem_req_ready;
    wire                  mem_req_write;
    wire [ADDR_WIDTH-1:0] mem_req_addr;
    wire [LINE_WIDTH-1:0] mem_req_wdata;
    reg                   mem_resp_valid;
    wire                  mem_resp_ready;
    reg  [LINE_WIDTH-1:0] mem_resp_rdata;
    reg                   mem_resp_error;

    wire                              tag_lookup_en;
    wire [SET_INDEX_WIDTH-1:0]        tag_lookup_set;
    reg  [WAYS*TAG_WIDTH-1:0]         tag_lookup_tags;
    reg  [WAYS-1:0]                   tag_lookup_valid;
    reg  [WAYS-1:0]                   tag_lookup_dirty;
    reg  [WAYS-1:0]                   tag_lookup_parity;
    wire                              tag_meta_write_en;
    wire [SET_INDEX_WIDTH-1:0]        tag_meta_write_set;
    wire [WAYS-1:0]                   tag_meta_write_way;
    wire [TAG_WIDTH-1:0]              tag_meta_write_tag;
    wire                              tag_meta_write_valid;
    wire                              tag_meta_write_dirty;
    wire                              tag_meta_write_parity;

    wire [TAG_WIDTH-1:0] compare_request_tag;
    reg  [WAYS-1:0]      compare_hit_vector;
    reg                  compare_hit_any;
    reg                  compare_hit_multiple;
    reg  [WAYS-1:0]      compare_parity_error_vector;
    reg                  compare_parity_error_any;

    wire [SET_INDEX_WIDTH-1:0] replacement_query_set;
    wire [WAYS-1:0]            replacement_query_valid;
    reg  [WAYS-1:0]            replacement_victim_way;
    wire                       replacement_update_en;
    wire [SET_INDEX_WIDTH-1:0] replacement_update_set;
    wire [WAYS-1:0]            replacement_update_way;

    wire                              data_read_en;
    wire [SET_INDEX_WIDTH-1:0]        data_read_set;
    wire [WAYS-1:0]                   data_read_way;
    wire [WORD_INDEX_WIDTH-1:0]       data_read_word;
    reg  [31:0]                       data_read_data;
    wire                              data_write_en;
    wire [SET_INDEX_WIDTH-1:0]        data_write_set;
    wire [WAYS-1:0]                   data_write_way;
    wire [WORD_INDEX_WIDTH-1:0]       data_write_word;
    wire [31:0]                       data_write_data;

    wire                        wb_begin_line;
    wire [ADDR_WIDTH-1:0]       wb_line_addr_in;
    wire                        wb_word_write_en;
    wire [WORD_INDEX_WIDTH-1:0] wb_word_write_index;
    wire [31:0]                 wb_word_write_data;
    wire                        wb_commit_line;
    wire                        wb_consume_line;
    reg                         wb_line_valid;
    reg  [ADDR_WIDTH-1:0]       wb_line_addr_out;
    reg  [LINE_WIDTH-1:0]       wb_line_data_out;

    wire                  scoreboard_pending;
    wire [31:0]           scoreboard_requests;
    wire [31:0]           scoreboard_responses;
    wire [31:0]           scoreboard_reads;
    wire [31:0]           scoreboard_writes;
    wire [31:0]           scoreboard_errors;
    wire [31:0]           scoreboard_mismatches;

    reg [TAG_WIDTH-1:0] mock_tag [0:SETS-1][0:WAYS-1];
    reg                 mock_valid [0:SETS-1][0:WAYS-1];
    reg                 mock_dirty [0:SETS-1][0:WAYS-1];
    reg                 mock_parity [0:SETS-1][0:WAYS-1];
    reg [31:0]          mock_data
        [0:SETS-1][0:WAYS-1][0:WORDS_PER_LINE-1];

    reg [LINE_WIDTH-1:0] lower_memory [0:MEMORY_LINES-1];
    reg [31:0] architectural_memory [0:MEMORY_WORDS-1];

    reg [WAYS-1:0] forced_victim_way;
    reg            force_multiple_hit;
    reg            inject_next_read_error;
    reg            inject_next_write_error;
    integer        configured_request_stall;
    integer        configured_response_latency;
    integer        memory_request_stall;
    integer        memory_response_countdown;
    reg            memory_busy;
    reg            memory_pending_write;
    reg            memory_pending_error;
    integer        memory_pending_index;
    reg [LINE_WIDTH-1:0] memory_pending_wdata;

    integer memory_read_count;
    integer memory_write_count;
    integer replacement_update_count;
    reg [WAYS-1:0] last_replacement_update_way;
    reg [SET_INDEX_WIDTH-1:0] last_replacement_update_set;
    reg [ADDR_WIDTH-1:0] last_writeback_addr;
    reg [LINE_WIDTH-1:0] last_writeback_data;

    reg held_mem_request;
    reg held_mem_write;
    reg [ADDR_WIDTH-1:0] held_mem_addr;
    reg [LINE_WIDTH-1:0] held_mem_wdata;

    integer seed;
    integer random_state;
    integer ignored_random;
    integer random_request;
    integer random_word_address;
    integer random_response_stall;
    reg     random_write;
    reg [31:0] random_wdata;
    integer model_set;
    integer model_way;
    integer compare_way;
    integer replacement_way;
    integer invariant_set;
    integer invariant_way;
    integer word_index;
    integer line_index;
    integer hit_count;
    integer selected_read_way;
    integer selected_write_way;
    reg invalid_found;
    reg parity_failed;
    reg [1023:0] vcd_path;

    cache_controller #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .LINE_WIDTH(LINE_WIDTH),
        .WAYS(WAYS),
        .TAG_WIDTH(TAG_WIDTH),
        .SET_INDEX_WIDTH(SET_INDEX_WIDTH),
        .WORD_INDEX_WIDTH(WORD_INDEX_WIDTH),
        .TAG_PARITY_ENABLE(1)
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
        .mem_resp_error(mem_resp_error),
        .tag_lookup_en(tag_lookup_en),
        .tag_lookup_set(tag_lookup_set),
        .tag_lookup_tags(tag_lookup_tags),
        .tag_lookup_valid(tag_lookup_valid),
        .tag_lookup_dirty(tag_lookup_dirty),
        .tag_lookup_parity(tag_lookup_parity),
        .tag_meta_write_en(tag_meta_write_en),
        .tag_meta_write_set(tag_meta_write_set),
        .tag_meta_write_way(tag_meta_write_way),
        .tag_meta_write_tag(tag_meta_write_tag),
        .tag_meta_write_valid(tag_meta_write_valid),
        .tag_meta_write_dirty(tag_meta_write_dirty),
        .tag_meta_write_parity(tag_meta_write_parity),
        .compare_request_tag(compare_request_tag),
        .compare_hit_vector(compare_hit_vector),
        .compare_hit_any(compare_hit_any),
        .compare_hit_multiple(compare_hit_multiple),
        .compare_parity_error_vector(compare_parity_error_vector),
        .compare_parity_error_any(compare_parity_error_any),
        .replacement_query_set(replacement_query_set),
        .replacement_query_valid(replacement_query_valid),
        .replacement_victim_way(replacement_victim_way),
        .replacement_update_en(replacement_update_en),
        .replacement_update_set(replacement_update_set),
        .replacement_update_way(replacement_update_way),
        .data_read_en(data_read_en),
        .data_read_set(data_read_set),
        .data_read_way(data_read_way),
        .data_read_word(data_read_word),
        .data_read_data(data_read_data),
        .data_write_en(data_write_en),
        .data_write_set(data_write_set),
        .data_write_way(data_write_way),
        .data_write_word(data_write_word),
        .data_write_data(data_write_data),
        .wb_begin_line(wb_begin_line),
        .wb_line_addr_in(wb_line_addr_in),
        .wb_word_write_en(wb_word_write_en),
        .wb_word_write_index(wb_word_write_index),
        .wb_word_write_data(wb_word_write_data),
        .wb_commit_line(wb_commit_line),
        .wb_consume_line(wb_consume_line),
        .wb_line_valid(wb_line_valid),
        .wb_line_addr_out(wb_line_addr_out),
        .wb_line_data_out(wb_line_data_out)
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

    function integer address_set;
        input [ADDR_WIDTH-1:0] address_value;
        begin
            address_set = (address_value >> 5) & (SETS-1);
        end
    endfunction

    function [TAG_WIDTH-1:0] address_tag;
        input [ADDR_WIDTH-1:0] address_value;
        begin
            address_tag = address_value >> 7;
        end
    endfunction

    function integer address_word;
        input [ADDR_WIDTH-1:0] address_value;
        begin
            address_word = (address_value >> 2) & (WORDS_PER_LINE-1);
        end
    endfunction

    function integer address_line;
        input [ADDR_WIDTH-1:0] address_value;
        begin
            address_line = (address_value >> 5) % MEMORY_LINES;
        end
    endfunction

    function integer address_word_index;
        input [ADDR_WIDTH-1:0] address_value;
        begin
            address_word_index = address_value >> 2;
        end
    endfunction

    function [LINE_WIDTH-1:0] make_line;
        input integer line_number;
        integer make_word;
        reg [LINE_WIDTH-1:0] line_value;
        begin
            line_value = {LINE_WIDTH{1'b0}};
            for (make_word = 0; make_word < WORDS_PER_LINE;
                 make_word = make_word + 1) begin
                line_value[(make_word*32) +: 32] =
                    32'h40000000 | (line_number << 8) | make_word;
            end
            make_line = line_value;
        end
    endfunction

    function is_onehot;
        input [WAYS-1:0] value;
        begin
            is_onehot = (value != {WAYS{1'b0}}) &&
                ((value & (value - 1'b1)) == {WAYS{1'b0}});
        end
    endfunction

    always @(*) begin
        compare_hit_vector = {WAYS{1'b0}};
        compare_parity_error_vector = {WAYS{1'b0}};
        hit_count = 0;

        for (compare_way = 0; compare_way < WAYS;
             compare_way = compare_way + 1) begin
            parity_failed = tag_lookup_valid[compare_way] &&
                (^{tag_lookup_tags[(compare_way*TAG_WIDTH) +: TAG_WIDTH],
                   tag_lookup_parity[compare_way]});
            compare_parity_error_vector[compare_way] = parity_failed;
            if (tag_lookup_valid[compare_way] && !parity_failed &&
                tag_lookup_tags[(compare_way*TAG_WIDTH) +: TAG_WIDTH] ==
                compare_request_tag) begin
                compare_hit_vector[compare_way] = 1'b1;
                hit_count = hit_count + 1;
            end
        end

        if (force_multiple_hit) begin
            compare_hit_vector = 4'b0011;
            hit_count = 2;
        end

        compare_hit_any = |compare_hit_vector;
        compare_hit_multiple = hit_count > 1;
        compare_parity_error_any = |compare_parity_error_vector;
    end

    always @(*) begin
        replacement_victim_way = {WAYS{1'b0}};
        invalid_found = 1'b0;
        for (replacement_way = 0; replacement_way < WAYS;
             replacement_way = replacement_way + 1) begin
            if (!invalid_found &&
                !replacement_query_valid[replacement_way]) begin
                replacement_victim_way[replacement_way] = 1'b1;
                invalid_found = 1'b1;
            end
        end
        if (!invalid_found) begin
            replacement_victim_way = forced_victim_way;
        end
    end

    always @(*) begin
        mem_req_ready = reset_n && !memory_busy && !mem_resp_valid &&
            (memory_request_stall == 0);
    end

    always @(negedge clk) begin
        if (reset_n) begin
            if (tag_meta_write_en && !is_onehot(tag_meta_write_way)) begin
                $fatal(1, "Controller issued non-one-hot metadata write");
            end
            if (data_read_en && !is_onehot(data_read_way)) begin
                $fatal(1, "Controller issued non-one-hot data read");
            end
            if (data_write_en && !is_onehot(data_write_way)) begin
                $fatal(1, "Controller issued non-one-hot data write");
            end
            if (replacement_update_en &&
                !is_onehot(replacement_update_way)) begin
                $fatal(1, "Controller issued non-one-hot replacement update");
            end
            for (invariant_set = 0; invariant_set < SETS;
                 invariant_set = invariant_set + 1) begin
                for (invariant_way = 0; invariant_way < WAYS;
                     invariant_way = invariant_way + 1) begin
                    if (mock_dirty[invariant_set][invariant_way] &&
                        !mock_valid[invariant_set][invariant_way]) begin
                        $fatal(1,
                            "Dirty metadata exists on invalid line set=%0d way=%0d",
                            invariant_set,
                            invariant_way);
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            tag_lookup_tags <= {WAYS*TAG_WIDTH{1'b0}};
            tag_lookup_valid <= {WAYS{1'b0}};
            tag_lookup_dirty <= {WAYS{1'b0}};
            tag_lookup_parity <= {WAYS{1'b0}};
            data_read_data <= 32'b0;
            wb_line_valid <= 1'b0;
            memory_busy <= 1'b0;
            mem_resp_valid <= 1'b0;
            mem_resp_rdata <= {LINE_WIDTH{1'b0}};
            mem_resp_error <= 1'b0;
            memory_request_stall <= configured_request_stall;
            memory_response_countdown <= 0;
            memory_read_count <= 0;
            memory_write_count <= 0;
            replacement_update_count <= 0;
            held_mem_request <= 1'b0;

            for (model_set = 0; model_set < SETS;
                 model_set = model_set + 1) begin
                for (model_way = 0; model_way < WAYS;
                     model_way = model_way + 1) begin
                    mock_valid[model_set][model_way] <= 1'b0;
                    mock_dirty[model_set][model_way] <= 1'b0;
                end
            end
        end else begin
            if (tag_lookup_en) begin
                for (model_way = 0; model_way < WAYS;
                     model_way = model_way + 1) begin
                    tag_lookup_tags[
                        (model_way*TAG_WIDTH) +: TAG_WIDTH
                    ] <= mock_tag[tag_lookup_set][model_way];
                    tag_lookup_valid[model_way]
                        <= mock_valid[tag_lookup_set][model_way];
                    tag_lookup_dirty[model_way]
                        <= mock_dirty[tag_lookup_set][model_way];
                    tag_lookup_parity[model_way]
                        <= mock_parity[tag_lookup_set][model_way];
                end
            end

            if (tag_meta_write_en) begin
                for (model_way = 0; model_way < WAYS;
                     model_way = model_way + 1) begin
                    if (tag_meta_write_way[model_way]) begin
                        mock_tag[tag_meta_write_set][model_way]
                            <= tag_meta_write_tag;
                        mock_valid[tag_meta_write_set][model_way]
                            <= tag_meta_write_valid;
                        mock_dirty[tag_meta_write_set][model_way]
                            <= tag_meta_write_valid && tag_meta_write_dirty;
                        mock_parity[tag_meta_write_set][model_way]
                            <= tag_meta_write_parity;
                    end
                end
            end

            if (data_read_en) begin
                selected_read_way = 0;
                for (model_way = 0; model_way < WAYS;
                     model_way = model_way + 1) begin
                    if (data_read_way[model_way]) begin
                        selected_read_way = model_way;
                    end
                end
                data_read_data <= mock_data[
                    data_read_set
                ][selected_read_way][data_read_word];
            end

            if (data_write_en) begin
                selected_write_way = 0;
                for (model_way = 0; model_way < WAYS;
                     model_way = model_way + 1) begin
                    if (data_write_way[model_way]) begin
                        selected_write_way = model_way;
                    end
                end
                mock_data[data_write_set][selected_write_way][data_write_word]
                    <= data_write_data;
            end

            if (replacement_update_en) begin
                replacement_update_count <= replacement_update_count + 1;
                last_replacement_update_set <= replacement_update_set;
                last_replacement_update_way <= replacement_update_way;
            end

            if (wb_begin_line) begin
                wb_line_addr_out <= wb_line_addr_in;
                wb_line_valid <= 1'b0;
            end else if (wb_consume_line) begin
                wb_line_valid <= 1'b0;
            end else if (wb_commit_line) begin
                wb_line_valid <= 1'b1;
            end
            if (wb_word_write_en) begin
                wb_line_data_out[(wb_word_write_index*32) +: 32]
                    <= wb_word_write_data;
            end

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
                if (mem_req_ready) begin
                    held_mem_request <= 1'b0;
                end
            end else begin
                held_mem_request <= 1'b0;
            end

            if (mem_req_valid && memory_request_stall > 0 &&
                !memory_busy) begin
                memory_request_stall <= memory_request_stall - 1;
            end

            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_addr[4:0] != 5'b0) begin
                    $fatal(1, "Controller issued unaligned memory request");
                end
                memory_busy <= 1'b1;
                memory_pending_write <= mem_req_write;
                memory_pending_index <= address_line(mem_req_addr);
                memory_pending_wdata <= mem_req_wdata;
                memory_pending_error <=
                    (mem_req_write && inject_next_write_error) ||
                    (!mem_req_write && inject_next_read_error);
                memory_response_countdown <= configured_response_latency;
                if (mem_req_write) begin
                    memory_write_count <= memory_write_count + 1;
                    last_writeback_addr <= mem_req_addr;
                    last_writeback_data <= mem_req_wdata;
                    inject_next_write_error <= 1'b0;
                end else begin
                    memory_read_count <= memory_read_count + 1;
                    inject_next_read_error <= 1'b0;
                end
            end else if (memory_busy && !mem_resp_valid) begin
                if (memory_response_countdown > 1) begin
                    memory_response_countdown
                        <= memory_response_countdown - 1;
                end else begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_error <= memory_pending_error;
                    if (memory_pending_write || memory_pending_error) begin
                        mem_resp_rdata <= {LINE_WIDTH{1'b0}};
                    end else begin
                        mem_resp_rdata <= lower_memory[memory_pending_index];
                    end
                end
            end

            if (mem_resp_valid && mem_resp_ready) begin
                if (memory_pending_write && !mem_resp_error) begin
                    lower_memory[memory_pending_index]
                        <= memory_pending_wdata;
                end
                mem_resp_valid <= 1'b0;
                mem_resp_error <= 1'b0;
                memory_busy <= 1'b0;
                memory_request_stall <= configured_request_stall;
            end
        end
    end

    task set_memory_timing;
        input integer request_stall_cycles;
        input integer response_latency_cycles;
        begin
            configured_request_stall = request_stall_cycles;
            configured_response_latency = response_latency_cycles;
            if (!memory_busy && !mem_resp_valid) begin
                memory_request_stall = request_stall_cycles;
            end
        end
    endtask

    task apply_reset;
        begin
            @(negedge clk);
            reset_n = 1'b0;
            req_valid = 1'b0;
            resp_ready = 1'b0;
            repeat (2) @(posedge clk);
            #1;
            if (resp_valid || mem_req_valid || !req_ready) begin
                $fatal(1, "Controller reset outputs are invalid");
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
                $fatal(1, "Reset failed to abort pending controller request");
            end
            @(negedge clk);
            reset_n = 1'b1;
        end
    endtask

    task run_request;
        input                  request_write_value;
        input [ADDR_WIDTH-1:0] request_address_value;
        input [31:0]           request_data_value;
        input [31:0]           expected_read_data;
        input                  expected_tag_error;
        input                  expected_fatal_error;
        input integer          response_stall_cycles;
        integer                timeout_cycles;
        integer                stall_cycle;
        reg [31:0]             held_response_data;
        reg [1:0]              held_response_errors;
        begin
            if (request_address_value[1:0] != 2'b00) begin
                $fatal(1, "Test attempted unaligned processor request");
            end

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
                    $fatal(1, "req_ready asserted while request was pending");
                end
                timeout_cycles = timeout_cycles + 1;
                if (timeout_cycles > 300) begin
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
                    resp_tag_parity_err, expected_tag_error,
                    resp_fatal_err, expected_fatal_error);
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

            held_response_data = resp_rdata;
            held_response_errors = {
                resp_fatal_err,
                resp_tag_parity_err
            };
            for (stall_cycle = 0; stall_cycle < response_stall_cycles;
                 stall_cycle = stall_cycle + 1) begin
                @(posedge clk);
                #1;
                if (!resp_valid || resp_rdata !== held_response_data ||
                    {resp_fatal_err, resp_tag_parity_err} !==
                    held_response_errors) begin
                    $fatal(1, "Response changed under backpressure");
                end
            end

            @(negedge clk);
            resp_ready = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            resp_ready = 1'b0;

            if (!expected_tag_error && !expected_fatal_error &&
                request_write_value) begin
                architectural_memory[
                    address_word_index(request_address_value)
                ] = request_data_value;
            end
        end
    endtask

    task expect_way;
        input [ADDR_WIDTH-1:0] address_value;
        input integer          expected_way;
        input                  expected_valid;
        input                  expected_dirty;
        begin
            if (mock_tag[address_set(address_value)][expected_way] !==
                    address_tag(address_value) ||
                mock_valid[address_set(address_value)][expected_way] !==
                    expected_valid ||
                mock_dirty[address_set(address_value)][expected_way] !==
                    expected_dirty) begin
                $fatal(1,
                    "Metadata mismatch addr=%h way=%0d tag=%h/%h valid=%b/%b dirty=%b/%b",
                    address_value, expected_way,
                    mock_tag[address_set(address_value)][expected_way],
                    address_tag(address_value),
                    mock_valid[address_set(address_value)][expected_way],
                    expected_valid,
                    mock_dirty[address_set(address_value)][expected_way],
                    expected_dirty);
            end
        end
    endtask

    initial begin
        #1000000;
        $fatal(1, "Timeout waiting for controller test completion");
    end

    initial begin
        clk = 1'b0;
        reset_n = 1'b1;
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr = {ADDR_WIDTH{1'b0}};
        req_wdata = 32'b0;
        resp_ready = 1'b0;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = {LINE_WIDTH{1'b0}};
        mem_resp_error = 1'b0;
        wb_line_valid = 1'b0;
        wb_line_addr_out = {ADDR_WIDTH{1'b0}};
        wb_line_data_out = {LINE_WIDTH{1'b0}};
        forced_victim_way = 4'b0001;
        force_multiple_hit = 1'b0;
        inject_next_read_error = 1'b0;
        inject_next_write_error = 1'b0;
        configured_request_stall = 0;
        configured_response_latency = 1;
        memory_request_stall = 0;
        memory_response_countdown = 0;
        memory_busy = 1'b0;
        held_mem_request = 1'b0;

        if (!$value$plusargs("SEED=%d", seed)) begin
            seed = 1;
        end
        random_state = seed;
        ignored_random = $urandom(random_state);

        if ($value$plusargs("VCD=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(0, tb_cache_controller);
        end

        scoreboard.clear_reference();
        for (line_index = 0; line_index < MEMORY_LINES;
             line_index = line_index + 1) begin
            lower_memory[line_index] = make_line(line_index);
            for (word_index = 0; word_index < WORDS_PER_LINE;
                 word_index = word_index + 1) begin
                architectural_memory[
                    (line_index*WORDS_PER_LINE) + word_index
                ] = lower_memory[line_index][(word_index*32) +: 32];
                scoreboard.preload_word(
                    ((line_index*WORDS_PER_LINE) + word_index) << 2,
                    architectural_memory[
                        (line_index*WORDS_PER_LINE) + word_index
                    ]
                );
            end
        end

        apply_reset();
        abort_request_with_reset();
        set_memory_timing(3, 4);

        run_request(1'b0, 16'h000c, 32'b0,
            architectural_memory[address_word_index(16'h000c)],
            1'b0, 1'b0, 3);
        expect_way(16'h000c, 0, 1'b1, 1'b0);
        if (memory_read_count != 1 || memory_write_count != 0) begin
            $fatal(1, "Cold miss did not issue exactly one refill");
        end

        run_request(1'b0, 16'h000c, 32'b0,
            architectural_memory[address_word_index(16'h000c)],
            1'b0, 1'b0, 1);
        if (memory_read_count != 1) begin
            $fatal(1, "Read hit unexpectedly accessed lower memory");
        end

        run_request(1'b1, 16'h000c, 32'ha5a55a5a,
            32'b0, 1'b0, 1'b0, 2);
        expect_way(16'h000c, 0, 1'b1, 1'b1);
        run_request(1'b0, 16'h000c, 32'b0, 32'ha5a55a5a,
            1'b0, 1'b0, 0);

        run_request(1'b1, 16'h0088, 32'h11223344,
            32'b0, 1'b0, 1'b0, 1);
        expect_way(16'h0088, 1, 1'b1, 1'b1);
        run_request(1'b0, 16'h0104, 32'b0,
            architectural_memory[address_word_index(16'h0104)],
            1'b0, 1'b0, 0);
        expect_way(16'h0104, 2, 1'b1, 1'b0);
        run_request(1'b0, 16'h0180, 32'b0,
            architectural_memory[address_word_index(16'h0180)],
            1'b0, 1'b0, 0);
        expect_way(16'h0180, 3, 1'b1, 1'b0);

        forced_victim_way = 4'b0001;
        run_request(1'b0, 16'h020c, 32'b0,
            architectural_memory[address_word_index(16'h020c)],
            1'b0, 1'b0, 2);
        expect_way(16'h020c, 0, 1'b1, 1'b0);
        if (last_writeback_addr !== 16'h0000 ||
            last_writeback_data[3*32 +: 32] !== 32'ha5a55a5a ||
            lower_memory[address_line(16'h0000)][3*32 +: 32] !==
                32'ha5a55a5a) begin
            $fatal(1, "Dirty eviction wrote an incorrect victim line");
        end
        for (word_index = 0; word_index < WORDS_PER_LINE;
             word_index = word_index + 1) begin
            if (lower_memory[address_line(16'h0000)][
                    (word_index*32) +: 32
                ] !== architectural_memory[word_index]) begin
                $fatal(1,
                    "Dirty writeback word mismatch word=%0d expected=%h actual=%h",
                    word_index,
                    architectural_memory[word_index],
                    lower_memory[address_line(16'h0000)][
                        (word_index*32) +: 32
                    ]);
            end
        end

        inject_next_read_error = 1'b1;
        forced_victim_way = 4'b0001;
        run_request(1'b0, 16'h0280, 32'b0, 32'b0,
            1'b0, 1'b1, 2);
        expect_way(16'h0200, 0, 1'b1, 1'b0);

        run_request(1'b1, 16'h0204, 32'h55667788,
            32'b0, 1'b0, 1'b0, 0);
        inject_next_write_error = 1'b1;
        run_request(1'b0, 16'h0280, 32'b0, 32'b0,
            1'b0, 1'b1, 1);
        expect_way(16'h0200, 0, 1'b1, 1'b1);
        if (lower_memory[address_line(16'h0200)][1*32 +: 32] ===
            32'h55667788) begin
            $fatal(1, "Failed writeback modified lower memory");
        end

        run_request(1'b0, 16'h0280, 32'b0,
            architectural_memory[address_word_index(16'h0280)],
            1'b0, 1'b0, 0);
        expect_way(16'h0280, 0, 1'b1, 1'b0);
        if (lower_memory[address_line(16'h0200)][1*32 +: 32] !==
            32'h55667788) begin
            $fatal(1, "Successful retry did not write back dirty data");
        end

        mock_parity[0][2] = ~mock_parity[0][2];
        run_request(1'b0, 16'h0104, 32'b0, 32'b0,
            1'b1, 1'b0, 1);
        if (mock_valid[0][2] !== 1'b0 || mock_dirty[0][2] !== 1'b0) begin
            $fatal(1, "Clean tag parity failure was not invalidated");
        end

        mock_parity[0][1] = ~mock_parity[0][1];
        run_request(1'b0, 16'h0088, 32'b0, 32'b0,
            1'b1, 1'b1, 1);
        if (!mock_valid[0][1] || !mock_dirty[0][1]) begin
            $fatal(1, "Dirty tag parity failure was not preserved");
        end
        mock_parity[0][1] = ^mock_tag[0][1];

        force_multiple_hit = 1'b1;
        run_request(1'b0, 16'h0088, 32'b0, 32'b0,
            1'b0, 1'b1, 0);
        force_multiple_hit = 1'b0;

        set_memory_timing(2, 3);
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
                1'b0,
                random_response_stall
            );
        end

        if (scoreboard_mismatches != 0 || scoreboard_pending) begin
            $fatal(1,
                "Architectural scoreboard failed mismatches=%0d pending=%b",
                scoreboard_mismatches,
                scoreboard_pending);
        end
        if (memory_read_count == 0 || memory_write_count == 0 ||
            replacement_update_count == 0) begin
            $fatal(1, "Required controller paths were not exercised");
        end

        $display(
            "TEST_PASS tb_cache_controller seed=%0d requests=%0d reads=%0d writes=%0d errors=%0d mem_reads=%0d mem_writes=%0d",
            seed,
            scoreboard_requests,
            scoreboard_reads,
            scoreboard_writes,
            scoreboard_errors,
            memory_read_count,
            memory_write_count);
        $finish;
    end

endmodule
