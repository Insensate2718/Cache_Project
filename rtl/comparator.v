`timescale 1ns/1ps

module comparator #(
    parameter WAYS              = 4,
    parameter TAG_WIDTH         = 20,
    parameter TAG_PARITY_ENABLE = 1
) (
    input  wire [WAYS*TAG_WIDTH-1:0] stored_tags,
    input  wire [WAYS-1:0]           stored_valid,
    input  wire [WAYS-1:0]           stored_tag_parity,
    input  wire [TAG_WIDTH-1:0]      request_tag,

    output reg  [WAYS-1:0]           hit_vector,
    output reg                       hit_any,
    output reg                       hit_multiple,
    output reg  [WAYS-1:0]           parity_error_vector,
    output reg                       parity_error_any
);

    reg [TAG_WIDTH-1:0] way_tag;
    reg                 parity_failed;
    integer             way_index;
    integer             hit_count;

    always @(*) begin
        hit_vector = {WAYS{1'b0}};
        hit_any = 1'b0;
        hit_multiple = 1'b0;
        parity_error_vector = {WAYS{1'b0}};
        parity_error_any = 1'b0;
        way_tag = {TAG_WIDTH{1'b0}};
        parity_failed = 1'b0;
        hit_count = 0;

        for (way_index = 0; way_index < WAYS; way_index = way_index + 1) begin
            way_tag =
                stored_tags[(way_index * TAG_WIDTH) +: TAG_WIDTH];
            parity_failed = 1'b0;

            if (TAG_PARITY_ENABLE && stored_valid[way_index])
                parity_failed =
                    ^{way_tag, stored_tag_parity[way_index]};

            parity_error_vector[way_index] = parity_failed;

            if (stored_valid[way_index] &&
                !parity_failed &&
                (way_tag == request_tag)) begin
                hit_vector[way_index] = 1'b1;
                hit_count = hit_count + 1;
            end
        end

        hit_any = |hit_vector;
        hit_multiple = (hit_count > 1);
        parity_error_any = |parity_error_vector;
    end

endmodule
