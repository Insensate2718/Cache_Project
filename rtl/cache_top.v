`timescale 1ns/1ps

module cache_top #(
    parameter ADDR_WIDTH        = 32,
    parameter CACHE_BYTES       = 16384,
    parameter LINE_BYTES        = 32,
    parameter WAYS              = 4,
    parameter TAG_PARITY_ENABLE = 1
) (
    input  wire                  clk,
    input  wire                  reset_n,

    input  wire                  req_valid,
    output wire                  req_ready,
    input  wire                  req_write,
    input  wire [ADDR_WIDTH-1:0] req_addr,
    input  wire [31:0]           req_wdata,

    output wire                  resp_valid,
    input  wire                  resp_ready,
    output wire [31:0]           resp_rdata,
    output wire                  resp_tag_parity_err,
    output wire                  resp_fatal_err,

    output wire                  mem_req_valid,
    input  wire                  mem_req_ready,
    output wire                  mem_req_write,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    output wire [255:0]          mem_req_wdata,

    input  wire                  mem_resp_valid,
    output wire                  mem_resp_ready,
    input  wire [255:0]          mem_resp_rdata,
    input  wire                  mem_resp_error
);

    function integer integer_log2;
        input integer value;
        integer remaining;
        begin
            integer_log2 = 0;
            remaining = value - 1;
            while (remaining > 0) begin
                integer_log2 = integer_log2 + 1;
                remaining = remaining >> 1;
            end
        end
    endfunction

    function integer is_power_of_two;
        input integer value;
        begin
            is_power_of_two =
                (value > 0) && ((value & (value - 1)) == 0);
        end
    endfunction

    localparam LINE_WIDTH = LINE_BYTES * 8;
    localparam WORDS_PER_LINE = LINE_BYTES / 4;
    localparam SETS = CACHE_BYTES / (LINE_BYTES * WAYS);
    localparam COMPUTED_SET_INDEX_WIDTH = integer_log2(SETS);
    localparam SET_INDEX_WIDTH =
        (COMPUTED_SET_INDEX_WIDTH > 0) ? COMPUTED_SET_INDEX_WIDTH : 1;
    localparam WORD_INDEX_WIDTH = integer_log2(WORDS_PER_LINE);
    localparam OFFSET_WIDTH = integer_log2(LINE_BYTES);
    localparam COMPUTED_TAG_WIDTH =
        ADDR_WIDTH - COMPUTED_SET_INDEX_WIDTH - OFFSET_WIDTH;
    localparam TAG_WIDTH =
        (COMPUTED_TAG_WIDTH > 0) ? COMPUTED_TAG_WIDTH : 1;

    initial begin
        if (WAYS != 1 && WAYS != 2 && WAYS != 4) begin
            $fatal(1,
                "CACHE_PARAMETER_ERROR WAYS must be 1, 2, or 4");
        end else if (TAG_PARITY_ENABLE != 0 && TAG_PARITY_ENABLE != 1) begin
            $fatal(1,
                "CACHE_PARAMETER_ERROR TAG_PARITY_ENABLE must be 0 or 1");
        end else if (LINE_BYTES != 32) begin
            $fatal(1,
                "CACHE_PARAMETER_ERROR LINE_BYTES must be 32");
        end else if (!is_power_of_two(CACHE_BYTES)) begin
            $fatal(1,
                "CACHE_PARAMETER_ERROR CACHE_BYTES must be a power of two");
        end else if ((CACHE_BYTES % (LINE_BYTES * WAYS)) != 0) begin
            $fatal(1,
                "CACHE_PARAMETER_ERROR cache geometry is not divisible");
        end else if (SETS < 2 || !is_power_of_two(SETS)) begin
            $fatal(1,
                "CACHE_PARAMETER_ERROR SETS must be a power of two >= 2");
        end else if (COMPUTED_TAG_WIDTH <= 0) begin
            $fatal(1,
                "CACHE_PARAMETER_ERROR ADDR_WIDTH leaves no tag bits");
        end
    end

    wire [WAYS*TAG_WIDTH-1:0] tag_lookup_tags;
    wire [WAYS-1:0]           tag_lookup_valid;
    wire [WAYS-1:0]           tag_lookup_dirty;
    wire [WAYS-1:0]           tag_lookup_parity;
    wire                      tag_lookup_en;
    wire [SET_INDEX_WIDTH-1:0] tag_lookup_set;

    wire                       tag_meta_write_en;
    wire [SET_INDEX_WIDTH-1:0] tag_meta_write_set;
    wire [WAYS-1:0]            tag_meta_write_way;
    wire [TAG_WIDTH-1:0]       tag_meta_write_tag;
    wire                       tag_meta_write_valid;
    wire                       tag_meta_write_dirty;
    wire                       tag_meta_write_parity;

    wire [TAG_WIDTH-1:0] compare_request_tag;
    wire [WAYS-1:0]      compare_hit_vector;
    wire                 compare_hit_any;
    wire                 compare_hit_multiple;
    wire [WAYS-1:0]      compare_parity_error_vector;
    wire                 compare_parity_error_any;

    wire [SET_INDEX_WIDTH-1:0] replacement_query_set;
    wire [WAYS-1:0]            replacement_query_valid;
    wire [WAYS-1:0]            replacement_victim_way;
    wire                       replacement_update_en;
    wire [SET_INDEX_WIDTH-1:0] replacement_update_set;
    wire [WAYS-1:0]            replacement_update_way;

    wire                              data_read_en;
    wire [SET_INDEX_WIDTH-1:0]        data_read_set;
    wire [WAYS-1:0]                   data_read_way;
    wire [WORD_INDEX_WIDTH-1:0]       data_read_word;
    wire [31:0]                       data_read_data;
    wire                              data_write_en;
    wire [SET_INDEX_WIDTH-1:0]        data_write_set;
    wire [WAYS-1:0]                   data_write_way;
    wire [WORD_INDEX_WIDTH-1:0]       data_write_word;
    wire [31:0]                       data_write_data;

    wire                        wb_begin_line;
    wire [ADDR_WIDTH-1:0]       wb_line_addr_in;
    wire                        wb_word_write_en;
    wire [WORD_INDEX_WIDTH-1:0] wb_word_write_index;
    wire [31:0]                 wb_word_write_data;
    wire                        wb_commit_line;
    wire                        wb_consume_line;
    wire                        wb_line_valid;
    wire [ADDR_WIDTH-1:0]       wb_line_addr_out;
    wire [255:0]                wb_line_data_out;

    tag_array #(
        .SETS(SETS),
        .WAYS(WAYS),
        .TAG_WIDTH(TAG_WIDTH),
        .SET_INDEX_WIDTH(SET_INDEX_WIDTH)
    ) tag_array_inst (
        .clk(clk),
        .reset_n(reset_n),
        .lookup_en(tag_lookup_en),
        .lookup_set(tag_lookup_set),
        .lookup_tags(tag_lookup_tags),
        .lookup_valid(tag_lookup_valid),
        .lookup_dirty(tag_lookup_dirty),
        .lookup_parity(tag_lookup_parity),
        .meta_write_en(tag_meta_write_en),
        .meta_write_set(tag_meta_write_set),
        .meta_write_way(tag_meta_write_way),
        .meta_write_tag(tag_meta_write_tag),
        .meta_write_valid(tag_meta_write_valid),
        .meta_write_dirty(tag_meta_write_dirty),
        .meta_write_parity(tag_meta_write_parity)
    );

    data_array #(
        .SETS(SETS),
        .WAYS(WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .SET_INDEX_WIDTH(SET_INDEX_WIDTH),
        .WORD_INDEX_WIDTH(WORD_INDEX_WIDTH)
    ) data_array_inst (
        .clk(clk),
        .read_en(data_read_en),
        .read_set(data_read_set),
        .read_way(data_read_way),
        .read_word(data_read_word),
        .read_data(data_read_data),
        .write_en(data_write_en),
        .write_set(data_write_set),
        .write_way(data_write_way),
        .write_word(data_write_word),
        .write_data(data_write_data)
    );

    comparator #(
        .WAYS(WAYS),
        .TAG_WIDTH(TAG_WIDTH),
        .TAG_PARITY_ENABLE(TAG_PARITY_ENABLE)
    ) comparator_inst (
        .stored_tags(tag_lookup_tags),
        .stored_valid(tag_lookup_valid),
        .stored_tag_parity(tag_lookup_parity),
        .request_tag(compare_request_tag),
        .hit_vector(compare_hit_vector),
        .hit_any(compare_hit_any),
        .hit_multiple(compare_hit_multiple),
        .parity_error_vector(compare_parity_error_vector),
        .parity_error_any(compare_parity_error_any)
    );

    replacement_unit #(
        .SETS(SETS),
        .WAYS(WAYS),
        .SET_INDEX_WIDTH(SET_INDEX_WIDTH)
    ) replacement_unit_inst (
        .clk(clk),
        .reset_n(reset_n),
        .query_set(replacement_query_set),
        .query_valid(replacement_query_valid),
        .victim_way(replacement_victim_way),
        .update_en(replacement_update_en),
        .update_set(replacement_update_set),
        .update_way(replacement_update_way)
    );

    writeback_buffer #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .WORD_INDEX_WIDTH(WORD_INDEX_WIDTH)
    ) writeback_buffer_inst (
        .clk(clk),
        .reset_n(reset_n),
        .begin_line(wb_begin_line),
        .line_addr_in(wb_line_addr_in),
        .word_write_en(wb_word_write_en),
        .word_write_index(wb_word_write_index),
        .word_write_data(wb_word_write_data),
        .commit_line(wb_commit_line),
        .consume_line(wb_consume_line),
        .line_valid(wb_line_valid),
        .line_addr_out(wb_line_addr_out),
        .line_data_out(wb_line_data_out)
    );

    cache_controller #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .LINE_WIDTH(LINE_WIDTH),
        .WAYS(WAYS),
        .TAG_WIDTH(TAG_WIDTH),
        .SET_INDEX_WIDTH(SET_INDEX_WIDTH),
        .WORD_INDEX_WIDTH(WORD_INDEX_WIDTH),
        .TAG_PARITY_ENABLE(TAG_PARITY_ENABLE)
    ) cache_controller_inst (
        .clk(clk),
        .reset_n(reset_n),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_write(req_write),
        .req_addr(req_addr),
        .req_wdata(req_wdata),
        .resp_valid(resp_valid),
        .resp_ready(resp_ready),
        .resp_rdata(resp_rdata),
        .resp_tag_parity_err(resp_tag_parity_err),
        .resp_fatal_err(resp_fatal_err),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_ready(mem_resp_ready),
        .mem_resp_rdata(mem_resp_rdata),
        .mem_resp_error(mem_resp_error),
        .tag_lookup_en(tag_lookup_en),
        .tag_lookup_set(tag_lookup_set),
        .tag_lookup_tags(tag_lookup_tags),
        .tag_lookup_valid(tag_lookup_valid),
        .tag_lookup_dirty(tag_lookup_dirty),
        .tag_lookup_parity(tag_lookup_parity),
        .tag_meta_write_en(tag_meta_write_en),
        .tag_meta_write_set(tag_meta_write_set),
        .tag_meta_write_way(tag_meta_write_way),
        .tag_meta_write_tag(tag_meta_write_tag),
        .tag_meta_write_valid(tag_meta_write_valid),
        .tag_meta_write_dirty(tag_meta_write_dirty),
        .tag_meta_write_parity(tag_meta_write_parity),
        .compare_request_tag(compare_request_tag),
        .compare_hit_vector(compare_hit_vector),
        .compare_hit_any(compare_hit_any),
        .compare_hit_multiple(compare_hit_multiple),
        .compare_parity_error_vector(compare_parity_error_vector),
        .compare_parity_error_any(compare_parity_error_any),
        .replacement_query_set(replacement_query_set),
        .replacement_query_valid(replacement_query_valid),
        .replacement_victim_way(replacement_victim_way),
        .replacement_update_en(replacement_update_en),
        .replacement_update_set(replacement_update_set),
        .replacement_update_way(replacement_update_way),
        .data_read_en(data_read_en),
        .data_read_set(data_read_set),
        .data_read_way(data_read_way),
        .data_read_word(data_read_word),
        .data_read_data(data_read_data),
        .data_write_en(data_write_en),
        .data_write_set(data_write_set),
        .data_write_way(data_write_way),
        .data_write_word(data_write_word),
        .data_write_data(data_write_data),
        .wb_begin_line(wb_begin_line),
        .wb_line_addr_in(wb_line_addr_in),
        .wb_word_write_en(wb_word_write_en),
        .wb_word_write_index(wb_word_write_index),
        .wb_word_write_data(wb_word_write_data),
        .wb_commit_line(wb_commit_line),
        .wb_consume_line(wb_consume_line),
        .wb_line_valid(wb_line_valid),
        .wb_line_addr_out(wb_line_addr_out),
        .wb_line_data_out(wb_line_data_out)
    );

endmodule
