`timescale 1ns/1ps
`include "defs.vh"

// ---------------------------------------------------------------------------
// Five-stage (IF / ID / EX / MEM / WB) in-order RISC-V RV32I subset core.
//
// Deliberately pedagogical design decisions:
//   * Branches and jumps are RESOLVED IN THE EX STAGE. A taken branch
//     therefore costs two wrong-path instructions, which are squashed by
//     flushing IF/ID and ID/EX. This is the "control hazard" lesson.
//   * ALU/writeback results are forwarded from EX/MEM and MEM/WB into the
//     EX operand muxes. Disable with FORWARDING_EN=0 to watch stale
//     register-file reads corrupt results.
//   * Load-use hazards stall the front end for exactly one cycle. Disable
//     with HAZARD_EN=0 to watch lw -> dependent instruction break.
//   * With FORWARDING_EN=0 the hazard unit can be put in STALL_ALL_DEP=1
//     mode ("stall_only"), which stalls every RAW dependency until the
//     producer has retired. Only MEM/WB forwarding remains in that mode
//     (the same-cycle register-file write cannot be relied on by the ID
//     read), so it is correct but slow. This is the README's step-two
//     experiment: compare its CPI against `full`.
//   * Control bundles travel explicitly through the pipeline registers,
//     so "flush" literally means "set these control bits to zero".
// ---------------------------------------------------------------------------
module cpu #(
    parameter FORWARDING_EN  = 1,
    parameter HAZARD_EN      = 1,
    parameter STALL_ALL_DEP  = 0,
    parameter IMEM_WORDS     = 4096,
    parameter DMEM_WORDS     = 4096,
    parameter PROG_FILE      = "prog.hex",
    parameter DATA_FILE      = "data.hex"
) (
    input  wire        clk,
    input  wire        reset,

    // Observability for the testbench / waveform debugging
    output wire [31:0] pc,
    output wire [31:0] if_id_pc,
    output wire [31:0] if_id_instr,
    output wire [31:0] id_ex_instr,
    output wire [31:0] ex_mem_instr,
    output wire [31:0] mem_wb_instr,
    output wire        load_use_hazard,
    output wire        stall_out,
    output wire [1:0]  forward_a,
    output wire [1:0]  forward_b,
    output wire        flush_if_id,
    output wire        flush_id_ex,
    output wire [1:0]  pc_src,
    output wire        halted,
    output wire        illegal_instr,
    output wire        retired_valid,
    output wire [4:0]  retired_rd,
    output wire [31:0] retired_result,
    output wire [31:0] retired_instr,
    output wire [31:0] retired_pc,

    // Backdoor reads (no architectural side effects)
    input  wire [4:0]  dbg_addr,
    output wire [31:0] dbg_reg,
    input  wire [31:0] dbg_daddr,
    output wire [31:0] dbg_dmem
);

    // =======================================================================
    // WB-stage signals (declared early: the EX forwarding mux refers to
    // wb_result, which combinational Verilog resolves regardless of order)
    // =======================================================================
    reg  [31:0] mem_wb_instr_r;
    reg  [31:0] mem_wb_pc_r;
    reg  [31:0] mem_wb_result_r;   // the value this instruction WILL write
    reg  [4:0]  mem_wb_rd_r;
    reg         mem_wb_reg_write_r;
    reg         mem_wb_illegal_r;

    // The writeback value is LATCHED into MEM/WB at the same edge as the
    // control that enables the write. Computing it combinationally from
    // MEM/WB instead would race with that very edge: the register-file
    // write could then sample the NEXT instruction's data. That subtle
    // bug silently corrupts values at dependency distance 3.
    wire [31:0] wb_result = mem_wb_result_r;

    // TWO DIFFERENT forwarding sources -- this distinction IS the whole
    // load-use lesson:
    //
    //  * ex_mem_early_value is what EX/MEM can supply to an EX operand
    //    mux. For ALU ops it is alu_result; for LUI it is the U-immediate;
    //    for JAL/JALR it is PC+4. Those values exist by the end of EX.
    //    For a LOAD, however, only the ADDRESS exists here -- the loaded
    //    word has not been produced yet. We deliberately leave the
    //    address as the "forwarded" value so that disabling the stall
    //    produces a visible, reproducible bug rather than accidentally
    //    correct behaviour.
    //
    //  * wb_result (= mem_wb_result_r) is the FULL writeback mux, latched
    //    at the posedge that ends the MEM stage. By then mem_rdata is
    //    valid, so a consumer in EX while the load is in WB gets the real
    //    data. That is why exactly ONE stall (or one independent
    //    instruction) suffices, and why no stall is needed at distance 2.
    wire [31:0] wb_uimm_pre = {ex_mem_instr_r[31:12], 12'b0};
    wire [31:0] ex_mem_early_value;
    assign ex_mem_early_value =
        (ex_mem_wb_sel_r == `WB_PC4) ? (ex_mem_pc_r + 32'h4) :
        (ex_mem_wb_sel_r == `WB_IMM) ? wb_uimm_pre :
        ex_mem_alu_result_r;   // includes loads: still only the address

    wire [31:0] wb_mux_pre;
    assign wb_mux_pre = (ex_mem_wb_sel_r == `WB_MEM) ? mem_rdata :
                        ex_mem_early_value;

    // =======================================================================
    // IF stage
    // =======================================================================
    reg  [31:0] pc_reg;
    assign pc = pc_reg;

    wire [31:0] pc_plus4      = pc_reg + 32'h4;
    wire [31:0] im_instr;
    wire [31:0] branch_target;
    wire        redirect_taken;
    wire        stall;

    // =======================================================================
    // IF/ID pipeline register
    // =======================================================================
    reg  [31:0] if_id_pc_r;
    reg  [31:0] if_id_instr_r;
    wire        if_id_hold;
    wire        if_id_flush;

    assign if_id_pc    = if_id_pc_r;
    assign if_id_instr = if_id_instr_r;

    always @(posedge clk) begin
        if (reset) begin
            if_id_pc_r    <= 32'h0;
            if_id_instr_r <= 32'h00000013;  // NOP
        end else if (if_id_flush) begin
            // Squash the wrong-path instruction: decode becomes an inert NOP.
            if_id_pc_r    <= 32'h0;
            if_id_instr_r <= 32'h00000013;
        end else if (if_id_hold) begin
            // Replay the same instruction next cycle (stall).
            if_id_pc_r    <= if_id_pc_r;
            if_id_instr_r <= if_id_instr_r;
        end else begin
            if_id_pc_r    <= pc_reg;
            if_id_instr_r <= im_instr;
        end
    end

    // =======================================================================
    // ID stage - decode, register file read, immediate generation
    // =======================================================================
    wire [6:0] id_opcode = if_id_instr_r[6:0];
    wire [4:0] id_rd     = if_id_instr_r[11:7];
    wire [2:0] id_funct3 = if_id_instr_r[14:12];
    wire [4:0] id_rs1    = if_id_instr_r[19:15];
    wire [4:0] id_rs2    = if_id_instr_r[24:20];
    wire [6:0] id_funct7 = if_id_instr_r[31:25];

    wire [1:0] id_wb_sel;
    wire       id_reg_write, id_mem_read, id_mem_write;
    wire [2:0] id_mem_width;
    wire       id_mem_unsigned;
    wire       id_branch, id_jump, id_jalr;
    wire       id_alu_src_a, id_alu_src_b;
    wire [3:0] id_alu_op;
    wire [2:0] id_imm_sel;
    wire       id_uses_rs1, id_uses_rs2;
    wire       id_is_store;
    wire       id_illegal;

    control u_control (
        .opcode        (id_opcode),
        .funct3        (id_funct3),
        .funct7        (id_funct7),
        .instr         (if_id_instr_r),
        .wb_sel        (id_wb_sel),
        .reg_write     (id_reg_write),
        .mem_read      (id_mem_read),
        .mem_write     (id_mem_write),
        .mem_width     (id_mem_width),
        .mem_unsigned  (id_mem_unsigned),
        .branch        (id_branch),
        .jump          (id_jump),
        .jalr          (id_jalr),
        .alu_src_a     (id_alu_src_a),
        .alu_src_b     (id_alu_src_b),
        .alu_op        (id_alu_op),
        .imm_sel       (id_imm_sel),
        .uses_rs1      (id_uses_rs1),
        .uses_rs2      (id_uses_rs2),
        .is_store      (id_is_store),
        .illegal       (id_illegal)
    );

    wire [31:0] id_imm;
    imm_gen u_imm_gen (
        .instr   (if_id_instr_r),
        .imm_sel (id_imm_sel),
        .imm     (id_imm)
    );

    wire [31:0] id_rdata1, id_rdata2;
    regfile u_regfile (
        .clk     (clk),
        .we      (mem_wb_reg_write_r),
        .waddr   (mem_wb_rd_r),
        .wdata   (wb_result),
        .raddr1  (id_rs1),
        .raddr2  (id_rs2),
        .rdata1  (id_rdata1),
        .rdata2  (id_rdata2)
    );

    // =======================================================================
    // ID/EX pipeline register
    // =======================================================================
    reg  [31:0] id_ex_pc_r, id_ex_instr_r;
    reg  [31:0] id_ex_rdata1_r, id_ex_rdata2_r, id_ex_imm_r;
    reg  [4:0]  id_ex_rs1_r, id_ex_rs2_r, id_ex_rd_r;
    reg  [1:0]  id_ex_wb_sel_r;
    reg         id_ex_reg_write_r, id_ex_mem_read_r, id_ex_mem_write_r;
    reg  [2:0]  id_ex_mem_width_r;
    reg         id_ex_mem_unsigned_r;
    reg         id_ex_branch_r, id_ex_jump_r, id_ex_jalr_r;
    reg         id_ex_alu_src_a_r, id_ex_alu_src_b_r;
    reg  [3:0]  id_ex_alu_op_r;
    reg         id_ex_uses_rs1_r, id_ex_uses_rs2_r;
    reg         id_ex_is_store_r;
    reg         id_ex_illegal_r;

    wire id_ex_bubble;

    assign id_ex_instr = id_ex_instr_r;

    always @(posedge clk) begin
        if (reset || id_ex_bubble || if_id_flush) begin
            // A bubble / flush = a control-squashed NOP. ALL control bits
            // go to zero; the instruction bits are kept only so waveforms
            // remain readable.
            id_ex_pc_r           <= (reset) ? 32'h0 : id_ex_pc_r;
            id_ex_instr_r        <= (reset) ? 32'h00000013 : id_ex_instr_r;
            id_ex_rdata1_r       <= 32'h0;
            id_ex_rdata2_r       <= 32'h0;
            id_ex_imm_r          <= 32'h0;
            id_ex_rs1_r          <= 5'h0;
            id_ex_rs2_r          <= 5'h0;
            id_ex_rd_r           <= 5'h0;
            id_ex_wb_sel_r       <= `WB_ALU;
            id_ex_reg_write_r    <= 1'b0;
            id_ex_mem_read_r     <= 1'b0;
            id_ex_mem_write_r    <= 1'b0;
            id_ex_mem_width_r    <= `F3_LW;
            id_ex_mem_unsigned_r <= 1'b0;
            id_ex_branch_r       <= 1'b0;
            id_ex_jump_r         <= 1'b0;
            id_ex_jalr_r         <= 1'b0;
            id_ex_alu_src_a_r    <= 1'b0;
            id_ex_alu_src_b_r    <= 1'b0;
            id_ex_alu_op_r       <= `ALU_ADD;
            id_ex_uses_rs1_r     <= 1'b0;
            id_ex_uses_rs2_r     <= 1'b0;
            id_ex_is_store_r     <= 1'b0;
            id_ex_illegal_r      <= 1'b0;
        end else begin
            id_ex_pc_r           <= if_id_pc_r;
            id_ex_instr_r        <= if_id_instr_r;
            id_ex_rdata1_r       <= id_rdata1;
            id_ex_rdata2_r       <= id_rdata2;
            id_ex_imm_r          <= id_imm;
            id_ex_rs1_r          <= id_rs1;
            id_ex_rs2_r          <= id_rs2;
            id_ex_rd_r           <= id_rd;
            id_ex_wb_sel_r       <= id_wb_sel;
            id_ex_reg_write_r    <= id_reg_write;
            id_ex_mem_read_r     <= id_mem_read;
            id_ex_mem_write_r    <= id_mem_write;
            id_ex_mem_width_r    <= id_mem_width;
            id_ex_mem_unsigned_r <= id_mem_unsigned;
            id_ex_branch_r       <= id_branch;
            id_ex_jump_r         <= id_jump;
            id_ex_jalr_r         <= id_jalr;
            id_ex_alu_src_a_r    <= id_alu_src_a;
            id_ex_alu_src_b_r    <= id_alu_src_b;
            id_ex_alu_op_r       <= id_alu_op;
            id_ex_uses_rs1_r     <= id_uses_rs1;
            id_ex_uses_rs2_r     <= id_uses_rs2;
            id_ex_is_store_r     <= id_is_store;
            id_ex_illegal_r      <= id_illegal;
        end
    end

    // =======================================================================
    // EX/MEM pipeline register
    // =======================================================================
    reg  [31:0] ex_mem_pc_r, ex_mem_instr_r;
    reg  [31:0] ex_mem_alu_result_r, ex_mem_store_data_r;
    reg  [4:0]  ex_mem_rd_r;
    reg  [1:0]  ex_mem_wb_sel_r;
    reg         ex_mem_reg_write_r, ex_mem_mem_read_r, ex_mem_mem_write_r;
    reg  [2:0]  ex_mem_mem_width_r;
    reg         ex_mem_mem_unsigned_r;
    reg         ex_mem_illegal_r;

    assign ex_mem_instr = ex_mem_instr_r;

    // =======================================================================
    // EX stage - forwarding, ALU, branch/target resolution
    // =======================================================================
    wire [1:0] fwd_a, fwd_b;
    wire       hazard_raw;
    wire       hz_pc_write, hz_if_id_hold, hz_id_ex_bubble;

    generate
        if (FORWARDING_EN) begin : gen_forwarding
            forwarding_unit u_fwd (
                .id_ex_rs1        (id_ex_rs1_r),
                .id_ex_rs2        (id_ex_rs2_r),
                .id_ex_uses_rs1   (id_ex_uses_rs1_r),
                .id_ex_uses_rs2   (id_ex_uses_rs2_r),
                .ex_mem_rd        (ex_mem_rd_r),
                .ex_mem_reg_write (ex_mem_reg_write_r),
                .mem_wb_rd        (mem_wb_rd_r),
                .mem_wb_reg_write (mem_wb_reg_write_r),
                .forward_a        (fwd_a),
                .forward_b        (fwd_b)
            );
        end else if (STALL_ALL_DEP) begin : gen_wb_forwarding_only
            // "stall_only" mode: no early (EX/MEM) forwarding, but a
            // value that is being written back in the very same cycle is
            // still forwarded. Otherwise the ID read would see the OLD
            // register-file content by one cycle.
            forwarding_unit #(.ENABLE_EXMEM(0)) u_fwd_wb (
                .id_ex_rs1        (id_ex_rs1_r),
                .id_ex_rs2        (id_ex_rs2_r),
                .id_ex_uses_rs1   (id_ex_uses_rs1_r),
                .id_ex_uses_rs2   (id_ex_uses_rs2_r),
                .ex_mem_rd        (ex_mem_rd_r),
                .ex_mem_reg_write (ex_mem_reg_write_r),
                .mem_wb_rd        (mem_wb_rd_r),
                .mem_wb_reg_write (mem_wb_reg_write_r),
                .forward_a        (fwd_a),
                .forward_b        (fwd_b)
            );
        end else begin : gen_no_forwarding
            // Naive core: neither forwarding mechanism. This is the
            // deliberately broken configuration.
            assign fwd_a = 2'b00;
            assign fwd_b = 2'b00;
        end
    endgenerate

    generate
        if (HAZARD_EN) begin : gen_hazard
            hazard_unit #(.STALL_ALL_DEP(STALL_ALL_DEP)) u_hz (
                .id_ex_mem_read  (id_ex_mem_read_r),
                .id_ex_rd        (id_ex_rd_r),
                .id_ex_reg_write (id_ex_reg_write_r),
                .if_id_rs1       (id_rs1),
                .if_id_rs2       (id_rs2),
                .if_id_uses_rs1  (id_uses_rs1),
                .if_id_uses_rs2  (id_uses_rs2),
                .ex_mem_reg_write(ex_mem_reg_write_r),
                .ex_mem_rd       (ex_mem_rd_r),
                .mem_wb_reg_write(mem_wb_reg_write_r),
                .mem_wb_rd       (mem_wb_rd_r),
                .load_use_hazard (hazard_raw),
                .stall           (stall),
                .pc_write        (hz_pc_write),
                .if_id_hold      (hz_if_id_hold),
                .id_ex_bubble    (hz_id_ex_bubble)
            );
        end else begin : gen_no_hazard
            assign hazard_raw      = 1'b0;
            assign stall           = 1'b0;
            assign hz_pc_write     = 1'b1;
            assign hz_if_id_hold   = 1'b0;
            assign hz_id_ex_bubble = 1'b0;
        end
    endgenerate

    // Store-data forwarding is computed independently of the ALU B mux.
    // In stall_only mode only the WB path is available.
    wire [1:0] fwd_store, fwd_store_full, fwd_store_wb;
    forwarding_unit u_fwd_store (
        .id_ex_rs1        (id_ex_rs1_r),
        .id_ex_rs2        (id_ex_rs2_r),
        .id_ex_uses_rs1   (1'b0),
        .id_ex_uses_rs2   (id_ex_is_store_r),
        .ex_mem_rd        (ex_mem_rd_r),
        .ex_mem_reg_write (ex_mem_reg_write_r),
        .mem_wb_rd        (mem_wb_rd_r),
        .mem_wb_reg_write (mem_wb_reg_write_r),
        .forward_a        (),
        .forward_b        (fwd_store_full)
    );
    forwarding_unit #(.ENABLE_EXMEM(0)) u_fwd_store_wb (
        .id_ex_rs1        (id_ex_rs1_r),
        .id_ex_rs2        (id_ex_rs2_r),
        .id_ex_uses_rs1   (1'b0),
        .id_ex_uses_rs2   (id_ex_is_store_r),
        .ex_mem_rd        (ex_mem_rd_r),
        .ex_mem_reg_write (ex_mem_reg_write_r),
        .mem_wb_rd        (mem_wb_rd_r),
        .mem_wb_reg_write (mem_wb_reg_write_r),
        .forward_a        (),
        .forward_b        (fwd_store_wb)
    );
    assign fwd_store = (FORWARDING_EN) ? fwd_store_full :
                       (STALL_ALL_DEP)  ? fwd_store_wb : 2'b00;

    assign forward_a       = fwd_a;
    assign forward_b       = fwd_b;
    assign load_use_hazard = hazard_raw;
    assign stall_out       = stall;

    // Forwarding sources:
    //   fwd == 01 -> ex_mem_early_value (one stage ahead: ALU result,
    //                U-immediate, or PC+4 -- never load data)
    //   fwd == 10 -> wb_result (two stages ahead: the FULL writeback mux,
    //                which DOES include loaded data). `lw; nop; add` is
    //                correct only because of this path.
    wire [31:0] operand_a_raw = (fwd_a == 2'b01) ? ex_mem_early_value
                              : (fwd_a == 2'b10) ? wb_result
                              : id_ex_rdata1_r;
    wire [31:0] operand_a = id_ex_alu_src_a_r ? id_ex_pc_r : operand_a_raw;

    wire [31:0] operand_b_raw = (fwd_b == 2'b01) ? ex_mem_early_value
                              : (fwd_b == 2'b10) ? wb_result
                              : id_ex_rdata2_r;
    wire [31:0] operand_b = id_ex_alu_src_b_r ? id_ex_imm_r : operand_b_raw;

    // A store's data always comes from rs2 (forwarded), never from the
    // S-immediate that was used to compute the address. It needs its OWN
    // forwarding mux: the ALU's B input is the immediate for a store, but
    // the store value is rs2. Reusing operand_b here would write the
    // immediate into memory instead of the register value.
    wire [31:0] store_data = (fwd_store == 2'b01) ? ex_mem_early_value
                           : (fwd_store == 2'b10) ? wb_result
                           : id_ex_rdata2_r;

    wire [31:0] alu_result;
    wire        alu_zero;

    alu u_alu (
        .a      (operand_a),
        .b      (operand_b),
        .op     (id_ex_alu_op_r),
        .result (alu_result),
        .zero   (alu_zero)
    );

    // Branches compare rs1/rs2 via the ALU; JAL/JALR compute their target
    // via the ALU too (PC+imm or rs1+imm). A separate adder forms the
    // taken-branch target PC + B-imm.
    wire [31:0] branch_target_ex = id_ex_pc_r + id_ex_imm_r;

    wire branch_taken = id_ex_branch_r && (alu_result != 32'h0);
    assign redirect_taken = id_ex_jump_r || branch_taken;
    assign branch_target  = id_ex_branch_r ? branch_target_ex : alu_result;

    // ---- global front-end control resolution -----------------------------
    // Priority: redirect (flush) > stall (replay) > normal PC+4.
    assign flush_if_id = redirect_taken;
    assign flush_id_ex = redirect_taken;
    assign pc_src      = redirect_taken ? `PC_JUMP
                       : stall           ? `PC_STALL
                       : `PC_PC4;

    assign if_id_flush = redirect_taken;
    assign if_id_hold  = hz_if_id_hold & ~redirect_taken;
    assign id_ex_bubble= hz_id_ex_bubble & ~redirect_taken;

    always @(posedge clk) begin
        if (reset)
            pc_reg <= 32'h0;
        else if (redirect_taken)
            pc_reg <= branch_target;
        else if (stall)
            pc_reg <= pc_reg;         // hold: replay the same instruction
        else
            pc_reg <= pc_plus4;
    end

    always @(posedge clk) begin
        if (reset) begin
            ex_mem_pc_r           <= 32'h0;
            ex_mem_instr_r        <= 32'h00000013;
            ex_mem_alu_result_r   <= 32'h0;
            ex_mem_store_data_r   <= 32'h0;
            ex_mem_rd_r           <= 5'h0;
            ex_mem_wb_sel_r       <= `WB_ALU;
            ex_mem_reg_write_r    <= 1'b0;
            ex_mem_mem_read_r     <= 1'b0;
            ex_mem_mem_write_r    <= 1'b0;
            ex_mem_mem_width_r    <= `F3_LW;
            ex_mem_mem_unsigned_r <= 1'b0;
            ex_mem_illegal_r      <= 1'b0;
        end else begin
            ex_mem_pc_r           <= id_ex_pc_r;
            ex_mem_instr_r        <= id_ex_instr_r;
            ex_mem_alu_result_r   <= alu_result;
            ex_mem_store_data_r   <= store_data;
            ex_mem_rd_r           <= id_ex_rd_r;
            ex_mem_wb_sel_r       <= id_ex_wb_sel_r;
            ex_mem_reg_write_r    <= id_ex_reg_write_r;
            ex_mem_mem_read_r     <= id_ex_mem_read_r;
            ex_mem_mem_write_r    <= id_ex_mem_write_r;
            ex_mem_mem_width_r    <= id_ex_mem_width_r;
            ex_mem_mem_unsigned_r <= id_ex_mem_unsigned_r;
            ex_mem_illegal_r      <= id_ex_illegal_r;
        end
    end

    // =======================================================================
    // MEM stage - data memory
    // =======================================================================
    wire [31:0] mem_rdata;
    wire        mem_misaligned;

    memory #(
        .IMEM_WORDS (IMEM_WORDS),
        .DMEM_WORDS (DMEM_WORDS),
        .PROG_FILE  (PROG_FILE),
        .DATA_FILE  (DATA_FILE)
    ) u_memory (
        .clk           (clk),
        .iaddr         (pc_reg),
        .instr         (im_instr),
        .mem_read      (ex_mem_mem_read_r),
        .mem_write     (ex_mem_mem_write_r),
        .mem_width     (ex_mem_mem_width_r),
        .mem_unsigned  (ex_mem_mem_unsigned_r),
        .daddr         (ex_mem_alu_result_r),
        .wdata         (ex_mem_store_data_r),
        .rdata         (mem_rdata),
        .misaligned    (mem_misaligned)
    );

    // =======================================================================
    // MEM/WB pipeline register
    // =======================================================================
    assign mem_wb_instr = mem_wb_instr_r;

    always @(posedge clk) begin
        if (reset) begin
            mem_wb_instr_r     <= 32'h00000013;
            mem_wb_pc_r        <= 32'h0;
            mem_wb_result_r    <= 32'h0;
            mem_wb_rd_r        <= 5'h0;
            mem_wb_reg_write_r <= 1'b0;
            mem_wb_illegal_r   <= 1'b0;
        end else begin
            mem_wb_instr_r     <= ex_mem_instr_r;
            mem_wb_pc_r        <= ex_mem_pc_r;
            mem_wb_result_r    <= wb_mux_pre;
            mem_wb_rd_r        <= ex_mem_rd_r;
            mem_wb_reg_write_r <= ex_mem_reg_write_r;
            mem_wb_illegal_r   <= ex_mem_illegal_r;
        end
    end

    // ---- status / observability ------------------------------------------
    // Halt is asserted when ECALL/EBREAK reaches WB (i.e. it really
    // retired), not when it is merely fetched.
    assign halted = (mem_wb_instr_r[6:0] == `OP_SYSTEM) &&
                    (mem_wb_instr_r[31:20] == 12'h000);
    assign illegal_instr = mem_wb_illegal_r;

    assign retired_valid  = mem_wb_reg_write_r && (mem_wb_rd_r != 5'b0);
    assign retired_rd     = mem_wb_rd_r;
    assign retired_result = wb_result;
    assign retired_instr  = mem_wb_instr_r;
    assign retired_pc     = mem_wb_pc_r;

    assign dbg_reg  = u_regfile.regs[dbg_addr];
    wire [31:0] dbg_offset = dbg_daddr - 32'h4000;
    wire [13:0] dbg_index  = dbg_offset[15:2];
    assign dbg_dmem = u_memory.dmem[dbg_index];

endmodule
