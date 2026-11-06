`timescale 1ns/1ps

module data_array #(
    parameter SETS              = 128,
    parameter WAYS              = 4,
    parameter WORDS_PER_LINE    = 8,
    parameter SET_INDEX_WIDTH   = 7,
    parameter WORD_INDEX_WIDTH  = 3
) (
    input  wire                              clk,

    input  wire                              read_en,
    input  wire [SET_INDEX_WIDTH-1:0]        read_set,
    input  wire [WAYS-1:0]                   read_way,
    input  wire [WORD_INDEX_WIDTH-1:0]       read_word,
    output reg  [31:0]                       read_data,

    input  wire                              write_en,
    input  wire [SET_INDEX_WIDTH-1:0]        write_set,
    input  wire [WAYS-1:0]                   write_way,
    input  wire [WORD_INDEX_WIDTH-1:0]       write_word,
    input  wire [31:0]                       write_data
);

    localparam ENTRIES = SETS * WAYS * WORDS_PER_LINE;

    reg [31:0] data_mem [0:ENTRIES-1];

    integer address_way;
    integer read_address;
    integer write_address;

    always @(*) begin
        read_address  = 0;
        write_address = 0;

        for (address_way = 0; address_way < WAYS;
             address_way = address_way + 1) begin
            if (read_way[address_way]) begin
                read_address = (((read_set * WAYS) + address_way)
                    * WORDS_PER_LINE) + read_word;
            end
            if (write_way[address_way]) begin
                write_address = (((write_set * WAYS) + address_way)
                    * WORDS_PER_LINE) + write_word;
            end
        end
    end

    always @(posedge clk) begin
        if (read_en) begin
            read_data <= data_mem[read_address];
        end

        if (write_en) begin
            data_mem[write_address] <= write_data;
        end
    end

endmodule
