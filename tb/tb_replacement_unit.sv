`timescale 1ns/1ps

module tb_replacement_unit;

    localparam integer SETS = 4;
    localparam integer SET_INDEX_WIDTH = 2;
    localparam integer RANDOM_TWO_WAY_UPDATES = 256;
    localparam integer RANDOM_FOUR_WAY_UPDATES = 512;

    reg clk;
    reg reset_n;

    reg  [SET_INDEX_WIDTH-1:0] query_set_1;
    reg                         query_valid_1;
    wire                        victim_way_1;
    reg                         update_en_1;
    reg  [SET_INDEX_WIDTH-1:0] update_set_1;
    reg                         update_way_1;

    reg  [SET_INDEX_WIDTH-1:0] query_set_2;
    reg  [1:0]                 query_valid_2;
    wire [1:0]                 victim_way_2;
    reg                         update_en_2;
    reg  [SET_INDEX_WIDTH-1:0] update_set_2;
    reg  [1:0]                 update_way_2;

    reg  [SET_INDEX_WIDTH-1:0] query_set_4;
    reg  [3:0]                 query_valid_4;
    wire [3:0]                 victim_way_4;
    reg                         update_en_4;
    reg  [SET_INDEX_WIDTH-1:0] update_set_4;
    reg  [3:0]                 update_way_4;

    reg       reference_2 [0:SETS-1];
    reg [2:0] reference_4 [0:SETS-1];

    integer seed;
    integer rng_seed;
    integer random_seed_result;
    integer check_count;
    integer set_index;
    integer pattern;
    integer iteration;
    string  wave_path;

    replacement_unit #(
        .SETS            (SETS),
        .WAYS            (1),
        .SET_INDEX_WIDTH (SET_INDEX_WIDTH)
    ) dut_one_way (
        .clk         (clk),
        .reset_n     (reset_n),
        .query_set   (query_set_1),
        .query_valid (query_valid_1),
        .victim_way  (victim_way_1),
        .update_en   (update_en_1),
        .update_set  (update_set_1),
        .update_way  (update_way_1)
    );

    replacement_unit #(
        .SETS            (SETS),
        .WAYS            (2),
        .SET_INDEX_WIDTH (SET_INDEX_WIDTH)
    ) dut_two_way (
        .clk         (clk),
        .reset_n     (reset_n),
        .query_set   (query_set_2),
        .query_valid (query_valid_2),
        .victim_way  (victim_way_2),
        .update_en   (update_en_2),
        .update_set  (update_set_2),
        .update_way  (update_way_2)
    );

    replacement_unit #(
        .SETS            (SETS),
        .WAYS            (4),
        .SET_INDEX_WIDTH (SET_INDEX_WIDTH)
    ) dut_four_way (
        .clk         (clk),
        .reset_n     (reset_n),
        .query_set   (query_set_4),
        .query_valid (query_valid_4),
        .victim_way  (victim_way_4),
        .update_en   (update_en_4),
        .update_set  (update_set_4),
        .update_way  (update_way_4)
    );

    function automatic [1:0] expected_two_way_victim(
        input [1:0] valid_vector,
        input       state
    );
        begin
            if (!valid_vector[0])
                expected_two_way_victim = 2'b01;
            else if (!valid_vector[1])
                expected_two_way_victim = 2'b10;
            else
                expected_two_way_victim = state ? 2'b10 : 2'b01;
        end
    endfunction

    function automatic [3:0] expected_four_way_victim(
        input [3:0] valid_vector,
        input [2:0] state
    );
        begin
            if (!valid_vector[0])
                expected_four_way_victim = 4'b0001;
            else if (!valid_vector[1])
                expected_four_way_victim = 4'b0010;
            else if (!valid_vector[2])
                expected_four_way_victim = 4'b0100;
            else if (!valid_vector[3])
                expected_four_way_victim = 4'b1000;
            else if (!state[0])
                expected_four_way_victim =
                    !state[1] ? 4'b0001 : 4'b0010;
            else
                expected_four_way_victim =
                    !state[2] ? 4'b0100 : 4'b1000;
        end
    endfunction

    function automatic bit is_one_hot_2(input [1:0] value);
        begin
            is_one_hot_2 =
                (value == 2'b01) ||
                (value == 2'b10);
        end
    endfunction

    function automatic bit is_one_hot_4(input [3:0] value);
        begin
            is_one_hot_4 =
                (value == 4'b0001) ||
                (value == 4'b0010) ||
                (value == 4'b0100) ||
                (value == 4'b1000);
        end
    endfunction

    task automatic check_one_way;
        begin
            query_set_1 = set_index;
            query_valid_1 = 1'b0;
            #1;

            if (victim_way_1 !== 1'b1)
                $fatal(1, "Direct-mapped invalid victim was not way 0");

            query_valid_1 = 1'b1;
            #1;

            if (victim_way_1 !== 1'b1)
                $fatal(1, "Direct-mapped valid victim was not way 0");

            check_count = check_count + 2;
        end
    endtask

    task automatic check_all_two_way_patterns(input integer selected_set);
        reg [1:0] expected;
        begin
            query_set_2 = selected_set;

            for (pattern = 0; pattern < 4; pattern = pattern + 1) begin
                query_valid_2 = pattern;
                #1;
                expected =
                    expected_two_way_victim(pattern, reference_2[selected_set]);

                if (victim_way_2 !== expected) begin
                    $fatal(
                        1,
                        "Two-way mismatch set=%0d valid=%02b state=%01b expected=%02b actual=%02b",
                        selected_set,
                        query_valid_2,
                        reference_2[selected_set],
                        expected,
                        victim_way_2
                    );
                end

                if (!is_one_hot_2(victim_way_2))
                    $fatal(1, "Two-way victim is not one-hot: %02b", victim_way_2);

                check_count = check_count + 1;
            end
        end
    endtask

    task automatic check_all_four_way_patterns(input integer selected_set);
        reg [3:0] expected;
        begin
            query_set_4 = selected_set;

            for (pattern = 0; pattern < 16; pattern = pattern + 1) begin
                query_valid_4 = pattern;
                #1;
                expected =
                    expected_four_way_victim(pattern, reference_4[selected_set]);

                if (victim_way_4 !== expected) begin
                    $fatal(
                        1,
                        "Four-way mismatch set=%0d valid=%04b state=%03b expected=%04b actual=%04b",
                        selected_set,
                        query_valid_4,
                        reference_4[selected_set],
                        expected,
                        victim_way_4
                    );
                end

                if (!is_one_hot_4(victim_way_4))
                    $fatal(1, "Four-way victim is not one-hot: %04b", victim_way_4);

                check_count = check_count + 1;
            end
        end
    endtask

    task automatic apply_two_way_update(
        input integer selected_set,
        input [1:0] accessed_way
    );
        begin
            @(negedge clk);
            update_en_2 = 1'b1;
            update_set_2 = selected_set;
            update_way_2 = accessed_way;

            @(posedge clk);
            #1;
            update_en_2 = 1'b0;

            case (accessed_way)
                2'b01: reference_2[selected_set] = 1'b1;
                2'b10: reference_2[selected_set] = 1'b0;
                default: reference_2[selected_set] =
                    reference_2[selected_set];
            endcase

            check_all_two_way_patterns(selected_set);
        end
    endtask

    task automatic apply_four_way_update(
        input integer selected_set,
        input [3:0] accessed_way
    );
        begin
            @(negedge clk);
            update_en_4 = 1'b1;
            update_set_4 = selected_set;
            update_way_4 = accessed_way;

            @(posedge clk);
            #1;
            update_en_4 = 1'b0;

            case (accessed_way)
                4'b0001: begin
                    reference_4[selected_set][0] = 1'b1;
                    reference_4[selected_set][1] = 1'b1;
                end
                4'b0010: begin
                    reference_4[selected_set][0] = 1'b1;
                    reference_4[selected_set][1] = 1'b0;
                end
                4'b0100: begin
                    reference_4[selected_set][0] = 1'b0;
                    reference_4[selected_set][2] = 1'b1;
                end
                4'b1000: begin
                    reference_4[selected_set][0] = 1'b0;
                    reference_4[selected_set][2] = 1'b0;
                end
                default: reference_4[selected_set] =
                    reference_4[selected_set];
            endcase

            check_all_four_way_patterns(selected_set);
        end
    endtask

    task automatic check_four_way_victim(
        input integer selected_set,
        input [3:0] expected
    );
        begin
            query_set_4 = selected_set;
            query_valid_4 = 4'b1111;
            #1;

            if (victim_way_4 !== expected) begin
                $fatal(
                    1,
                    "Four-way convention mismatch set=%0d expected=%04b actual=%04b",
                    selected_set,
                    expected,
                    victim_way_4
                );
            end

            check_count = check_count + 1;
        end
    endtask

    always #5 clk = ~clk;

    initial begin
        if (!$value$plusargs("SEED=%d", seed))
            seed = 1;

        if ($value$plusargs("VCD=%s", wave_path)) begin
            $dumpfile(wave_path);
            $dumpvars(0, tb_replacement_unit);
        end

        rng_seed = seed;
        random_seed_result = $urandom(rng_seed);
        check_count = 0;

        clk = 1'b0;
        reset_n = 1'b0;

        query_set_1 = 0;
        query_valid_1 = 0;
        update_en_1 = 0;
        update_set_1 = 0;
        update_way_1 = 0;

        query_set_2 = 0;
        query_valid_2 = 0;
        update_en_2 = 0;
        update_set_2 = 0;
        update_way_2 = 0;

        query_set_4 = 0;
        query_valid_4 = 0;
        update_en_4 = 0;
        update_set_4 = 0;
        update_way_4 = 0;

        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            reference_2[set_index] = 1'b0;
            reference_4[set_index] = 3'b000;
        end

        $display("tb_replacement_unit: seed=%0d", seed);

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset_n = 1'b1;

        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            check_one_way();
            check_all_two_way_patterns(set_index);
            check_all_four_way_patterns(set_index);
        end

        apply_two_way_update(0, 2'b01);
        query_set_2 = 0;
        query_valid_2 = 2'b11;
        #1;
        if (victim_way_2 !== 2'b10)
            $fatal(1, "Two-way access to way 0 did not make way 1 LRU");

        apply_two_way_update(0, 2'b10);
        query_valid_2 = 2'b11;
        #1;
        if (victim_way_2 !== 2'b01)
            $fatal(1, "Two-way access to way 1 did not make way 0 LRU");

        apply_four_way_update(0, 4'b0001);
        check_four_way_victim(0, 4'b0100);
        apply_four_way_update(0, 4'b0100);
        check_four_way_victim(0, 4'b0010);
        apply_four_way_update(0, 4'b0010);
        check_four_way_victim(0, 4'b1000);
        apply_four_way_update(0, 4'b1000);
        check_four_way_victim(0, 4'b0001);

        for (set_index = 1; set_index < SETS; set_index = set_index + 1) begin
            check_all_two_way_patterns(set_index);
            check_all_four_way_patterns(set_index);
        end

        @(negedge clk);
        update_en_2 = 1'b0;
        update_set_2 = 0;
        update_way_2 = 2'b01;
        update_en_4 = 1'b0;
        update_set_4 = 0;
        update_way_4 = 4'b0001;
        @(posedge clk);
        #1;
        check_all_two_way_patterns(0);
        check_all_four_way_patterns(0);

        for (iteration = 0;
             iteration < RANDOM_TWO_WAY_UPDATES;
             iteration = iteration + 1) begin
            set_index = $urandom_range(SETS - 1, 0);
            apply_two_way_update(
                set_index,
                $urandom_range(1, 0) ? 2'b10 : 2'b01
            );
        end

        for (iteration = 0;
             iteration < RANDOM_FOUR_WAY_UPDATES;
             iteration = iteration + 1) begin
            set_index = $urandom_range(SETS - 1, 0);

            case ($urandom_range(3, 0))
                2'b00: apply_four_way_update(set_index, 4'b0001);
                2'b01: apply_four_way_update(set_index, 4'b0010);
                2'b10: apply_four_way_update(set_index, 4'b0100);
                default: apply_four_way_update(set_index, 4'b1000);
            endcase
        end

        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            check_all_two_way_patterns(set_index);
            check_all_four_way_patterns(set_index);
        end

        $display(
            "TEST_PASS tb_replacement_unit checks=%0d seed=%0d",
            check_count,
            seed
        );
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "tb_replacement_unit timed out");
    end

endmodule
