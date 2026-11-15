#!/usr/bin/env python3
"""Build + run the full simulation matrix for the teaching CPU.

For each program:
    assemble -> reference trace -> for each hazard configuration:
        iverilog compile -> vvp run -> parse PASS/FAIL and CPI

Configurations:
    full       : forwarding ON,  hazard detection ON,  stall-all OFF
    stall_only : forwarding OFF, hazard detection ON,  stall-all ON
    no_forward : forwarding OFF, hazard detection ON,  stall-all OFF  (expected FAIL)
    no_hazard  : forwarding ON,  hazard detection OFF                 (expected FAIL)

The last two are intentionally broken configurations: they demonstrate
that forwarding and the load-use stall are each NECESSARY, not optional.
A configuration that unexpectedly passes on a program it should fail on
is itself reported as a test failure.

Usage: run_tests.py [--workdir DIR] [--only PROG] [--iverilog PATH] [--vvp PATH]
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

CONFIGS = {
    'full':       dict(FWD=1, HAZ=1, ALL=0, expect='pass'),
    'stall_only': dict(FWD=0, HAZ=1, ALL=1, expect='pass'),
    'no_forward': dict(FWD=0, HAZ=1, ALL=0, expect='fail'),
    'no_hazard':  dict(FWD=1, HAZ=0, ALL=0, expect='fail'),
}

# Which intentionally-broken configs are EXPECTED to fail on each program.
# A configuration missing a mechanism only fails when the program actually
# exercises that mechanism:
#
#   no_forward : no bypass at all -> fails on any distance-1 RAW dependency
#   no_hazard  : no load-use stall -> fails ONLY on an immediately adjacent
#                load followed by a consumer of the loaded register
#
# This table is itself part of the lesson: forwarding and stalling solve
# DIFFERENT hazards, and neither is universally required.
SHOULD_FAIL = {
    'basic':         {'no_forward'},             # chained add/sub/xor at distance 1
    'alu_hazard':    {'no_forward'},             # data hazards only
    'load_use':      {'no_forward', 'no_hazard'},  # adjacent load consumers
    'load_use_adj':  {'no_forward', 'no_hazard'},
    'branch':        {'no_forward'},             # branch compares freshly-written regs
    'memory':        {'no_forward', 'no_hazard'},  # adjacent lw -> addi -> sw
    'stress':        {'no_forward'},             # fib loop has distance-1 deps
}


def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--workdir')
    ap.add_argument('--only', help='only run this program (stem name)')
    ap.add_argument('--iverilog', default=os.environ.get('IVERILOG', 'iverilog'))
    ap.add_argument('--vvp', default=os.environ.get('VVP', 'vvp'))
    args = ap.parse_args()

    # Every path must be ABSOLUTE: each subprocess runs with cwd set to
    # its program directory, so a relative workdir would be re-resolved
    # from there and the generated files would land in a nested tree.
    work = os.path.abspath(args.workdir or
                           tempfile.mkdtemp(prefix='riscv_sim_'))
    os.makedirs(work, exist_ok=True)
    keep = bool(args.workdir)

    rtl_files = sorted(os.path.join(RTL, f) for f in os.listdir(RTL)
                       if f.endswith('.v'))
    programs = sorted(f for f in os.listdir(PROGRAMS) if f.endswith('.s'))
    if args.only:
        programs = [p for p in programs if os.path.splitext(p)[0] == args.only]

    print(f'workdir : {work}')
    print(f'iverilog: {args.iverilog}')
    print(f'vvp     : {args.vvp}')
    print(f'programs: {", ".join(os.path.splitext(p)[0] for p in programs)}')
    print()

    total, failures = 0, 0
    summary = {}

    for prog in programs:
        stem = os.path.splitext(prog)[0]
        pdir = os.path.join(work, stem)
        os.makedirs(pdir, exist_ok=True)

        r = run([sys.executable, '-I', os.path.join(HERE, 'asm.py'),
                 os.path.join(PROGRAMS, prog), pdir], cwd=pdir)
        if r.returncode != 0:
            print(f'[{stem}] ASSEMBLY FAILED\n{r.stdout}')
            failures += 1
            continue
        r = run([sys.executable, '-I', os.path.join(HERE, 'ref.py'), pdir],
                cwd=pdir)
        if r.returncode != 0:
            print(f'[{stem}] REFERENCE FAILED\n{r.stdout}')
            failures += 1
            continue

        for cfg, spec in CONFIGS.items():
            total += 1
            sim = os.path.join(pdir, f'{cfg}.vvp')
            # Generate a per-configuration config.vh. Its include dir is
            # placed FIRST on -I so it shadows tb/config.vh. This avoids
            # iverilog -P entirely (its syntax differs across releases
            # and Windows shells).
            cfgdir = os.path.join(pdir, 'inc_' + cfg)
            os.makedirs(cfgdir, exist_ok=True)
            with open(os.path.join(cfgdir, 'config.vh'), 'w') as f:
                f.write('`ifndef CPU_TB_CONFIG_VH\n')
                f.write('`define CPU_TB_CONFIG_VH\n')
                f.write('`define TB_PROG          "prog.hex"\n')
                f.write('`define TB_DATA          "data.hex"\n')
                f.write('`define TB_TRACE         "ref.trace"\n')
                f.write('`define TB_REFDATA       "ref.data"\n')
                f.write('`define TB_REFREGS       "ref.regs"\n')
                f.write(f'`define TB_FORWARDING_EN {spec["FWD"]}\n')
                f.write(f'`define TB_HAZARD_EN     {spec["HAZ"]}\n')
                f.write(f'`define TB_STALL_ALL_DEP {spec["ALL"]}\n')
                f.write(f'`define TB_CFG_NAME      "{cfg}"\n')
                f.write('`define TB_MAX_CYCLES    5000\n')
                f.write('`endif\n')
            cmd = [
                args.iverilog, '-g2012', '-o', sim,
                '-I', cfgdir,
                '-I', RTL,
                '-I', os.path.join(ROOT, 'tb'),
            ] + rtl_files + [TB]
            r = run(cmd, cwd=pdir)
            if r.returncode != 0:
                print(f'[{stem}/{cfg}] COMPILE FAILED\n{r.stdout[:2000]}')
                failures += 1
                continue
            r = run([args.vvp, sim], cwd=pdir)
            out = r.stdout
            passed = 'PASS cfg=' in out
            failed_marker = ('FAIL cfg=' in out) or not passed
            cpi = ''
            for line in out.splitlines():
                if line.startswith('CPI '):
                    cpi = line.split()[-1]
                    break
            should_fail = cfg in SHOULD_FAIL.get(stem, set())
            expected = not should_fail
            ok = (passed == expected)
            if not ok:
                failures += 1
            tag = 'ok' if ok else 'UNEXPECTED'
            print(f'[{stem:12s}/{cfg:11s}] {"PASS" if passed else "FAIL":4s} '
                  f'expected={"PASS" if expected else "FAIL":4s} '
                  f'CPI={cpi or "-":8s} {tag}')
            if not ok or (failed_marker and expected):
                for line in out.splitlines():
                    if ('ERROR' in line or 'TIMEOUT' in line or
                            line.startswith('RESULT') or
                            line.startswith('FAIL')):
                        print('   ' + line)
            summary.setdefault(stem, {})[cfg] = dict(
                passed=passed, cpi=cpi, expected=expected, ok=ok)

    # Machine- and human-readable summary, written to the workdir so CI
    # can attach it to $GITHUB_STEP_SUMMARY and upload it as an artifact.
    lines = []
    lines.append('## Simulation matrix: CPI by configuration')
    lines.append('')
    lines.append('| program | ' + ' | '.join(CONFIGS) + ' |')
    lines.append('| --- | ' + ' | '.join(['---'] * len(CONFIGS)) + ' |')
    for stem, row in summary.items():
        cells = []
        for cfg in CONFIGS:
            v = row.get(cfg)
            cpi = v['cpi'] if v and v['cpi'] else '-'
            if v and not v['ok']:
                cpi += ' (unexpected)'
            cells.append(cpi)
        lines.append(f'| `{stem}` | ' + ' | '.join(cells) + ' |')
    lines.append('')
    lines.append('`no_forward` / `no_hazard` are deliberately broken '
                 'configurations; a FAIL there is an expected outcome. '
                 'CPI = cycles / executed instructions, including the '
                 '4-cycle pipeline fill.')

    print()
    print('=' * 68)
    print('Summary (CPI by configuration; "-" = run failed/no value)')
    print(f'{"program":14s}' + ''.join(f'{c:>14s}' for c in CONFIGS))
    for stem, row in summary.items():
        cells = []
        for cfg in CONFIGS:
            v = row.get(cfg)
            cells.append(f'{v["cpi"]:>14s}' if v and v['cpi'] else f'{"-":>14s}')
        print(f'{stem:14s}' + ''.join(cells))
    print('=' * 68)
    print(f'{total} runs, {failures} unexpected outcomes')

    with open(os.path.join(work, 'summary.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
        f.write(f'\n{total} runs, {failures} unexpected outcomes.\n')

    if not keep:
        shutil.rmtree(work, ignore_errors=True)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
