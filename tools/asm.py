#!/usr/bin/env python3
"""Minimal RV32I assembler for the teaching CPU.

Input is a small assembly subset with labels; output is one 32-bit hex
word per line (prog.hex) plus, optionally, initial data words (data.hex).

Supported directives:
    .word <value>            -- append a data word (in the data section)
    .data / .text            -- switch sections
    .equ SYM, value          -- constant (useful for addresses)

Supported instructions (all real RV32I encodings):
    add sub sll slt sltu xor srl sra or and
    addi slli slti sltiu xori srli srai ori andi
    lw lh lb lhu lbu
    sw sh sb
    beq bne blt bge bltu bgeu
    lui auipc jal jalr ecall nop

Registers: x0..x31 plus ABI names zero, ra, sp, t0..t6, s0..s11, a0..a7.
Labels resolve to byte addresses; branch/jump immediates are computed
relative to the instruction's own address, as in real RISC-V.
"""
import re
import sys
from dataclasses import dataclass, field

MASK = 0xFFFFFFFF

ABI = {
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4,
    't0': 5, 't1': 6, 't2': 7,
    's0': 8, 'fp': 8, 's1': 9,
    'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13, 'a4': 14, 'a5': 15,
    'a6': 16, 'a7': 17,
    's2': 18, 's3': 19, 's4': 20, 's5': 21, 's6': 22, 's7': 23,
    's8': 24, 's9': 25, 's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31,
}

R_OPS = {'add': (0x00, 0x33), 'sub': (0x20, 0x33), 'sll': (0x00, 0x33),
         'slt': (0x00, 0x33), 'sltu': (0x00, 0x33), 'xor': (0x00, 0x33),
         'srl': (0x00, 0x33), 'sra': (0x20, 0x33), 'or': (0x00, 0x33),
         'and': (0x00, 0x33)}
R_F3 = {'add': 0, 'sub': 0, 'sll': 1, 'slt': 2, 'sltu': 3, 'xor': 4,
        'srl': 5, 'sra': 5, 'or': 6, 'and': 7}

I_OPS = {'addi': (0x13, 0), 'slli': (0x13, 1), 'slti': (0x13, 2),
         'sltiu': (0x13, 3), 'xori': (0x13, 4), 'srli': (0x13, 5),
         'srai': (0x13, 5), 'ori': (0x13, 6), 'andi': (0x13, 7),
         'jalr': (0x67, 0), 'lb': (0x03, 0), 'lh': (0x03, 1),
         'lw': (0x03, 2), 'lbu': (0x03, 4), 'lhu': (0x03, 5),
         'ecall': (0x73, 0)}

S_F3 = {'sb': 0, 'sh': 1, 'sw': 2}
B_F3 = {'beq': 0, 'bne': 1, 'blt': 4, 'bge': 5, 'bltu': 6, 'bgeu': 7}


def reg(tok):
    tok = tok.strip().lower()
    if tok in ABI:
        return ABI[tok]
    m = re.fullmatch(r'x(\d+)', tok)
    if m and 0 <= int(m.group(1)) <= 31:
        return int(m.group(1))
    raise ValueError(f'bad register: {tok}')


def num(tok, consts):
    tok = tok.strip()
    if tok in consts:
        return consts[tok]
    if re.fullmatch(r'0x[0-9a-fA-F]+', tok):
        return int(tok, 16)
    if re.fullmatch(r'-?0b[01]+', tok):
        return int(tok.replace('-0b', '-0b'), 2)
    return int(tok, 0)


def signed(v, bits=32):
    return v & ((1 << bits) - 1)


@dataclass
class Item:
    addr: int
    kind: str
    parts: list = field(default_factory=list)
    word: int = 0
    line: str = ''


