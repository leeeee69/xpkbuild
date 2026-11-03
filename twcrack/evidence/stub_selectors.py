#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""枚举 __objc_stubs 里每个 stub 对应的 selector 名，用于定位「所有 Objective-C
消息出口」（例如 dataTaskWithRequest: 系列），比按字符串 axt 更可靠。"""
import struct, sys

STUB_VA, STUB_SIZE = 0x14BBC0, 0x7DA0
SEGS = [(0x0, 0x264000, 0x0), (0x264000, 0x2c000, 0x264000), (0x290000, 0x10000, 0x290000),
        (0x1388000, 0x34000, 0x2A0000), (0x13BC000, 0x4000, 0x2D4000),
        (0x13C0000, 0x4000, 0x2D8000), (0x13C4000, 0x1C970, 0x2DC000)]


def va2off(va):
    for a, sz, off in SEGS:
        if a <= va < a + sz:
            return off + (va - a)
    return None


def cstr(d, va):
    o = va2off(va)
    if o is None:
        return "<unmapped>"
    e = d.find(b"\x00", o)
    return d[o:e].decode("utf-8", "replace")


def main():
    path = sys.argv[1]
    d = open(path, "rb").read()
    out = []
    va = STUB_VA
    end = STUB_VA + STUB_SIZE
    while va < end:
        o = va2off(va)
        insn0, insn1, insn2 = struct.unpack_from("<III", d, o)
        # adrp x1, page
        if (insn0 & 0x9F000001) != 0x90000001:
            va += 4
            continue
        immlo = (insn0 >> 29) & 3
        immhi = (insn0 >> 5) & 0x7FFFF
        imm = ((immhi << 2) | immlo)
        if imm & (1 << 20):
            imm -= 1 << 21
        page = (va & ~0xFFF) + (imm << 12)
        # ldr x1, [x1, #imm12*8]
        if (insn1 & 0xFFC00001) != 0xF9400001:
            va += 4
            continue
        off12 = ((insn1 >> 10) & 0xFFF) * 8
        selref_va = page + off12
        so = va2off(selref_va)
        if so is None:
            va += 4
            continue
        raw = struct.unpack_from("<Q", d, so)[0]
        ptr = raw & 0xFFFFFFFFFFFF
        name = cstr(d, ptr)
        out.append((va, selref_va, name))
        va += 4
    for stub_va, selref_va, name in out:
        print("stub=0x%06x selref=0x%08x  %s" % (stub_va, selref_va, name))
    print("total=%d" % len(out))


if __name__ == "__main__":
    main()
