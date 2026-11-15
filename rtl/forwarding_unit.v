`timescale 1ns/1ps
`include "defs.vh"

// EX-stage operand forwarding.
//
// Priority: EX/MEM (the instruction one stage ahead) wins over MEM/WB
// (two stages ahead), because the younger instruction is the one whose
// result must be observed. A zero destination is never forwarded: x0 is
// hardwired to zero, so forwarding "into" it must be suppressed.
//
// The classic hazard this fixes:
//     add x1, x2, x3     ; result is produced in EX, written in WB
//     sub x4, x1, x5     ; needs x1 in EX one cycle later
// Without forwarding, the sub reads the stale register file value.
//
// ENABLE_EXMEM=0 disables only the early (one-stage-ahead) path. It is
// used by the "stall_only" configuration: stall on every RAW dependency,
// but still forward the value being written back in the same cycle. That
// makes the mode correct without any reliance on intra-cycle register
// file read/write ordering.
module forwarding_unit #(
    parameter ENABLE_EXMEM = 1
) (
    input  wire [4:0]  id_ex_rs1,
    input  wire [4:0]  id_ex_rs2,
    input  wire        id_ex_uses_rs1,
    input  wire        id_ex_uses_rs2,
    input  wire [4:0]  ex_mem_rd,
    input  wire        ex_mem_reg_write,
    input  wire [4:0]  mem_wb_rd,
    input  wire        mem_wb_reg_write,

    output reg  [1:0]  forward_a,   // 00 = regfile, 01 = EX/MEM, 10 = MEM/WB
    output reg  [1:0]  forward_b
);
    `define FWD_NONE  2'b00
    `define FWD_EXMEM 2'b01
    `define FWD_MEMWB 2'b10

    always @* begin
        forward_a = `FWD_NONE;
        forward_b = `FWD_NONE;

        if (id_ex_uses_rs1 && (id_ex_rs1 != 5'b0)) begin
            if (ENABLE_EXMEM && ex_mem_reg_write && (ex_mem_rd == id_ex_rs1))
                forward_a = `FWD_EXMEM;
            else if (mem_wb_reg_write && (mem_wb_rd == id_ex_rs1))
                forward_a = `FWD_MEMWB;
        end

        if (id_ex_uses_rs2 && (id_ex_rs2 != 5'b0)) begin
            if (ENABLE_EXMEM && ex_mem_reg_write && (ex_mem_rd == id_ex_rs2))
                forward_b = `FWD_EXMEM;
            else if (mem_wb_reg_write && (mem_wb_rd == id_ex_rs2))
                forward_b = `FWD_MEMWB;
        end
    end
endmodule
