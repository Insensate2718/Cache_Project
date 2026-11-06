`timescale 1ns/1ps

module tb_comparator;

    localparam integer WAYS = 4;
    localparam integer TAG_WIDTH = 8;
    localparam integer RANDOM_TESTS = 2048;

    reg  [WAYS*TAG_WIDTH-1:0] stored_tags;
    reg  [WAYS-1:0]           stored_valid;
    reg  [WAYS-1:0]           stored_tag_parity;
    reg  [TAG_WIDTH-1:0]      request_tag;

    wire [WAYS-1:0] hit_vector_enabled;
    wire            hit_any_enabled;
    wire            hit_multiple_enabled;
    wire [WAYS-1:0] parity_error_vector_enabled;
    wire            parity_error_any_enabled;

    wire [WAYS-1:0] hit_vector_disabled;
    wire            hit_any_disabled;
    wire            hit_multiple_disabled;
    wire [WAYS-1:0] parity_error_vector_disabled;
    wire            parity_error_any_disabled;

    integer seed;
    integer rng_seed;
    integer random_seed_result;
    integer test_count;
    integer random_index;
    integer way_index;
    integer multiple_hit_count;
    integer parity_error_count;
    reg [WAYS-1:0] hit_way_coverage;
    reg [WAYS-1:0] parity_way_coverage;
    string wave_path;

    comparator #(
        .WAYS              (WAYS),
        .TAG_WIDTH         (TAG_WIDTH),
        .TAG_PARITY_ENABLE (1)
    ) dut_parity_enabled (
        .stored_tags         (stored_tags),
        .stored_valid        (stored_valid),
        .stored_tag_parity   (stored_tag_parity),
        .request_tag         (request_tag),
        .hit_vector          (hit_vector_enabled),
        .hit_any             (hit_any_enabled),
        .hit_multiple        (hit_multiple_enabled),
        .parity_error_vector (parity_error_vector_enabled),
        .parity_error_any    (parity_error_any_enabled)
    );

    comparator #(
        .WAYS              (WAYS),
        .TAG_WIDTH         (TAG_WIDTH),
        .TAG_PARITY_ENABLE (0)
    ) dut_parity_disabled (
        .stored_tags         (stored_tags),
        .stored_valid        (stored_valid),
        .stored_tag_parity   (stored_tag_parity),
        .request_tag         (request_tag),
        .hit_vector          (hit_vector_disabled),
        .hit_any             (hit_any_disabled),
        .hit_multiple        (hit_multiple_disabled),
        .parity_error_vector (parity_error_vector_disabled),
        .parity_error_any    (parity_error_any_disabled)
    );

    function automatic parity_bit(input [TAG_WIDTH-1:0] tag);
        begin
            parity_bit = ^tag;
        end
    endfunction

    task automatic set_way_tag(
        input integer selected_way,
        input [TAG_WIDTH-1:0] tag
    );
        begin
            stored_tags[(selected_way * TAG_WIDTH) +: TAG_WIDTH] = tag;
        end
    endtask

    task automatic set_clean_parity;
        reg [TAG_WIDTH-1:0] tag;
        begin
            for (way_index = 0; way_index < WAYS; way_index = way_index + 1) begin
                tag = stored_tags[(way_index * TAG_WIDTH) +: TAG_WIDTH];
                stored_tag_parity[way_index] = parity_bit(tag);
            end
        end
    endtask

    task automatic calculate_reference(
        input integer parity_enabled,
        output reg [WAYS-1:0] expected_hit_vector,
        output reg [WAYS-1:0] expected_parity_vector,
        output reg expected_hit_multiple
    );
        reg [TAG_WIDTH-1:0] tag;
        reg parity_failed;
        integer hit_count;
        integer reference_way;
        begin
            expected_hit_vector = {WAYS{1'b0}};
            expected_parity_vector = {WAYS{1'b0}};
            expected_hit_multiple = 1'b0;
            hit_count = 0;

            for (reference_way = 0;
                 reference_way < WAYS;
                 reference_way = reference_way + 1) begin
                tag = stored_tags[
                    (reference_way * TAG_WIDTH) +: TAG_WIDTH
                ];
                parity_failed = 1'b0;

                if (parity_enabled && stored_valid[reference_way])
                    parity_failed =
                        ^{tag, stored_tag_parity[reference_way]};

                expected_parity_vector[reference_way] = parity_failed;

                if (stored_valid[reference_way] &&
                    !parity_failed &&
                    (tag == request_tag)) begin
                    expected_hit_vector[reference_way] = 1'b1;
                    hit_count = hit_count + 1;
                end
            end

            expected_hit_multiple = (hit_count > 1);
        end
    endtask

    task automatic check_against_reference(input string test_name);
        reg [WAYS-1:0] expected_hit_enabled;
        reg [WAYS-1:0] expected_parity_enabled;
        reg expected_multiple_enabled;
        reg [WAYS-1:0] expected_hit_disabled;
        reg [WAYS-1:0] expected_parity_disabled;
        reg expected_multiple_disabled;
        begin
            #1;

            calculate_reference(
                1,
                expected_hit_enabled,
                expected_parity_enabled,
                expected_multiple_enabled
            );
            calculate_reference(
                0,
                expected_hit_disabled,
                expected_parity_disabled,
                expected_multiple_disabled
            );

            if (hit_vector_enabled !== expected_hit_enabled)
                $fatal(
                    1,
                    "%s: enabled hit vector expected=%04b actual=%04b",
                    test_name,
                    expected_hit_enabled,
                    hit_vector_enabled
                );

            if (parity_error_vector_enabled !== expected_parity_enabled)
                $fatal(
                    1,
                    "%s: enabled parity vector expected=%04b actual=%04b",
                    test_name,
                    expected_parity_enabled,
                    parity_error_vector_enabled
                );

            if (hit_multiple_enabled !== expected_multiple_enabled)
                $fatal(
                    1,
                    "%s: enabled multiple expected=%01b actual=%01b",
                    test_name,
                    expected_multiple_enabled,
                    hit_multiple_enabled
                );

            if (hit_any_enabled !== (|expected_hit_enabled))
                $fatal(1, "%s: enabled hit_any reduction mismatch", test_name);

            if (parity_error_any_enabled !== (|expected_parity_enabled))
                $fatal(
                    1,
                    "%s: enabled parity_error_any reduction mismatch",
                    test_name
                );

            if (hit_vector_disabled !== expected_hit_disabled)
                $fatal(
                    1,
                    "%s: disabled hit vector expected=%04b actual=%04b",
                    test_name,
                    expected_hit_disabled,
                    hit_vector_disabled
                );

            if (parity_error_vector_disabled !== expected_parity_disabled)
                $fatal(
                    1,
                    "%s: disabled parity vector expected=%04b actual=%04b",
                    test_name,
                    expected_parity_disabled,
                    parity_error_vector_disabled
                );

            if (hit_multiple_disabled !== expected_multiple_disabled)
                $fatal(
                    1,
                    "%s: disabled multiple expected=%01b actual=%01b",
                    test_name,
                    expected_multiple_disabled,
                    hit_multiple_disabled
                );

            if (hit_any_disabled !== (|expected_hit_disabled))
                $fatal(1, "%s: disabled hit_any reduction mismatch", test_name);

            if (parity_error_any_disabled !== 1'b0)
                $fatal(
                    1,
                    "%s: parity-disabled instance reported parity error",
                    test_name
                );

            hit_way_coverage =
                hit_way_coverage |
                hit_vector_enabled |
                hit_vector_disabled;
            parity_way_coverage =
                parity_way_coverage |
                parity_error_vector_enabled;

            if (hit_multiple_enabled || hit_multiple_disabled)
                multiple_hit_count = multiple_hit_count + 1;
            if (parity_error_any_enabled)
                parity_error_count = parity_error_count + 1;

            test_count = test_count + 1;
        end
    endtask

    task automatic expect_enabled(
        input string test_name,
        input [WAYS-1:0] expected_hit,
        input [WAYS-1:0] expected_parity,
        input expected_multiple
    );
        begin
            check_against_reference(test_name);

            if (hit_vector_enabled !== expected_hit)
                $fatal(
                    1,
                    "%s: directed hit expected=%04b actual=%04b",
                    test_name,
                    expected_hit,
                    hit_vector_enabled
                );

            if (parity_error_vector_enabled !== expected_parity)
                $fatal(
                    1,
                    "%s: directed parity expected=%04b actual=%04b",
                    test_name,
                    expected_parity,
                    parity_error_vector_enabled
                );

            if (hit_multiple_enabled !== expected_multiple)
                $fatal(
                    1,
                    "%s: directed multiple expected=%01b actual=%01b",
                    test_name,
                    expected_multiple,
                    hit_multiple_enabled
                );
        end
    endtask

    initial begin
        if (!$value$plusargs("SEED=%d", seed))
            seed = 1;

        if ($value$plusargs("VCD=%s", wave_path)) begin
            $dumpfile(wave_path);
            $dumpvars(0, tb_comparator);
        end

        rng_seed = seed;
        random_seed_result = $urandom(rng_seed);
        test_count = 0;
        multiple_hit_count = 0;
        parity_error_count = 0;
        hit_way_coverage = {WAYS{1'b0}};
        parity_way_coverage = {WAYS{1'b0}};

        stored_tags = {WAYS*TAG_WIDTH{1'b0}};
        stored_valid = {WAYS{1'b0}};
        stored_tag_parity = {WAYS{1'b1}};
        request_tag = {TAG_WIDTH{1'b0}};

        $display("tb_comparator: seed=%0d", seed);

        expect_enabled(
            "no valid ways",
            4'b0000,
            4'b0000,
            1'b0
        );

        stored_tags = {8'hd4, 8'hc3, 8'hb2, 8'ha1};
        stored_valid = 4'b1111;
        set_clean_parity();

        request_tag = 8'he5;
        expect_enabled("all valid mismatch", 4'b0000, 4'b0000, 1'b0);

        request_tag = 8'ha1;
        expect_enabled("flattened way 0", 4'b0001, 4'b0000, 1'b0);
        request_tag = 8'hb2;
        expect_enabled("flattened way 1", 4'b0010, 4'b0000, 1'b0);
        request_tag = 8'hc3;
        expect_enabled("flattened way 2", 4'b0100, 4'b0000, 1'b0);
        request_tag = 8'hd4;
        expect_enabled("flattened way 3", 4'b1000, 4'b0000, 1'b0);

        request_tag = 8'hc3;
        stored_valid = 4'b1011;
        expect_enabled(
            "invalid matching way",
            4'b0000,
            4'b0000,
            1'b0
        );

        stored_valid = 4'b1111;
        request_tag = 8'hb2;
        stored_tag_parity[1] = ~stored_tag_parity[1];
        expect_enabled(
            "matching tag parity error",
            4'b0000,
            4'b0010,
            1'b0
        );

        request_tag = 8'ha1;
        stored_tag_parity[1] = parity_bit(8'hb2);
        stored_tag_parity[3] = ~stored_tag_parity[3];
        expect_enabled(
            "nonmatching tag parity error",
            4'b0001,
            4'b1000,
            1'b0
        );

        stored_valid[3] = 1'b0;
        expect_enabled(
            "invalid way parity ignored",
            4'b0001,
            4'b0000,
            1'b0
        );

        stored_tags = {8'h77, 8'h55, 8'h77, 8'h77};
        stored_valid = 4'b1111;
        set_clean_parity();
        request_tag = 8'h77;
        expect_enabled(
            "multiple identical tags",
            4'b1011,
            4'b0000,
            1'b1
        );

        stored_tags = {8'h40, 8'h30, 8'h20, 8'h10};
        stored_valid = 4'b0010;
        set_clean_parity();
        stored_tag_parity[1] = ~stored_tag_parity[1];
        request_tag = 8'h20;
        expect_enabled(
            "parity disabled ignores corruption",
            4'b0000,
            4'b0010,
            1'b0
        );

        if (hit_vector_disabled !== 4'b0010)
            $fatal(
                1,
                "Parity-disabled comparator failed to hit corrupted-parity way"
            );

        stored_tags = {8'hd4, 8'hc3, 8'hb2, 8'ha1};
        stored_valid = 4'b1111;
        request_tag = 8'he5;
        set_clean_parity();

        for (way_index = 0; way_index < WAYS; way_index = way_index + 1) begin
            stored_tag_parity[way_index] =
                ~stored_tag_parity[way_index];
            expect_enabled(
                "parity error in each way",
                4'b0000,
                4'b0001 << way_index,
                1'b0
            );
            stored_tag_parity[way_index] =
                ~stored_tag_parity[way_index];
        end

        for (random_index = 0;
             random_index < RANDOM_TESTS;
             random_index = random_index + 1) begin
            for (way_index = 0; way_index < WAYS; way_index = way_index + 1)
                set_way_tag(way_index, $urandom);

            stored_valid = $urandom;
            stored_tag_parity = $urandom;
            request_tag = $urandom;

            check_against_reference("randomized comparison");
        end

        if (hit_way_coverage !== {WAYS{1'b1}})
            $fatal(
                1,
                "Not every way produced a hit; coverage=%04b",
                hit_way_coverage
            );

        if (parity_way_coverage !== {WAYS{1'b1}})
            $fatal(
                1,
                "Not every way produced a parity error; coverage=%04b",
                parity_way_coverage
            );

        if (multiple_hit_count == 0)
            $fatal(1, "Multiple-hit behavior was not exercised");

        if (parity_error_count == 0)
            $fatal(1, "Parity-error behavior was not exercised");

        $display(
            "TEST_PASS tb_comparator tests=%0d multi=%0d parity=%0d seed=%0d",
            test_count,
            multiple_hit_count,
            parity_error_count,
            seed
        );
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "tb_comparator timed out");
    end

endmodule
