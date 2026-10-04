# -*- coding: utf-8 -*-
"""把旧版 chaos 安装器里那块**已上机验证过**的 flash 代码, 逐字节搬进管理器 dotui.lua。

为什么要"搬"而不是"重写":
  这是**唯一能刷砖设备的能力**（改 AP 分区 rcS 那个 inode 的 size/checksum + 末行窗口）。
  重写一遍 = 在唯一会砖的地方引入全新的字节。搬则一个字节都不动, 而且可以证明:
    md5(抽出来的) == md5(源里的)          —— 见下面第 ③ 段
    adler32(原块/载荷) == 源里写死的常量   —— 独立复算, 不信"搬运工嘴里说的"
    romfs 超级块 / rcS inode 两处门

抽哪四段（SRC 行号 1-based, 闭区间）:
  S1  常量段      FLASH_FIRMWARE_CODE / FLASH_BS / FLASH_TEMP / HOOK / P_SIZE / P_CK /
                  HEAD_END / BODY_END / WIN_OFF / WIN_LEN / ORIG_ADLER / PAY_ADLER /
                  FW_VERSION_* / FLASH_CAND
  S2  内置原块    local ORIG_HEX = ([[ … 65,536 个 hex 字符 … ]]):gsub("%s+", "")
  S3  载荷推导    NUL / ORIG / be4() / HOOKB / HPAD / PAY   （PAY 由 ORIG 确定性推出来）
  S4  读/判/写    flash_adler … flash_fw_code / flash_gate / flash_probe /
                  hook_install / hook_restore

**不抽**（管理器里另有实现、或本就不该进来）: set_status / 视图与按钮 /
  autostart_* 那一套 / as_armed / 二跳 / SUPERVISOR_PATH 等。

★ derive() 是**对外复用**的: 仿真门 _sim_manager.py import 它来造"假 flash 里的那个块"。
  推导规则只写这一份 —— 两份实现只会落得"改一处忘一处"。

用法:
  python _port_flash_to_manager.py           # 有占位符就注入, 没有就只校验
  python _port_flash_to_manager.py --show    # 额外打印每段的 md5 与字节数
"""
import hashlib
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

SRC = os.path.join(ROOT, "patches", "chaos_installer.patched-v2-flash.lua")
DST = os.path.join(ROOT, "manager", "app", "_lua", "_Lua", "dotui.lua")
PLACEHOLDER = "-- @@FLASH_BLOCK@@"

# 段名 / 起行 / 止行（1-based, 闭区间）
SEGMENTS = [
    ("S1 常量段",        108, 126),
    ("S2 内置原块",      128, 787),
    ("S3 载荷推导",      788, 804),
    ("S4 读判写+四道门", 1081, 1278),
]

# 源里写死的认证常量（★ 只用来**交叉核对**抽出来的东西, 不作为唯一真源）
ORIG_ADLER_EXPECT = "40877019"
PAY_ADLER_EXPECT = "1E4A726D"
HOOK_EXPECT = "sh /data/rc &"

FAILS = []
NCHK = [0]


def check(cond, label, extra=""):
    NCHK[0] += 1
    if cond:
        print("  ok   %s" % label)
    else:
        print("  FAIL %s  %s" % (label, extra))
        FAILS.append(label)
    return bool(cond)


def md5b(b):
    return hashlib.md5(b).hexdigest()


def adler32(data):
    a, b = 1, 0
    for c in data:
        a = (a + c) % 65521
        b = (b + a) % 65521
    return "%08X" % ((b << 16) | a)


def read_text(path):
    raw = io.open(path, "rb").read()
    has_crlf = b"\r\n" in raw
    txt = raw.decode("utf-8").replace("\r\n", "\n")
    return txt, has_crlf


def source_block():
    """把四段按固定顺序拼成一整块（\\n\\n 分隔）。"""
    src, _ = read_text(SRC)
    lines = src.split("\n")
    return "\n\n".join("\n".join(lines[a - 1:b]) for _n, a, b in SEGMENTS)


