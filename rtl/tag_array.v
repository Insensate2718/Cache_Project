`timescale 1ns/1ps

module tag_array #(
    parameter SETS            = 128,
    parameter WAYS            = 4,
    parameter TAG_WIDTH       = 20,
    parameter SET_INDEX_WIDTH = 7
) (
    input  wire                       clk,
    input  wire                       reset_n,

    input  wire                       lookup_en,
    input  wire [SET_INDEX_WIDTH-1:0] lookup_set,
    output reg  [WAYS*TAG_WIDTH-1:0]  lookup_tags,
    output reg  [WAYS-1:0]            lookup_valid,
    output reg  [WAYS-1:0]            lookup_dirty,
    output reg  [WAYS-1:0]            lookup_parity,

    input  wire                       meta_write_en,
    input  wire [SET_INDEX_WIDTH-1:0] meta_write_set,
    input  wire [WAYS-1:0]            meta_write_way,
    input  wire [TAG_WIDTH-1:0]       meta_write_tag,
    input  wire                       meta_write_valid,
    input  wire                       meta_write_dirty,
    input  wire                       meta_write_parity
);

    localparam ENTRIES = SETS * WAYS;

    reg [TAG_WIDTH-1:0] tag_mem    [0:ENTRIES-1];
    reg                 valid_mem  [0:ENTRIES-1];
    reg                 dirty_mem  [0:ENTRIES-1];
    reg                 parity_mem [0:ENTRIES-1];

    integer reset_entry;
    integer lookup_way;
    integer write_way;
    integer lookup_entry;
    integer write_entry;

    always @(posedge clk) begin
        if (!reset_n) begin
            lookup_tags   <= {WAYS*TAG_WIDTH{1'b0}};
            lookup_valid  <= {WAYS{1'b0}};
            lookup_dirty  <= {WAYS{1'b0}};
            lookup_parity <= {WAYS{1'b0}};

            for (reset_entry = 0; reset_entry < ENTRIES;
                 reset_entry = reset_entry + 1) begin
                valid_mem[reset_entry] <= 1'b0;
                dirty_mem[reset_entry] <= 1'b0;
            end
        end else begin
            if (lookup_en) begin
                for (lookup_way = 0; lookup_way < WAYS;
                     lookup_way = lookup_way + 1) begin
                    lookup_entry = (lookup_set * WAYS) + lookup_way;
                    lookup_tags[(lookup_way*TAG_WIDTH) +: TAG_WIDTH]
                        <= tag_mem[lookup_entry];
                    lookup_valid[lookup_way]  <= valid_mem[lookup_entry];
                    lookup_dirty[lookup_way]  <= dirty_mem[lookup_entry];
                    lookup_parity[lookup_way] <= parity_mem[lookup_entry];
                end
            end

            if (meta_write_en) begin
                for (write_way = 0; write_way < WAYS;
                     write_way = write_way + 1) begin
                    if (meta_write_way[write_way]) begin
                        write_entry = (meta_write_set * WAYS) + write_way;
                        tag_mem[write_entry]    <= meta_write_tag;
                        valid_mem[write_entry]  <= meta_write_valid;
                        dirty_mem[write_entry]
                            <= meta_write_valid && meta_write_dirty;
                        parity_mem[write_entry] <= meta_write_parity;
                    end
                end
            end
        end
    end

endmodule
