# -*- coding: utf-8 -*-
"""把 10pro.autorun 管理器打成可安装的 .face（v2 布局：源在 Watchface/ 里）。

链路（每步都有判据，任一不过就停）：
  Watchface/module.autorun.Manager/resources/_lua/_Lua/module-autorun-manager.lua
    -> 拷成 _build/manager/app/_lua/_Lua/dotui.lua（compile.exe 只认 fprj 里那个名字）
    -> preview.png / images/preview.png（compile.exe 必需，336x480）
    -> manager.fprj（DeviceType=11 / Title=10pro.autorun / Name=app__lua%2F_Lua%2Fdotui.lua）
    -> compile.exe -b <fprj> output <face> <ID>
    -> 验容器：魔数 / 0x68 显示名 / 单条记录 / **容器里的 lua 与本文件逐字节相同**

用法：
  python tool/build_face.py             # 打包 + 校验，产物在 _build/manager/output/
  python tool/build_face.py --check     # 只做静态检查（不调 compile.exe）
  python tool/build_face.py --desk NAME # 另外复制一份到桌面（NAME 为文件名）
"""
import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PKG = os.path.join(ROOT, "Watchface", "module.autorun.Manager")
SRC = os.path.join(PKG, "resources", "_lua", "_Lua", "module-autorun-manager.lua")
PREVIEW = os.path.join(PKG, "preview", "preview.png")

BUILD = os.path.join(ROOT, "_build", "manager")
OUT_DIR = os.path.join(BUILD, "output")
FACE = os.path.join(OUT_DIR, "10pro.autorun.face")
FPRJ = os.path.join(BUILD, "manager.fprj")

TITLE = "10pro.autorun"
PKG_ID = "37653044"          # 只决定命令行参数；容器 0x28 由 compile.exe 写死
W, H = 336, 480
CREATE_NEW_CONSOLE = 0x00000010
COMPILE_CAND = [r"C:\Program Files (x86)\Mi Create\compiler\compile.exe",
                r"C:\face_tools\compiler\compile.exe"]

FAILS, NCHK = [], [0]


def check(cond, label, extra=""):
    NCHK[0] += 1
    if cond:
        print("  ok   %s" % label)
    else:
        print("  FAIL %s  %s" % (label, extra))
        FAILS.append(label)
    return bool(cond)


