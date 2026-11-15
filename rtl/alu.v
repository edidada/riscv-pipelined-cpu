`timescale 1ns/1ps
`include "defs.vh"

// Pure combinational ALU. Comparison ops return 0/1; branch decisions
// are made here so the EX stage only needs to look at alu_zero.
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output reg  [31:0] result,
    output wire        zero
);
    wire [4:0] shamt = b[4:0];
    wire signed [31:0] a_signed = a;

    always @* begin
        case (op)
            `ALU_ADD:   result = a + b;
            `ALU_SUB:   result = a - b;
            `ALU_SLL:   result = a << shamt;
            `ALU_SLT:   result = ($signed(a) < $signed(b)) ? 32'h1 : 32'h0;
            `ALU_SLTU:  result = (a < b) ? 32'h1 : 32'h0;
            `ALU_XOR:   result = a ^ b;
            `ALU_SRL:   result = a >> shamt;
            `ALU_SRA:   result = a_signed >>> shamt;
            `ALU_OR:    result = a | b;
            `ALU_AND:   result = a & b;
            `ALU_EQ:    result = (a == b) ? 32'h1 : 32'h0;
            `ALU_NE:    result = (a != b) ? 32'h1 : 32'h0;
            `ALU_LT:    result = ($signed(a) < $signed(b)) ? 32'h1 : 32'h0;
            `ALU_GE:    result = ($signed(a) >= $signed(b)) ? 32'h1 : 32'h0;
            `ALU_LTU:   result = (a < b) ? 32'h1 : 32'h0;
            `ALU_GEU:   result = (a >= b) ? 32'h1 : 32'h0;
            default:    result = 32'h0;
        endcase
    end

    assign zero = (result == 32'h0);
endmodule
