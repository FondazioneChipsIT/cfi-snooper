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
// Author: Emanuele Parisi, University of Bologna
// Description: Control Transfer Records unit.


module ctr_unit
  import ariane_pkg::*;
#(
    parameter int unsigned NR_COMMIT_PORTS = 2,
    parameter int unsigned XLEN = 64
) (
    // Subsystem clock - SUBSYSTEM
    input  logic                        clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input  logic                        rst_ni,
    // Input commit ports
    input  riscv::ctr_port_t [NR_COMMIT_PORTS-1:0] ctr_commit_ports_i,
    // Filter enable
    input  logic [1:0]                  filter_enable_i,
    // Control Transfer Records source register - CTR_UNIT
    output riscv::ctrsource_rv_t        emitter_source_o,
    // Control Transfer Records target register - CTR_UNIT
    output riscv::ctrtarget_rv_t        emitter_target_o,
    // Control Transfer Records data register - CTR_UNIT
    output riscv::ctr_type_t            emitter_data_o,
    // Control Transfer Records instr register - CTR_UNIT
    output logic                 [31:0] emitter_instr_o,
    // Privilege execution level - CTR_UNIT
    output riscv::priv_lvl_t            priv_lvl_o
);

  riscv::ctr_port_t ctr_sbe_entry_out;

  localparam int ReqFifoWidth = $bits(riscv::ctr_port_t);
  logic fifo_empty, fifo_full, fifo_out_valid;

  assign priv_lvl_o = ctr_sbe_entry_out.priv_lvl;
  assign fifo_out_valid = ~fifo_empty;


  // Dual port fifo to serialize CVA6 commit ports
  fifo_dp_v3 #(
      .FALL_THROUGH(1'b1),
      .DATA_WIDTH  (ReqFifoWidth),
      .DEPTH       (32),
      .dtype       (riscv::ctr_port_t)
  ) dual_port_fifo (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .flush_i      (1'b0),
      .testmode_i   (1'b0),
      .full_o       (fifo_full),
      .empty_o      (fifo_empty),
      .usage_o      (),
      .data_port_0_i(ctr_commit_ports_i[0]),
      .push_port_0_i(~fifo_full && ctr_commit_ports_i[0].valid && filter_enable_i[0]),
      .data_port_1_i(ctr_commit_ports_i[1]),
      .push_port_1_i(~fifo_full && ctr_commit_ports_i[1].valid && filter_enable_i[1]),
      .data_o       (ctr_sbe_entry_out),
      .pop_i        (fifo_out_valid)
  );

  always_comb begin
    emitter_source_o = 'b0;
    emitter_target_o = 'b0;
    emitter_data_o   = riscv::CTR_TYPE_NONE;
    emitter_instr_o  = 'b0;
    if (fifo_out_valid) begin
      emitter_source_o.pc = ctr_sbe_entry_out.ctr_source[XLEN-1:1];
      emitter_source_o.v = fifo_out_valid;
      // The MISP bit is unimplemented.
      emitter_target_o.pc = ctr_sbe_entry_out.ctr_target[XLEN-1:1];
      emitter_target_o.misp = 'b0;
      // Cycle counting is unimplemented.
      emitter_data_o = ctr_sbe_entry_out.ctr_type;
      emitter_instr_o = ctr_sbe_entry_out.ctr_instr;
    end
  end

endmodule