def md5f(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()


def stage(preview=None):
    """把源和预览图摆成 compile.exe 认得的样子。"""
    print("== ① 摆工程 ==")
    preview = preview or PREVIEW
    app_dir = os.path.join(BUILD, "app", "_lua", "_Lua")
    shutil.rmtree(BUILD, ignore_errors=True)
    os.makedirs(app_dir)
    os.makedirs(OUT_DIR)
    os.makedirs(os.path.join(BUILD, "images"))

    check(os.path.isfile(SRC), "源存在", SRC)
    src_bytes = open(SRC, "rb").read()
    shutil.copyfile(SRC, os.path.join(app_dir, "dotui.lua"))
    check(open(os.path.join(app_dir, "dotui.lua"), "rb").read() == src_bytes,
          "源已拷进工程（逐字节）", "%d B" % len(src_bytes))

    # Lua 语法门（有 lupa 就跑，没有就跳过 —— 不能因为工具缺就假装通过）
    try:
        import lupa
        L = lupa.LuaRuntime()
        chk = L.eval('function(s) local f,e = load(s,"=m") '
                     'if f then return "OK" else return "FAIL: "..tostring(e) end end')
        r = chk(src_bytes.decode("utf-8"))
        check(r == "OK", "Lua 语法门", str(r))
    except ImportError:
        print("  --   跳过 Lua 语法门（没有 lupa）")

    # 预览图：不是 336x480 就等比缩放过来（2 倍图缩小最干净；别的尺寸会裁成等比留边）
    dst = os.path.join(BUILD, "preview.png")
    try:
        from PIL import Image
        im = Image.open(preview).convert("RGB")
        if im.size != (W, H):
            im = im.resize((W, H), Image.LANCZOS)
            print("  --   预览图 %s -> %dx%d" % (str(Image.open(preview).size), W, H))
        im.save(dst, "PNG")
        check(Image.open(dst).size == (W, H), "preview.png 是 336x480", str(Image.open(dst).size))
    except ImportError:
        shutil.copyfile(preview, dst)
        print("  --   跳过预览图缩放（没有 Pillow）")
    shutil.copyfile(dst, os.path.join(BUILD, "images", "preview.png"))
    shutil.copyfile(dst, os.path.join(BUILD, "market-preview.png"))
    return len(src_bytes)


def write_fprj():
    print("== ② 写 fprj ==")
    body = ('<?xml version="1.0" ?>\n'
            '<FaceProject DeviceType="11">\n'
            '\t<Screen Title="%s" Bitmap="preview.png" Width="%d" Height="%d">\n'
            '\t\t<Widget xmlns:p3="http://www.w3.org/2001/XMLSchema-instance" '
            'p3:type="FaceWidgetContainer" Shape="34" Name="app__lua%%2F_Lua%%2Fdotui.lua" '
            'X="0" Y="0" Width="%d" Height="%d" Alpha="0" Visible_Src="0"/>\n'
            '\t</Screen>\n'
            '</FaceProject>\n') % (TITLE, W, H, W, H)
    open(FPRJ, "wb").write(body.encode("utf-8"))
    back = open(FPRJ, "rb").read().decode("utf-8")
    check(TITLE in back and 'DeviceType="11"' in back and "dotui.lua" in back,
          "fprj 写好", "%d B" % len(body.encode("utf-8")))


def compile_face():
    print("== ③ compile.exe ==")
    exe = next((c for c in COMPILE_CAND if os.path.exists(c)), None)
    if not check(exe is not None, "compile.exe 存在", str(COMPILE_CAND)):
        return False
    if os.path.exists(FACE):
        os.replace(FACE, FACE + ".prev")
    # ★ compile.exe 必须给真控制台（否则 Console.WindowWidth==0 -> Array.Copy 崩），
    #   而且 cwd 必须是工程目录（它去找 <cwd>/images/）。
    inner = 'chcp 936 >nul && "%s" -b "%s" output "%s" %s' % (exe, FPRJ, FACE, PKG_ID)
    r = subprocess.run(inner, shell=True, cwd=BUILD,
                       creationflags=CREATE_NEW_CONSOLE, stdin=subprocess.DEVNULL)
    if not os.path.exists(FACE) or os.path.getsize(FACE) == 0:
        check(False, "产出 .face", "exit=%s，没产物" % r.returncode)
        return False
    check(True, "产出 .face", "exit=%s  %d B" % (r.returncode, os.path.getsize(FACE)))
    return True


def verify(src_len):
    print("== ④ 验容器 ==")
    raw = open(FACE, "rb").read()
    src = open(SRC, "rb").read()
    check(raw[:4] == b"\x5a\xa5\x34\x12", "容器魔数", raw[:4].hex())
    disp = raw[0x68:0x88].split(b"\x00")[0].decode("utf-8", "replace")
    check(disp == TITLE, "0x68 显示名 == %s" % TITLE, repr(disp))

    hdr = struct.unpack_from("<4I", raw, 0x100)
    off, body = 0x110, None
    for _ in range(8):
        uid, zero, foff, fsize = struct.unpack_from("<4I", raw, off)
        if foff == 0 and fsize == 0:
            break
        body = raw[foff:foff + fsize]
        off += 16
    check(body is not None, "找到资源记录")
    if body is not None:
        # 实测（旧包）：记录体 = [39 B 小头][lua 源]，小头里带内部路径 `_lua/_Lua/dotui.lua`。
        # 所以判据是"源在记录体里、且在记录体尾部" —— 不是整段相等。
        i = body.find(src)
        check(i >= 0 and body[i:] == src, "容器里的 lua 与源逐字节相同",
              "记录体 %d B / 源 %d B / 源起点 %s" % (len(body), len(src), i))
        if i > 0:
            head = body[:i]
            check(b"_lua/_Lua/" in head, "记录体小头里带内部路径",
                  repr(head[:i][-40:]))
            print("  记录体小头 %d B: %r" % (i, head))
    print("  产物: %s" % FACE)
    print("  大小: %d B   md5: %s" % (len(raw), hashlib.md5(raw).hexdigest()))


def main():
    ap = argparse.ArgumentParser(description="把管理器打成 .face")
    ap.add_argument("--check", action="store_true", help="只静态检查，不调 compile.exe")
    ap.add_argument("--desk", default="", help="另外复制到桌面的文件名")
    ap.add_argument("--preview", default="", help="表盘预览图（任意尺寸，会缩放到 336x480）")
    args = ap.parse_args()

    n = stage(args.preview or None)
    write_fprj()
    if args.check:
        print("\nCHECK-ONLY: 静态部分通过（没有调 compile.exe）")
        return 0 if not FAILS else 1

    if compile_face():
        verify(n)

    if FAILS:
        print("\nBUILD-FACE: FAIL (%d)" % len(FAILS))
        for f in FAILS:
            print("   - %s" % f)
        return 1
    print("\nBUILD-FACE: PASS (%d 项)" % NCHK[0])
    if args.desk:
        dst = os.path.join(os.path.expanduser("~"), "Desktop", args.desk)
        shutil.copyfile(FACE, dst)
        ok = md5f(FACE) == md5f(dst)
        print("已复制到 %s  md5 %s %s" % (dst, md5f(dst), "一致" if ok else "不一致!"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
