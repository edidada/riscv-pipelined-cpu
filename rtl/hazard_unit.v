`timescale 1ns/1ps
`include "defs.vh"

// Hazard detection unit. Two independent jobs:
//
// (1) LOAD-USE (always active when HAZARD_EN=1): a load's data appears at
//     the end of MEM, so even with forwarding it cannot reach an
//     instruction that would be in EX in the very next cycle. One bubble
//     is unavoidable:
//
//       lw  x1, 0(x2)     IF  ID  EX  MEM  WB
//       add x3, x1, x4    IF  ID  ID  EX   MEM  (ID replayed, EX = NOP)
//
//     With one stall the consumer reaches EX exactly when the load is in
//     WB, at which point MEM/WB forwarding can supply the loaded data.
//
//     Implementation = three precise operations on pipeline state:
//       pc_write     = 0 : hold the PC and its instruction
//       if_id_hold   = 1 : re-decode the same instruction next cycle
//       id_ex_bubble = 1 : force the next EX slot's control to zero
//
// (2) STALL_ALL_DEP=1 ("stall_only" mode, no forwarding): stall on ANY
//     RAW dependency whose producer is still in ID/EX or EX/MEM. Stall
//     for two cycles:
//
//       add x1,...    IF ID EX MEM WB
//       add x2,x1,..  IF ID ID ID EX MEM WB
//
//     The producer is in WB while the consumer is still in ID. Because
//     the register file is written on negedge (first half) and the ID
//     read is captured at the following posedge (second half), the
//     consumer then reads the correct value. Note the producer in
//     MEM/WB is deliberately NOT a stall condition: that would add a
//     useless third bubble.
//
// Redirects from EX (taken branch/jump) are combined with these signals
// in cpu.v and take priority over a replay.
module hazard_unit #(
    parameter STALL_ALL_DEP = 0
) (
    input  wire       id_ex_mem_read,
    input  wire [4:0] id_ex_rd,
    input  wire       id_ex_reg_write,
    input  wire [4:0] if_id_rs1,
    input  wire [4:0] if_id_rs2,
    input  wire       if_id_uses_rs1,
    input  wire       if_id_uses_rs2,
    input  wire       ex_mem_reg_write,
    input  wire [4:0] ex_mem_rd,
    input  wire       mem_wb_reg_write,
    input  wire [4:0] mem_wb_rd,

    output wire       load_use_hazard,
    output wire       stall,
    output wire       pc_write,
    output wire       if_id_hold,
    output wire       id_ex_bubble
);
    wire rs1_match = if_id_uses_rs1 && (if_id_rs1 != 5'b0) && (if_id_rs1 == id_ex_rd);
    wire rs2_match = if_id_uses_rs2 && (if_id_rs2 != 5'b0) && (if_id_rs2 == id_ex_rd);

    assign load_use_hazard = id_ex_mem_read && id_ex_reg_write &&
                            (id_ex_rd != 5'b0) && (rs1_match || rs2_match);

    // Producer one stage ahead of the consumer (ID/EX): the consumer
    // would be in EX when this producer is only in MEM.
    wire id_dep = id_ex_reg_write && (id_ex_rd != 5'b0) &&
                  (rs1_match || rs2_match);

    wire ex_rs1_match = if_id_uses_rs1 && (if_id_rs1 != 5'b0) &&
                        (if_id_rs1 == ex_mem_rd);
    wire ex_rs2_match = if_id_uses_rs2 && (if_id_rs2 != 5'b0) &&
                        (if_id_rs2 == ex_mem_rd);
    wire ex_dep = ex_mem_reg_write && (ex_mem_rd != 5'b0) &&
                  (ex_rs1_match || ex_rs2_match);

    generate
        if (STALL_ALL_DEP) begin : gen_stall_all
            assign stall = load_use_hazard || id_dep || ex_dep;
        end else begin : gen_stall_load_use_only
            assign stall = load_use_hazard;
        end
    endgenerate

    assign pc_write     = ~stall;
    assign if_id_hold   =  stall;
    assign id_ex_bubble =  stall;
endmodule
