#!/usr/bin/env python3
"""Reproduce the hands-on exercises from README section 6.

Each exercise states a concrete, machine-checkable claim about the
pipeline. This script builds the relevant program in the relevant
configuration, runs vvp with +TRACE, parses the log, and checks the
evidence. It never modifies the RTL: exercise 4's "wrong hazard
condition" is compiled from tools/experiments/ via a shadow -I directory.

Exercises are registered with @exercise(N) and added one commit at a
time, so `python -I tools/exercises.py` always runs exactly the ones
that have been implemented so far.

Usage:
    exercises.py            # run all implemented exercises
    exercises.py 1 3        # run only 1 and 3
    exercises.py --workdir DIR --iverilog PATH --vvp PATH

Exit status is 0 only if every claimed observation is actually seen.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RTL = os.path.join(ROOT, 'rtl')
TB = os.path.join(ROOT, 'tb', 'cpu_tb.v')
PROGRAMS = os.path.join(ROOT, 'tests', 'programs')
EXPERIMENTS = os.path.join(ROOT, 'tools', 'experiments')

CONFIGS = {
    'full':       dict(FWD=1, HAZ=1, ALL=0),
    'stall_only': dict(FWD=0, HAZ=1, ALL=1),
    'no_forward': dict(FWD=0, HAZ=1, ALL=0),
    'no_hazard':  dict(FWD=1, HAZ=0, ALL=0),
}

EXERCISES = {}


def exercise(n):
    def deco(fn):
        EXERCISES[n] = fn
        return fn
    return deco


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------
def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)


def build(pdir, stem, cfg, iverilog, vvp, rtl_override=None):
    """Assemble, build reference, compile, run with +TRACE. Return the log."""
    os.makedirs(pdir, exist_ok=True)
    r = run([sys.executable, '-I', os.path.join(HERE, 'asm.py'),
             os.path.join(PROGRAMS, stem + '.s'), pdir], cwd=pdir)
    assert r.returncode == 0, f'asm failed: {r.stdout}'
    r = run([sys.executable, '-I', os.path.join(HERE, 'ref.py'), pdir], cwd=pdir)
    assert r.returncode == 0, f'ref failed: {r.stdout}'

    spec = CONFIGS[cfg]
    cfgdir = os.path.join(pdir, 'inc_' + cfg)
    os.makedirs(cfgdir, exist_ok=True)
    with open(os.path.join(cfgdir, 'config.vh'), 'w') as f:
        f.write('`ifndef CPU_TB_CONFIG_VH\n`define CPU_TB_CONFIG_VH\n')
        f.write('`define TB_PROG          "prog.hex"\n')
        f.write('`define TB_DATA          "data.hex"\n')
        f.write('`define TB_TRACE         "ref.trace"\n')
        f.write('`define TB_REFDATA       "ref.data"\n')
        f.write('`define TB_REFREGS       "ref.regs"\n')
        for k, v in (('TB_FORWARDING_EN', spec['FWD']),
                     ('TB_HAZARD_EN', spec['HAZ']),
                     ('TB_STALL_ALL_DEP', spec['ALL'])):
            f.write(f'`define {k} {v}\n')
        f.write(f'`define TB_CFG_NAME      "{cfg}"\n')
        f.write('`define TB_MAX_CYCLES    5000\n`endif\n')

    # rtl_override is an include dir holding a modified hazard_unit.v. It
    # must precede rtl/ on -I, and the modified file replaces the original.
    rtl_files = sorted(os.path.join(RTL, x) for x in os.listdir(RTL)
                       if x.endswith('.v'))
    incs = ['-I', cfgdir]
    if rtl_override:
        incs += ['-I', rtl_override]
        rtl_files = [x for x in rtl_files
                     if not x.endswith('hazard_unit.v')]
        rtl_files.append(os.path.join(rtl_override, 'hazard_unit.v'))
    incs += ['-I', RTL, '-I', os.path.join(ROOT, 'tb')]

    sim = os.path.join(pdir, f'{cfg}.vvp')
    cmd = [iverilog, '-g2012', '-o', sim] + incs + rtl_files + [TB]
    r = run(cmd, cwd=pdir)
    assert r.returncode == 0, f'iverilog failed: {r.stdout}'
    r = run([vvp, sim, '+TRACE'], cwd=pdir)
    return r.stdout


def traces_of(log):
    return [l for l in log.splitlines() if l.startswith('TRACE c=')]


def result_line(log):
    for line in log.splitlines():
        if line.startswith('RESULT '):
            return line
    return ''


def cpi_of(log):
    for line in log.splitlines():
        if line.startswith('CPI '):
            return float(line.split()[-1])
    return 0.0


def int_field(line, name):
    tok = name + '='
    i = line.find(tok)
    if i < 0:
        return 0
    j = i + len(tok)
    while j < len(line) and line[j].isdigit():
        j += 1
    return int(line[i + len(tok):j]) if j > i + len(tok) else 0


def fwd_tokens(log):
    """Yield (forward_a, forward_b) 2-bit strings for each traced cycle."""
    for l in traces_of(log):
        if 'fwd=' in l:
            tok = l.split('fwd=')[1].split()[0]
            if len(tok) == 4:
                yield tok[0:2], tok[2:4]


def err_values(log):
    """Value mismatches reported by the testbench."""
    out = []
    for line in log.splitlines():
        if (line.startswith('ERROR cycle=') and ' got=' in line
                and ' expected=' in line):
            pc = line.split('PC=')[1].split()[0]
            got = line.split('got=')[1].split()[0]
            exp = line.split('expected=')[1].split()[0]
            out.append((pc, got, exp, line))
    return out


# ---------------------------------------------------------------------------
# Exercise 1
# ---------------------------------------------------------------------------
@exercise(1)
def ex1(work, iverilog, vvp):
    print('=== Exercise 1: alu_hazard / full -> forwarding 01 and 10 ===')
    log = build(os.path.join(work, 'ex1'), 'alu_hazard', 'full',
                iverilog, vvp)
    exmem, memwb = 0, 0
    first_exmem, first_memwb = '', ''
    for l in traces_of(log):
        if 'fwd=' not in l:
            continue
        tok = l.split('fwd=')[1].split()[0]
        if len(tok) != 4:
            continue
        a, b = tok[0:2], tok[2:4]
        if '01' in (a, b):
            exmem += 1
            if not first_exmem:
                first_exmem = l
        if '10' in (a, b):
            memwb += 1
            if not first_memwb:
                first_memwb = l
    print(f'  result: {result_line(log)}')
    print(f'  EX/MEM (01) cycles: {exmem}; MEM/WB (10) cycles: {memwb}')
    if first_exmem:
        print(f'  first 01: {first_exmem.strip()}')
    if first_memwb:
        print(f'  first 10: {first_memwb.strip()}')
    return [
        ('EX/MEM forwarding (01) really happens', exmem > 0, first_exmem),
        ('MEM/WB forwarding (10) really happens', memwb > 0, first_memwb),
    ], f'{exmem} cycles with fwd=01, {memwb} with fwd=10'


# ---------------------------------------------------------------------------
# Exercise 2
# ---------------------------------------------------------------------------
@exercise(2)
def ex2(work, iverilog, vvp):
    print('=== Exercise 2: no_forward -> stale register file (x2 = 0) ===')
    log = build(os.path.join(work, 'ex2'), 'alu_hazard', 'no_forward',
                iverilog, vvp)
    vals = err_values(log)
    stale = [v for v in vals if v[0] == '00000004' and
             v[1] == '00000000' and v[2] == '00000002']
    toks = list(fwd_tokens(log))
    all_zero = bool(toks) and all(a == '00' and b == '00' for a, b in toks)
    print(f'  result: {result_line(log)}')
    print(f'  cycles traced: {len(toks)}, all fwd=00: {all_zero}')
    if stale:
        print(f'  first stale read: {stale[0][3].strip()}')
    return [
        ('add x2,x1,x1 at PC=0x04 got 0 instead of 2 (stale regfile)',
         bool(stale), stale[0][3] if stale else
         '\n'.join(v[3] for v in vals[:4])),
        ('forward_a/forward_b are 00 in every cycle', all_zero, ''),
    ], f'x2=0 instead of 2; {len(toks)} cycles with no forwarding'


# ---------------------------------------------------------------------------
# Exercise 3
# ---------------------------------------------------------------------------
@exercise(3)
def ex3(work, iverilog, vvp):
    print('=== Exercise 3: load_use_adj / no_hazard -> load ADDRESS forwarded ===')
    log = build(os.path.join(work, 'ex3'), 'load_use_adj', 'no_hazard',
                iverilog, vvp)
    vals = err_values(log)
    # lw x1,0(x2) is at PC=0x04; the immediately following
    # `addi x3,x1,1` is at PC=0x08. With no stall, EX/MEM can only
    # supply the load's ADDRESS (0x4000), so x3 becomes 0x4001 instead
    # of the loaded word 0x2a + 1 = 0x2b.
    bad = [v for v in vals if v[0] == '00000008' and
           v[1] == '00004001' and v[2] == '0000002b']
    traces = traces_of(log)
    no_stall = bool(traces) and all('stall=0' in l for l in traces)
    # Find the cycle where the address is actually on the ALU input.
    addr_fwd = [l for l in traces if 'opA=00004000' in l]
    print(f'  result: {result_line(log)}')
    print(f'  cycles traced: {len(traces)}, no stall inserted: {no_stall}')
    print(f'  cycles with 0x4000 (load address) on ALU input A: {len(addr_fwd)}')
    if bad:
        print(f'  corrupted result: {bad[0][3].strip()}')
    if addr_fwd:
        print(f'  address on opA: {addr_fwd[0].strip()}')
    return [
        ('addi x3,x1,1 at PC=0x08 got 0x4001 (address+1) instead of 0x2b',
         bool(bad), bad[0][3] if bad else
         '\n'.join(v[3] for v in vals[:4])),
        ('no load-use stall was inserted', no_stall, ''),
        ('the load ADDRESS 0x4000 really appears on an ALU input',
         bool(addr_fwd), addr_fwd[0] if addr_fwd else ''),
    ], f'x3=0x4001 instead of 0x2b; {len(addr_fwd)} cycles forwarding 0x4000'


# ---------------------------------------------------------------------------
# Exercise 4
# ---------------------------------------------------------------------------
@exercise(4)
def ex4(work, iverilog, vvp):
    print('=== Exercise 4: over-stall (drop id_ex_mem_read) ===')
    base = build(os.path.join(work, 'ex4_base'), 'load_use_adj', 'full',
                 iverilog, vvp)
    over = build(os.path.join(work, 'ex4_over'), 'load_use_adj', 'full',
                 iverilog, vvp,
                 rtl_override=os.path.join(EXPERIMENTS, 'over_stall'))
    base_stalls = int_field(result_line(base), 'stalls')
    over_stalls = int_field(result_line(over), 'stalls')
    base_cpi, over_cpi = cpi_of(base), cpi_of(over)
    base_ok = 'PASS cfg=' in base
    over_ok = 'PASS cfg=' in over
    print(f'  unmodified : stalls={base_stalls} CPI={base_cpi:.4f} PASS={base_ok}')
    print(f'  over-stall : stalls={over_stalls} CPI={over_cpi:.4f} PASS={over_ok}')
    print(f'  base result: {result_line(base)}')
    print(f'  over result: {result_line(over)}')
    return [
        ('over-stall still produces CORRECT results', over_ok, ''),
        ('but inserts MORE stalls', over_stalls > base_stalls, ''),
        ('and has a WORSE CPI', over_cpi > base_cpi, ''),
    ], (f'stalls {base_stalls} -> {over_stalls}, '
        f'CPI {base_cpi:.4f} -> {over_cpi:.4f}, results still correct')


# ---------------------------------------------------------------------------
# Exercise 5
# ---------------------------------------------------------------------------
@exercise(5)
def ex5(work, iverilog, vvp):
    print('=== Exercise 5: branch flush count (branch.s with far jal) ===')
    log = build(os.path.join(work, 'ex5'), 'branch', 'full',
                iverilog, vvp)
    flushes = int_field(result_line(log), 'flushes')
    traces = traces_of(log)
    redirects = [l for l in traces if 'flush=11' in l]
    taken = len(redirects)

    # A redirect squashes BOTH wrong-path slots:
    #   cycle +1 : IF/ID holds the flushed NOP (IFID=00000013)
    #   cycle +2 : ID/EX holds the squashed NOP (IDEX=00000013)
    # So each redirect must produce one of each -- 2 bubbles total.
    ifid_nops, idex_nops = 0, 0
    for i, l in enumerate(traces):
        if 'flush=11' not in l:
            continue
        following = traces[i + 1:i + 3]
        if any('IFID=00000013' in n for n in following):
            ifid_nops += 1
        if any('IDEX=00000013' in n for n in following):
            idex_nops += 1
    squashed = ifid_nops + idex_nops

    # The far `jal x15, far_target` must actually be executed: x15 is
    # its link address and x22 = x14 + 1 is computed after the jump.
    ref_path = os.path.join(work, 'ex5', 'ref.trace')
    link_ok = False
    if os.path.exists(ref_path):
        with open(ref_path) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 4 and parts[2] == '15':
                    link_ok = True
    print(f'  result: {result_line(log)}')
    print(f'  taken redirects (flush=11 cycles): {taken}')
    print(f'  flush counter: {flushes}')
    print(f'  squashed NOP slots: IF/ID={ifid_nops}, ID/EX={idex_nops} '
          f'(total {squashed}, expected {2 * taken})')
    print(f'  far jal link register x15 retired: {link_ok}')
    return [
        ('flush counter == number of taken redirects (+1 each, NOT +2)',
         taken > 0 and flushes == taken, ''),
        ('each redirect squashes BOTH IF/ID and ID/EX (2 NOP slots)',
         ifid_nops == taken and idex_nops == taken, ''),
        ('the newly added far `jal` really executed', link_ok, ''),
    ], (f'{taken} taken redirects, flushes={flushes}, '
        f'{squashed} squashed NOP slots, far jal retired')


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('which', nargs='*', type=int)
    ap.add_argument('--workdir')
    ap.add_argument('--iverilog', default=os.environ.get('IVERILOG', 'iverilog'))
    ap.add_argument('--vvp', default=os.environ.get('VVP', 'vvp'))
    args = ap.parse_args()

    todo = args.which or sorted(EXERCISES)
    unknown = [n for n in todo if n not in EXERCISES]
    if unknown:
        print(f'exercises not implemented yet: {unknown}')
        return 2

    work = os.path.abspath(args.workdir or
                           tempfile.mkdtemp(prefix='riscv_ex_'))
    os.makedirs(work, exist_ok=True)
    print(f'workdir : {work}')
    print(f'iverilog: {args.iverilog}')
    print(f'exercises implemented: {sorted(EXERCISES)}\n')

    ok_all = True
    summary = []
    for n in todo:
        claims, note = EXERCISES[n](work, args.iverilog, args.vvp)
        for claim, ok, detail in claims:
            ok_all = ok_all and ok
            print(f'  [{"OK" if ok else "NOT SEEN"}] {claim}')
            if not ok and detail:
                for line in str(detail).rstrip().splitlines()[-6:]:
                    print('        ' + line)
        summary.append((n, all(c[1] for c in claims), note))
        print()

    print('=' * 64)
    for n, ok, note in summary:
        print(f'  exercise {n}: {"OK" if ok else "NOT SEEN"} - {note}')
    print('ALL EXERCISES REPRODUCED' if ok_all else 'SOME CLAIMS NOT SEEN')

    if not args.workdir:
        shutil.rmtree(work, ignore_errors=True)
    return 0 if ok_all else 1


if __name__ == '__main__':
    sys.exit(main())
