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
// Date: 22/07/2024
// Description: Snooper module to collect and filter control-flow data from CVA6

`include "axi/typedef.svh"
`include "axi/assign.svh"
`include "register_interface/typedef.svh"
`include "register_interface/assign.svh"

module snooper
   import snooper_pkg::*;
   import cfg_regs_reg_pkg::*;
   import trace_regs_reg_pkg::*;
#(
   parameter int unsigned AXI_ID_WIDTH = 8,
   parameter int unsigned AXI_ADDR_WIDTH = 48,
   parameter int unsigned AXI_DATA_WIDTH = 64,
   parameter int unsigned AXI_USER_WIDTH = 2,
   parameter int unsigned ADDR_WIDTH = 32,
   parameter int unsigned DATA_WIDTH = 32,
   parameter int unsigned NR_COMMIT_PORTS = 2,
   parameter int unsigned XLEN = 64,
   parameter              type axi_aw_chan_t = logic,
   parameter              type axi_ar_chan_t = logic,
   parameter              type axi_r_chan_t = logic,
   parameter              type axi_w_chan_t = logic,
   parameter              type axi_b_chan_t = logic,
   parameter              type axi_req_t = logic,
   parameter              type axi_rsp_t = logic
)  (
   input  logic                 clk_i,
   input  logic                 rst_ni,
   input  axi_req_t             axi_sw_req_i,
   output axi_rsp_t             axi_sw_rsp_o,
   input  axi_req_t             axi_cfg_req_i,
   output axi_rsp_t             axi_cfg_rsp_o,
   input  riscv::ctr_port_t [NR_COMMIT_PORTS-1:0] ctr_commit_i,
   output logic                 trigger_o,
   output logic                 core_select_o,
   output logic                 watermark_irq_o
);