def derive(block):
    """从抽出来的那段 Lua 文本里把常量与 32KB 原块/载荷**算**出来。
    ★ 仿真门也 import 这个函数来造"假 flash 里那个块"的初值 —— 推导只写一份。"""
    def g(pat, base=10):
        m = re.search(pat, block)
        return int(m.group(1), base) if m else None

    d = {"BS": g(r"local FLASH_BS\s*=\s*(\d+)"),
         "P_SIZE": g(r"local P_SIZE\s*=\s*(\d+)"),
         "P_CK": g(r"local P_CK\s*=\s*0x([0-9A-Fa-f]+)", 16),
         "HEAD_END": g(r"local HEAD_END\s*=\s*0x([0-9A-Fa-f]+)", 16),
         "BODY_END": g(r"local BODY_END\s*=\s*0x([0-9A-Fa-f]+)", 16),
         "WIN_OFF": g(r"local WIN_OFF\s*=\s*0x([0-9A-Fa-f]+)", 16),
         "WIN_LEN": g(r"local WIN_LEN\s*=\s*(\d+)")}
    m = re.search(r'local HOOK\s*=\s*"([^"]*)"', block)
    d["HOOK"] = m.group(1) if m else None
    m = re.search(r"local ORIG_HEX = \(\[\[(.*?)\]\]\):gsub", block, re.S)
    d["HEX"] = re.sub(r"\s+", "", m.group(1)) if m else None
    # FLASH_CAND: 三个候选 (dev, byteoff)
    d["CAND"] = [(dev, int(off), name) for dev, off, name in re.findall(
        r'\{\s*dev\s*=\s*"([^"]+)"\s*,\s*off\s*=\s*(\d+)\s*,\s*name\s*=\s*"([^"]+)"\s*\}',
        block)]
    # 仿真门要按 FLASH_TEMP 摆假设备 —— 它是 DATA_DIR .. "/apblk.bin"，而 DATA_DIR
    # 在管理器里是 /data/chaos（dotui.lua 的路径段），这里只把**文件名**抽出来。
    d["FLASH_TEMP_NAME"] = (re.search(r'local FLASH_TEMP\s*=\s*DATA_DIR\s*\.\.\s*"([^"]+)"',
                                      block) or [None, None])[1]
    if any(v is None for v in d.values()):
        return d
    d["ORIG"] = bytes.fromhex(d["HEX"])
    hookb = ((d["HOOK"] + "\n").encode("ascii"))[:d["WIN_LEN"]]
    d["HPAD"] = hookb + b"\x00" * (d["WIN_LEN"] - len(hookb))
    d["PAY"] = (d["ORIG"][:d["HEAD_END"]]
                + d["P_SIZE"].to_bytes(4, "big") + d["P_CK"].to_bytes(4, "big")
                + d["ORIG"][0x64F4:d["WIN_OFF"]]
                + d["HPAD"]
                + d["ORIG"][d["WIN_OFF"] + d["WIN_LEN"]:])
    return d


