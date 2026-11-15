`include "defs.vh"

// EXPERIMENT ONLY -- README section 6, exercise 4.
//
// This is a deliberately OVER-CONSERVATIVE hazard_unit.v, compiled only
// by tools/exercises.py into a scratch -I directory. It is NOT part of
// rtl/ and never affects the normal CI simulation matrix.
//
// The change versus rtl/hazard_unit.v is one condition:
//
//   original : load_use_hazard = id_ex_mem_read && id_ex_reg_write && ...
//   here     : load_use_hazard =          id_ex_reg_write && ...
//              ^^^^^^^^^^^^^^^^ dropped
//
// That makes the core stall on ANY RAW dependency whose producer is in
// ID/EX, not just on loads. Results stay CORRECT (the consumer simply
// starts later), but the pipeline inserts many useless bubbles and the
// CPI gets noticeably worse. This is exactly the experiment:
//   "把 load_use_hazard 的 id_ex_mem_read 条件去掉，重跑，看多停顿几拍
//    但结果仍对不对、CPI 变成多少。"
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

    // *** THE ONE-LINE CHANGE: id_ex_mem_read removed ***
    assign load_use_hazard = id_ex_reg_write &&
                            (id_ex_rd != 5'b0) && (rs1_match || rs2_match);

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
