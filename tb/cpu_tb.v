`include "defs.vh"
`include "config.vh"
`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// Self-checking testbench for one CPU configuration.
//
// Configuration comes from config.vh (macros), which the CI runner
// generates per run into an include directory placed BEFORE tb/ on the
// -I path. A single source therefore drives every program x every hazard
// configuration without depending on iverilog's platform-specific -P
// parameter-override syntax.
//
// The reference interpreter (tools/ref.py) produces ref.trace: one line
// "<pc_hex> <instr_hex> <rd> <value_hex>" per writing instruction, in
// EXECUTED PROGRAM ORDER. The DUT retires writing instructions in exactly
// the same order, so the testbench compares them one-for-one by index:
//
//   * every retirement must match the next unmatched reference entry;
//   * no entry may be left over, and none may be extra;
//   * final data memory and all 32 registers must match too.
//
// Ordered matching (rather than keying on the PC) is essential: a loop
// body executes the same PC many times with different values, and a
// naive PC lookup would keep picking the first iteration's value.
//
// Additionally, the retiring instruction's PC is checked against the
// reference PC. That catches wrong-path writes after taken branches.
// ---------------------------------------------------------------------------
module cpu_tb;
    parameter PROG          = `TB_PROG;
    parameter DATA          = `TB_DATA;
    parameter TRACE         = `TB_TRACE;
    parameter REFDATA       = `TB_REFDATA;
    parameter REFREGS       = `TB_REFREGS;
    parameter FORWARDING_EN = `TB_FORWARDING_EN;
    parameter HAZARD_EN     = `TB_HAZARD_EN;
    parameter STALL_ALL_DEP = `TB_STALL_ALL_DEP;
    parameter MAX_CYCLES    = `TB_MAX_CYCLES;
    parameter CFG_NAME      = `TB_CFG_NAME;

    reg         clk = 0;
    reg         reset = 1;

    wire        halted;
    wire        illegal_instr;
    wire        retired_valid;
    wire [4:0]  retired_rd;
    wire [31:0] retired_result;
    wire [31:0] retired_instr;
    wire [31:0] retired_pc;
    wire [31:0] pc;
    wire        stall_out;
    wire [1:0]  forward_a, forward_b;
    wire        flush_if_id, flush_id_ex;
    wire        load_use_hazard;
    wire [1:0]  pc_src;
    wire [31:0] if_id_pc, if_id_instr;
    wire [31:0] id_ex_instr, ex_mem_instr, mem_wb_instr;

    reg  [4:0]  dbg_addr  = 5'd0;
    wire [31:0] dbg_reg;
    reg  [31:0] dbg_daddr = 32'h4000;
    wire [31:0] dbg_dmem;

    cpu #(
        .FORWARDING_EN (FORWARDING_EN),
        .HAZARD_EN     (HAZARD_EN),
        .STALL_ALL_DEP (STALL_ALL_DEP),
        .PROG_FILE     (PROG),
        .DATA_FILE     (DATA)
    ) dut (
        .clk             (clk),
        .reset           (reset),
        .pc              (pc),
        .if_id_pc        (if_id_pc),
        .if_id_instr     (if_id_instr),
        .id_ex_instr     (id_ex_instr),
        .ex_mem_instr    (ex_mem_instr),
        .mem_wb_instr    (mem_wb_instr),
        .load_use_hazard (load_use_hazard),
        .stall_out       (stall_out),
        .forward_a       (forward_a),
        .forward_b       (forward_b),
        .flush_if_id     (flush_if_id),
        .flush_id_ex     (flush_id_ex),
        .pc_src          (pc_src),
        .halted          (halted),
        .illegal_instr   (illegal_instr),
        .retired_valid   (retired_valid),
        .retired_rd      (retired_rd),
        .retired_result  (retired_result),
        .retired_instr   (retired_instr),
        .retired_pc      (retired_pc),
        .dbg_addr        (dbg_addr),
        .dbg_reg         (dbg_reg),
        .dbg_daddr       (dbg_daddr),
        .dbg_dmem        (dbg_dmem)
    );

    always #5 clk = ~clk;   // 10 ns period

    integer cycle        = 0;
    integer errors       = 0;
    integer stall_count  = 0;
    integer flush_count  = 0;
    integer fwd_count    = 0;
    integer retire_count = 0;
    integer finished     = 0;
    integer trace_idx    = 0;
    integer ref_steps    = 0;

    // ---- reference trace --------------------------------------------------
    integer TRACE_WORDS = 0;
    integer fd;
    reg [31:0] ref_pc    [0:16383];
    reg [31:0] ref_val   [0:16383];
    reg [31:0] ref_instr [0:16383];
    reg [4:0]  ref_rd    [0:16383];
    integer c, t_pc, t_instr, t_rd, t_val;
    integer m;

    // ---- expected final data memory --------------------------------------
    reg [31:0] ref_daddr [0:4095];
    reg [31:0] ref_dword [0:4095];
    integer REF_DATA_WORDS = 0;
    integer d_a, d_w;

    initial begin
        fd = $fopen(TRACE, "r");
        if (fd == 0) begin
            $display("FATAL: cannot open reference trace %s", TRACE);
            $finish;
        end
        while (!$feof(fd)) begin
            c = $fscanf(fd, "%h %h %d %h\n", t_pc, t_instr, t_rd, t_val);
            if (c == 4) begin
                ref_pc[TRACE_WORDS]    = t_pc;
                ref_instr[TRACE_WORDS] = t_instr;
                ref_rd[TRACE_WORDS]    = t_rd;
                ref_val[TRACE_WORDS]   = t_val;
                TRACE_WORDS = TRACE_WORDS + 1;
            end
        end
        $fclose(fd);

        fd = $fopen(REFDATA, "r");
        if (fd == 0) begin
            $display("FATAL: cannot open reference data %s", REFDATA);
            $finish;
        end
        while (!$feof(fd)) begin
            c = $fscanf(fd, "%h %h\n", d_a, d_w);
            if (c == 2) begin
                ref_daddr[REF_DATA_WORDS] = d_a;
                ref_dword[REF_DATA_WORDS] = d_w;
                REF_DATA_WORDS = REF_DATA_WORDS + 1;
            end
        end
        $fclose(fd);

        fd = $fopen("ref.steps", "r");
        if (fd != 0) begin
            c = $fscanf(fd, "%d\n", ref_steps);
            $fclose(fd);
        end

        $display("=== CFG=%0s FWD=%0d HAZ=%0d STALLALL=%0d trace=%0d writes ===",
                 CFG_NAME, FORWARDING_EN, HAZARD_EN, STALL_ALL_DEP, TRACE_WORDS);
        repeat (2) @(posedge clk);
        reset = 0;
    end

    wire stall_now    = stall_out && !(flush_if_id || flush_id_ex);
    wire redirect_now = flush_if_id;

    // ---- optional per-cycle pipeline trace (README 6 / howto 3) ----------
    // Enable with `vvp sim.vvp +TRACE`. This makes the waveform exercises
    // reproducible from a plain CI log: no gtkwave needed to see WHY a
    // hazard is being forwarded, stalled or flushed.
    reg trace_on = 0;
    integer trace_cycle = 0;
    initial begin
        if ($test$plusargs("TRACE")) trace_on = 1;
    end

    // Use a DEDICATED counter, not `cycle`: the statistics block below
    // also runs at posedge, so reading `cycle` here is a race. Print at
    // negedge instead, when all posedge-updated state has settled.
    always @(negedge clk) begin
        if (!reset && !finished && trace_on) begin
            trace_cycle = trace_cycle + 1;
            // Icarus 11 does not accept adjacent string literals here;
            // use explicit concatenation so all three OS versions agree.
            $display({"TRACE c=%0d pc=%h IFID=%h[%h] IDEX=%h EXMEM=%h MEMWB=%h ",
                      "fwd=%b%b store=%b stall=%b lu=%b flush=%b%b ",
                      "opA=%h opB=%h alu=%h memrd=%h wb=%h"},
                     trace_cycle, pc, if_id_instr, if_id_pc, id_ex_instr,
                     ex_mem_instr, mem_wb_instr,
                     dut.forward_a, dut.forward_b, dut.fwd_store,
                     stall_now, load_use_hazard, flush_if_id, flush_id_ex,
                     dut.operand_a_raw, dut.operand_b_raw,
                     dut.alu_result, dut.mem_rdata, dut.wb_result);
        end
    end

    // ---- per-cycle statistics and per-retirement checking -----------------
    always @(posedge clk) begin
        if (!reset && !finished) begin
            cycle = cycle + 1;
            if (stall_now)    stall_count  = stall_count + 1;
            if (redirect_now) flush_count  = flush_count + 1;
            if ((forward_a != 2'b00) || (forward_b != 2'b00))
                fwd_count = fwd_count + 1;

            if (illegal_instr) begin
                $display("ERROR cycle=%0d: illegal instruction retired: %h",
                         cycle, retired_instr);
                errors = errors + 1;
            end

            if (retired_valid && !halted) begin
                retire_count = retire_count + 1;
                if (trace_idx >= TRACE_WORDS) begin
                    $display("ERROR cycle=%0d: extra write beyond reference: PC=%h instr=%h rd=%0d val=%h",
                             cycle, retired_pc, retired_instr, retired_rd,
                             retired_result);
                    errors = errors + 1;
                end else begin
                    if (retired_pc !== ref_pc[trace_idx]) begin
                        $display("ERROR cycle=%0d: PC mismatch: got=%h expected=%h (instr=%h)",
                                 cycle, retired_pc, ref_pc[trace_idx],
                                 retired_instr);
                        errors = errors + 1;
                    end
                    if (retired_instr !== ref_instr[trace_idx]) begin
                        $display("ERROR cycle=%0d: instr mismatch at PC=%h: got=%h expected=%h",
                                 cycle, retired_pc, retired_instr,
                                 ref_instr[trace_idx]);
                        errors = errors + 1;
                    end
                    if (retired_rd !== ref_rd[trace_idx]) begin
                        $display("ERROR cycle=%0d: rd mismatch at PC=%h: got=%0d expected=%0d",
                                 cycle, retired_pc, retired_rd,
                                 ref_rd[trace_idx]);
                        errors = errors + 1;
                    end
                    if (retired_result !== ref_val[trace_idx]) begin
                        $display("ERROR cycle=%0d: PC=%h instr=%h rd=%0d got=%h expected=%h",
                                 cycle, retired_pc, retired_instr, retired_rd,
                                 retired_result, ref_val[trace_idx]);
                        errors = errors + 1;
                    end
                    trace_idx = trace_idx + 1;
                end
            end

            if (halted) begin
                // Give in-flight instructions a few cycles to reach WB.
                finished = 1;
                #60;
                check_final();
            end
        end
    end

    task check_final;
        reg [31:0] got_word;
        reg [31:0] got_reg;
        integer    reg_fd, rc, ri;
        reg [31:0] rv;
        begin
            // Any reference write that never retired is an error.
            for (m = trace_idx; m < TRACE_WORDS; m = m + 1) begin
                $display("ERROR: expected write never retired: PC=%h instr=%h rd=%0d val=%h",
                         ref_pc[m], ref_instr[m], ref_rd[m], ref_val[m]);
                errors = errors + 1;
            end

            for (m = 0; m < REF_DATA_WORDS; m = m + 1) begin
                dbg_daddr = ref_daddr[m];
                #1;
                got_word = dbg_dmem;
                if (got_word !== ref_dword[m]) begin
                    $display("ERROR: dmem[%h] got=%h expected=%h",
                             ref_daddr[m], got_word, ref_dword[m]);
                    errors = errors + 1;
                end
            end

            reg_fd = $fopen(REFREGS, "r");
            if (reg_fd == 0) begin
                $display("FATAL: cannot open reference regs %s", REFREGS);
                errors = errors + 1;
            end else begin
                while (!$feof(reg_fd)) begin
                    rc = $fscanf(reg_fd, "%d %h\n", ri, rv);
                    if (rc == 2) begin
                        dbg_addr = ri;
                        #1;
                        got_reg = dbg_reg;
                        if (got_reg !== rv) begin
                            $display("ERROR: x%0d got=%h expected=%h",
                                     ri, got_reg, rv);
                            errors = errors + 1;
                        end
                    end
                end
                $fclose(reg_fd);
            end

            $display("RESULT cfg=%0s cycles=%0d instructions=%0d writes=%0d stalls=%0d flushes=%0d fwd_cycles=%0d errors=%0d",
                     CFG_NAME, cycle, ref_steps, retire_count, stall_count,
                     flush_count, fwd_count, errors);
            // Real CPI = cycles / executed instructions. Pipeline fill (4
            // cycles) is included, so small programs sit above 1.0; the
            // RELATIVE difference between configurations is the lesson.
            $display("CPI cfg=%0s %0d.%04d", CFG_NAME,
                     (ref_steps > 0) ? (cycle / ref_steps) : 0,
                     (ref_steps > 0) ?
                         ((cycle * 10000) / ref_steps) % 10000 : 0);
            if (errors == 0) $display("PASS cfg=%0s", CFG_NAME);
            else             $display("FAIL cfg=%0s", CFG_NAME);
            #10;
            $finish;
        end
    endtask

    // Timeout guard
    initial begin
        #(MAX_CYCLES * 10);
        if (!finished) begin
            $display("FAIL cfg=%0s TIMEOUT after %0d cycles (halted=%b pc=%h)",
                     CFG_NAME, cycle, halted, pc);
            $display("RESULT cfg=%0s cycles=%0d retires=%0d stalls=%0d flushes=%0d errors=%0d",
                     CFG_NAME, cycle, retire_count, stall_count,
                     flush_count, errors + 1);
            $finish;
        end
    end

    initial begin
        if ($test$plusargs("DUMP")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, cpu_tb);
        end
    end
endmodule
