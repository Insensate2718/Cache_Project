`timescale 1ns/1ps

module cache_controller #(
    parameter ADDR_WIDTH          = 32,
    parameter LINE_BYTES         = 32,
    parameter LINE_WIDTH         = 256,
    parameter WAYS               = 4,
    parameter TAG_WIDTH          = 20,
    parameter SET_INDEX_WIDTH    = 7,
    parameter WORD_INDEX_WIDTH   = 3,
    parameter TAG_PARITY_ENABLE  = 1
) (
    input  wire                              clk,
    input  wire                              reset_n,

    input  wire                              req_valid,
    output reg                               req_ready,
    input  wire                              req_write,
    input  wire [ADDR_WIDTH-1:0]             req_addr,
    input  wire [31:0]                       req_wdata,

    output reg                               resp_valid,
    input  wire                              resp_ready,
    output reg  [31:0]                       resp_rdata,
    output reg                               resp_tag_parity_err,
    output reg                               resp_fatal_err,

    output reg                               mem_req_valid,
    input  wire                              mem_req_ready,
    output reg                               mem_req_write,
    output reg  [ADDR_WIDTH-1:0]             mem_req_addr,
    output reg  [LINE_WIDTH-1:0]             mem_req_wdata,
    input  wire                              mem_resp_valid,
    output reg                               mem_resp_ready,
    input  wire [LINE_WIDTH-1:0]             mem_resp_rdata,
    input  wire                              mem_resp_error,

    output reg                               tag_lookup_en,
    output reg  [SET_INDEX_WIDTH-1:0]        tag_lookup_set,
    input  wire [WAYS*TAG_WIDTH-1:0]         tag_lookup_tags,
    input  wire [WAYS-1:0]                   tag_lookup_valid,
    input  wire [WAYS-1:0]                   tag_lookup_dirty,
    input  wire [WAYS-1:0]                   tag_lookup_parity,

    output reg                               tag_meta_write_en,
    output reg  [SET_INDEX_WIDTH-1:0]        tag_meta_write_set,
    output reg  [WAYS-1:0]                   tag_meta_write_way,
    output reg  [TAG_WIDTH-1:0]              tag_meta_write_tag,
    output reg                               tag_meta_write_valid,
    output reg                               tag_meta_write_dirty,
    output reg                               tag_meta_write_parity,

    output reg  [TAG_WIDTH-1:0]              compare_request_tag,
    input  wire [WAYS-1:0]                   compare_hit_vector,
    input  wire                              compare_hit_any,
    input  wire                              compare_hit_multiple,
    input  wire [WAYS-1:0]                   compare_parity_error_vector,
    input  wire                              compare_parity_error_any,

    output reg  [SET_INDEX_WIDTH-1:0]        replacement_query_set,
    output reg  [WAYS-1:0]                   replacement_query_valid,
    input  wire [WAYS-1:0]                   replacement_victim_way,
    output reg                               replacement_update_en,
    output reg  [SET_INDEX_WIDTH-1:0]        replacement_update_set,
    output reg  [WAYS-1:0]                   replacement_update_way,

    output reg                               data_read_en,
    output reg  [SET_INDEX_WIDTH-1:0]        data_read_set,
    output reg  [WAYS-1:0]                   data_read_way,
    output reg  [WORD_INDEX_WIDTH-1:0]       data_read_word,
    input  wire [31:0]                       data_read_data,

    output reg                               data_write_en,
    output reg  [SET_INDEX_WIDTH-1:0]        data_write_set,
    output reg  [WAYS-1:0]                   data_write_way,
    output reg  [WORD_INDEX_WIDTH-1:0]       data_write_word,
    output reg  [31:0]                       data_write_data,

    output reg                               wb_begin_line,
    output reg  [ADDR_WIDTH-1:0]             wb_line_addr_in,
    output reg                               wb_word_write_en,
    output reg  [WORD_INDEX_WIDTH-1:0]       wb_word_write_index,
    output reg  [31:0]                       wb_word_write_data,
    output reg                               wb_commit_line,
    output reg                               wb_consume_line,
    input  wire                              wb_line_valid,
    input  wire [ADDR_WIDTH-1:0]             wb_line_addr_out,
    input  wire [LINE_WIDTH-1:0]             wb_line_data_out
);

    localparam OFFSET_WIDTH = WORD_INDEX_WIDTH + 2;
    localparam WORDS_PER_LINE = LINE_WIDTH / 32;
    localparam [ADDR_WIDTH-1:0] LINE_ADDR_MASK =
        {ADDR_WIDTH{1'b1}} << OFFSET_WIDTH;

    localparam STATE_IDLE              = 5'd0;
    localparam STATE_LOOKUP_READ       = 5'd1;
    localparam STATE_LOOKUP_EVALUATE   = 5'd2;
    localparam STATE_READ_DATA         = 5'd3;
    localparam STATE_READ_RETURN       = 5'd4;
    localparam STATE_WRITE_HIT         = 5'd5;
    localparam STATE_VICTIM_BEGIN      = 5'd6;
    localparam STATE_VICTIM_READ       = 5'd7;
    localparam STATE_VICTIM_CAPTURE    = 5'd8;
    localparam STATE_WRITEBACK_REQUEST = 5'd9;
    localparam STATE_WRITEBACK_WAIT    = 5'd10;
    localparam STATE_REFILL_REQUEST    = 5'd11;
    localparam STATE_REFILL_WAIT       = 5'd12;
    localparam STATE_INSTALL           = 5'd13;
    localparam STATE_TAG_ERROR         = 5'd14;
    localparam STATE_RESPONSE          = 5'd15;

    reg [4:0] state;

    reg                   request_write_reg;
    reg [ADDR_WIDTH-1:0]  request_addr_reg;
    reg [31:0]            request_wdata_reg;
    reg [WAYS-1:0]        selected_way_reg;
    reg [ADDR_WIDTH-1:0]  victim_line_addr_reg;
    reg [WORD_INDEX_WIDTH-1:0] word_counter;
    reg [LINE_WIDTH-1:0]  refill_buffer;
    reg [WAYS-1:0]        parity_pending_reg;

    reg [31:0] response_data_reg;
    reg        response_tag_parity_reg;
    reg        response_fatal_reg;

    reg [WAYS-1:0] parity_clear_way;
    reg            parity_clear_found;
    integer        parity_way;

    function [TAG_WIDTH-1:0] tag_for_way;
        input [WAYS*TAG_WIDTH-1:0] flattened_tags;
        input [WAYS-1:0]           selected_way;
        integer                    way;
        begin
            tag_for_way = {TAG_WIDTH{1'b0}};
            for (way = 0; way < WAYS; way = way + 1) begin
                if (selected_way[way]) begin
                    tag_for_way = flattened_tags[
                        (way*TAG_WIDTH) +: TAG_WIDTH
                    ];
                end
            end
        end
    endfunction

    always @(*) begin
        parity_clear_way = {WAYS{1'b0}};
        parity_clear_found = 1'b0;
        for (parity_way = 0; parity_way < WAYS;
             parity_way = parity_way + 1) begin
            if (!parity_clear_found && parity_pending_reg[parity_way]) begin
                parity_clear_way[parity_way] = 1'b1;
                parity_clear_found = 1'b1;
            end
        end
    end

    always @(*) begin
        req_ready = 1'b0;
        resp_valid = 1'b0;
        resp_rdata = response_data_reg;
        resp_tag_parity_err = response_tag_parity_reg;
        resp_fatal_err = response_fatal_reg;

        mem_req_valid = 1'b0;
        mem_req_write = 1'b0;
        mem_req_addr = request_addr_reg & LINE_ADDR_MASK;
        mem_req_wdata = {LINE_WIDTH{1'b0}};
        mem_resp_ready = 1'b0;

        tag_lookup_en = 1'b0;
        tag_lookup_set = request_addr_reg[
            OFFSET_WIDTH +: SET_INDEX_WIDTH
        ];
        tag_meta_write_en = 1'b0;
        tag_meta_write_set = request_addr_reg[
            OFFSET_WIDTH +: SET_INDEX_WIDTH
        ];
        tag_meta_write_way = selected_way_reg;
        tag_meta_write_tag = request_addr_reg[
            ADDR_WIDTH-1 -: TAG_WIDTH
        ];
        tag_meta_write_valid = 1'b0;
        tag_meta_write_dirty = 1'b0;
        tag_meta_write_parity = ^request_addr_reg[
            ADDR_WIDTH-1 -: TAG_WIDTH
        ];

        compare_request_tag = request_addr_reg[
            ADDR_WIDTH-1 -: TAG_WIDTH
        ];

        replacement_query_set = request_addr_reg[
            OFFSET_WIDTH +: SET_INDEX_WIDTH
        ];
        replacement_query_valid = tag_lookup_valid;
        replacement_update_en = 1'b0;
        replacement_update_set = request_addr_reg[
            OFFSET_WIDTH +: SET_INDEX_WIDTH
        ];
        replacement_update_way = selected_way_reg;

        data_read_en = 1'b0;
        data_read_set = request_addr_reg[
            OFFSET_WIDTH +: SET_INDEX_WIDTH
        ];
        data_read_way = selected_way_reg;
        data_read_word = request_addr_reg[2 +: WORD_INDEX_WIDTH];
        data_write_en = 1'b0;
        data_write_set = request_addr_reg[
            OFFSET_WIDTH +: SET_INDEX_WIDTH
        ];
        data_write_way = selected_way_reg;
        data_write_word = request_addr_reg[2 +: WORD_INDEX_WIDTH];
        data_write_data = 32'b0;

        wb_begin_line = 1'b0;
        wb_line_addr_in = victim_line_addr_reg;
        wb_word_write_en = 1'b0;
        wb_word_write_index = word_counter;
        wb_word_write_data = data_read_data[31:0];
        wb_commit_line = 1'b0;
        wb_consume_line = 1'b0;

        case (state)
            STATE_IDLE: begin
                req_ready = 1'b1;
            end

            STATE_LOOKUP_READ: begin
                tag_lookup_en = 1'b1;
            end

            STATE_READ_DATA: begin
                data_read_en = 1'b1;
            end

            STATE_READ_RETURN: begin
                replacement_update_en = 1'b1;
            end

            STATE_WRITE_HIT: begin
                data_write_en = 1'b1;
                data_write_data[31:0] = request_wdata_reg;
                tag_meta_write_en = 1'b1;
                tag_meta_write_valid = 1'b1;
                tag_meta_write_dirty = 1'b1;
                replacement_update_en = 1'b1;
            end

            STATE_VICTIM_BEGIN: begin
                wb_begin_line = 1'b1;
            end

            STATE_VICTIM_READ: begin
                data_read_en = 1'b1;
                data_read_word = word_counter;
            end

            STATE_VICTIM_CAPTURE: begin
                wb_word_write_en = 1'b1;
                wb_word_write_index = word_counter;
                if (word_counter == WORDS_PER_LINE-1) begin
                    wb_commit_line = 1'b1;
                end
            end

            STATE_WRITEBACK_REQUEST: begin
                mem_req_valid = wb_line_valid;
                mem_req_write = 1'b1;
                mem_req_addr = wb_line_addr_out;
                mem_req_wdata = wb_line_data_out;
            end

            STATE_WRITEBACK_WAIT: begin
                mem_resp_ready = 1'b1;
                if (mem_resp_valid && !mem_resp_error) begin
                    wb_consume_line = 1'b1;
                end
            end

            STATE_REFILL_REQUEST: begin
                mem_req_valid = 1'b1;
                mem_req_write = 1'b0;
                mem_req_addr = request_addr_reg & LINE_ADDR_MASK;
            end

            STATE_REFILL_WAIT: begin
                mem_resp_ready = 1'b1;
            end

            STATE_INSTALL: begin
                data_write_en = 1'b1;
                data_write_word = word_counter;
                data_write_data[31:0] = refill_buffer[
                    (word_counter*32) +: 32
                ];

                if (word_counter == WORDS_PER_LINE-1) begin
                    tag_meta_write_en = 1'b1;
                    tag_meta_write_valid = 1'b1;
                    tag_meta_write_dirty = 1'b0;
                    replacement_update_en = 1'b1;
                end
            end

            STATE_TAG_ERROR: begin
                tag_meta_write_en = parity_clear_found;
                tag_meta_write_way = parity_clear_way;
                tag_meta_write_tag = tag_for_way(
                    tag_lookup_tags,
                    parity_clear_way
                );
                tag_meta_write_valid = 1'b0;
                tag_meta_write_dirty = 1'b0;
                tag_meta_write_parity = 1'b0;
            end

            STATE_RESPONSE: begin
                resp_valid = 1'b1;
            end

            default: begin
                req_ready = 1'b0;
            end
        endcase
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            state <= STATE_IDLE;
            request_write_reg <= 1'b0;
            request_addr_reg <= {ADDR_WIDTH{1'b0}};
            request_wdata_reg <= 32'b0;
            selected_way_reg <= {WAYS{1'b0}};
            victim_line_addr_reg <= {ADDR_WIDTH{1'b0}};
            word_counter <= {WORD_INDEX_WIDTH{1'b0}};
            refill_buffer <= {LINE_WIDTH{1'b0}};
            parity_pending_reg <= {WAYS{1'b0}};
            response_data_reg <= 32'b0;
            response_tag_parity_reg <= 1'b0;
            response_fatal_reg <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (req_valid && req_ready) begin
                        request_write_reg <= req_write;
                        request_addr_reg <= req_addr;
                        request_wdata_reg <= req_wdata;
                        response_data_reg <= 32'b0;
                        response_tag_parity_reg <= 1'b0;
                        response_fatal_reg <= 1'b0;
                        state <= STATE_LOOKUP_READ;
                    end
                end

                STATE_LOOKUP_READ: begin
                    state <= STATE_LOOKUP_EVALUATE;
                end

                STATE_LOOKUP_EVALUATE: begin
                    if (TAG_PARITY_ENABLE != 0 &&
                        compare_parity_error_any) begin
                        if (|(compare_parity_error_vector &
                              tag_lookup_dirty)) begin
                            response_tag_parity_reg <= 1'b1;
                            response_fatal_reg <= 1'b1;
                            state <= STATE_RESPONSE;
                        end else begin
                            parity_pending_reg <=
                                compare_parity_error_vector;
                            state <= STATE_TAG_ERROR;
                        end
                    end else if (compare_hit_multiple) begin
                        response_fatal_reg <= 1'b1;
                        state <= STATE_RESPONSE;
                    end else if (compare_hit_any) begin
                        selected_way_reg <= compare_hit_vector;
                        if (request_write_reg) begin
                            state <= STATE_WRITE_HIT;
                        end else begin
                            state <= STATE_READ_DATA;
                        end
                    end else begin
                        selected_way_reg <= replacement_victim_way;
                        victim_line_addr_reg <= {
                            tag_for_way(
                                tag_lookup_tags,
                                replacement_victim_way
                            ),
                            request_addr_reg[
                                OFFSET_WIDTH +: SET_INDEX_WIDTH
                            ],
                            {OFFSET_WIDTH{1'b0}}
                        };
                        word_counter <= {WORD_INDEX_WIDTH{1'b0}};

                        if (|(tag_lookup_dirty &
                              replacement_victim_way)) begin
                            state <= STATE_VICTIM_BEGIN;
                        end else begin
                            state <= STATE_REFILL_REQUEST;
                        end
                    end
                end

                STATE_READ_DATA: begin
                    state <= STATE_READ_RETURN;
                end

                STATE_READ_RETURN: begin
                    response_data_reg <= data_read_data[31:0];
                    state <= STATE_RESPONSE;
                end

                STATE_WRITE_HIT: begin
                    state <= STATE_RESPONSE;
                end

                STATE_VICTIM_BEGIN: begin
                    word_counter <= {WORD_INDEX_WIDTH{1'b0}};
                    state <= STATE_VICTIM_READ;
                end

                STATE_VICTIM_READ: begin
                    state <= STATE_VICTIM_CAPTURE;
                end

                STATE_VICTIM_CAPTURE: begin
                    if (word_counter == WORDS_PER_LINE-1) begin
                        state <= STATE_WRITEBACK_REQUEST;
                    end else begin
                        word_counter <= word_counter + 1'b1;
                        state <= STATE_VICTIM_READ;
                    end
                end

                STATE_WRITEBACK_REQUEST: begin
                    if (mem_req_valid && mem_req_ready) begin
                        state <= STATE_WRITEBACK_WAIT;
                    end
                end

                STATE_WRITEBACK_WAIT: begin
                    if (mem_resp_valid && mem_resp_ready) begin
                        if (mem_resp_error) begin
                            response_fatal_reg <= 1'b1;
                            state <= STATE_RESPONSE;
                        end else begin
                            state <= STATE_REFILL_REQUEST;
                        end
                    end
                end

                STATE_REFILL_REQUEST: begin
                    if (mem_req_valid && mem_req_ready) begin
                        state <= STATE_REFILL_WAIT;
                    end
                end

                STATE_REFILL_WAIT: begin
                    if (mem_resp_valid && mem_resp_ready) begin
                        if (mem_resp_error) begin
                            response_fatal_reg <= 1'b1;
                            state <= STATE_RESPONSE;
                        end else begin
                            refill_buffer <= mem_resp_rdata;
                            word_counter <= {WORD_INDEX_WIDTH{1'b0}};
                            state <= STATE_INSTALL;
                        end
                    end
                end

                STATE_INSTALL: begin
                    if (word_counter == WORDS_PER_LINE-1) begin
                        state <= STATE_LOOKUP_READ;
                    end else begin
                        word_counter <= word_counter + 1'b1;
                    end
                end

                STATE_TAG_ERROR: begin
                    parity_pending_reg <=
                        parity_pending_reg & ~parity_clear_way;
                    if ((parity_pending_reg & ~parity_clear_way) ==
                        {WAYS{1'b0}}) begin
                        response_tag_parity_reg <= 1'b1;
                        state <= STATE_RESPONSE;
                    end
                end

                STATE_RESPONSE: begin
                    if (resp_valid && resp_ready) begin
                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                    response_fatal_reg <= 1'b1;
                end
            endcase
        end
    end

endmodule
