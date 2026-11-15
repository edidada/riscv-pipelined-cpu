`timescale 1ns/1ps
`include "defs.vh"

// Main decoder: instruction -> control bundle. Kept deliberately flat
// (one output per signal) so the pipeline registers can carry the whole
// bundle verbatim and hazard/flush logic can zero it with one assign.
//
// IMPORTANT: an instruction whose rd is x0 writes nothing. That includes
// the canonical NOP 0x00000013 (= addi x0,x0,0), which is also the
// encoding used for pipeline bubbles and flushed wrong-path slots. Such
// instructions must never be reported to the hazard / forwarding units
// as producers or consumers.
module control (
    input  wire [6:0]  opcode,
    input  wire [2:0]  funct3,
    input  wire [6:0]  funct7,
    input  wire [31:0] instr,

    output reg  [1:0]  wb_sel,
    output reg         reg_write,
    output reg         mem_read,
    output reg         mem_write,
    output reg  [2:0]  mem_width,
    output reg         mem_unsigned,
    output reg         branch,       // instruction MAY redirect the PC
    output reg         jump,         // unconditional redirect (JAL / JALR)
    output reg         jalr,         // redirect target is rs1 + imm
    output reg         alu_src_a,    // 0 = rs1, 1 = PC
    output reg         alu_src_b,    // 0 = rs2, 1 = imm
    output reg  [3:0]  alu_op,
    output reg  [2:0]  imm_sel,
    output reg         uses_rs1,
    output reg         uses_rs2,
    output reg         is_store,
    output reg         illegal
);
    wire rd_nonzero = (instr[11:7] != 5'b0);

    always @* begin
        // Safe default: an inert instruction that writes nothing.
        wb_sel        = `WB_ALU;
        reg_write     = 1'b0;
        mem_read      = 1'b0;
        mem_write     = 1'b0;
        mem_width     = `F3_LW;
        mem_unsigned  = 1'b0;
        branch        = 1'b0;
        jump          = 1'b0;
        jalr          = 1'b0;
        alu_src_a     = 1'b0;
        alu_src_b     = 1'b0;
        alu_op        = `ALU_ADD;
        imm_sel       = `IMM_I;
        uses_rs1      = 1'b0;
        uses_rs2      = 1'b0;
        is_store      = 1'b0;
        illegal       = 1'b0;

        case (opcode)
            `OP_LUI: begin
                if (rd_nonzero) begin
                    reg_write = 1'b1;
                    wb_sel    = `WB_IMM;
                end
                imm_sel   = `IMM_U;
            end

            `OP_AUIPC: begin
                if (rd_nonzero) reg_write = 1'b1;
                alu_src_a = 1'b1;
                alu_src_b = 1'b1;
                imm_sel   = `IMM_U;
            end

            `OP_JAL: begin
                if (rd_nonzero) begin
                    reg_write = 1'b1;
                    wb_sel    = `WB_PC4;
                end
                jump      = 1'b1;
                alu_src_a = 1'b1;   // PC + J-imm = jump target
                alu_src_b = 1'b1;
                imm_sel   = `IMM_J;
            end

            `OP_JALR: begin
                if (rd_nonzero) begin
                    reg_write = 1'b1;
                    wb_sel    = `WB_PC4;
                end
                jump      = 1'b1;
                jalr      = 1'b1;
                uses_rs1  = 1'b1;
                alu_src_a = 1'b0;   // rs1 + I-imm = jump target
                alu_src_b = 1'b1;
                imm_sel   = `IMM_I;
            end

            `OP_BRANCH: begin
                // Comparison operands are rs1 and rs2 (NOT PC and imm).
                // The branch target (PC + B-imm) is produced by a separate
                // adder in EX, in parallel with the comparison.
                branch    = 1'b1;
                uses_rs1  = 1'b1;
                uses_rs2  = 1'b1;
                alu_src_a = 1'b0;
                alu_src_b = 1'b0;
                imm_sel   = `IMM_B;
                case (funct3)
                    `F3_BEQ:  alu_op = `ALU_EQ;
                    `F3_BNE:  alu_op = `ALU_NE;
                    `F3_BLT:  alu_op = `ALU_LT;
                    `F3_BGE:  alu_op = `ALU_GE;
                    `F3_BLTU: alu_op = `ALU_LTU;
                    `F3_BGEU: alu_op = `ALU_GEU;
                    default:  illegal = 1'b1;
                endcase
            end

            `OP_LOAD: begin
                if (rd_nonzero) begin
                    reg_write = 1'b1;
                    wb_sel    = `WB_MEM;
                    mem_read  = 1'b1;
                end
                uses_rs1  = rd_nonzero;
                alu_src_b = 1'b1;
                mem_width = funct3;
                case (funct3)
                    `F3_LB, `F3_LH, `F3_LW: mem_unsigned = 1'b0;
                    `F3_LBU, `F3_LHU:       mem_unsigned = 1'b1;
                    default:               illegal = 1'b1;
                endcase
            end

            `OP_STORE: begin
                mem_write = 1'b1;
                is_store  = 1'b1;
                uses_rs1  = 1'b1;
                uses_rs2  = 1'b1;
                alu_src_b = 1'b1;
                imm_sel   = `IMM_S;
                mem_width = funct3;
                case (funct3)
                    `F3_SB, `F3_SH, `F3_SW: ;
                    default:                illegal = 1'b1;
                endcase
            end

            `OP_ITYPE: begin
                if (rd_nonzero) begin
                    reg_write = 1'b1;
                    uses_rs1  = 1'b1;
                end
                alu_src_b = 1'b1;
                case (funct3)
                    `F3_ADD_SUB: alu_op = `ALU_ADD;
                    `F3_SLL:     alu_op = `ALU_SLL;
                    `F3_SLT:     alu_op = `ALU_SLT;
                    `F3_SLTU:    alu_op = `ALU_SLTU;
                    `F3_XOR:     alu_op = `ALU_XOR;
                    `F3_SRL_SRA: alu_op = (funct7 == `F7_SUB_SRA) ? `ALU_SRA : `ALU_SRL;
                    `F3_OR:      alu_op = `ALU_OR;
                    `F3_AND:     alu_op = `ALU_AND;
                endcase
            end

            `OP_RTYPE: begin
                if (rd_nonzero) begin
                    reg_write = 1'b1;
                    uses_rs1  = 1'b1;
                    uses_rs2  = 1'b1;
                end
                case (funct3)
                    `F3_ADD_SUB: alu_op = (funct7 == `F7_SUB_SRA) ? `ALU_SUB : `ALU_ADD;
                    `F3_SLL:     alu_op = `ALU_SLL;
                    `F3_SLT:     alu_op = `ALU_SLT;
                    `F3_SLTU:    alu_op = `ALU_SLTU;
                    `F3_XOR:     alu_op = `ALU_XOR;
                    `F3_SRL_SRA: alu_op = (funct7 == `F7_SUB_SRA) ? `ALU_SRA : `ALU_SRL;
                    `F3_OR:      alu_op = `ALU_OR;
                    `F3_AND:     alu_op = `ALU_AND;
                endcase
            end

            // FENCE is a NOP in a single-hart, in-order core.
            `OP_FENCE: ;

            // ECALL / EBREAK is the testbench's program-end marker.
            // It writes nothing and is NOT illegal.
            `OP_SYSTEM: if (instr[31:20] != 12'h000) illegal = 1'b1;

            default: illegal = 1'b1;
        endcase
    end
endmodule