/////////////////////////////
// Defines and Assignments //
/////////////////////////////

   localparam int unsigned NumFields = 5;
   localparam int unsigned NumBanks  = 8;
   localparam int unsigned NumWords  = 4096;
   localparam int unsigned MemAddrWidth  = 14;
   localparam int unsigned NumReadMst = AXI_DATA_WIDTH / DATA_WIDTH;

   typedef logic [ADDR_WIDTH-1:0]   addr_lite_t;
   typedef logic [DATA_WIDTH-1:0]   data_lite_t;
   typedef logic [DATA_WIDTH/8-1:0] strb_lite_t;

   `REG_BUS_TYPEDEF_ALL(reg, addr_lite_t, data_lite_t, strb_lite_t)

   logic [NumFields-1:0]                     buff_req;
   logic [NumFields-1:0] [MemAddrWidth-1:0 ] buff_add;
   logic [NumFields-1:0]                     buff_wen;
   logic [NumFields-1:0] [DATA_WIDTH-1:0]    buff_wdata;
   logic [NumFields-1:0] [DATA_WIDTH/8-1:0]  buff_be;
   logic [NumFields-1:0]                     buff_r_valid;
   logic [NumFields-1:0]                     buff_gnt;
   logic [NumFields-1:0] [DATA_WIDTH-1:0]    buff_r_data;

   logic [NumReadMst-1:0]                   sw_req;
   logic [NumReadMst-1:0][MemAddrWidth-1:0] sw_add;
   logic [NumReadMst-1:0]                   sw_wen;
   logic [NumReadMst-1:0][DATA_WIDTH-1:0]   sw_wdata;
   logic [NumReadMst-1:0]                   sw_gnt;
   logic [NumReadMst-1:0]                   sw_r_valid;
   logic [NumReadMst-1:0][DATA_WIDTH-1:0]   sw_r_rdata;
   logic [NumReadMst-1:0][DATA_WIDTH/8-1:0] sw_be;

   logic snoop_en;

   logic [MemAddrWidth-1:0] cnt;
   logic [MemAddrWidth-1:0] first_valid;
   logic [MemAddrWidth-1:0] last_valid;

   logic trigger_edge;
   logic [31:0] watermark_lvl;
   logic        read_en;

   reg_req_t cfg_reg_req;
   reg_rsp_t cfg_reg_rsp;

   cfg_regs_hw2reg_t cfg_hw2reg;
   cfg_regs_reg2hw_t cfg_reg2hw;

   trace_regs_hw2reg_t trace_hw2reg;
   trace_regs_reg2hw_t trace_reg2hw;

   trace_t trace_buff;

   riscv::priv_lvl_t priv_lvl;
   riscv::ctrtarget_rv_t emitter_target;
   riscv::ctrsource_rv_t emitter_source;
   riscv::ctr_type_t emitter_data;
   logic [31:0] emitter_instr;
   logic [NR_COMMIT_PORTS-1:0] filter_en;

   axi_req_t   axi_req_cut;
   axi_rsp_t  axi_rsp_cut;

   assign cfg_hw2reg.base.de = 1'b1;
   assign cfg_hw2reg.base.d  = first_valid;

   assign cfg_hw2reg.last.de = 1'b1;
   assign cfg_hw2reg.last.d  = last_valid;

   assign cfg_hw2reg.ctrl.pc_range_0.de = trigger_edge;
   assign cfg_hw2reg.ctrl.pc_range_0.d  = 1'b0;

   assign cfg_hw2reg.ctrl.pc_range_1.de = trigger_edge;
   assign cfg_hw2reg.ctrl.pc_range_1.d  = 1'b0;

   assign cfg_hw2reg.ctrl.pc_range_2.de = trigger_edge;
   assign cfg_hw2reg.ctrl.pc_range_2.d  = 1'b0;

   assign cfg_hw2reg.ctrl.pc_range_3.de = trigger_edge;
   assign cfg_hw2reg.ctrl.pc_range_3.d  = 1'b0;

   assign cfg_hw2reg.ctrl.trig_pc_0.de = trigger_edge;
   assign cfg_hw2reg.ctrl.trig_pc_0.d  = 1'b0;

   assign cfg_hw2reg.ctrl.trig_pc_1.de = trigger_edge;
   assign cfg_hw2reg.ctrl.trig_pc_1.d  = 1'b0;

   assign cfg_hw2reg.ctrl.trig_pc_2.de = trigger_edge;
   assign cfg_hw2reg.ctrl.trig_pc_2.d  = 1'b0;

   assign cfg_hw2reg.ctrl.trig_pc_3.de = trigger_edge;
   assign cfg_hw2reg.ctrl.trig_pc_3.d  = 1'b0;

   assign cfg_hw2reg.ctrl.u_mode.de = trigger_edge;
   assign cfg_hw2reg.ctrl.u_mode.d  = 1'b0;

   assign cfg_hw2reg.ctrl.s_mode.de = trigger_edge;
   assign cfg_hw2reg.ctrl.s_mode.d  = 1'b0;

   assign cfg_hw2reg.ctrl.m_mode.de = trigger_edge;
   assign cfg_hw2reg.ctrl.m_mode.d  = 1'b0;

   assign cfg_hw2reg.ctrl.trigger_irq.de = trigger_edge;
   assign cfg_hw2reg.ctrl.trigger_irq.d  = 1'b1;

   assign core_select_o = cfg_reg2hw.ctrl.core_select.q;

   assign read_en = sw_req && sw_gnt && ~sw_wen;

   assign watermark_lvl = cfg_reg2hw.watermark_lvl.q;

   assign trigger_o = cfg_reg2hw.ctrl.level_trigger_en ? cfg_reg2hw.ctrl.trigger_irq : trigger_edge;
////////////////////
// Snooping Logic //
////////////////////

   // Enable the snooper to collect data only when needed
   trace_filter #(
      .NR_COMMIT_PORTS(NR_COMMIT_PORTS)
   ) u_trace_filter (
      .ctr_commit_i(ctr_commit_i),
      .config_i    (cfg_reg2hw),
      .enable_o    (filter_en)
   );

   ctr_unit #(
      .NR_COMMIT_PORTS(NR_COMMIT_PORTS),
      .XLEN(XLEN)
   ) i_ctr_unit (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .ctr_commit_ports_i (ctr_commit_i),
      .filter_enable_i    (filter_en),
      .emitter_source_o   (emitter_source),
      .emitter_target_o   (emitter_target),
      .emitter_data_o     (emitter_data),
      .emitter_instr_o    (emitter_instr),
      .priv_lvl_o         (priv_lvl)
   );

   assign trace_hw2reg.priv_lvl.unused.de   = 1'b1;
   assign trace_hw2reg.priv_lvl.priv_lvl.de = 1'b1;
   assign trace_hw2reg.pc_src_h.de          = 1'b1;
   assign trace_hw2reg.pc_src_l.de          = 1'b1;
   assign trace_hw2reg.pc_dst_h.de          = 1'b1;
   assign trace_hw2reg.pc_dst_l.de          = 1'b1;
   assign trace_hw2reg.metadata.de          = 1'b1;
   assign trace_hw2reg.opcode.de            = 1'b1;
   assign trace_hw2reg.valid.de             = 1'b1;

   assign trace_hw2reg.priv_lvl.unused.d    = '0;
   assign trace_hw2reg.priv_lvl.priv_lvl.d  = priv_lvl;
   assign trace_hw2reg.pc_src_h.d           = { 1'b0, emitter_source.pc[62:32] };
   assign trace_hw2reg.pc_src_l.d           = { emitter_source.pc[31:1], 1'b0  };
   assign trace_hw2reg.pc_dst_h.d           = { 1'b0, emitter_target.pc[62:32] };
   assign trace_hw2reg.pc_dst_l.d           = { emitter_target.pc[31:1], 1'b0  };
   assign trace_hw2reg.metadata.d           = { 28'b0, emitter_data            };
   assign trace_hw2reg.opcode.d             = emitter_instr;
   assign trace_hw2reg.valid.d              = emitter_source.v;

   // Buffering the input traces
   trace_regs_reg_top #(
     .reg_req_t  ( reg_req_t ),
     .reg_rsp_t  ( reg_rsp_t )
   ) u_fields_buff (
     .clk_i      ( clk_i         ),
     .rst_ni     ( rst_ni        ),
     .reg_req_i  ( '0            ),
     .reg_rsp_o  (               ),
     .reg2hw     ( trace_reg2hw  ),
     .hw2reg     ( trace_hw2reg  ),
     .devmode_i  ( 1'b0          )
   );

   assign trace_buff.priv_lvl               = riscv::priv_lvl_t'(trace_reg2hw.priv_lvl.priv_lvl.q);
   assign trace_buff.pc_src_h               = trace_reg2hw.pc_src_h.q;
   assign trace_buff.pc_src_l               = trace_reg2hw.pc_src_l.q;
   assign trace_buff.pc_dst_h               = trace_reg2hw.pc_dst_h.q;
   assign trace_buff.pc_dst_l               = trace_reg2hw.pc_dst_l.q;
   assign trace_buff.metadata               = riscv::ctr_type_t'(trace_reg2hw.metadata.q);
   assign trace_buff.opcode                 = trace_reg2hw.opcode.q;
   assign trace_buff.pc_v                   = trace_reg2hw.valid.q;

   snooping_engine #(
       .NumFields ( NumFields           ),
       .AddrWidth ( MemAddrWidth        ),
       .DataWidth ( DATA_WIDTH )
   ) i_snooping_engine (
       .clk_i           ( clk_i           ),
       .rst_ni          ( rst_ni          ),
       // Memory interface
       .buff_req_o      ( buff_req        ),
       .buff_add_o      ( buff_add        ),
       .buff_wen_o      ( buff_wen        ),
       .buff_wdata_o    ( buff_wdata      ),
       .buff_be_o       ( buff_be         ),
       // Control interface
       .traces_i        ( trace_buff      ),
       .config_i        ( cfg_reg2hw      ),
       .snoop_en_i      ( trace_buff.pc_v ),
       // Last valid entry
       .cnt_o           ( cnt             ),
       .first_valid_o   ( first_valid     ),
       .last_valid_o    ( last_valid      ),
       .read_en_i       ( read_en         ),
       .watermark_lvl_i ( watermark_lvl   ),
       .watermark_irq_o ( watermark_irq_o )
   );

///////////////////////////
// Circular Buffer Logic //
///////////////////////////

   // Break comb path between DW conv and AXI2MEM
   axi_cut #(
       .aw_chan_t  ( axi_aw_chan_t ),
       .w_chan_t   ( axi_w_chan_t  ),
       .b_chan_t   ( axi_b_chan_t  ),
       .ar_chan_t  ( axi_ar_chan_t ),
       .r_chan_t   ( axi_r_chan_t  ),
       .axi_req_t  ( axi_req_t     ),
       .axi_resp_t ( axi_rsp_t     )
   ) i_axi_cut (
       .clk_i      ( clk_i         ),
       .rst_ni     ( rst_ni        ),
       .slv_req_i  ( axi_sw_req_i  ),
       .slv_resp_o ( axi_sw_rsp_o  ),
       .mst_req_o  ( axi_req_cut   ),
       .mst_resp_i ( axi_rsp_cut   )
   );

   axi_to_mem #(
       .axi_req_t    ( axi_req_t        ),
       .axi_resp_t   ( axi_rsp_t        ),
       .AddrWidth    ( MemAddrWidth     ),
       .DataWidth    ( AXI_DATA_WIDTH   ),
       .IdWidth      ( AXI_ID_WIDTH     ),
       .NumBanks     ( NumReadMst       ),
       .BufDepth     ( 1                ),
       .HideStrb     ( 1'b0             ),
       .OutFifoDepth ( 1                )
   ) i_axi_to_mem (
       .clk_i        ( clk_i         ),
       .rst_ni       ( rst_ni        ),
       .busy_o       (               ),
       .axi_req_i    ( axi_req_cut   ),
       .axi_resp_o   ( axi_rsp_cut   ),
       .mem_req_o    ( sw_req        ),
       .mem_gnt_i    ( sw_gnt        ),
       .mem_addr_o   ( sw_add        ),
       .mem_wdata_o  ( sw_wdata      ),
       .mem_strb_o   ( sw_be         ),
       .mem_atop_o   (               ),
       .mem_we_o     ( sw_wen        ),
       .mem_rvalid_i ( sw_r_valid    ),
       .mem_rdata_i  ( sw_r_rdata    )
   );

   circular_buffer  #(
       .SlvNumWords  ( NumWords               ),
       .SlvDataWidth ( DATA_WIDTH             ),
       .NumSlv       ( NumBanks               ),
       .NumMst       ( NumFields + NumReadMst ),
       .MstAddrWidth ( MemAddrWidth           )
   ) i_circular_buff (
       .clk_i     (   clk_i                       ),
       .rst_ni    (   rst_ni                      ),
       .req_i     ( { buff_req     , sw_req     } ),
       .wen_i     ( { buff_wen     , sw_wen     } ),
       .gnt_o     ( { buff_gnt     , sw_gnt     } ),
       .add_i     ( { buff_add     , sw_add     } ),
       .wdata_i   ( { buff_wdata   , sw_wdata   } ),
       .be_i      ( { buff_be      , sw_be      } ),
       .r_valid_o ( { buff_r_valid , sw_r_valid } ),
       .r_rdata_o ( { buff_r_data  , sw_r_rdata } )
   );

/////////////////////////
// Configuration Logic //
/////////////////////////

   // Convert from AXI to reg protocol
   axi_to_reg_v2 #(
      .AxiAddrWidth ( AXI_ADDR_WIDTH ),
      .AxiDataWidth ( AXI_DATA_WIDTH ),
      .AxiIdWidth   ( AXI_ID_WIDTH   ),
      .AxiUserWidth ( AXI_USER_WIDTH ),
      .RegDataWidth ( DATA_WIDTH     ),
      .axi_req_t    ( axi_req_t ),
      .axi_rsp_t    ( axi_rsp_t ),
      .reg_req_t    ( reg_req_t ),
      .reg_rsp_t    ( reg_rsp_t )
   ) i_axi_to_reg_v2 (
      .clk_i,
      .rst_ni,
      .axi_req_i ( axi_cfg_req_i ),
      .axi_rsp_o ( axi_cfg_rsp_o ),
      .reg_req_o ( cfg_reg_req   ),
      .reg_rsp_i ( cfg_reg_rsp   ),
      .reg_id_o  ( ),
      .busy_o    ( )
   );

   cfg_regs_reg_top #(
     .reg_req_t  ( reg_req_t ),
     .reg_rsp_t  ( reg_rsp_t )
   ) flash_buffer (
     .clk_i      ( clk_i       ),
     .rst_ni     ( rst_ni      ),
     .reg_req_i  ( cfg_reg_req ),
     .reg_rsp_o  ( cfg_reg_rsp ),
     .reg2hw     ( cfg_reg2hw  ),
     .hw2reg     ( cfg_hw2reg  ),
     .devmode_i  ( 1'b0        )
   );

///////////////////////
// Triggering Logic  //
///////////////////////

   trigger #(
    .NR_COMMIT_PORTS(NR_COMMIT_PORTS)
   ) inference_trigger (
    .traces_i ( ctr_commit_i ),
    .config_i ( cfg_reg2hw   ),
    .irq_o    ( trigger_edge )
   );

endmodule
