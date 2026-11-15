#!/usr/bin/env python3
"""Single-cycle golden reference interpreter for the RV32I subset CPU.

Reads prog.hex / data.hex produced by asm.py, executes the program
instruction by instruction (one instruction at a time = no hazards), and
writes:

  ref.trace : "<pc_hex> <instr_hex> <rd> <value_hex>" per writing instruction
              in executed program order, including x0 writes? No: only
              instructions whose *decoded* rd != 0 are recorded, because
              the DUT reports retired_valid only for rd != 0.
  ref.data  : "<addr_hex> <word_hex>" for every data word that changed
  ref.regs  : "x <value_hex>" for all 32 registers

Usage: ref.py <outdir> [max_steps]
"""
import os
import sys

MASK = 0xFFFFFFFF
DMEM_BASE = 0x4000


def s32(v):
    v &= MASK
    return v - (1 << 32) if v & 0x80000000 else v


def sext(v, bits):
    v &= (1 << bits) - 1
    sign = 1 << (bits - 1)
    return (v - (1 << bits)) if (v & sign) else v


class Ref:
    def __init__(self, outdir):
        with open(os.path.join(outdir, 'prog.hex')) as f:
            self.imem = [int(x, 16) for x in f.read().split()]
        with open(os.path.join(outdir, 'data.hex')) as f:
            self.dmem = [int(x, 16) for x in f.read().split()]
        self.regs = [0] * 32
        self.pc = 0
        self.trace = []
        self.steps = 0

    def rd(self, addr):
        off = addr - DMEM_BASE
        if off < 0 or off + 4 > 4 * len(self.dmem):
            return 0
        return self.dmem[off >> 2] & MASK

    def wr(self, addr, value, width, unsigned=False):
        off = addr - DMEM_BASE
        if off < 0 or off // 4 >= len(self.dmem):
            return
        idx, boff = off >> 2, off & 3
        word = self.dmem[idx] & MASK
        if width == 4:
            self.dmem[idx] = value & MASK
        elif width == 2:
            shift = (boff & 2) * 8
            word = (word & ~(0xFFFF << shift) & MASK) | ((value & 0xFFFF) << shift)
            self.dmem[idx] = word & MASK
        elif width == 1:
            shift = boff * 8
            word = (word & ~(0xFF << shift) & MASK) | ((value & 0xFF) << shift)
            self.dmem[idx] = word & MASK

    def load(self, addr, f3):
        off = addr - DMEM_BASE
        if off < 0 or off // 4 >= len(self.dmem):
            return 0
        idx, boff = off >> 2, off & 3
        word = self.dmem[idx] & MASK
        if f3 in (0, 4):   # lb / lbu
            b = (word >> (boff * 8)) & 0xFF
            return b if f3 == 4 else sext(b, 8)
        if f3 in (1, 5):   # lh / lhu
            h = (word >> ((boff & 2) * 8)) & 0xFFFF
            return h if f3 == 5 else sext(h, 16)
        if f3 == 2:        # lw
            return word
        raise ValueError(f'bad load f3={f3}')

    def step(self):
        instr = self.imem[self.pc >> 2] if (self.pc >> 2) < len(self.imem) else 0x13
        pc = self.pc
        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        f3 = (instr >> 12) & 7
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        f7 = (instr >> 25) & 0x7F
        a = self.regs[rs1]
        b = self.regs[rs2]
        result = None
        next_pc = (pc + 4) & MASK

        imm_i = sext(instr >> 20, 12)
        imm_s = sext(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)
        imm_b = sext((((instr >> 31) & 1) << 12) |
                     (((instr >> 7) & 1) << 11) |
                     (((instr >> 25) & 0x3F) << 5) |
                     (((instr >> 8) & 0xF) << 1), 13)
        imm_u = instr & 0xFFFFF000
        imm_j = sext((((instr >> 31) & 1) << 20) |
                     (((instr >> 12) & 0xFF) << 12) |
                     (((instr >> 20) & 1) << 11) |
                     (((instr >> 21) & 0x3FF) << 1), 21)

        if opcode == 0x73:      # ECALL = halt
            return False
        elif opcode == 0x37:    # LUI
            result = imm_u
        elif opcode == 0x17:    # AUIPC
            result = (pc + imm_u) & MASK
        elif opcode == 0x6F:    # JAL
            result = (pc + 4) & MASK
            next_pc = (pc + imm_j) & MASK
        elif opcode == 0x67:    # JALR
            result = (pc + 4) & MASK
            next_pc = (a + imm_i) & 0xFFFFFFFE
        elif opcode == 0x63:    # BRANCH
            take = {
                0: a == b, 1: a != b,
                4: s32(a) < s32(b), 5: s32(a) >= s32(b),
                6: a < b, 7: a >= b,
            }[f3]
            if take:
                next_pc = (pc + imm_b) & MASK
        elif opcode == 0x03:    # LOAD
            result = self.load((a + imm_i) & MASK, f3)
        elif opcode == 0x23:    # STORE
            size = {0: 1, 1: 2, 2: 4}[f3]
            self.wr((a + imm_s) & MASK, b, size)
        elif opcode == 0x13:    # ITYPE
            shamt = (instr >> 20) & 0x1F
            ops = {
                0: (a + imm_i) & MASK,
                1: (a << shamt) & MASK,
                2: 1 if s32(a) < s32(imm_i) else 0,
                3: 1 if a < (imm_i & MASK) else 0,
                4: (a ^ (imm_i & MASK)) & MASK,
                5: (((a & MASK) >> shamt) if f7 == 0 else
                    (s32(a) >> shamt) & MASK),
                6: (a | (imm_i & MASK)) & MASK,
                7: (a & (imm_i & MASK)) & MASK,
            }
            result = ops[f3]
        elif opcode == 0x33:    # RTYPE
            shamt = b & 0x1F
            ops = {
                0: ((a - b) if f7 == 0x20 else (a + b)) & MASK,
                1: (a << shamt) & MASK,
                2: 1 if s32(a) < s32(b) else 0,
                3: 1 if (a & MASK) < (b & MASK) else 0,
                4: (a ^ b) & MASK,
                5: (((a & MASK) >> shamt) if f7 == 0 else
                    (s32(a) >> shamt) & MASK),
                6: (a | b) & MASK,
                7: (a & b) & MASK,
            }
            result = ops[f3]
        elif opcode == 0x0F:    # FENCE = NOP
            pass
        else:
            raise ValueError(f'unsupported opcode {opcode:02x} at pc={pc:08x}')

        if result is not None:
            if rd != 0:
                self.regs[rd] = result & MASK
            # Record the write for DUT comparison (DUT retires rd!=0 only).
            if rd != 0:
                self.trace.append((pc, instr, rd, result & MASK))

        self.pc = next_pc
        self.steps += 1
        return True

    def run(self, max_steps=10000):
        while self.steps < max_steps:
            if not self.step():
                break
        else:
            raise RuntimeError(f'reference did not halt after {max_steps} steps')
        return self.steps

    def write(self, outdir):
        # Total executed instructions (ECALL excluded). The testbench uses
        # this as the denominator for a real CPI: cycles / instructions.
        with open(os.path.join(outdir, 'ref.steps'), 'w') as f:
            f.write(f'{self.steps}\n')
        with open(os.path.join(outdir, 'ref.trace'), 'w') as f:
            for pc, instr, rd, val in self.trace:
                f.write(f'{pc:08x} {instr:08x} {rd:d} {val:08x}\n')
        with open(os.path.join(outdir, 'ref.data'), 'w') as f:
            # Only the words actually present in data.hex need checking.
            for i, w in enumerate(self.dmem):
                f.write(f'{DMEM_BASE + 4 * i:08x} {w & MASK:08x}\n')
        with open(os.path.join(outdir, 'ref.regs'), 'w') as f:
            for i, v in enumerate(self.regs):
                f.write(f'{i:d} {v & MASK:08x}\n')


def main():
    if len(sys.argv) < 2:
        print('usage: ref.py <outdir> [max_steps]')
        sys.exit(2)
    outdir = sys.argv[1]
    max_steps = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
    r = Ref(outdir)
    steps = r.run(max_steps)
    r.write(outdir)
    print(f'reference: {steps} steps, {len(r.trace)} register writes -> {outdir}')


if __name__ == '__main__':
    main()
