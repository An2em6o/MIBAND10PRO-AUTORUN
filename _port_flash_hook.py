# -*- coding: utf-8 -*-
"""
把 Shell++ II main.lua 里的 32KB 内置原块(ORIG_HEX)原样搬进 chaos_installer.lua 的占位符,
并在搬的过程中**独立复算**一遍载荷与四个常量 —— 搬运不许改一个字节, 复算用来证明搬对了。

一次性脚本: 占位符只存在一次, 重复跑会被断言咬住。
"""
import hashlib
import os
import re
import sys

SRC = r"C:\zcode\shellpp2-autostart\Shellpp-II-Autostart-Lua\_Lua\main.lua"
DST = r"C:\zcode\chaos-autostart\Chaos-Module\installer\chaos_installer.lua"
PLACEHOLDER = "-- @@ORIG_HEX_BODY@@"

BS = 32768
P_SIZE, P_CK = 332, 0x8D9C53E2
HEAD_END, BODY_END, WIN_OFF, WIN_LEN = 0x64EC, 0x6654, 0x6642, 18
ORIG_ADLER, PAY_ADLER = "40877019", "1E4A726D"
ORIG_MD5, PAY_MD5 = "ca1175d73b726589c9cdc077f8bbb857", "0b66f9c1efabc4173d3785904ff1516c"
HOOK = b"sh /data/rc &"


def adler32(data):
    a, b = 1, 0
    for c in data:
        a = (a + c) % 65521
        b = (b + a) % 65521
    return "%08X" % ((b << 16) | a)


def extract_hex(text):
    m = re.search(r"local ORIG_HEX = \(\[\[(.*?)\]\]\):gsub", text, re.S)
    assert m, "main.lua 里没找到 ORIG_HEX 长字符串"
    return re.sub(r"\s+", "", m.group(1))


def wrap(hexstr, width=100):
    return "\n".join(hexstr[i:i + width] for i in range(0, len(hexstr), width))


def main():
    src = open(SRC, "rb").read().decode("utf-8")
    hexstr = extract_hex(src)
    print("ORIG_HEX: %d 个 hex 字符 = %d B" % (len(hexstr), len(hexstr) // 2))
    assert len(hexstr) == BS * 2, "长度不符: %d" % len(hexstr)
    assert re.fullmatch(r"[0-9a-f]+", hexstr), "混进了非 hex 字符"

    orig = bytes.fromhex(hexstr)
    assert len(orig) == BS
    assert adler32(orig) == ORIG_ADLER, "adler(ORIG)=%s" % adler32(orig)
    assert hashlib.md5(orig).hexdigest() == ORIG_MD5, "md5(ORIG) 不符"
    # 注意: main.lua 里写的是 Lua 的 string.sub(0xE85, 0xE8C), 那是 1-based 闭区间,
    # 等价于 Python 的 0-based 半开区间 [0xE84, 0xE8C)。差 1 就会"门永远不过"。
    assert orig[0xE84:0xE8C] == b"-rom1fs-", "romfs 超级块门"
    # 同上: Lua sub(0x64F5, 0x64F7) -> Python [0x64F4, 0x64F7)。
    assert orig[0x64F4:0x64F7] == b"rcS", "rcS inode 门"

    hookb = HOOK + b"\n"
    hookb = hookb[:WIN_LEN]
    hpad = hookb + b"\x00" * (WIN_LEN - len(hookb))
    pay = (orig[:HEAD_END]
           + P_SIZE.to_bytes(4, "big") + P_CK.to_bytes(4, "big")
           + orig[0x64F4:WIN_OFF]
           + hpad
           + orig[WIN_OFF + WIN_LEN:])
    assert len(pay) == BS
    assert adler32(pay) == PAY_ADLER, "adler(PAY)=%s" % adler32(pay)
    assert hashlib.md5(pay).hexdigest() == PAY_MD5, "md5(PAY) 不符"
    assert pay[WIN_OFF:WIN_OFF + WIN_LEN] == b"sh /data/rc &\n" + b"\x00" * 4
    print("PAY: %d B  adler=%s(OK)  md5=%s(OK)" % (len(pay), adler32(pay), PAY_MD5))
    print("两处门: romfs 超级块 OK / rcS inode OK")

    dst = open(DST, "rb").read().decode("utf-8")
    assert dst.count(PLACEHOLDER) == 1, "占位符出现 %d 次(应恰好 1)" % dst.count(PLACEHOLDER)
    new = dst.replace(PLACEHOLDER, wrap(hexstr))
    assert "@@" not in new, "还有没替换的占位符"
    # 注入的串是按 100 列换行的, 所以只能"重新抽出来 + 去空白"再比 —— 直接 find 长串必然找不到。
    m2 = re.search(r"local ORIG_HEX = \(\[\[(.*?)\]\]\):gsub", new, re.S)
    assert m2, "注入后找不到 ORIG_HEX 长字符串"
    assert re.sub(r"\s+", "", m2.group(1)) == hexstr, "注入后的串与源不一致"
    open(DST, "wb").write(new.encode("utf-8"))
    print("INJECT: %d B -> %d B" % (len(dst.encode("utf-8")), len(new.encode("utf-8"))))
    print("PORT-FLASH-HOOK: OK")


if __name__ == "__main__":
    sys.exit(main())
