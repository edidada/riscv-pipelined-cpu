// Shared definitions for the teaching RV32I subset pipeline.
// Included with `include "defs.vh" from every module.

`ifndef RISCV_PIPELINE_DEFS_VH
`define RISCV_PIPELINE_DEFS_VH

// Opcodes (RV32I base opcode space)
`define OP_RTYPE   7'b0110011
`define OP_ITYPE   7'b0010011
`define OP_LOAD    7'b0000011
`define OP_STORE   7'b0100011
`define OP_BRANCH  7'b1100011
`define OP_LUI     7'b0110111
`define OP_AUIPC   7'b0010111
`define OP_JAL     7'b1101111
`define OP_JALR    7'b1100111
`define OP_FENCE   7'b0001111  // encoded as a NOP by this implementation
`define OP_SYSTEM  7'b1110011  // used as the "halt / simulation end" marker

// funct3
`define F3_ADD_SUB 3'b000  // ADD / SUB / ADDI
`define F3_SLL     3'b001  // SLL / SLLI
`define F3_SLT     3'b010  // SLT / SLTI
`define F3_SLTU    3'b011  // SLTU / SLTIU
`define F3_XOR     3'b100  // XOR / XORI
`define F3_SRL_SRA 3'b101  // SRL / SRA / SRLI / SRAI
`define F3_OR      3'b110  // OR  / ORI
`define F3_AND     3'b111  // AND / ANDI
`define F3_BEQ     3'b000
`define F3_BNE     3'b001
`define F3_BLT     3'b100
`define F3_BGE     3'b101
`define F3_BLTU    3'b110
`define F3_BGEU    3'b111
`define F3_LB      3'b000
`define F3_LH      3'b001
`define F3_LW      3'b010
`define F3_LBU     3'b100
`define F3_LHU     3'b101
`define F3_SB      3'b000
`define F3_SH      3'b001
`define F3_SW      3'b010

// funct7
`define F7_SUB_SRA 7'b0100000

// ALU operation selectors
`define ALU_ADD    4'b0000
`define ALU_SUB    4'b0001
`define ALU_SLL    4'b0010
`define ALU_SLT    4'b0011
`define ALU_SLTU   4'b0100
`define ALU_XOR    4'b0101
`define ALU_SRL    4'b0110
`define ALU_SRA    4'b0111
`define ALU_OR     4'b1000
`define ALU_AND    4'b1001
`define ALU_EQ     4'b1010
`define ALU_NE     4'b1011
`define ALU_LT     4'b1100
`define ALU_GE     4'b1101
`define ALU_LTU    4'b1110
`define ALU_GEU    4'b1111

// Immediate format selector for the immediate generator
`define IMM_I      3'b000
`define IMM_S      3'b001
`define IMM_B      3'b010
`define IMM_U      3'b011
`define IMM_J      3'b100

// Where the WB stage takes its result from
`define WB_ALU     2'b00
`define WB_MEM     2'b01
`define WB_PC4     2'b10
`define WB_IMM     2'b11

// Program counter source (resolved in EX, applied in IF)
`define PC_PC4     2'b00
`define PC_JUMP    2'b01  // taken branch / jal / jalr, target from EX
`define PC_STALL   2'b10  // replay PC, load-use stall
`define PC_FLUSH   2'b11  // wrong-path instruction was squashed

`endif