class Asm:
    def __init__(self):
        self.text = []          # list of Item
        self.data = []          # list of (addr, word)
        self.labels = {}
        self.consts = {}
        self.section = 'text'
        self.text_size = 0
        self.data_size = 0

    def parse(self, lines):
        # Pass 1: collect labels and layout, keep raw items
        for raw in lines:
            line = raw.split('#')[0].split('//')[0].strip()
            if not line:
                continue
            while True:
                m = re.match(r'^([A-Za-z_][\w.]*):\s*(.*)$', line)
                if not m:
                    break
                self.labels[m.group(1)] = (self.section,
                                           self.text_size if self.section == 'text'
                                           else 0x4000 + self.data_size)
                line = m.group(2).strip()
                if not line:
                    break
            if not line:
                continue

            if line.startswith('.'):
                self.directive(line)
                continue

            if self.section == 'data':
                # data lines must be directives
                raise ValueError(f'only directives allowed in .data: {line}')

            parts = [p.strip() for p in re.split(r'[,\s]+', line) if p.strip()]
            self.text.append(Item(self.text_size, 'insn', parts, 0, line))
            self.text_size += 4
        return self

    def directive(self, line):
        parts = [p.strip() for p in re.split(r'[,\s]+', line) if p.strip()]
        d = parts[0].lower()
        if d == '.text':
            self.section = 'text'
        elif d == '.data':
            self.section = 'data'
        elif d == '.word':
            if self.section != 'data':
                raise ValueError('.word only allowed in .data section')
            val = num(parts[1], self.consts) & MASK
            self.data.append((0x4000 + self.data_size, val))
            self.data_size += 4
        elif d == '.equ':
            self.consts[parts[1]] = num(parts[2], self.consts)
        else:
            raise ValueError(f'unknown directive: {d}')

    def resolve(self, tok, addr, rel=False, width=13):
        """Resolve an immediate / label token."""
        if tok in self.labels:
            target = self.labels[tok][1]
        else:
            target = num(tok, self.consts)
        value = target - addr if rel else target
        lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
        if not (lo <= value <= hi):
            raise ValueError(f'immediate out of range: {tok} -> {value}')
        return value & ((1 << width) - 1)

    def encode(self, it):
        p = it.parts
        op = p[0].lower()
        a, addr = it.addr, it.addr

        def r_type():
            rd, rs1, rs2 = reg(p[1]), reg(p[2]), reg(p[3])
            f7, opcode = R_OPS[op]
            return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (R_F3[op] << 12) | \
                   (rd << 7) | opcode

        def i_type():
            opcode, f3 = I_OPS[op]
            if op == 'ecall':
                return 0x00000073
            if op == 'jalr':
                rd, rs1 = reg(p[1]), reg(p[2])
                imm = self.resolve(p[3], addr, width=12) if len(p) > 3 else 0
                return (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opcode
            if op in ('lw', 'lh', 'lb', 'lhu', 'lbu'):
                rd = reg(p[1])
                m = re.fullmatch(r'(-?[^\s(]+)\((\w+)\)', p[2])
                if not m:
                    raise ValueError(f'bad load operand: {p[2]}')
                imm = self.resolve(m.group(1), addr, width=12)
                rs1 = reg(m.group(2))
                return (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opcode
            # regular immediate ALU
            rd, rs1 = reg(p[1]), reg(p[2])
            imm = self.resolve(p[3], addr, width=12)
            if op == 'slli':
                imm = (imm & 0x1F)
            elif op == 'srli':
                imm = (imm & 0x1F)
            elif op == 'srai':
                imm = (0x400 | (imm & 0x1F))
            return (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opcode

        def s_type():
            rs2 = reg(p[1])
            m = re.fullmatch(r'(-?[^\s(]+)\((\w+)\)', p[2])
            if not m:
                raise ValueError(f'bad store operand: {p[2]}')
            imm = self.resolve(m.group(1), addr, width=12)
            rs1 = reg(m.group(2))
            f3 = S_F3[op]
            imm &= 0xFFF
            return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | \
                   (f3 << 12) | ((imm & 0x1F) << 7) | 0x23

        def b_type():
            rs1, rs2 = reg(p[1]), reg(p[2])
            imm = self.resolve(p[3], addr, rel=True, width=13)
            f3 = B_F3[op]
            imm &= 0x1FFF
            return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
                   (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
                   (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63

        def u_type():
            rd = reg(p[1])
            # RISC-V LUI/AUIPC take a 20-bit immediate that occupies bits
            # [31:12] of the result. `lui x2, 0x4` therefore yields
            # 0x4000, which is the base of our data memory.
            field = self.resolve(p[2], addr, width=20) & 0xFFFFF
            return (field << 12) | (rd << 7) | (0x37 if op == 'lui' else 0x17)

        def j_type():
            rd = reg(p[1])
            imm = self.resolve(p[2], addr, rel=True, width=21)
            imm &= 0x1FFFFF
            return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
                   (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
                   (rd << 7) | 0x6F

        if op in R_OPS:
            return r_type()
        if op in I_OPS:
            return i_type()
        if op in S_F3:
            return s_type()
        if op in B_F3:
            return b_type()
        if op in ('lui', 'auipc'):
            return u_type()
        if op == 'jal':
            return j_type()
        if op == 'nop':
            return 0x00000013
        if op == 'ecall':
            return 0x00000073
        raise ValueError(f'unknown instruction: {op} ({it.line})')

    def assemble(self):
        words = []
        for it in self.text:
            w = self.encode(it)
            words.append(w & MASK)
        return words, [(a, w) for a, w in self.data], dict(self.labels)


def main():
    if len(sys.argv) < 3:
        print('usage: asm.py <input.s> <outdir>')
        sys.exit(2)
    src, outdir = sys.argv[1], sys.argv[2]
    with open(src, 'r', encoding='utf-8') as f:
        asm = Asm().parse(f.readlines())
    words, data, labels = asm.assemble()

    import os
    os.makedirs(outdir, exist_ok=True)
    # Pad both images to the full 4096-word depth of memory.v. This keeps
    # $readmemh from emitting "Not enough words" warnings on every run and
    # makes the memory model identical across simulators.
    depth = 4096
    with open(os.path.join(outdir, 'prog.hex'), 'w') as f:
        for w in words:
            f.write(f'{w:08x}\n')
        for _ in range(max(0, depth - len(words))):
            f.write('00000013\n')          # NOP
    with open(os.path.join(outdir, 'data.hex'), 'w') as f:
        # data.hex is word-indexed from address 0x4000
        by_addr = {a: w for a, w in data}
        for i in range(depth):
            f.write(f'{by_addr.get(0x4000 + 4 * i, 0):08x}\n')
    with open(os.path.join(outdir, 'symbols.txt'), 'w') as f:
        for k, v in sorted(labels.items(), key=lambda kv: kv[1][1]):
            f.write(f'{k} {v[1]:08x}\n')
    print(f'assembled {len(words)} instructions, {len(data)} data words -> {outdir}')


if __name__ == '__main__':
    main()
