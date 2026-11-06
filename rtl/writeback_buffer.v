`timescale 1ns/1ps

module writeback_buffer #(
    parameter ADDR_WIDTH       = 32,
    parameter WORDS_PER_LINE   = 8,
    parameter WORD_INDEX_WIDTH = 3
) (
    input  wire                        clk,
    input  wire                        reset_n,

    input  wire                        begin_line,
    input  wire [ADDR_WIDTH-1:0]       line_addr_in,
    input  wire                        word_write_en,
    input  wire [WORD_INDEX_WIDTH-1:0] word_write_index,
    input  wire [31:0]                 word_write_data,
    input  wire                        commit_line,
    input  wire                        consume_line,

    output reg                         line_valid,
    output reg  [ADDR_WIDTH-1:0]       line_addr_out,
    output reg  [255:0]                line_data_out
);

    always @(posedge clk) begin
        if (!reset_n) begin
            line_valid <= 1'b0;
        end else begin
            if (begin_line) begin
                line_addr_out <= line_addr_in;
                line_valid    <= 1'b0;
            end else if (consume_line) begin
                line_valid <= 1'b0;
            end else if (commit_line) begin
                line_valid <= 1'b1;
            end

            if (word_write_en) begin
                line_data_out[(word_write_index*32) +: 32]
                    <= word_write_data;
            end
        end
    end

endmodule
