`timescale 1ns/1ps
`include "defs.vh"

// Unified instruction + data memory, byte addressable, little endian.
// Word accesses must be 4-byte aligned and halfword accesses 2-byte
// aligned (misaligned accesses are reported but otherwise ignored).
//
// Address map:
//   0x0000 - (IMEM_WORDS*4-1) : instructions, $readmemh(PROG_FILE)
//   0x4000 - (0x4000+DMEM_WORDS*4-1) : data, $readmemh(DATA_FILE)
//
// Out-of-range reads return 0 and out-of-range writes are ignored. This
// matches the reference interpreter and keeps stray addresses (e.g.
// `lw x7, 0(x0)`) from injecting X values into the pipeline.
//
// Both ports are combinational (asynchronous read); stores are
// synchronous on posedge clk. NOTE: a load's data only ENTERS the
// pipeline at the end of its MEM stage (it is captured into MEM/WB).
// That is precisely why a load-use hazard needs one stall cycle even
// when forwarding is present.
module memory #(
    parameter IMEM_WORDS = 4096,
    parameter DMEM_WORDS = 4096,
    parameter PROG_FILE  = "prog.hex",
    parameter DATA_FILE  = "data.hex"
) (
    input  wire        clk,
    input  wire [31:0] iaddr,
    output wire [31:0] instr,

    input  wire        mem_read,
    input  wire        mem_write,
    input  wire [2:0]  mem_width,
    input  wire        mem_unsigned,
    input  wire [31:0] daddr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output reg         misaligned
);
    localparam [31:0] IMEM_BYTES = IMEM_WORDS * 4;
    localparam [31:0] DMEM_BYTES = DMEM_WORDS * 4;

    reg [31:0] imem [0:IMEM_WORDS-1];
    reg [31:0] dmem [0:DMEM_WORDS-1];
    integer i;

    initial begin
        for (i = 0; i < IMEM_WORDS; i = i + 1) imem[i] = 32'h00000013; // NOP
        for (i = 0; i < DMEM_WORDS; i = i + 1) dmem[i] = 32'h0;
        $readmemh(PROG_FILE, imem);
        $readmemh(DATA_FILE, dmem);
    end

    // ---- instruction port ----
    wire i_in_range = (iaddr < IMEM_BYTES);
    wire [31:0] iword = i_in_range ? imem[iaddr[15:2]] : 32'h00000013;
    assign instr = iword;

    // ---- data port ----
    wire [31:0] doffset    = daddr - 32'h4000;
    wire        d_in_range = (doffset < DMEM_BYTES);
    wire [13:0] dindex     = doffset[15:2];
    wire [1:0]  boffset    = doffset[1:0];
    wire [31:0] word       = d_in_range ? dmem[dindex] : 32'h0;

    reg [7:0]  b;
    reg [15:0] h;
    reg        bad;

    always @* begin
        bad        = 1'b0;
        rdata      = 32'h0;
        misaligned = 1'b0;
        b          = 8'h0;
        h          = 16'h0;

        if (mem_read || mem_write) begin
            case (mem_width)
                `F3_LW, `F3_SW: begin
                    if (boffset != 2'b00) bad = 1'b1;
                end
                `F3_LH, `F3_LHU, `F3_SH: begin
                    if (boffset[0] != 1'b0) bad = 1'b1;
                end
                default: ;
            endcase
            misaligned = bad;
        end

        if (mem_read && d_in_range) begin
            case (mem_width)
                `F3_LB, `F3_LBU: begin
                    case (boffset)
                        2'b00: b = word[7:0];
                        2'b01: b = word[15:8];
                        2'b10: b = word[23:16];
                        2'b11: b = word[31:24];
                    endcase
                    rdata = (mem_unsigned || (mem_width == `F3_LBU))
                          ? {24'h0, b} : {{24{b[7]}}, b};
                end
                `F3_LH, `F3_LHU: begin
                    h = (boffset[1] == 1'b0) ? word[15:0] : word[31:16];
                    rdata = (mem_unsigned || (mem_width == `F3_LHU))
                          ? {16'h0, h} : {{16{h[15]}}, h};
                end
                `F3_LW: rdata = word;
                default: rdata = 32'h0;
            endcase
        end
    end

    // Store data is the *forwarded* rs2 value supplied by the CPU top level.
    always @(posedge clk) begin
        if (mem_write && !bad && d_in_range) begin
            case (mem_width)
                `F3_SB: begin
                    case (boffset)
                        2'b00: dmem[dindex][7:0]   <= wdata[7:0];
                        2'b01: dmem[dindex][15:8]  <= wdata[7:0];
                        2'b10: dmem[dindex][23:16] <= wdata[7:0];
                        2'b11: dmem[dindex][31:24] <= wdata[7:0];
                    endcase
                end
                `F3_SH: begin
                    if (boffset[1] == 1'b0) dmem[dindex][15:0]  <= wdata[15:0];
                    else                    dmem[dindex][31:16] <= wdata[15:0];
                end
                `F3_SW: dmem[dindex] <= wdata;
                default: ;
            endcase
        end
    end
endmodule
