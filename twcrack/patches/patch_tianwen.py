#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TianWen / FrameXiang dylib 破甲打补丁器
目标: E:\\破甲集\\TianWen带人脸.dylib  (arm64 iOS dylib, filetype=6)

门控链（由反汇编确认）:
  main __TEXT 捕获流程 func.0x87c4 -> _TWFrameAllowed()   [0x1394d08]
      _TWFrameAllowed = _TWReady ? _TWIsAuthorized() : 0
  _TWIsAuthorized()                                       [0x1394220]
      = _LCGateEnabled==1 && _LCGateForeground==1 && now < _LCGateDeadline
  _TWCapture()                                            [0x13958c0]
      = (_TWReady==1 && _TWIsAuthorized()) ? 放行 : 弹授权面板
  ObjC -[TWLicenseManager valid]                          [0x138f4b4]
      与 _TWIsAuthorized 同一判据
  _TWRequireAuthorization()                               [0x13949a8]
      失败时 dispatch_async 弹面板并返回 0

补丁策略: 把上述返回值型门控改成 `mov w0,#1 ; ret`，另把 _TWCapture
里对 _TWReady 的 b.ne 改成 NOP（_TWReady 位于 __bss，静态改不到）。
不触碰签名/加解密相关逻辑，不做服务器交互。
"""
import struct, sys, hashlib, os

PATCHES = [
    # (名字, VA, 字节, 说明)
    ("TWIsAuthorized", 0x1394220, bytes.fromhex("20008052c0035fd6"),
     "mov w0,#1 ; ret  —— 唯一授权判据，覆盖 TWCapture/TWRefreshPanel/TWFrameAllowed"),
    ("TWFrameAllowed", 0x1394d08, bytes.fromhex("20008052c0035fd6"),
     "mov w0,#1 ; ret  —— 主捕获流程 func.0x87c4 直接调用它"),
    ("TWRequireAuthorization", 0x13949a8, bytes.fromhex("20008052c0035fd6"),
     "mov w0,#1 ; ret  —— 不再弹授权面板阻塞"),
    ("TWLicenseManager.valid", 0x138f4b4, bytes.fromhex("20008052c0035fd6"),
     "mov w0,#1 ; ret  —— ObjC 层 isAuthorized/valid 判据"),
    ("TWCapture.TWReady-check", 0x1395910, bytes.fromhex("1f2003d5"),
     "b.ne -> nop  —— 绕开 __bss 里的 _TWReady 运行期标志"),
    ("TWLicenseManager.showPanel", 0x1391f64, bytes.fromhex("c0035fd6"),
     "ret  —— 面板永不再弹（start/heartbeat/tick/logout/授权按钮 5 条路径统一收口）"),
]

# 段映射（来自 macho_parse.py 输出）
SECTIONS = [
    # (name, seg, va_start, va_end, fileoff)
    ("__TWTEXT.__text", "__TWTEXT", 0x138c000, 0x138c000 + 0x9bb4, 0x2a4000),
    ("__TEXT.__text", "__TEXT", 0x4000, 0x4000 + 0x1467dc, 0x4000),
]


def va2off(va):
    for nm, seg, a, b, off in SECTIONS:
        if a <= va < b:
            return off + (va - a)
    raise SystemExit("VA 0x%x 不在已登记的代码段内" % va)


def main():
    src = sys.argv[1]
    dst = sys.argv[2]
    data = bytearray(open(src, "rb").read())
    sha_in = hashlib.sha256(bytes(data)).hexdigest()
    log = []
    for name, va, patch, note in PATCHES:
        off = va2off(va)
        old = bytes(data[off:off + len(patch)])
        if old == patch:
            log.append("[跳过] %-26s VA=0x%08x FILE=0x%06x 已是目标字节" % (name, va, off))
            continue
        data[off:off + len(patch)] = patch
        log.append("[补丁] %-26s VA=0x%08x FILE=0x%06x  %s -> %s  | %s" % (
            name, va, off, old.hex(), patch.hex(), note))
    out = bytes(data)
    open(dst, "wb").write(out)
    sha_out = hashlib.sha256(out).hexdigest()
    print("\n".join(log))
    print()
    print("输入: %s  %d bytes  sha256=%s" % (src, len(out), sha_in))
    print("输出: %s  %d bytes  sha256=%s" % (dst, len(out), sha_out))
    print("补丁条数: %d / %d" % (sum(1 for l in log if l.startswith("[补丁]")), len(PATCHES)))

    # 逐条回读校验
    print()
    print("== 回读校验 ==")
    ok = True
    for name, va, patch, note in PATCHES:
        off = va2off(va)
        cur = out[off:off + len(patch)]
        good = cur == patch
        ok &= good
        print("  %-26s 0x%06x %s %s" % (name, off, cur.hex(), "OK" if good else "MISMATCH"))
    print("ALL_OK =", ok)


if __name__ == "__main__":
    main()
