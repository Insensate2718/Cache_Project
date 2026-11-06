`timescale 1ns/1ps

module tb_data_array;

    localparam SETS              = 4;
    localparam WAYS              = 4;
    localparam WORDS_PER_LINE    = 4;
    localparam WORD_WIDTH        = 32;
    localparam SET_INDEX_WIDTH   = 2;
    localparam WORD_INDEX_WIDTH  = 2;
    localparam ENTRIES           = SETS * WAYS * WORDS_PER_LINE;
    localparam RANDOM_CYCLES     = 600;

    reg                               clk;
    reg                               read_en;
    reg  [SET_INDEX_WIDTH-1:0]        read_set;
    reg  [WAYS-1:0]                   read_way;
    reg  [WORD_INDEX_WIDTH-1:0]       read_word;
    wire [WORD_WIDTH-1:0]             read_data;
    reg                               write_en;
    reg  [SET_INDEX_WIDTH-1:0]        write_set;
    reg  [WAYS-1:0]                   write_way;
    reg  [WORD_INDEX_WIDTH-1:0]       write_word;
    reg  [WORD_WIDTH-1:0]             write_data;

    reg [WORD_WIDTH-1:0] ref_data
        [0:SETS-1][0:WAYS-1][0:WORDS_PER_LINE-1];
    reg ref_known [0:SETS-1][0:WAYS-1][0:WORDS_PER_LINE-1];

    reg [ENTRIES-1:0] write_coverage;
    reg [ENTRIES-1:0] read_coverage;

    integer seed;
    integer random_state;
    integer ignored_random;
    integer test_count;
    integer set_index;
    integer way_index;
    integer word_index;
    integer flat_index;
    integer random_cycle;
    integer random_operation;
    integer random_read_flat;
    integer random_write_flat;
    integer random_read_set;
    integer random_read_way;
    integer random_read_word;
    integer random_write_set;
    integer random_write_way;
    integer random_write_word;
    reg [1023:0] vcd_path;

    data_array #(
        .SETS(SETS),
        .WAYS(WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .SET_INDEX_WIDTH(SET_INDEX_WIDTH),
        .WORD_INDEX_WIDTH(WORD_INDEX_WIDTH)
    ) dut (
        .clk(clk),
        .read_en(read_en),
        .read_set(read_set),
        .read_way(read_way),
        .read_word(read_word),
        .read_data(read_data),
        .write_en(write_en),
        .write_set(write_set),
        .write_way(write_way),
        .write_word(write_word),
        .write_data(write_data)
    );

    always #5 clk = ~clk;

    function integer coverage_index;
        input integer set_number;
        input integer way_number;
        input integer word_number;
        begin
            coverage_index = ((set_number * WAYS) + way_number)
                * WORDS_PER_LINE + word_number;
        end
    endfunction

    task check_read_data;
        input integer expected_set;
        input integer expected_way;
        input integer expected_word;
        begin
            if (!ref_known[expected_set][expected_way][expected_word]) begin
                $fatal(1,
                    "Attempted to check unwritten location set=%0d way=%0d word=%0d",
                    expected_set, expected_way, expected_word);
            end

            if (read_data !==
                ref_data[expected_set][expected_way][expected_word]) begin
                $fatal(1,
                    "Read mismatch set=%0d way=%0d word=%0d expected=%h actual=%h",
                    expected_set, expected_way, expected_word,
                    ref_data[expected_set][expected_way][expected_word],
                    read_data);
            end

            read_coverage[
                coverage_index(expected_set, expected_way, expected_word)
            ] = 1'b1;
            test_count = test_count + 1;
        end
    endtask

    task write_location;
        input integer set_number;
        input integer way_number;
        input integer word_number;
        input [WORD_WIDTH-1:0] data_value;
        begin
            @(negedge clk);
            read_en    = 1'b0;
            write_en   = 1'b1;
            write_set  = set_number[SET_INDEX_WIDTH-1:0];
            write_way  = {{(WAYS-1){1'b0}}, 1'b1} << way_number;
            write_word = word_number[WORD_INDEX_WIDTH-1:0];
            write_data = data_value;

            @(posedge clk);
            #1;
            ref_data[set_number][way_number][word_number] = data_value;
            ref_known[set_number][way_number][word_number] = 1'b1;
            write_coverage[
                coverage_index(set_number, way_number, word_number)
            ] = 1'b1;

            @(negedge clk);
            write_en  = 1'b0;
            write_way = {WAYS{1'b0}};
        end
    endtask

    task read_location;
        input integer set_number;
        input integer way_number;
        input integer word_number;
        begin
            @(negedge clk);
            read_en   = 1'b1;
            read_set  = set_number[SET_INDEX_WIDTH-1:0];
            read_way  = {{(WAYS-1){1'b0}}, 1'b1} << way_number;
            read_word = word_number[WORD_INDEX_WIDTH-1:0];

            @(posedge clk);
            #1;
            check_read_data(set_number, way_number, word_number);

            @(negedge clk);
            read_en  = 1'b0;
            read_way = {WAYS{1'b0}};
        end
    endtask

    task read_write_different_locations;
        input integer read_set_number;
        input integer read_way_number;
        input integer read_word_number;
        input integer write_set_number;
        input integer write_way_number;
        input integer write_word_number;
        input [WORD_WIDTH-1:0] data_value;
        begin
            if (read_set_number == write_set_number &&
                read_way_number == write_way_number &&
                read_word_number == write_word_number) begin
                $fatal(1, "Simultaneous read and write addresses must differ");
            end

            @(negedge clk);
            read_en    = 1'b1;
            read_set   = read_set_number[SET_INDEX_WIDTH-1:0];
            read_way   = {{(WAYS-1){1'b0}}, 1'b1} << read_way_number;
            read_word  = read_word_number[WORD_INDEX_WIDTH-1:0];
            write_en   = 1'b1;
            write_set  = write_set_number[SET_INDEX_WIDTH-1:0];
            write_way  = {{(WAYS-1){1'b0}}, 1'b1} << write_way_number;
            write_word = write_word_number[WORD_INDEX_WIDTH-1:0];
            write_data = data_value;

            @(posedge clk);
            #1;
            check_read_data(
                read_set_number, read_way_number, read_word_number
            );
            ref_data[write_set_number][write_way_number][write_word_number]
                = data_value;
            ref_known[write_set_number][write_way_number][write_word_number]
                = 1'b1;
            write_coverage[
                coverage_index(
                    write_set_number, write_way_number, write_word_number
                )
            ] = 1'b1;

            @(negedge clk);
            read_en   = 1'b0;
            read_way  = {WAYS{1'b0}};
            write_en  = 1'b0;
            write_way = {WAYS{1'b0}};
        end
    endtask

    task check_read_hold;
        input integer known_set;
        input integer known_way;
        input integer known_word;
        reg [WORD_WIDTH-1:0] held_data;
        begin
            read_location(known_set, known_way, known_word);
            held_data = read_data;

            @(negedge clk);
            read_en   = 1'b0;
            read_set  = (known_set + 1) % SETS;
            read_way  = {{(WAYS-1){1'b0}}, 1'b1}
                << ((known_way + 1) % WAYS);
            read_word = (known_word + 1) % WORDS_PER_LINE;

            @(posedge clk);
            #1;
            if (read_data !== held_data) begin
                $fatal(1,
                    "read_data changed while read_en was low: expected=%h actual=%h",
                    held_data, read_data);
            end
            test_count = test_count + 1;
        end
    endtask

    task check_synchronous_read;
        begin
            @(negedge clk);
            read_en   = 1'b1;
            read_set  = 0;
            read_way  = 4'b0001;
            read_word = 0;

            @(posedge clk);
            #1;
            check_read_data(0, 0, 0);

            #2;
            read_set  = 3;
            read_way  = 4'b1000;
            read_word = 3;
            #1;
            check_read_data(0, 0, 0);

            @(posedge clk);
            #1;
            check_read_data(3, 3, 3);

            @(negedge clk);
            read_en  = 1'b0;
            read_way = {WAYS{1'b0}};
        end
    endtask

    task decode_flat_location;
        input integer location;
        output integer decoded_set;
        output integer decoded_way;
        output integer decoded_word;
        integer remainder;
        begin
            decoded_set = location / (WAYS * WORDS_PER_LINE);
            remainder = location % (WAYS * WORDS_PER_LINE);
            decoded_way = remainder / WORDS_PER_LINE;
            decoded_word = remainder % WORDS_PER_LINE;
        end
    endtask

    initial begin
        clk            = 1'b0;
        read_en        = 1'b0;
        read_set       = {SET_INDEX_WIDTH{1'b0}};
        read_way       = {WAYS{1'b0}};
        read_word      = {WORD_INDEX_WIDTH{1'b0}};
        write_en       = 1'b0;
        write_set      = {SET_INDEX_WIDTH{1'b0}};
        write_way      = {WAYS{1'b0}};
        write_word     = {WORD_INDEX_WIDTH{1'b0}};
        write_data     = {WORD_WIDTH{1'b0}};
        write_coverage = {ENTRIES{1'b0}};
        read_coverage  = {ENTRIES{1'b0}};
        test_count     = 0;

        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            for (way_index = 0; way_index < WAYS;
                 way_index = way_index + 1) begin
                for (word_index = 0; word_index < WORDS_PER_LINE;
                     word_index = word_index + 1) begin
                    ref_data[set_index][way_index][word_index]
                        = {WORD_WIDTH{1'b0}};
                    ref_known[set_index][way_index][word_index] = 1'b0;
                end
            end
        end

        if (!$value$plusargs("SEED=%d", seed)) begin
            seed = 1;
        end
        random_state = seed;
        ignored_random = $urandom(random_state);

        if ($value$plusargs("VCD=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(0, tb_data_array);
        end

        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            for (way_index = 0; way_index < WAYS;
                 way_index = way_index + 1) begin
                for (word_index = 0; word_index < WORDS_PER_LINE;
                     word_index = word_index + 1) begin
                    write_location(
                        set_index,
                        way_index,
                        word_index,
                        16'h4000 | (set_index << 8)
                            | (way_index << 4) | word_index
                    );
                end
            end
        end

        for (set_index = 0; set_index < SETS; set_index = set_index + 1) begin
            for (way_index = 0; way_index < WAYS;
                 way_index = way_index + 1) begin
                for (word_index = 0; word_index < WORDS_PER_LINE;
                     word_index = word_index + 1) begin
                    read_location(set_index, way_index, word_index);
                end
            end
        end

        check_synchronous_read();
        check_read_hold(1, 2, 3);

        write_location(2, 1, 2, 16'ha12e);
        read_location(2, 1, 2);
        read_location(2, 1, 1);
        read_location(2, 0, 2);
        read_location(1, 1, 2);

        read_write_different_locations(
            0, 0, 0,
            0, 0, 1,
            16'hd001
        );
        read_location(0, 0, 1);

        read_write_different_locations(
            3, 3, 3,
            1, 2, 0,
            16'hd120
        );
        read_location(1, 2, 0);

        for (random_cycle = 0; random_cycle < RANDOM_CYCLES;
             random_cycle = random_cycle + 1) begin
            random_operation = $urandom_range(0, 3);
            random_read_flat = $urandom_range(0, ENTRIES-1);
            decode_flat_location(
                random_read_flat,
                random_read_set,
                random_read_way,
                random_read_word
            );

            case (random_operation)
                0: begin
                    write_location(
                        random_read_set,
                        random_read_way,
                        random_read_word,
                        $urandom
                    );
                end
                1: begin
                    read_location(
                        random_read_set,
                        random_read_way,
                        random_read_word
                    );
                end
                2: begin
                    random_write_flat = $urandom_range(0, ENTRIES-2);
                    if (random_write_flat >= random_read_flat) begin
                        random_write_flat = random_write_flat + 1;
                    end
                    decode_flat_location(
                        random_write_flat,
                        random_write_set,
                        random_write_way,
                        random_write_word
                    );
                    read_write_different_locations(
                        random_read_set,
                        random_read_way,
                        random_read_word,
                        random_write_set,
                        random_write_way,
                        random_write_word,
                        $urandom
                    );
                end
                default: begin
                    check_read_hold(
                        random_read_set,
                        random_read_way,
                        random_read_word
                    );
                end
            endcase
        end

        for (flat_index = 0; flat_index < ENTRIES;
             flat_index = flat_index + 1) begin
            decode_flat_location(
                flat_index,
                random_read_set,
                random_read_way,
                random_read_word
            );
            read_location(
                random_read_set,
                random_read_way,
                random_read_word
            );
        end

        if (write_coverage !== {ENTRIES{1'b1}}) begin
            $fatal(1, "Not every data location was written: coverage=%h",
                write_coverage);
        end
        if (read_coverage !== {ENTRIES{1'b1}}) begin
            $fatal(1, "Not every data location was read: coverage=%h",
                read_coverage);
        end

        $display("TEST_PASS tb_data_array seed=%0d checks=%0d",
            seed, test_count);
        $finish;
    end

    initial begin
        #250000;
        $fatal(1, "Simulation timeout");
    end

endmodule
