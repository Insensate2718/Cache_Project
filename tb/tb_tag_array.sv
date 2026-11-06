`timescale 1ns/1ps

module tb_tag_array;

    localparam SETS            = 4;
    localparam WAYS            = 4;
    localparam TAG_WIDTH       = 8;
    localparam SET_INDEX_WIDTH = 2;
    localparam ENTRIES         = SETS * WAYS;
    localparam RANDOM_CYCLES   = 512;

    reg                         clk;
    reg                         reset_n;
    reg                         lookup_en;
    reg  [SET_INDEX_WIDTH-1:0] lookup_set;
    wire [WAYS*TAG_WIDTH-1:0]  lookup_tags;
    wire [WAYS-1:0]            lookup_valid;
    wire [WAYS-1:0]            lookup_dirty;
    wire [WAYS-1:0]            lookup_parity;
    reg                         meta_write_en;
    reg  [SET_INDEX_WIDTH-1:0] meta_write_set;
    reg  [WAYS-1:0]            meta_write_way;
    reg  [TAG_WIDTH-1:0]       meta_write_tag;
    reg                         meta_write_valid;
    reg                         meta_write_dirty;
    reg                         meta_write_parity;

    reg [TAG_WIDTH-1:0] ref_tag    [0:ENTRIES-1];
    reg                 ref_valid  [0:ENTRIES-1];
    reg                 ref_dirty  [0:ENTRIES-1];
    reg                 ref_parity [0:ENTRIES-1];
    reg                 ref_written[0:ENTRIES-1];

    reg [ENTRIES-1:0] write_coverage;
    reg [SETS-1:0]    lookup_coverage;

    integer seed;
    integer test_count;
    integer random_cycle;
    integer random_op;
    integer random_set;
    integer random_way;
    integer other_set;
    integer set_index;
    integer way_index;
    integer entry_index;
    integer ignored_random;
    integer random_state;
    reg [1023:0] vcd_path;

    tag_array #(
        .SETS(SETS),
        .WAYS(WAYS),
        .TAG_WIDTH(TAG_WIDTH),
        .SET_INDEX_WIDTH(SET_INDEX_WIDTH)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .lookup_en(lookup_en),
        .lookup_set(lookup_set),
        .lookup_tags(lookup_tags),
        .lookup_valid(lookup_valid),
        .lookup_dirty(lookup_dirty),
        .lookup_parity(lookup_parity),
        .meta_write_en(meta_write_en),
        .meta_write_set(meta_write_set),
        .meta_write_way(meta_write_way),
        .meta_write_tag(meta_write_tag),
        .meta_write_valid(meta_write_valid),
        .meta_write_dirty(meta_write_dirty),
        .meta_write_parity(meta_write_parity)
    );

    always #5 clk = ~clk;

    task clear_reference_metadata;
        integer entry;
        begin
            for (entry = 0; entry < ENTRIES; entry = entry + 1) begin
                ref_valid[entry] = 1'b0;
                ref_dirty[entry] = 1'b0;
            end
        end
    endtask

    task check_reset_outputs;
        begin
            if (lookup_tags !== {WAYS*TAG_WIDTH{1'b0}} ||
                lookup_valid !== {WAYS{1'b0}} ||
                lookup_dirty !== {WAYS{1'b0}} ||
                lookup_parity !== {WAYS{1'b0}}) begin
                $fatal(1, "Reset did not clear all lookup outputs");
            end
            test_count = test_count + 1;
        end
    endtask

    task check_lookup_outputs;
        input integer expected_set;
        integer way;
        integer entry;
        begin
            for (way = 0; way < WAYS; way = way + 1) begin
                entry = (expected_set * WAYS) + way;

                if (lookup_valid[way] !== ref_valid[entry]) begin
                    $fatal(1,
                        "Valid mismatch: set=%0d way=%0d expected=%b actual=%b",
                        expected_set, way, ref_valid[entry],
                        lookup_valid[way]);
                end
                if (lookup_dirty[way] !== ref_dirty[entry]) begin
                    $fatal(1,
                        "Dirty mismatch: set=%0d way=%0d expected=%b actual=%b",
                        expected_set, way, ref_dirty[entry],
                        lookup_dirty[way]);
                end

                if (ref_written[entry]) begin
                    if (lookup_tags[(way*TAG_WIDTH) +: TAG_WIDTH]
                        !== ref_tag[entry]) begin
                        $fatal(1,
                            "Tag mismatch: set=%0d way=%0d expected=%h actual=%h",
                            expected_set, way, ref_tag[entry],
                            lookup_tags[(way*TAG_WIDTH) +: TAG_WIDTH]);
                    end
                    if (lookup_parity[way] !== ref_parity[entry]) begin
                        $fatal(1,
                            "Parity mismatch: set=%0d way=%0d expected=%b actual=%b",
                            expected_set, way, ref_parity[entry],
                            lookup_parity[way]);
                    end
                end

                if (!lookup_valid[way] && lookup_dirty[way]) begin
                    $fatal(1,
                        "Invalid line is dirty: set=%0d way=%0d",
                        expected_set, way);
                end
            end

            lookup_coverage[expected_set] = 1'b1;
            test_count = test_count + 1;
        end
    endtask

    task apply_reset;
        begin
            @(negedge clk);
            reset_n       = 1'b0;
            lookup_en     = 1'b0;
            meta_write_en = 1'b0;
            @(posedge clk);
            #1;
            clear_reference_metadata();
            check_reset_outputs();
            @(posedge clk);
            #1;
            check_reset_outputs();
            @(negedge clk);
            reset_n = 1'b1;
        end
    endtask

    task write_entry;
        input integer set_number;
        input integer way_number;
        input [TAG_WIDTH-1:0] tag_value;
        input valid_value;
        input dirty_value;
        input parity_value;
        integer entry;
        begin
            @(negedge clk);
            meta_write_en     = 1'b1;
            meta_write_set    = set_number[SET_INDEX_WIDTH-1:0];
            meta_write_way    = {{(WAYS-1){1'b0}}, 1'b1} << way_number;
            meta_write_tag    = tag_value;
            meta_write_valid  = valid_value;
            meta_write_dirty  = dirty_value;
            meta_write_parity = parity_value;
            lookup_en         = 1'b0;

            @(posedge clk);
            #1;

            entry = (set_number * WAYS) + way_number;
            ref_tag[entry]     = tag_value;
            ref_valid[entry]   = valid_value;
            ref_dirty[entry]   = valid_value && dirty_value;
            ref_parity[entry]  = parity_value;
            ref_written[entry] = 1'b1;
            write_coverage[entry] = 1'b1;

            @(negedge clk);
            meta_write_en  = 1'b0;
            meta_write_way = {WAYS{1'b0}};
        end
    endtask

    task lookup_and_check;
        input integer set_number;
        begin
            @(negedge clk);
            lookup_en  = 1'b1;
            lookup_set = set_number[SET_INDEX_WIDTH-1:0];

            @(posedge clk);
            #1;
            check_lookup_outputs(set_number);

            @(negedge clk);
            lookup_en = 1'b0;
        end
    endtask

    task write_and_lookup_different_sets;
        input integer read_set;
        input integer write_set;
        input integer write_way;
        input [TAG_WIDTH-1:0] tag_value;
        input valid_value;
        input dirty_value;
        input parity_value;
        integer entry;
        begin
            if (read_set == write_set) begin
                $fatal(1, "Simultaneous test requires different sets");
            end

            @(negedge clk);
            lookup_en          = 1'b1;
            lookup_set         = read_set[SET_INDEX_WIDTH-1:0];
            meta_write_en      = 1'b1;
            meta_write_set     = write_set[SET_INDEX_WIDTH-1:0];
            meta_write_way     = {{(WAYS-1){1'b0}}, 1'b1} << write_way;
            meta_write_tag     = tag_value;
            meta_write_valid   = valid_value;
            meta_write_dirty   = dirty_value;
            meta_write_parity  = parity_value;

            @(posedge clk);
            #1;
            check_lookup_outputs(read_set);

            entry = (write_set * WAYS) + write_way;
            ref_tag[entry]     = tag_value;
            ref_valid[entry]   = valid_value;
            ref_dirty[entry]   = valid_value && dirty_value;
            ref_parity[entry]  = parity_value;
            ref_written[entry] = 1'b1;
            write_coverage[entry] = 1'b1;

            @(negedge clk);
            lookup_en      = 1'b0;
            meta_write_en  = 1'b0;
            meta_write_way = {WAYS{1'b0}};
        end
    endtask

    task check_output_hold;
        reg [WAYS*TAG_WIDTH-1:0] held_tags;
        reg [WAYS-1:0]           held_valid;
        reg [WAYS-1:0]           held_dirty;
        reg [WAYS-1:0]           held_parity;
        begin
            lookup_and_check(0);
            held_tags   = lookup_tags;
            held_valid  = lookup_valid;
            held_dirty  = lookup_dirty;
            held_parity = lookup_parity;

            @(negedge clk);
            lookup_en  = 1'b0;
            lookup_set = 2;
            @(posedge clk);
            #1;

            if (lookup_tags !== held_tags ||
                lookup_valid !== held_valid ||
                lookup_dirty !== held_dirty ||
                lookup_parity !== held_parity) begin
                $fatal(1, "Lookup outputs changed while lookup_en was low");
            end
            test_count = test_count + 1;
        end
    endtask

    task check_synchronous_lookup;
        begin
            @(negedge clk);
            lookup_en  = 1'b1;
            lookup_set = 0;
            @(posedge clk);
            #1;
            check_lookup_outputs(0);

            #2;
            lookup_set = 1;
            #1;
            check_lookup_outputs(0);

            @(posedge clk);
            #1;
            check_lookup_outputs(1);

            @(negedge clk);
            lookup_en = 1'b0;
        end
    endtask

    initial begin
        clk                = 1'b0;
        reset_n            = 1'b1;
        lookup_en          = 1'b0;
        lookup_set         = {SET_INDEX_WIDTH{1'b0}};
        meta_write_en      = 1'b0;
        meta_write_set     = {SET_INDEX_WIDTH{1'b0}};
        meta_write_way     = {WAYS{1'b0}};
        meta_write_tag     = {TAG_WIDTH{1'b0}};
        meta_write_valid   = 1'b0;
        meta_write_dirty   = 1'b0;
        meta_write_parity  = 1'b0;
        test_count         = 0;
        write_coverage     = {ENTRIES{1'b0}};
        lookup_coverage    = {SETS{1'b0}};

        for (entry_index = 0; entry_index < ENTRIES;
             entry_index = entry_index + 1) begin
            ref_tag[entry_index]     = {TAG_WIDTH{1'b0}};
            ref_valid[entry_index]   = 1'b0;
            ref_dirty[entry_index]   = 1'b0;
            ref_parity[entry_index]  = 1'b0;
            ref_written[entry_index] = 1'b0;
        end

        if (!$value$plusargs("SEED=%d", seed)) begin
            seed = 1;
        end
        random_state = seed;
        ignored_random = $urandom(random_state);

        if ($value$plusargs("VCD=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(0, tb_tag_array);
        end

        apply_reset();

        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            lookup_and_check(set_index);
        end

        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            for (way_index = 0; way_index < WAYS; way_index = way_index + 1) begin
                write_entry(
                    set_index,
                    way_index,
                    (set_index * WAYS) + way_index + 8'h20,
                    1'b1,
                    way_index[0],
                    ^((set_index * WAYS) + way_index + 8'h20)
                );
            end
        end

        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            lookup_and_check(set_index);
        end

        check_synchronous_lookup();
        check_output_hold();

        write_entry(1, 2, 8'hd2, 1'b0, 1'b1, 1'b1);
        lookup_and_check(1);

        write_entry(2, 3, 8'he3, 1'b1, 1'b1, 1'b0);
        write_entry(2, 3, 8'he4, 1'b0, 1'b0, 1'b1);
        lookup_and_check(2);

        write_and_lookup_different_sets(
            0, 3, 1, 8'hf1, 1'b1, 1'b1, 1'b0
        );
        lookup_and_check(3);

        apply_reset();
        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            lookup_and_check(set_index);
        end

        for (random_cycle = 0; random_cycle < RANDOM_CYCLES;
             random_cycle = random_cycle + 1) begin
            random_op  = $urandom_range(0, 3);
            random_set = $urandom_range(0, SETS-1);
            random_way = $urandom_range(0, WAYS-1);

            case (random_op)
                0: begin
                    write_entry(
                        random_set,
                        random_way,
                        $urandom,
                        $urandom_range(0, 1),
                        $urandom_range(0, 1),
                        $urandom_range(0, 1)
                    );
                end
                1: begin
                    lookup_and_check(random_set);
                end
                2: begin
                    other_set = $urandom_range(0, SETS-2);
                    if (other_set >= random_set) begin
                        other_set = other_set + 1;
                    end
                    write_and_lookup_different_sets(
                        random_set,
                        other_set,
                        random_way,
                        $urandom,
                        $urandom_range(0, 1),
                        $urandom_range(0, 1),
                        $urandom_range(0, 1)
                    );
                end
                default: begin
                    check_output_hold();
                end
            endcase
        end

        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            lookup_and_check(set_index);
        end

        if (write_coverage !== {ENTRIES{1'b1}}) begin
            $fatal(1, "Not every set/way entry was written: coverage=%h",
                write_coverage);
        end
        if (lookup_coverage !== {SETS{1'b1}}) begin
            $fatal(1, "Not every set was looked up: coverage=%h",
                lookup_coverage);
        end

        $display("TEST_PASS tb_tag_array seed=%0d checks=%0d",
            seed, test_count);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "Simulation timeout");
    end

endmodule
