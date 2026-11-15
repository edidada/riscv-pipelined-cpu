`timescale 1ns/1ps
`include "defs.vh"

// 32 x 32 register file with two combinational read ports and one
// write port. x0 is hardwired to zero.
//
// WHY THE WRITE IS ON negedge:
// The textbook 5-stage datapath writes the register file in the FIRST
// half of a clock cycle and reads it in the SECOND half. With a single
// clock, that means WRITE ON negedge, and the pipeline registers capture
// the (already-updated) ID read at the following posedge.
//
// This is what makes a distance-3 dependency work without forwarding:
//
//   add x1, ...    IF ID EX MEM WB
//   ...            ...
//   add x2,x1,..            IF ID EX MEM WB
//                           ^ same cycle: WB writes on negedge, ID reads
//
// The producer has already left MEM/WB by the time the consumer reaches
// EX, so EX forwarding CANNOT help at distance 3. The register file is
// the only source. Forwarding is still required for distances 1 and 2 --
// that is exactly what FORWARDING_EN=0 demonstrates.
//
// Reads are not otherwise bypassed: a value written at negedge of cycle
// N is visible to an ID read during cycle N, but NOT to a read that was
// captured into ID/EX at the posedge starting cycle N. That one-cycle
// gap is the hazard the forwarding unit exists to close.
module regfile (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata,
    input  wire [4:0]  raddr1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2
);
    reg [31:0] regs [0:31];
    integer i;

    initial begin
        for (i = 0; i < 32; i = i + 1)
            regs[i] = 32'h0;
    end

    assign rdata1 = (raddr1 == 5'b0) ? 32'h0 : regs[raddr1];
    assign rdata2 = (raddr2 == 5'b0) ? 32'h0 : regs[raddr2];

    always @(negedge clk) begin
        if (we && (waddr != 5'b0))
            regs[waddr] <= wdata;
    end
endmodule
