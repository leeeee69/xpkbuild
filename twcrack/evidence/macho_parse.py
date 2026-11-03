#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Minimal Mach-O (64-bit LE) parser: header, load commands, segments, sections,
dylibs, symbol table, ObjC metadata, strings. No external deps."""
import struct, sys, os, json, re

LC = {
    0x1: "LC_SEGMENT", 0x2: "LC_SYMTAB", 0x3: "LC_SYMSEG", 0x4: "LC_THREAD",
    0x5: "LC_UNIXTHREAD", 0x6: "LC_LOADFVMLIB", 0x7: "LC_IDFVMLIB",
    0x8: "LC_IDENT", 0x9: "LC_FVMFILE", 0xa: "LC_PREPAGE", 0xb: "LC_DYSYMTAB",
    0xc: "LC_LOAD_DYLIB", 0xd: "LC_ID_DYLIB", 0xe: "LC_LOAD_DYLINKER",
    0xf: "LC_ID_DYLINKER", 0x10: "LC_PREBOUND_DYLIB", 0x11: "LC_ROUTINES",
    0x12: "LC_SUB_FRAMEWORK", 0x13: "LC_SUB_UMBRELLA", 0x14: "LC_SUB_CLIENT",
    0x15: "LC_SUB_LIBRARY", 0x16: "LC_TWOLEVEL_HINTS", 0x17: "LC_PREBIND_CKSUM",
    0x80000018: "LC_LOAD_WEAK_DYLIB", 0x19: "LC_SEGMENT_64", 0x1a: "LC_ROUTINES_64",
    0x1b: "LC_UUID", 0x8000001c: "LC_RPATH", 0x1d: "LC_CODE_SIGNATURE",
    0x1e: "LC_SEGMENT_SPLIT_INFO", 0x8000001f: "LC_REEXPORT_DYLIB",
    0x20: "LC_LAZY_LOAD_DYLIB", 0x21: "LC_ENCRYPTION_INFO", 0x22: "LC_DYLD_INFO",
    0x80000022: "LC_DYLD_INFO_ONLY", 0x80000023: "LC_LOAD_UPWARD_DYLIB",
    0x24: "LC_VERSION_MIN_MACOSX", 0x25: "LC_VERSION_MIN_IPHONEOS",
    0x26: "LC_FUNCTION_STARTS", 0x27: "LC_DYLD_ENVIRONMENT",
    0x28: "LC_MAIN", 0x29: "LC_DATA_IN_CODE", 0x2a: "LC_SOURCE_VERSION",
    0x2b: "LC_DYLIB_CODE_SIGN_DRS", 0x2c: "LC_ENCRYPTION_INFO_64",
    0x2d: "LC_LINKER_OPTION", 0x2e: "LC_LINKER_OPTIMIZATION_HINT",
    0x2f: "LC_VERSION_MIN_TVOS", 0x30: "LC_VERSION_MIN_WATCHOS",
    0x31: "LC_NOTE", 0x32: "LC_BUILD_VERSION", 0x33: "LC_DYLD_EXPORTS_TRIE",
    0x34: "LC_DYLD_CHAINED_FIXUPS", 0x80000034: "LC_FILESET_ENTRY",
}

CPU = {0x0100000c: "arm64", 0x01000007: "x86_64"}

class MachO:
    def __init__(self, path):
        self.path = path
        self.data = open(path, "rb").read()
        d = self.data
        magic = struct.unpack_from("<I", d, 0)[0]
        assert magic == 0xFEEDFACF, hex(magic)
        (self.cputype, self.cpusubtype, self.filetype, self.ncmds,
         self.sizeofcmds, self.flags, self.reserved) = struct.unpack_from("<iiIIIII", d, 4)
        self.header_size = 32
        self.cmds = []
        self.segments = []
        self.sections = []
        self.dylibs = []
        self.rpaths = []
        off = 32
        for _ in range(self.ncmds):
            cmd, size = struct.unpack_from("<II", d, off)
            body = d[off:off + size]
            name = LC.get(cmd, "LC_0x%x" % cmd)
            ent = {"cmd": cmd, "name": name, "size": size, "off": off, "raw": body}
            self.cmds.append(ent)
            if cmd == 0x19:  # SEGMENT_64
                segname = body[8:24].split(b"\0")[0].decode("utf-8", "replace")
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", body, 24)
                maxprot, initprot, nsects, segflags = struct.unpack_from("<IIII", body, 56)
                seg = dict(name=segname, vmaddr=vmaddr, vmsize=vmsize, fileoff=fileoff,
                           filesize=filesize, maxprot=maxprot, initprot=initprot,
                           nsects=nsects, flags=segflags, sects=[])
                so = 64 + 8
                for i in range(nsects):
                    s = body[72 + i * 80: 72 + (i + 1) * 80]
                    sectname = s[0:16].split(b"\0")[0].decode("utf-8", "replace")
                    sseg = s[16:32].split(b"\0")[0].decode("utf-8", "replace")
                    addr, ssize = struct.unpack_from("<QQ", s, 32)
                    offset, align, reloff, nreloc, sflags = struct.unpack_from("<IIIII", s, 48)
                    sec = dict(sectname=sectname, segname=sseg, addr=addr, size=ssize,
                               offset=offset, align=align, reloff=reloff, nreloc=nreloc,
                               flags=sflags)
                    seg["sects"].append(sec)
                    self.sections.append(sec)
                self.segments.append(seg)
            elif cmd in (0xc, 0xd, 0x80000018, 0x8000001f, 0x20, 0x80000023):
                noff = struct.unpack_from("<I", body, 8)[0]
                nm = body[noff:].split(b"\0")[0].decode("utf-8", "replace")
                self.dylibs.append((name, nm, unix_ts(body, 16)))
            elif cmd == 0x8000001c:
                noff = struct.unpack_from("<I", body, 8)[0]
                self.rpaths.append(body[noff:].split(b"\0")[0].decode("utf-8", "replace"))
            off += size
        self.cmd_end = 32 + self.sizeofcmds

    def seg(self, name):
        for s in self.segments:
            if s["name"] == name:
                return s
        return None

    def sect(self, secname, segname=None):
        for s in self.sections:
            if s["sectname"] == secname and (segname is None or s["segname"] == segname):
                return s
        return None

    def va2off(self, va):
        for s in self.segments:
            if s["vmaddr"] <= va < s["vmaddr"] + s["vmsize"] and s["filesize"]:
                if va - s["vmaddr"] < s["filesize"]:
                    return s["fileoff"] + (va - s["vmaddr"])
        return None

    def off2va(self, o):
        for s in self.segments:
            if s["fileoff"] <= o < s["fileoff"] + s["filesize"]:
                return s["vmaddr"] + (o - s["fileoff"])
        return None

    def symbols(self):
        symtab = None
        dysym = None
        for c in self.cmds:
            if c["name"] == "LC_SYMTAB":
                symtab = struct.unpack_from("<IIII", c["raw"], 8)
            elif c["name"] == "LC_DYSYMTAB":
                dysym = struct.unpack_from("<" + "I" * 18, c["raw"], 8)
        out = []
        if not symtab:
            return out
        symoff, nsyms, stroff, strsize = symtab
        strtab = self.data[stroff:stroff + strsize]
        for i in range(nsyms):
            strx, ntype, nsect, ndesc, nvalue = struct.unpack_from("<IBBHQ", self.data, symoff + i * 16)
            end = strtab.find(b"\0", strx)
            nm = strtab[strx:end].decode("utf-8", "replace") if strx < len(strtab) else ""
            out.append(dict(name=nm, type=ntype, sect=nsect, desc=ndesc, value=nvalue))
        return out

    def cstr(self, va):
        o = self.va2off(va)
        if o is None:
            return None
        e = self.data.find(b"\0", o)
        return self.data[o:e].decode("utf-8", "replace")


def unix_ts(b, off):
    return struct.unpack_from("<I", b, off)[0] if len(b) >= off + 4 else 0


def main():
    path = sys.argv[1]
    m = MachO(path)
    print("== HEADER ==")
    print("path      :", path)
    print("cputype   : 0x%x (%s)" % (m.cputype, CPU.get(m.cputype, "?")))
    print("filetype  : %d (6=dylib,2=exe,8=bundle)" % m.filetype)
    print("ncmds     :", m.ncmds, " sizeofcmds:", m.sizeofcmds)
    print("flags     : 0x%x" % m.flags)
    print()
    print("== LOAD COMMANDS ==")
    for c in m.cmds:
        print("  %-24s size=%d" % (c["name"], c["size"]))
    print()
    print("== SEGMENTS / SECTIONS ==")
    for s in m.segments:
        print("  %-16s vmaddr=0x%x vmsize=0x%-8x fileoff=0x%-8x filesize=0x%-8x prot=%d/%d" %
              (s["name"], s["vmaddr"], s["vmsize"], s["fileoff"], s["filesize"], s["initprot"], s["maxprot"]))
        for sec in s["sects"]:
            print("      %-18s %-16s addr=0x%-9x size=0x%-8x off=0x%-8x" %
                  (sec["sectname"], sec["segname"], sec["addr"], sec["size"], sec["offset"]))
    print()
    print("== DYLIB DEPENDENCIES ==")
    for kind, nm, ts in m.dylibs:
        print("  %-22s %s" % (kind, nm))
    print()
    print("== RPATHS ==")
    for r in m.rpaths:
        print("  ", r)
    print()
    syms = m.symbols()
    print("== SYMTAB: %d symbols ==" % len(syms))
    defined = [s for s in syms if s["value"] and s["type"] & 0x0E != 0x0]
    undef = [s for s in syms if not (s["type"] & 0x01)]
    print("defined=%d undefined=%d" % (len(defined), len(undef)))
    outdir = os.path.dirname(os.path.abspath(path))
    with open(os.path.join(outdir, "symbols.txt"), "w", encoding="utf-8") as f:
        for s in syms:
            f.write("%016x t=%02x s=%02x d=%04x %s\n" % (s["value"], s["type"], s["sect"], s["desc"], s["name"]))
    print("wrote symbols.txt")

    # dump strings from __TEXT,__cstring and __objc_methname etc.
    with open(os.path.join(outdir, "strings_dump.txt"), "w", encoding="utf-8", errors="replace") as f:
        for sec in m.sections:
            if sec["sectname"] in ("__cstring", "__objc_methname", "__objc_classname", "__objc_methtype", "__const"):
                blob = m.data[sec["offset"]:sec["offset"] + sec["size"]]
                for sm in re.finditer(rb"[\x20-\x7e\xc2-\xf4][\x20-\x7e\x80-\xff]{3,}", blob):
                    try:
                        t = sm.group().decode("utf-8")
                    except Exception:
                        continue
                    if len(t) >= 5:
                        f.write("%-20s 0x%x %s\n" % (sec["sectname"], sec["addr"] + sm.start(), t))
    print("wrote strings_dump.txt")

    # objc classes
    cl = m.sect("__objc_classlist")
    cls = []
    if cl:
        n = cl["size"] // 8
        for i in range(n):
            va = struct.unpack_from("<Q", m.data, cl["offset"] + i * 8)[0]
            # class_t: isa, superclass, cache, vtable, data(bits)
            o = m.va2off(va)
            if o is None:
                continue
            try:
                isa, sup, cache, vt, bits = struct.unpack_from("<QQQQQ", m.data, o)
            except Exception:
                continue
            data_va = bits & 0x00007FFFFFFFFFF8
            do = m.va2off(data_va)
            nm = None
            if do is not None:
                rodata = struct.unpack_from("<I", m.data, do + 4)[0]
                name_va = struct.unpack_from("<Q", m.data, do + 8)[0]
                # in newer runtimes name is a relative field... try absolute first
                nm = m.cstr(name_va)
                if nm is None:
                    rel = struct.unpack_from("<i", m.data, do + 8)[0]
                    nm = m.cstr(do + 8 + rel) if True else None
            cls.append((va, nm))
    print()
    print("== OBJC CLASSES: %d ==" % len(cls))
    for va, nm in cls:
        print("   0x%x %s" % (va, nm))

    with open(os.path.join(outdir, "layout.json"), "w", encoding="utf-8") as f:
        json.dump(dict(
            path=path, cputype=m.cputype, filetype=m.filetype,
            segments=[dict(name=s["name"], vmaddr=s["vmaddr"], vmsize=s["vmsize"],
                           fileoff=s["fileoff"], filesize=s["filesize"],
                           sects=[{k: v for k, v in sec.items()} for sec in s["sects"]])
                      for s in m.segments],
            dylibs=[d[1] for d in m.dylibs], rpaths=m.rpaths,
            objc_classes=[{"addr": va, "name": nm} for va, nm in cls],
        ), f, ensure_ascii=False, indent=1)
    print("wrote layout.json")


if __name__ == "__main__":
    main()
