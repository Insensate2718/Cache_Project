`timescale 1ns/1ps

module tb_writeback_buffer;

    localparam ADDR_WIDTH       = 16;
    localparam WORDS_PER_LINE   = 8;
    localparam WORD_INDEX_WIDTH = 3;
    localparam RANDOM_LINES     = 100;

    reg                          clk;
    reg                          reset_n;
    reg                          begin_line;
    reg  [ADDR_WIDTH-1:0]        line_addr_in;
    reg                          word_write_en;
    reg  [WORD_INDEX_WIDTH-1:0]  word_write_index;
    reg  [31:0]                  word_write_data;
    reg                          commit_line;
    reg                          consume_line;
    wire                         line_valid;
    wire [ADDR_WIDTH-1:0]        line_addr_out;
    wire [255:0]                 line_data_out;

    reg                          ref_line_valid;
    reg [ADDR_WIDTH-1:0]         ref_line_addr;
    reg [255:0]                  ref_line_data;
    reg                          ref_addr_known;
    reg [WORDS_PER_LINE-1:0]     ref_word_known;
    reg [WORDS_PER_LINE-1:0]     current_line_words_written;

    reg [WORDS_PER_LINE-1:0]     word_write_coverage;
    integer                      begin_count;
    integer                      commit_count;
    integer                      consume_count;
    integer                      idle_count;
    integer                      final_word_commit_count;
    integer                      test_count;
    integer                      seed;
    integer                      random_state;
    integer                      ignored_random;
    integer                      line_number;
    integer                      word_number;
    integer                      check_word;
    integer                      start_word;
    integer                      step_choice;
    integer                      word_step;
    integer                      selected_word;
    integer                      idle_cycles;
    integer                      idle_number;
    integer                      commit_with_last_word;
    reg [ADDR_WIDTH-1:0]         random_addr;
    reg [31:0]                   random_word_data;
    reg [1023:0]                 vcd_path;

    writeback_buffer #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .WORD_INDEX_WIDTH(WORD_INDEX_WIDTH)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .begin_line(begin_line),
        .line_addr_in(line_addr_in),
        .word_write_en(word_write_en),
        .word_write_index(word_write_index),
        .word_write_data(word_write_data),
        .commit_line(commit_line),
        .consume_line(consume_line),
        .line_valid(line_valid),
        .line_addr_out(line_addr_out),
        .line_data_out(line_data_out)
    );

    always #5 clk = ~clk;

    task check_outputs;
        begin
            if (line_valid !== ref_line_valid) begin
                $fatal(1,
                    "line_valid mismatch expected=%b actual=%b",
                    ref_line_valid, line_valid);
            end

            if (ref_addr_known && line_addr_out !== ref_line_addr) begin
                $fatal(1,
                    "line address mismatch expected=%h actual=%h",
                    ref_line_addr, line_addr_out);
            end

            for (check_word = 0; check_word < WORDS_PER_LINE;
                 check_word = check_word + 1) begin
                if (ref_word_known[check_word] &&
                    line_data_out[(check_word*32) +: 32] !==
                    ref_line_data[(check_word*32) +: 32]) begin
                    $fatal(1,
                        "line word mismatch index=%0d expected=%h actual=%h",
                        check_word,
                        ref_line_data[(check_word*32) +: 32],
                        line_data_out[(check_word*32) +: 32]);
                end
            end

            test_count = test_count + 1;
        end
    endtask

    task apply_cycle;
        input                         reset_value;
        input                         begin_value;
        input [ADDR_WIDTH-1:0]        address_value;
        input                         write_value;
        input [WORD_INDEX_WIDTH-1:0]  write_index_value;
        input [31:0]                  write_data_value;
        input                         commit_value;
        input                         consume_value;
        begin
            @(negedge clk);
            reset_n          = reset_value;
            begin_line       = begin_value;
            line_addr_in     = address_value;
            word_write_en    = write_value;
            word_write_index = write_index_value;
            word_write_data  = write_data_value;
            commit_line      = commit_value;
            consume_line     = consume_value;

            @(posedge clk);
            #1;

            if (!reset_value) begin
                ref_line_valid = 1'b0;
            end else begin
                if (begin_value) begin
                    ref_line_addr  = address_value;
                    ref_addr_known = 1'b1;
                    ref_line_valid = 1'b0;
                    current_line_words_written
                        = {WORDS_PER_LINE{1'b0}};
                    begin_count = begin_count + 1;
                end else if (consume_value) begin
                    ref_line_valid = 1'b0;
                    consume_count = consume_count + 1;
                end else if (commit_value) begin
                    ref_line_valid = 1'b1;
                    commit_count = commit_count + 1;
                end

                if (write_value) begin
                    ref_line_data[(write_index_value*32) +: 32]
                        = write_data_value;
                    ref_word_known[write_index_value] = 1'b1;
                    current_line_words_written[write_index_value] = 1'b1;
                    word_write_coverage[write_index_value] = 1'b1;
                    if (commit_value && !begin_value && !consume_value) begin
                        final_word_commit_count
                            = final_word_commit_count + 1;
                    end
                end

                if (commit_value && !begin_value && !consume_value &&
                    current_line_words_written !==
                    {WORDS_PER_LINE{1'b1}}) begin
                    $fatal(1,
                        "Test attempted commit before all words were assembled: written=%b",
                        current_line_words_written);
                end

                if (!begin_value && !write_value &&
                    !commit_value && !consume_value) begin
                    idle_count = idle_count + 1;
                end
            end

            check_outputs();
        end
    endtask

    initial begin
        clk                     = 1'b0;
        reset_n                 = 1'b1;
        begin_line              = 1'b0;
        line_addr_in            = {ADDR_WIDTH{1'b0}};
        word_write_en           = 1'b0;
        word_write_index        = {WORD_INDEX_WIDTH{1'b0}};
        word_write_data         = 32'b0;
        commit_line             = 1'b0;
        consume_line            = 1'b0;
        ref_line_valid          = 1'b0;
        ref_line_addr           = {ADDR_WIDTH{1'b0}};
        ref_line_data           = 256'b0;
        ref_addr_known          = 1'b0;
        ref_word_known          = {WORDS_PER_LINE{1'b0}};
        current_line_words_written = {WORDS_PER_LINE{1'b0}};
        word_write_coverage     = {WORDS_PER_LINE{1'b0}};
        begin_count             = 0;
        commit_count            = 0;
        consume_count           = 0;
        idle_count              = 0;
        final_word_commit_count = 0;
        test_count              = 0;

        if (!$value$plusargs("SEED=%d", seed)) begin
            seed = 1;
        end
        random_state = seed;
        ignored_random = $urandom(random_state);

        if ($value$plusargs("VCD=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(0, tb_writeback_buffer);
        end

        apply_cycle(
            1'b0, 1'b0, 16'h0000,
            1'b0, 3'd0, 32'h00000000,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b0, 1'b1, 16'hffe0,
            1'b1, 3'd4, 32'hdeadbeef,
            1'b1, 1'b1
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b0, 3'd0, 32'h00000000,
            1'b0, 1'b0
        );

        apply_cycle(
            1'b1, 1'b1, 16'h1220,
            1'b0, 3'd0, 32'h00000000,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd5, 32'h50000005,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd0, 32'h50000000,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd7, 32'h50000007,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd2, 32'h50000002,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd6, 32'h50000006,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd1, 32'h50000001,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd4, 32'h50000004,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd3, 32'h50000003,
            1'b1, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b0, 3'd0, 32'h00000000,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b0, 3'd0, 32'h00000000,
            1'b0, 1'b1
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b0, 3'd0, 32'h00000000,
            1'b0, 1'b0
        );

        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b0, 3'd0, 32'h00000000,
            1'b1, 1'b0
        );
        apply_cycle(
            1'b1, 1'b1, 16'h3440,
            1'b1, 3'd6, 32'haabbccdd,
            1'b1, 1'b1
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b0, 3'd0, 32'h00000000,
            1'b1, 1'b1
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd0, 32'h60000000,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd1, 32'h60000001,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd2, 32'h60000002,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd3, 32'h60000003,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd4, 32'h60000004,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd5, 32'h60000005,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b1, 3'd7, 32'h60000007,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b0, 3'd0, 32'h00000000,
            1'b1, 1'b0
        );
        apply_cycle(
            1'b0, 1'b1, 16'h5660,
            1'b1, 3'd6, 32'h01234567,
            1'b1, 1'b1
        );
        apply_cycle(
            1'b0, 1'b0, 16'h0000,
            1'b0, 3'd0, 32'h00000000,
            1'b0, 1'b0
        );
        apply_cycle(
            1'b1, 1'b0, 16'h0000,
            1'b0, 3'd0, 32'h00000000,
            1'b0, 1'b0
        );

        for (line_number = 0; line_number < RANDOM_LINES;
             line_number = line_number + 1) begin
            random_addr = $urandom & 16'hffe0;
            apply_cycle(
                1'b1, 1'b1, random_addr,
                1'b0, 3'd0, 32'h00000000,
                1'b0, 1'b0
            );

            start_word = $urandom_range(0, WORDS_PER_LINE-1);
            step_choice = $urandom_range(0, 3);
            case (step_choice)
                0: word_step = 1;
                1: word_step = 3;
                2: word_step = 5;
                default: word_step = 7;
            endcase
            commit_with_last_word = $urandom_range(0, 1);

            for (word_number = 0; word_number < WORDS_PER_LINE;
                 word_number = word_number + 1) begin
                selected_word = (start_word + (word_number * word_step))
                    % WORDS_PER_LINE;
                random_word_data = $urandom;
                apply_cycle(
                    1'b1, 1'b0, 16'h0000,
                    1'b1, selected_word[WORD_INDEX_WIDTH-1:0],
                    random_word_data,
                    commit_with_last_word &&
                        (word_number == WORDS_PER_LINE-1),
                    1'b0
                );
            end

            if (!commit_with_last_word) begin
                apply_cycle(
                    1'b1, 1'b0, 16'h0000,
                    1'b0, 3'd0, 32'h00000000,
                    1'b1, 1'b0
                );
            end

            idle_cycles = $urandom_range(0, 2);
            for (idle_number = 0; idle_number < idle_cycles;
                 idle_number = idle_number + 1) begin
                apply_cycle(
                    1'b1, 1'b0, 16'h0000,
                    1'b0, 3'd0, 32'h00000000,
                    1'b0, 1'b0
                );
            end

            apply_cycle(
                1'b1, 1'b0, 16'h0000,
                1'b0, 3'd0, 32'h00000000,
                1'b0, 1'b1
            );
        end

        if (word_write_coverage !== {WORDS_PER_LINE{1'b1}}) begin
            $fatal(1, "Not every writeback word was written: coverage=%b",
                word_write_coverage);
        end
        if (begin_count < RANDOM_LINES ||
            commit_count < RANDOM_LINES ||
            consume_count < RANDOM_LINES ||
            idle_count == 0 ||
            final_word_commit_count == 0) begin
            $fatal(1,
                "Control coverage incomplete begin=%0d commit=%0d consume=%0d idle=%0d final_commit=%0d",
                begin_count, commit_count, consume_count, idle_count,
                final_word_commit_count);
        end

        $display(
            "TEST_PASS tb_writeback_buffer seed=%0d checks=%0d lines=%0d",
            seed, test_count, RANDOM_LINES
        );
        $finish;
    end

    initial begin
        #250000;
        $fatal(1, "Simulation timeout");
    end

endmodule
