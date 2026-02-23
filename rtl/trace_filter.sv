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
// Date: 29/07/2024

module trace_filter
  import snooper_pkg::*;
  import cfg_regs_reg_pkg::*;
  import riscv::*;
#(
    parameter int unsigned NR_COMMIT_PORTS = 2
) (
    input  riscv::ctr_port_t [NR_COMMIT_PORTS-1:0] ctr_commit_i,
    input  cfg_regs_reg2hw_t                       config_i,
    output logic             [NR_COMMIT_PORTS-1:0] enable_o
);

  logic [NR_COMMIT_PORTS-1:0] priv_lvl_en, ctr_type_en;
  logic [NR_COMMIT_PORTS-1:0][3:0] cfg_en;
  logic instr_en;

  assign instr_en = config_i.ctrl.trace_mode.q[0];

  always_comb begin : ctr_filter
    for (int i = 0; i < NR_COMMIT_PORTS; i++) begin
      ctr_type_en[i] = 1'b0;
      case (ctr_commit_i[i].ctr_type)
        CTR_TYPE_NONE: begin
          ctr_type_en[i] = 1'b0;
        end
        CTR_TYPE_EXC: begin
          ctr_type_en[i] = config_i.ctrl.excinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_INTR: begin
          ctr_type_en[i] = config_i.ctrl.intrinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_TRET: begin
          ctr_type_en[i] = config_i.ctrl.tretinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_NTBR: begin
          ctr_type_en[i] = config_i.ctrl.ntbren.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_TKBR: begin
          ctr_type_en[i] = config_i.ctrl.tkbrinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_INDCALL: begin
          ctr_type_en[i] = config_i.ctrl.indcallinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_DIRCALL: begin
          ctr_type_en[i] = config_i.ctrl.dircallinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_INDJMP: begin
          ctr_type_en[i] = config_i.ctrl.indjmpinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_DIRJMP: begin
          ctr_type_en[i] = config_i.ctrl.dirjmpinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_CORSWAP: begin
          ctr_type_en[i] = config_i.ctrl.corswapinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_RET: begin
          ctr_type_en[i] = config_i.ctrl.retinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_INDLJMP: begin
          ctr_type_en[i] = config_i.ctrl.indljmpinh.q ? 1'b0 : 1'b1;
        end
        CTR_TYPE_DIRLJMP: begin
          ctr_type_en[i] = config_i.ctrl.dirljmpinh.q ? 1'b0 : 1'b1;
        end
        default: begin
          ctr_type_en[i] = 1'b0;
        end
      endcase
    end
  end

  for (genvar i = 0; i < NR_COMMIT_PORTS; i++) begin
    assign priv_lvl_en[i] = ( config_i.ctrl.m_mode.q & ( ctr_commit_i[i].priv_lvl == PRIV_LVL_M )) |
                              ( config_i.ctrl.s_mode.q & ( ctr_commit_i[i].priv_lvl == PRIV_LVL_S )) |
                              ( config_i.ctrl.u_mode.q & ( ctr_commit_i[i].priv_lvl == PRIV_LVL_U ));

    assign cfg_en[i][0] =   config_i.ctrl.pc_range_0.q &
                              ({ config_i.range_0_base_h.q, config_i.range_0_base_l.q } <= ctr_commit_i[i].ctr_source) &
                              (ctr_commit_i[i].ctr_source <= { config_i.range_0_last_h.q, config_i.range_0_last_l.q });

    assign cfg_en[i][1] =   config_i.ctrl.pc_range_1.q &
                              ({ config_i.range_1_base_h.q, config_i.range_1_base_l.q } <= ctr_commit_i[i].ctr_source) &
                              (ctr_commit_i[i].ctr_source <= { config_i.range_1_last_h.q, config_i.range_1_last_l.q });

    assign cfg_en[i][2] =   config_i.ctrl.pc_range_2.q &
                              ({ config_i.range_2_base_h.q, config_i.range_2_base_l.q } <= ctr_commit_i[i].ctr_source) &
                              (ctr_commit_i[i].ctr_source <= { config_i.range_2_last_h.q, config_i.range_2_last_l.q });

    assign cfg_en[i][3] =   config_i.ctrl.pc_range_3.q &
                              ({ config_i.range_3_base_h.q, config_i.range_3_base_l.q } <= ctr_commit_i[i].ctr_source) &
                              (ctr_commit_i[i].ctr_source <= { config_i.range_3_last_h.q, config_i.range_3_last_l.q });

    assign enable_o[i] = ctr_commit_i[i].valid & priv_lvl_en[i] & (ctr_type_en[i] | instr_en) & |cfg_en[i];
  end

endmodule
