#!/usr/bin/env python3
"""Tiny two-pass RV32I(+MUL) assembler for Aurora firmware.

Supports exactly what fw/ needs -- not a general assembler:
  labels, .word, li/la (32-bit constants), mv, j, nop, ret,
  lui auipc jal jalr, beq bne blt bge bltu bgeu,
  lw sw lb lbu lh lhu sb sh,
  addi andi ori xori slti sltiu slli srli srai,
  add sub and or xor sll srl sra slt sltu mul mulh mulhu

Usage: rvasm.py in.S out.hex     (one 32-bit word per line, $readmemh format)
"""
import re
import sys

REGS = {"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
        "fp": 8}
for _i in range(8):  REGS["t%d" % _i] = [5, 6, 7, 28, 29, 30, 31, 0][_i] if _i < 7 else 0
REGS.update({"t0": 5, "t1": 6, "t2": 7, "t3": 28, "t4": 29, "t5": 30, "t6": 31})
REGS.update({"s0": 8, "s1": 9})
for _i in range(2, 12): REGS["s%d" % _i] = 16 + _i
for _i in range(8):     REGS["a%d" % _i] = 10 + _i
for _i in range(32):    REGS["x%d" % _i] = _i


def reg(t):
    t = t.strip()
    if t not in REGS:
        raise SystemExit("unknown register %r" % t)
    return REGS[t]


def num(t, labels):
    t = t.strip()
    if t in labels:
        return labels[t]
    return int(t, 0)


def enc_r(f7, rs2, rs1, f3, rd, opc):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc


def enc_i(imm, rs1, f3, rd, opc):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc


def enc_s(imm, rs2, rs1, f3, opc):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | ((imm & 0x1F) << 7) | opc


def enc_b(imm, rs2, rs1, f3):
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | \
           (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def enc_u(imm, rd, opc):
    return (imm & 0xFFFFF000) | (rd << 7) | opc


def enc_j(imm, rd):
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | \
           (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) | \
           (rd << 7) | 0x6F


BR = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}
LD = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
ST = {"sb": 0, "sh": 1, "sw": 2}
IMM = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
RR = {"add": (0, 0), "sub": (0x20, 0), "sll": (0, 1), "slt": (0, 2),
      "sltu": (0, 3), "xor": (0, 4), "srl": (0, 5), "sra": (0x20, 5),
      "or": (0, 6), "and": (0, 7),
      "mul": (1, 0), "mulh": (1, 1), "mulhu": (1, 3)}
MEM_RE = re.compile(r"^(-?\w+)\((\w+)\)$")


def expand(line):
    """Pseudo-instructions -> base instructions (may yield 1 or 2)."""
    p = [x.strip() for x in re.split(r"[,\s]+", line.strip()) if x.strip()]
    op = p[0]
    if op in ("li", "la"):
        return [("_li32", p[1], p[2])]
    if op == "mv":
        return [("addi", p[1], p[2], "0")]
    if op == "j":
        return [("jal", "zero", p[1])]
    if op == "nop":
        return [("addi", "zero", "zero", "0")]
    if op == "ret":
        return [("jalr", "zero", "ra", "0")]
    return [tuple(p)]


def assemble(src):
    # pass 0: strip, expand, place labels (li/la always 2 words: lui+addi)
    items, labels, pc = [], {}, 0
    for raw in src.splitlines():
        line = raw.split("#")[0].strip()
        if not line:
            continue
        while ":" in line.split()[0] if line else False:
            lbl, line = line.split(":", 1)
            labels[lbl.strip()] = pc
            line = line.strip()
            if not line:
                break
        if not line:
            continue
        if line.startswith(".word"):
            for w in re.split(r"[,\s]+", line[5:].strip()):
                if w:
                    items.append((".word", w, pc)); pc += 4
            continue
        for it in expand(line):
            items.append(it + (pc,))
            pc += 8 if it[0] == "_li32" else 4
    # pass 1: encode
    out = []
    for it in items:
        op, pc = it[0], it[-1]
        p = it[1:-1]
        if op == ".word":
            out.append(num(p[0], labels) & 0xFFFFFFFF)
        elif op == "_li32":
            v = num(p[1], labels) & 0xFFFFFFFF
            hi = (v + 0x800) & 0xFFFFF000
            lo = (v - hi) & 0xFFFFFFFF
            out.append(enc_u(hi, reg(p[0]), 0x37))                    # lui
            out.append(enc_i(lo & 0xFFF, reg(p[0]), 0, reg(p[0]), 0x13))
        elif op == "lui":
            out.append(enc_u(num(p[1], labels) << 12, reg(p[0]), 0x37))
        elif op == "auipc":
            out.append(enc_u(num(p[1], labels) << 12, reg(p[0]), 0x17))
        elif op == "jal":
            out.append(enc_j(num(p[1], labels) - pc, reg(p[0])))
        elif op == "jalr":
            out.append(enc_i(num(p[2], labels), reg(p[1]), 0, reg(p[0]), 0x67))
        elif op in BR:
            out.append(enc_b(num(p[2], labels) - pc, reg(p[1]), reg(p[0]), BR[op]))
        elif op in LD:
            m = MEM_RE.match(p[1])
            out.append(enc_i(num(m.group(1), labels), reg(m.group(2)),
                             LD[op], reg(p[0]), 0x03))
        elif op in ST:
            m = MEM_RE.match(p[1])
            out.append(enc_s(num(m.group(1), labels), reg(p[0]),
                             reg(m.group(2)), ST[op], 0x23))
        elif op in IMM:
            out.append(enc_i(num(p[2], labels), reg(p[1]), IMM[op],
                             reg(p[0]), 0x13))
        elif op in ("slli", "srli", "srai"):
            f7 = 0x20 if op == "srai" else 0
            f3 = 1 if op == "slli" else 5
            out.append(enc_r(f7, num(p[2], labels), reg(p[1]), f3,
                             reg(p[0]), 0x13))
        elif op in RR:
            f7, f3 = RR[op]
            out.append(enc_r(f7, reg(p[2]), reg(p[1]), f3, reg(p[0]), 0x33))
        else:
            raise SystemExit("unknown instruction %r" % (it,))
    return out


if __name__ == "__main__":
    words = assemble(open(sys.argv[1]).read())
    with open(sys.argv[2], "w") as f:
        for w in words:
            f.write("%08x\n" % w)
    print("assembled %d words" % len(words))
