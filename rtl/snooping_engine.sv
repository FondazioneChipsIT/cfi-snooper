// Copyright 2024 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Maicol Ciani <maicol.ciani@unibo.it> University of Bologna
// Date: 24/07/2024

module snooping_engine
    import snooper_pkg::*;
    import cfg_regs_reg_pkg::*;
#(
    parameter int unsigned NumFields = 5,
    parameter int unsigned AddrWidth = 15,
    parameter int unsigned DataWidth = 32
)  (
    input  logic clk_i,
    input  logic rst_ni,
    // Memory interface
    output logic [NumFields-1:0]                   buff_req_o,
    output logic [NumFields-1:0] [AddrWidth-1:0]   buff_add_o,
    output logic [NumFields-1:0]                   buff_wen_o,
    output logic [NumFields-1:0] [DataWidth-1:0]   buff_wdata_o,
    output logic [NumFields-1:0] [DataWidth/8-1:0] buff_be_o,
    // Control interface
    input trace_t                                  traces_i,
    input cfg_regs_reg2hw_t                        config_i,
    input logic                                    snoop_en_i,
    // Last Valid Entry
    output logic [AddrWidth-1:0]                   cnt_o,
    output logic [AddrWidth-1:0]                   first_valid_o,
    output logic [AddrWidth-1:0]                   last_valid_o,
    // New additions
    input  logic                                   read_en_i,   // Input to indicate read on AXI
    input  logic [31:0]                            watermark_lvl_i,
    output logic                                   watermark_irq_o
);

    typedef enum logic [1:0] {
        ADDRESS     = 2'b00,
        INSTRUCTION = 2'b01
    } modes_t;

    localparam logic [AddrWidth-1:0] ADDR_MODE_MAX   = 16'h3FE8;
    localparam logic [AddrWidth-1:0] INSTR_MODE_MAX  = 16'h3FFC;
    localparam logic [AddrWidth-1:0] ADDR_MODE_INCR  = 20; // 4*5 bytes
    localparam logic [AddrWidth-1:0] INSTR_MODE_INCR = 4;

    logic buffer_full_q, buffer_full_d;
    logic [AddrWidth-1:0] first_valid_d, last_valid_d;

    logic [AddrWidth-1:0] next_cnt;

    logic [AddrWidth-1:0] cnt_o_incr;
    logic [15:0]          BUFFER_SIZE;
    logic [AddrWidth-1:0] entries_in_buffer;

    logic [AddrWidth-1:0] last_read_q, last_read_d; // Internal last_read pointer

    // Assign write data based on trace mode
    assign buff_wdata_o = config_i.ctrl.trace_mode.q[0] ?
                    { 32'h0,
                        32'h0,
                        32'h0,
                        32'h0,
                        traces_i.opcode } :
                    { traces_i.metadata,
                        traces_i.pc_dst_h,
                        traces_i.pc_dst_l,
                        traces_i.pc_src_h,
                        traces_i.pc_src_l };

    assign cnt_o_incr = config_i.ctrl.trace_mode.q[0] ?
                        INSTR_MODE_INCR               :
                        ADDR_MODE_INCR                ;

    // Set BUFFER_SIZE based on trace mode
    always_comb begin : set_buffer_size
        unique case (config_i.ctrl.trace_mode.q)
            ADDRESS: begin
                BUFFER_SIZE = ADDR_MODE_MAX + ADDR_MODE_INCR; // 16360 + 20 = 16380
            end
            INSTRUCTION: begin
                BUFFER_SIZE = INSTR_MODE_MAX + INSTR_MODE_INCR; // 16380 + 4 = 16384
            end
            default: begin
                BUFFER_SIZE = 16'h4000; // Default buffer size
            end
        endcase
    end

    // Memory Interface FSM
    always_comb begin : mem_interface_fsm
        buff_req_o   = '0;
        buff_add_o   = '0;
        buff_wen_o   = '0;
        buff_be_o    = '1;

        case(config_i.ctrl.trace_mode.q)
            ADDRESS: begin
                if(snoop_en_i) begin
                    for(int i = 0; i < NumFields; i++) begin
                        buff_req_o[i]   = 1'b1;
                        buff_wen_o[i]   = 1'b1;
                        buff_add_o[i]   = cnt_o + 4*i;
                        buff_be_o[i]    = '1;
                    end
                end
            end
            INSTRUCTION: begin
                if(snoop_en_i) begin
                    buff_req_o[0]   = 1'b1;
                    buff_wen_o[0]   = 1'b1;
                    buff_add_o[0]   = cnt_o;
                    buff_be_o[0]    = '1;
                end
            end
            default: begin
                buff_req_o   = '0;
                buff_add_o   = '0;
                buff_wen_o   = '0;
                buff_be_o    = '0;
            end
        endcase
    end

    always_comb begin
        last_valid_d = last_valid_o;
        first_valid_d = first_valid_o;
        if (config_i.ctrl.cnt_rst.q) begin
            last_valid_d = '0;
            first_valid_d = '0;
        end else if (snoop_en_i) begin
            last_valid_d = cnt_o;
            if (buffer_full_q) begin
                first_valid_d = first_valid_o + cnt_o_incr;
                if (first_valid_o >= BUFFER_SIZE) begin
                    first_valid_d = first_valid_o - BUFFER_SIZE;
                end
            end
        end
    end

    always_comb begin
        last_read_d = last_read_q;
        if (config_i.ctrl.cnt_rst.q) begin
            last_read_d = '0;
        end else if (read_en_i) begin
            case (config_i.ctrl.trace_mode.q)
                ADDRESS: begin
                    last_read_d = last_read_q + ADDR_MODE_INCR;
                    if (last_read_q >= BUFFER_SIZE - ADDR_MODE_INCR) begin
                        last_read_d = last_read_q - BUFFER_SIZE;
                    end
                end
                INSTRUCTION: begin
                    last_read_d = last_read_q + INSTR_MODE_INCR;
                    if (last_read_q >= BUFFER_SIZE - INSTR_MODE_INCR) begin
                        last_read_d = last_read_q - BUFFER_SIZE;
                    end
                end
            endcase
        end
    end

    always_comb begin : compute_entries_in_buffer
        if (last_valid_o >= last_read_q) begin
            entries_in_buffer = last_valid_o - last_read_q;
        end else begin
            entries_in_buffer = BUFFER_SIZE - last_read_q + last_valid_o;
        end
    end

    always_comb begin
        next_cnt = cnt_o;
        buffer_full_d = buffer_full_q;
        if (config_i.ctrl.cnt_rst.q) begin
            next_cnt = '0;
            buffer_full_d = 1'b0;
        end else if (snoop_en_i) begin
            if (cnt_o + cnt_o_incr >= BUFFER_SIZE) begin
                next_cnt = '0;
                buffer_full_d = 1'b1;
            end else begin
                next_cnt = cnt_o + cnt_o_incr;
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            first_valid_o <= '0;
            last_valid_o  <= '0;
            last_read_q <= '0;
            cnt_o <= 1'b0;
            buffer_full_q <= 1'b0;
        end else begin
            first_valid_o <= first_valid_d;
            last_valid_o <= last_valid_d;
            last_read_q <= last_read_d;
            cnt_o <= next_cnt;
            buffer_full_q <= buffer_full_d;
        end
    end

    // IRQ Logic
    assign watermark_irq_o = config_i.ctrl.watermark_en.q ? ((entries_in_buffer >> 2) >= watermark_lvl_i) : 1'b0;

endmodule
