`timescale 1ns/1ps

module replacement_unit #(
    parameter SETS            = 128,
    parameter WAYS            = 4,
    parameter SET_INDEX_WIDTH = 7
) (
    input  wire                       clk,
    input  wire                       reset_n,

    input  wire [SET_INDEX_WIDTH-1:0] query_set,
    input  wire [WAYS-1:0]            query_valid,
    output reg  [WAYS-1:0]            victim_way,

    input  wire                       update_en,
    input  wire [SET_INDEX_WIDTH-1:0] update_set,
    input  wire [WAYS-1:0]            update_way
);

    wire [WAYS-1:0] plru_victim_way;
    reg              invalid_found;
    integer          way_index;

    always @(*) begin
        victim_way = {WAYS{1'b0}};
        invalid_found = 1'b0;

        for (way_index = 0; way_index < WAYS; way_index = way_index + 1) begin
            if (!invalid_found && !query_valid[way_index]) begin
                victim_way[way_index] = 1'b1;
                invalid_found = 1'b1;
            end
        end

        if (!invalid_found)
            victim_way = plru_victim_way;
    end

    generate
        if (WAYS == 1) begin : gen_direct_mapped
            assign plru_victim_way = 1'b1;
        end else if (WAYS == 2) begin : gen_two_way
            reg plru_state [0:SETS-1];
            integer reset_index;

            assign plru_victim_way =
                plru_state[query_set] ? 2'b10 : 2'b01;

            always @(posedge clk) begin
                if (!reset_n) begin
                    for (reset_index = 0;
                         reset_index < SETS;
                         reset_index = reset_index + 1)
                        plru_state[reset_index] <= 1'b0;
                end else if (update_en) begin
                    case (update_way)
                        2'b01: plru_state[update_set] <= 1'b1;
                        2'b10: plru_state[update_set] <= 1'b0;
                        default: plru_state[update_set] <=
                            plru_state[update_set];
                    endcase
                end
            end
        end else if (WAYS == 4) begin : gen_four_way
            reg [2:0] plru_state [0:SETS-1];
            wire [2:0] query_state;
            integer reset_index;

            assign query_state = plru_state[query_set];
            assign plru_victim_way =
                !query_state[0]
                    ? (!query_state[1] ? 4'b0001 : 4'b0010)
                    : (!query_state[2] ? 4'b0100 : 4'b1000);

            always @(posedge clk) begin
                if (!reset_n) begin
                    for (reset_index = 0;
                         reset_index < SETS;
                         reset_index = reset_index + 1)
                        plru_state[reset_index] <= 3'b000;
                end else if (update_en) begin
                    case (update_way)
                        4'b0001: begin
                            plru_state[update_set][0] <= 1'b1;
                            plru_state[update_set][1] <= 1'b1;
                        end
                        4'b0010: begin
                            plru_state[update_set][0] <= 1'b1;
                            plru_state[update_set][1] <= 1'b0;
                        end
                        4'b0100: begin
                            plru_state[update_set][0] <= 1'b0;
                            plru_state[update_set][2] <= 1'b1;
                        end
                        4'b1000: begin
                            plru_state[update_set][0] <= 1'b0;
                            plru_state[update_set][2] <= 1'b0;
                        end
                        default: plru_state[update_set] <=
                            plru_state[update_set];
                    endcase
                end
            end
        end else begin : gen_unsupported_ways
            assign plru_victim_way = {{(WAYS-1){1'b0}}, 1'b1};
        end
    endgenerate

endmodule