def main():
    show = "--show" in sys.argv

    src, src_crlf = read_text(SRC)
    check(not src_crlf, "源文件是 LF（CRLF 会让逐字节比对变成假失败）")
    lines = src.split("\n")

    seg_texts = []
    for name, a, b in SEGMENTS:
        t = "\n".join(lines[a - 1:b])
        seg_texts.append(t)
        if show:
            print("     %-16s 行 %4d..%-4d  %6d B  md5 %s"
                  % (name, a, b, len(t.encode("utf-8")), md5b(t.encode("utf-8"))))
    block = "\n\n".join(seg_texts)

    print("== ① 源段落 ==")
    check(len(seg_texts) == 4, "四段都取到了")
    check(all(t.strip() for t in seg_texts), "没有空段")
    print("     拼接后 %d B  md5 %s"
          % (len(block.encode("utf-8")), md5b(block.encode("utf-8"))))

    # ---------------- ② 独立复算：抽出来的原块/载荷必须自证 ----------------
    print("== ② 独立复算（不信搬运工，只信算出来的数）==")
    d = derive(block)
    check(None not in (d["BS"], d["P_SIZE"], d["P_CK"], d["HEAD_END"], d["BODY_END"],
                       d["WIN_OFF"], d["WIN_LEN"], d["HOOK"], d["HEX"]),
          "常量段能解析出块几何",
          ",".join("%s=%s" % kv for kv in sorted(d.items()) if kv[1] is None))
    check(d["HOOK"] == HOOK_EXPECT, "HOOK 就是那句开机钩子", repr(d["HOOK"]))
    check(len(d["CAND"]) == 3, "三个候选块都在", str(d["CAND"]))
    if FAILS:
        return finish()

    BS, orig, pay = d["BS"], d["ORIG"], d["PAY"]
    check(len(d["HEX"]) == BS * 2, "hex 字符数 == 2×FLASH_BS",
          "%d vs %d" % (len(d["HEX"]), BS * 2))
    check(re.fullmatch(r"[0-9a-f]+", d["HEX"]) is not None, "全是小写 hex, 没混进别的字符")
    check(len(orig) == BS, "原块 %d B" % BS)
    check(adler32(orig) == ORIG_ADLER_EXPECT,
          "adler32(原块) == 源里写的 %s" % ORIG_ADLER_EXPECT, adler32(orig))
    check(orig[0xE84:0xE8C] == b"-rom1fs-",
          "门: 原块 @0xE84 是 romfs 超级块", orig[0xE84:0xE8C].hex())
    check(orig[0x64F4:0x64F7] == b"rcS",
          "门: 原块 @0x64F4 是 rcS inode", orig[0x64F4:0x64F7].hex())

    WIN_OFF, WIN_LEN, HEAD_END, BODY_END = (d["WIN_OFF"], d["WIN_LEN"],
                                            d["HEAD_END"], d["BODY_END"])
    check(len(pay) == BS, "载荷 %d B" % BS)
    check(adler32(pay) == PAY_ADLER_EXPECT,
          "adler32(载荷) == 源里写的 %s" % PAY_ADLER_EXPECT, adler32(pay))
    check(pay[WIN_OFF:WIN_OFF + WIN_LEN] == b"sh /data/rc &\n" + b"\x00" * 4,
          "载荷窗口里就是那句钩子 + 4 个 0", pay[WIN_OFF:WIN_OFF + WIN_LEN].hex())
    check(pay[:HEAD_END] == orig[:HEAD_END], "载荷前段与原块逐字节相同")
    check(pay[BODY_END:] == orig[BODY_END:], "载荷后段与原块逐字节相同")
    print("     原块 adler=%s  载荷 adler=%s  窗口 @0x%04X %dB  候选 %s"
          % (adler32(orig), adler32(pay), WIN_OFF, WIN_LEN,
             " ".join("%s@%d" % (dev, off) for dev, off, _n in d["CAND"])))

    # ---------------- ③ 注入 / 校验 ----------------
    print("== ③ 注入 / 校验 ==")
    dst, dst_crlf = read_text(DST)
    check(not dst_crlf, "dotui.lua 是 LF")
    n_ph = dst.count(PLACEHOLDER)
    check(n_ph <= 1, "占位符最多出现 1 次", "%d 次" % n_ph)

    if n_ph == 1:
        new = dst.replace(PLACEHOLDER, block)
        check("@@FLASH_BLOCK@@" not in new, "注入后没有残留占位符")
        check(block in new, "注入后整块**逐字节**在文件里")
        io.open(DST, "wb").write(new.encode("utf-8"))
        print("     INJECT: %d B -> %d B"
              % (len(dst.encode("utf-8")), len(new.encode("utf-8"))))
        dst = new
    else:
        check(block in dst,
              "dotui.lua 里那一整块与源**逐字节相同**（不是重新写的一份）")
        if block not in dst:
            for i, ln in enumerate(block.split("\n")):
                if ln and ln not in dst:
                    print("     第一处差异在段落第 %d 行: %r" % (i + 1, ln[:80]))
                    break

    # 反向：这几样**不许**跟着搬进来（管理器自己那套 / 不该进来的）
    for bad, what in (("set_status", "旧版的上屏辅助（管理器用自己的 log_append）"),
                      ("as_armed", "旧版的四键两段式闸门（管理器用 armed）"),
                      ("SUPERVISOR_PATH", "sup.ko 的路径（那是 chaos 自己的事）"),
                      ("autostart_staged", "旧版的自启动文件核对（管理器另有）"),
                      ("log_page", "不该混进 flash 段")):
        check(bad not in block, "搬进来的段里没有 %s（%s）" % (bad, what))

    return finish()


def finish():
    print()
    if FAILS:
        print("PORT-FLASH: FAIL (%d/%d)" % (len(FAILS), NCHK[0]))
        for f in FAILS:
            print("   - " + f)
        return 2
    print("PORT-FLASH: OK (%d)" % NCHK[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
