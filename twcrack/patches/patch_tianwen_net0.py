#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TianWen / FrameXiang dylib —— 破甲 + 禁网（net0）补丁器

两项独立目标：
  A. 破甲：授权判据恒真（与 patch_tianwen.py 相同 6 处）
  B. 禁网：除 RTMP 推流外，禁止本 dylib 发出任何 HTTP(S) 请求

禁网依据（静态穷举，见报告 §9）：
  全二进制只有 4 个 NSURLSession 创建/使用点，覆盖全部 HTTP 出口：
   1) -[TWLicenseManager request:body:kind:completion:]        0x138d844  （授权，唯一 dataTask 调用点）
   2) +[FXCommerceRequest fetch:limit:completion:]             0x12eb20   （卡包/支付）
   3) +[FXUpdateTransfer start:release:progress:completion:]   0x1327d0   （更新下载）
   4) func.0x881c 插件授权客户端（dispatch queue 名 app.framexiang.plugin-auth）
      在 0x8924 用 [NSURLSession sessionWithConfiguration:] 建 session，存 [x19+0x88]
  RTMP 走 ffmpeg 内置 libavformat/rtmppkt.c（socket/connect/getaddrinfo），
  不经过 NSURLSession，因此上面 4 处封死不影响推流。

字符串黑洞（第二道保险）：把两个厂商 base URL 改指 127.0.0.1:9，
即使有未识别的拼接路径，连接也不会离开本机。
"""
import hashlib, sys

CODE_PATCHES = [
    # ---------- A. 破甲（6 处） ----------
    ("A1 TWIsAuthorized", 0x1394220, bytes.fromhex("20008052c0035fd6"),
     "mov w0,#1; ret —— C 层唯一授权判据"),
    ("A2 TWFrameAllowed", 0x1394d08, bytes.fromhex("20008052c0035fd6"),
     "mov w0,#1; ret —— 主捕获入口"),
    ("A3 TWRequireAuthorization", 0x13949a8, bytes.fromhex("20008052c0035fd6"),
     "mov w0,#1; ret —— 死代码，防御性置真"),
    ("A4 valid", 0x138f4b4, bytes.fromhex("20008052c0035fd6"),
     "mov w0,#1; ret —— 主机回调拿的就是它"),
    ("A5 TWCapture.TWReady", 0x1395910, bytes.fromhex("1f2003d5"),
     "b.ne -> nop —— 绕开 _TWReady 运行期标志"),
    ("A6 showPanel", 0x1391f64, bytes.fromhex("c0035fd6"),
     "ret —— 面板永不再弹"),

    # ---------- B. 禁网（4 处代码 + 2 处字符串） ----------
    ("B1 TWLicenseManager.request", 0x138D844, bytes.fromhex("c0035fd6"),
     "ret —— 授权请求直接返回，不再建 dataTask"),
    ("B2 FXCommerceRequest.fetch", 0x12EB20, bytes.fromhex("000080d2c0035fd6"),
     "mov x0,#0; ret —— 支付/卡包请求返回 nil"),
    ("B3 FXUpdateTransfer.start", 0x1327D0, bytes.fromhex("000080d2c0035fd6"),
     "mov x0,#0; ret —— 更新下载返回 nil"),
    ("B4 plugin-auth session", 0x8924, bytes.fromhex("000080d2"),
     "bl sessionWithConfiguration: -> mov x0,#0 —— 插件授权客户端拿不到 session"),
]

# 字符串黑洞：VA, 新内容（不足原长补 \0，超出则报错）
STRING_PATCHES = [
    ("B5 base(tianwen)", 0x1395F5B, "https://127.0.0.1:9"),
    ("B6 base(ybdskj)", 0x156478, "https://127.0.0.1:9"),
]

SECTIONS = [
    # (name, start, end, fileoff)
    ("__TEXT.__text", 0x4000, 0x4000 + 0x1467DC, 0x4000),
    ("__TWTEXT.__text", 0x138C000, 0x138C000 + 0x9BB4, 0x2A4000),
    ("__TEXT.__cstring", 0x155B94, 0x155B94 + 0x1AD3F, 0x155B94),
    ("__TWTEXT.__cstring", 0x1395DE8, 0x1395DE8 + 0x20FE7, 0x2ADDE8),
]


def va2off(va):
    for nm, a, b, off in SECTIONS:
        if a <= va < b:
            return off + (va - a)
    raise SystemExit("VA 0x%x 不在已登记节内" % va)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, "rb").read())
    sha_in = hashlib.sha256(bytes(data)).hexdigest()
    log = []

    for name, va, patch, note in CODE_PATCHES:
        off = va2off(va)
        old = bytes(data[off:off + len(patch)])
        tag = "skip" if old == patch else "PATCH"
        if tag == "PATCH":
            data[off:off + len(patch)] = patch
        log.append("[%s] %-28s VA=0x%08x FILE=0x%06x  %s -> %s | %s" %
                   (tag, name, va, off, old.hex(), patch.hex(), note))

    for name, va, new in STRING_PATCHES:
        off = va2off(va)
        end = data.find(b"\x00", off)
        old = bytes(data[off:end])
        nb = new.encode()
        if len(nb) > len(old):
            raise SystemExit("%s 新串 %d > 原串 %d" % (name, len(nb), len(old)))
        data[off:off + len(old)] = nb + b"\x00" * (len(old) - len(nb))
        log.append("[PATCH] %-28s VA=0x%08x FILE=0x%06x  \"%s\" -> \"%s\"(补\\0 %d)" %
                   (name, va, off, old.decode("utf-8", "replace"), new, len(old) - len(nb)))

    out = bytes(data)
    open(dst, "wb").write(out)
    print("\n".join(log))
    print()
    print("输入: %s  %d bytes  sha256=%s" % (src, len(out), sha_in))
    print("输出: %s  %d bytes  sha256=%s" % (dst, len(out), hashlib.sha256(out).hexdigest()))
    print("代码补丁 %d 条 / 字符串补丁 %d 条" % (len(CODE_PATCHES), len(STRING_PATCHES)))
    print()
    print("== 回读校验 ==")
    ok = True
    for name, va, patch in [(p[0], p[1], p[2]) for p in CODE_PATCHES]:
        off = va2off(va)
        cur = out[off:off + len(patch)]
        good = cur == patch
        ok &= good
        print("  %-28s 0x%06x %s %s" % (name, off, cur.hex(), "OK" if good else "MISMATCH"))
    for name, va, new in STRING_PATCHES:
        off = va2off(va)
        end = out.find(b"\x00", off)
        cur = out[off:end].decode("utf-8", "replace")
        good = cur == new
        ok &= good
        print("  %-28s 0x%06x \"%s\" %s" % (name, off, cur, "OK" if good else "MISMATCH"))
    print("ALL_OK =", ok)


if __name__ == "__main__":
    main()
