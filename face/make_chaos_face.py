# -*- coding: utf-8 -*-
"""把 Chaos 安装器打成表盘（.face）。

产物: face/chaos_inst/output/chaos_inst.face

链路（每个前置产物都带判据, 见 stage_*/verify）:
  Chaos-Module/installer/chaos_installer.lua -> app/_lua/_Lua/dotui.lua
  supervisor/chaos_sup.ko                    -> app/_lua/_Lua/chaos_sup.ko
  Chaos-Module/chaos_icon.bin (生成)          -> app/_lua/_Lua/chaos_icon.bin
  -> compile.exe -b chaos_inst.fprj output <face> <ID>

为什么 lua 要叫 dotui.lua: 容器里 lua 的落点由 fprj 的
`Name="app__lua%2F_Lua%2Fdotui.lua"` 决定, 设备上解出来是 `_lua/_Lua/dotui.lua`,
而 `SCRIPT_PATH` 就指向那个目录 —— 安装器里 `SCRIPT_PATH .. "chaos_sup.ko"`
才找得到同级文件。编译实测: compile.exe 会把 `app/` 下**所有**文件原样收进容器
(不是只收 fprj 里点名那一个), 靠的是 probc 工程现场核对。

编译的真实入口是 `build_face.py` 那套（compile.exe 在 stdout 非控制台时崩
Array.Copy）, 这里只是把它并进了本工程的流水线。
"""
import hashlib
import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))              # ...\chaos-autostart\face
REPO = os.path.dirname(ROOT)                                   # ...\chaos-autostart
PROJ = os.path.join(ROOT, 'chaos_inst')
LUA_DIR = os.path.join(PROJ, 'app', '_lua', '_Lua')
OUT_DIR = os.path.join(PROJ, 'output')
FACE = os.path.join(OUT_DIR, 'chaos_inst.face')
FPRJ = os.path.join(PROJ, 'chaos_inst.fprj')

LUA_SRC = os.path.join(REPO, 'Chaos-Module', 'installer', 'chaos_installer.lua')
KO_SRC = os.path.join(REPO, 'Chaos-Module', 'supervisor', 'chaos_sup.ko')
ICON_GEN = os.path.join(REPO, 'Chaos-Module', 'tools', 'gen_chaos_icon.py')
ICON_PNG = os.path.join(REPO, 'Chaos-Module', 'tools', 'chaos.png')
# ★ 老版本这里有个 SRC_LUA, 用来把容器里 32KB 的 ORIG_HEX 跟上游 main.lua 逐字符比对。
#   新标准下写 flash 的能力已整段交给管理器（见 chaos_installer.lua 头部说明）,
#   本包不再内嵌任何原块 ⇒ 这个常量连同那几条判据一起删掉。

COMPILE_CAND = [r"C:\Program Files (x86)\Mi Create\compiler\compile.exe",
                r"C:\face_tools\compiler\compile.exe"]
EXE = next((c for c in COMPILE_CAND if os.path.exists(c)), None)

TITLE = 'Chaos 自启动'
PKG_ID = '37653043'                      # 10 位, compile.exe 的最后一个参数
CREATE_NEW_CONSOLE = 0x00000010

W, H = 336, 480
ICON_BYTES = 50188                       # 12 头 + 112*112*4

# 容器内路径 -> 本地源文件。判据就是"这三个都原样在里面"。
WANT = {
    '_lua/_Lua/dotui.lua':        os.path.join(LUA_DIR, 'dotui.lua'),
    '_lua/_Lua/chaos_sup.ko':     os.path.join(LUA_DIR, 'chaos_sup.ko'),
    '_lua/_Lua/chaos_icon.bin':   os.path.join(LUA_DIR, 'chaos_icon.bin'),
}

FAILS = []


def say(ok, label, extra=''):
    print('  %s %-46s %s' % ('ok  ' if ok else 'FAIL', label, extra))
    if not ok:
        FAILS.append(label)
    return ok


def md5b(b):
    return hashlib.md5(b).hexdigest()


def md5f(p):
    return md5b(open(p, 'rb').read())


# --------------------------------------------------------------- ① 摆文件
def stage_lua():
    raw = open(LUA_SRC, 'rb').read()
    say(raw.count(b'\r') == 0, 'lua 纯 LF（有 CR 设备端会整屏黑）',
        'CR=%d' % raw.count(b'\r'))
    say(not raw.startswith(b'\xef\xbb\xbf'), 'lua 无 UTF-8 BOM')
    say(raw.endswith(b'\n'), 'lua 以换行收尾')
    say(b'CMD_BOOT_DQ' in raw, 'lua 里能看到自启动那条补丁（CMD_BOOT_DQ）')
    dst = WANT['_lua/_Lua/dotui.lua']
    open(dst, 'wb').write(raw)
    say(md5f(dst) == md5f(LUA_SRC), 'dotui.lua 与源逐字节相同',
        '%d B  %s' % (len(raw), md5b(raw)))


def stage_ko():
    if not os.path.exists(KO_SRC):
        say(False, 'ko 存在', '缺 %s（先跑 build_ko）' % KO_SRC)
        return
    raw = open(KO_SRC, 'rb').read()
    say(raw[:4] == b'\x7fELF', 'ko 是 ELF')
    say(raw[5] == 1, 'ko 小端（EI_DATA=1）', 'EI_DATA=%d' % raw[5])
    say(len(raw) < 256 * 1024, 'ko < 256KB（insmod 上限）', '%d B' % len(raw))
    dst = WANT['_lua/_Lua/chaos_sup.ko']
    open(dst, 'wb').write(raw)
    say(md5f(dst) == md5f(KO_SRC), 'chaos_sup.ko 与源逐字节相同',
        '%d B  %s' % (len(raw), md5b(raw)))

    # ★ 符号级判据：.strtab 里的名字是明文, 直接搜字节 (不用 llvm-nm, 免环境依赖)。
    #   这一组同时证明两件事: ① 自启动补丁（DQ 那半）真的编进了这个 ko;
    #   ② App 那半（14 页表 + 页面钩子 + 派发）也在里面 —— 模块就是那个原生应用本身。
    WANT_SYM = [
        (b'dq_timer_cb', '自启动 DQ 回调'),
        (b'run_install_cmd', '从 chaos_write 搬出的注册链'),
        (b'DQ_SEQ', '自启动序列 0x18/0x13/0x22'),
        (b'DQ_FIRED', '自启动一次性闸'),
        (b'cmd_install', '注册链 install 阶段'),
        (b'PAGE_TABLE', '14 页应用描述表'),
        (b'chaos_on_create', '页面钩子 on_create'),
        (b'chaos_on_resume', '页面钩子 on_resume'),
        (b'chaos_on_destroy', '页面钩子 on_destroy'),
        (b'render_page', '页面渲染'),
        (b'chaos_row_dispatch', '行派发'),
        (b'chaos_ctor', '模块构造入口（init_array）'),
    ]
    for sym, what in WANT_SYM:
        say(sym in raw, 'ko 符号 %-18s（%s）' % (sym.decode(), what))


def stage_icon():
    r = subprocess.run([sys.executable, '-X', 'utf8', ICON_GEN, ICON_PNG,
                        WANT['_lua/_Lua/chaos_icon.bin']],
                       capture_output=True)
    out = (r.stdout + r.stderr).decode('utf-8', 'replace').strip()
    ok = r.returncode == 0 and os.path.exists(WANT['_lua/_Lua/chaos_icon.bin'])
    say(ok, 'chaos_icon.bin 已生成', out.split('\n')[-1] if ok else out[-200:])
    if not ok:
        return
    raw = open(WANT['_lua/_Lua/chaos_icon.bin'], 'rb').read()
    say(len(raw) == ICON_BYTES, 'icon 50,188 B（112x112 BGRA + 12 头）', '%d B' % len(raw))
    tag, cf, fl, rs, w, h, stride = struct.unpack_from('<4B3H', raw, 0)[:7]
    say(raw[:4] == bytes([0x19, 0x10, 0, 0]) and w == 112 and h == 112 and stride == 448,
        'icon 头字段 112x112/stride448', '%02x %02x %02x %02x %d %d %d'
        % (tag, cf, fl, rs, w, h, stride))
    say(struct.unpack_from('<I', raw, 12)[0] == 0, 'icon 左上角像素透明（四角留白）')


def stage_preview():
    from PIL import Image, ImageDraw, ImageFont
    BG, CARD, ACC, TXT, DIM = (0x0E, 0x11, 0x17, 0xFF), (0x16, 0x1B, 0x24), \
        (0xFF, 0x5A, 0x3C, 0xFF), (0xF2, 0xF5, 0xF8, 0xFF), (0x93, 0x9E, 0xAD, 0xFF)
    im = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 6, H], fill=ACC)                      # 左侧色条

    def font(path, size):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            return ImageFont.load_default()

    f_big = font(r'C:\Windows\Fonts\consolab.ttf', 46)
    f_cn = font(r'C:\Windows\Fonts\msyh.ttc', 30)
    f_sm = font(r'C:\Windows\Fonts\consola.ttf', 17)
    f_li = font(r'C:\Windows\Fonts\msyh.ttc', 19)   # 中文行必须用中文字体, 否则全是豆腐块

    d.text((34, 96), 'CHAOS', font=f_big, fill=TXT)
    d.rectangle([34, 156, 34 + 96, 156 + 4], fill=ACC)
    d.text((34, 178), '自启动安装器', font=f_cn, fill=TXT)
    d.text((34, 224), 'p67tc · 3.101.043', font=f_sm, fill=DIM)

    # 底部：四步摘要，让人一眼知道这是安装器不是表盘
    steps = ['1 部署模块', '3 加载模块', '8 发布桌面条目', '★ rcS 开机钩子']
    y = 306
    for s in steps:
        d.rectangle([34, y + 7, 40, y + 13], fill=ACC)
        d.text((52, y), s, font=f_li, fill=DIM)
        y += 34

    d.rectangle([24, 24, W - 24, H - 24], outline=(0x2A, 0x32, 0x3E, 255), width=2)

    for rel in ('preview.png', 'market-preview.png', os.path.join('images', 'preview.png')):
        p = os.path.join(PROJ, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        im.save(p, 'PNG')
    got = Image.open(os.path.join(PROJ, 'preview.png'))
    say(got.size == (W, H) and got.mode == 'RGBA' or got.size == (W, H),
        'preview.png 336x480', '%s %s' % (got.size, got.mode))


def write_fprj():
    body = ('<?xml version="1.0" ?>\n'
            '<FaceProject DeviceType="11">\n'
            '\t<Screen Title="%s" Bitmap="preview.png" Width="%d" Height="%d">\n'
            '\t\t<Widget xmlns:p3="http://www.w3.org/2001/XMLSchema-instance" '
            'p3:type="FaceWidgetContainer" Shape="34" Name="app__lua%%2F_Lua%%2Fdotui.lua" '
            'X="0" Y="0" Width="%d" Height="%d" Alpha="0" Visible_Src="0"/>\n'
            '\t</Screen>\n'
            '</FaceProject>\n') % (TITLE, W, H, W, H)
    open(FPRJ, 'wb').write(body.encode('utf-8'))
    back = open(FPRJ, 'rb').read().decode('utf-8')
    say(TITLE in back and 'DeviceType="11"' in back and 'dotui.lua' in back,
        'fprj 写好（UTF-8, DeviceType=11）', '%d B' % len(back.encode('utf-8')))


# --------------------------------------------------------------- ② 编译
def compile_face():
    if not EXE:
        say(False, 'compile.exe 存在', '两处都没有')
        return False
    os.makedirs(OUT_DIR, exist_ok=True)
    for p in (FACE, os.path.join(OUT_DIR, 'chaos_inst.info')):
        if os.path.exists(p):
            os.replace(p, p + '.prev')          # 不删, 只让位（存量闸门/留档）
    # ★ 必须给子进程一个真控制台: 否则 compile.exe 里 Console.WindowWidth==0
    #   -> Array.Copy 崩, 一个字节都不产出。整串交给 shell=True, 不要传 list。
    inner = 'chcp 936 >nul && "%s" -b "%s" output "%s" %s' % (EXE, FPRJ, FACE, PKG_ID)
    r = subprocess.run(inner, shell=True, cwd=PROJ,
                       creationflags=CREATE_NEW_CONSOLE, stdin=subprocess.DEVNULL)
    if not os.path.exists(FACE) or os.path.getsize(FACE) == 0:
        say(False, 'compile.exe 产出 .face', 'exit=%s, 没产物' % r.returncode)
        return False
    say(True, 'compile.exe 产出 .face',
        'exit=%s  %d B' % (r.returncode, os.path.getsize(FACE)))
    return True


# --------------------------------------------------------------- ③ 验容器
def verify():
    raw = open(FACE, 'rb').read()
    say(raw[:4] == b'\x5a\xa5\x34\x12', '容器魔数 5a a5 34 12', raw[:4].hex())

    # 记录表固定在 0x100（头部+包名+显示名+主题表都是定长）；首条 = (0,0,尾标记,0x10)
    rec_off = 0x100
    hdr = struct.unpack_from('<4I', raw, rec_off)
    say(hdr[0] == 0 and hdr[3] == 0x10, '记录表首条形状 (0,0,tail,0x10)',
        '%08x %08x %08x %08x' % hdr)
    files, off, i = {}, rec_off + 16, 0
    while i < 256:                      # 有界: 找不到终止记录就停下来, 不要跑飞
        uid, zero, foff, fsize = struct.unpack_from('<4I', raw, off)
        # ★ 终止记录的判据是 off==0（len 也 0）。**不要**写成 uid==0x05000000 ——
        #   compile.exe 在终止记录里填的是别的槽号（实测 2 文件填 0x05000000、
        #   3 文件填 0x05000002、真表盘 14 文件填 0x05000001），按 uid 判会多读一条。
        if foff == 0 and fsize == 0:
            say(off == hdr[2], '终止记录落在首条记的 tail 地址上',
                '%#x vs %#x' % (off, hdr[2]))
            break
        packed, = struct.unpack_from('<I', raw, foff)
        plen, dlen = packed >> 24, packed & 0xFFFFFF
        path = raw[foff + 20:foff + 20 + plen].decode('ascii')
        files[path] = raw[foff + 20 + plen:foff + 20 + plen + dlen]
        say(fsize == 20 + plen + dlen, 'slot %d 记录长度自洽' % i, path)
        off += 16
        i += 1
    say(len(files) == len(WANT), '容器内文件条数 = %d' % len(WANT),
        '%d 条: %s' % (len(files), ', '.join(sorted(files))))

    for path, src in WANT.items():
        if path not in files:
            say(False, '容器里有 %s' % path, '缺')
            continue
        a, b = md5b(files[path]), md5f(src)
        say(a == b, '容器内 %s 逐字节 == 源' % path,
            '%d B  %s' % (len(files[path]), a))

    # 安装器里那几处 SCRIPT_PATH 名字必须真在里面
    lua = files.get('_lua/_Lua/dotui.lua', b'')
    for need in (b'chaos_sup.ko', b'chaos_icon.bin', b'SCRIPT_PATH', b'CMD_BOOT_DQ'):
        say(need in lua, 'lua 明文里有 %s' % need.decode())

    # ★ 新标准（2026-10-04 定）—— 判据直接读**容器里那份** lua, 不是读源文件:
    #   要证明的是"进了包", 不是"源码里有"。
    WANT_LUA = [
        (b'local RC_DIR = "/data/rc.d"', '注册目录 = 管理器的 /data/rc.d'),
        (b'local RC_SH  = RC_DIR .. "/chaos.sh"', '本模块的注册脚本路径'),
        (b'local LEGACY_FLAG', '旧版模块闸的清理目标(不许留雷)'),
        (b'local function rc_dir_ready', '判"管理器装没装"(试写, 不是 exists)'),
        (b'local function build_chaos_sh', 'chaos.sh 全文生成器'),
        (b'local function autostart_install', '安装 = 投文件'),
        (b'local function autostart_remove', '删除 = 撤文件'),
        (b'local function legacy_cleanup', '清旧版二跳残留(只删自己那行)'),
        (b'local function autostart_state_text', '自启动页状态行'),
        (b'w("insmod " .. SUPERVISOR_PATH', 'chaos.sh = 纯干活的命令序列'),
        ('"  开关→管理器"'.encode('utf-8'), '状态行不再显示开关(闸归 /data/rc 那一层)'),
    ]
    for need, what in WANT_LUA:
        say(need in lua, 'lua 里 %-40s（%s）' % (need.decode(), what))

    # ★★ 反向判据（本轮的核心）—— 写 flash / 写 /data/rc 的能力**已整段交给管理器**,
    #    本包一个字节都不许带。判的是**代码**不是散文: 先剥掉整行注释再判 ——
    #    头部那段"老做法是什么"的说明里就写着二跳原文, 不剥会逼着人把有用的说明删掉
    #    （管理器的门踩过同一个坑）。
    code = b'\n'.join(ln for ln in lua.split(b'\n') if not ln.strip().startswith(b'--'))
    for ban, why in [
        (b'ORIG_HEX', '不含 32KB 原块（不再写 flash）'),
        (b'FLASH_BS', '不含 32KB 块几何'),
        (b'flash_probe', '不含目标块探测'),
        (b'flash_gate', '不含固件版本门'),
        (b'hook_install', '不含装 hook'),
        (b'hook_restore', '不含还原 hook'),
        (b'/dev/bes_flash', '不碰 flash 设备节点'),
        (b'/dev/ap', '不碰 flash 设备节点'),
        (b'0x8D9C53E2', '不含 rcS inode checksum'),
        (b'0x6642', '不含末行窗口偏移'),
        (b'AS_BTN', '不含旧的自启动页紧凑按钮尺寸'),
        (b'as_armed', '不含旧的两段式确认闸'),
    ]:
        say(ban not in code, '代码里**没有** %-16s（%s）' % (ban.decode(), why))

    # ★★ 反向判据（本轮核心）：**模块脚本里不许有任何"机制"**。
    #    2026-10-04 第三次改（用户定的职责边界: 管理器和模块要分开）——
    #    模块只写"自己要干什么"; 闸(防砖)与计时(8s 前置 / 15s 安全窗)整段上移到
    #    /data/rc（管理器）。钉死它的两个理由:
    #      ① 旧版每个模块自带一个 15s 安全窗 ⇒ N 个模块白等 N×15 秒;
    #      ② 自带闸会让"管理器显示开、模块却不跑"的不一致回来 —— 就是那次血案。
    #    同时钉住 nsh 里**没有证据**的构造: else / [ ! ] / && / || / $( )。
    #    已验证子集只有: set +e / rm -f / echo > 、>> / sleep / insmod / dd / ls。
    for ban, why in [
        (b'w("if ', '模块脚本里不许有 if（判断归 /data/rc）'),
        (b'w("sleep ', '模块脚本里不许有 sleep（8s/15s 延时归 /data/rc）'),
        (b'w("rm ', '模块脚本里不许有 rm（闸的扣与放归 /data/rc）'),
        (b'w("else")', 'nsh 不支持 else(无证据) ⇒ 不许出现'),
        (b'[ ! ', 'nsh 里 [ ! ] 无证据 ⇒ 不许用取反写门'),
        (b'&&', 'nsh 里 && 无证据'),
        (b'|| ', 'nsh 里 || 无证据'),
    ]:
        say(ban not in code, '代码里**没有** %-14s（%s）' % (ban.decode(), why))

    say(code.count(b'sh /data/chaos/rc &') == 1,
        '代码里二跳字样只剩 1 处（LEGACY_HOP, 只用于清残留）',
        '%d' % code.count(b'sh /data/chaos/rc &'))
    say(code.count(b'"/data/rc"') == 1,
        '代码里 "/data/rc" 只剩 1 处（LEGACY_RC_PATH, 只读）',
        '%d' % code.count(b'"/data/rc"'))
    say(code.count(b'"/data/rc.d"') == 1,
        '代码里 "/data/rc.d" 恰好 1 处（RC_DIR, 唯一入口）',
        '%d' % code.count(b'"/data/rc.d"'))

    # ★ 自启动页只有"安装 / 删除"两个**功能**键（外加一个返回键）—— 用户明确要求压成两个。
    #   旧版的 4 个功能键（装自启文件/开自启动/关自启动/移除文件）一个都不许留:
    #   "开/关"的职责已经分给了管理器策略与模块自己脚本里的开关判句, 留着就是第三个真相源。
    for need in ('安装', '删除', '< 返回'):
        say(('"%s"' % need).encode('utf-8') in lua, '自启动页有按钮「%s」' % need)
    for gone in ('装自启文件', '开自启动', '关自启动', '移除文件'):
        say(('"%s"' % gone).encode('utf-8') not in lua, '旧按钮「%s」已移除' % gone)

    # ★ 删除动作的边界: 只删两个自启动文件 + 旧版残留的模块闸,
    #   **不碰**主功能、**不删**数据目录。
    m_rm = re.search(rb'local function autostart_remove\(\)(.*?)\nend\n', lua, re.S)
    rmblk = m_rm.group(1) if m_rm else b''
    say(m_rm is not None, 'lua 里有 autostart_remove 函数体')
    for need in (b'RC_SH', b'BOOT_FRAME', b'LEGACY_FLAG'):
        say(need in rmblk, '删除动作含自启动文件 %s' % need.decode())
    for ban in (b'SUPERVISOR_PATH', b'ICON_PATH', b'ICON_DIR', b'FONT_DIR', b'DATA_DIR'):
        say(ban not in rmblk, '删除动作里**没有**主功能路径 %s' % ban.decode())

    prev_off = struct.unpack_from('<I', raw, 0x20)[0]
    tag, w, h, plen = struct.unpack_from('<IHHI', raw, prev_off)
    say((tag & 0xFF00) == 0x400 and w == W and h == H,
        '缩略图块 %dx%d tag=%#x' % (W, H, tag), 'len=%d' % plen)
    tail_pad = raw[prev_off + 12 + plen:]
    say(0 <= len(tail_pad) <= 3 and tail_pad == b'\x00' * len(tail_pad),
        '缩略图块之后只剩 0 填充（≤3B 对齐）',
        'pad=%d %s' % (len(tail_pad), tail_pad.hex()))
    name = raw[0x68:0xA8].split(b'\0')[0].decode('utf-8', 'replace')
    say(name == TITLE, '显示名 = fprj 的 Title', repr(name))
    print('       -> face=%s (%d B, %s)' % (FACE, len(raw), md5b(raw)))


def main():
    print('== Chaos 安装器 -> 表盘 (.face) ==')
    print('   proj    %s' % PROJ)
    print('   compiler %s' % EXE)
    os.makedirs(LUA_DIR, exist_ok=True)
    stage_lua()
    stage_ko()
    stage_icon()
    stage_preview()
    write_fprj()
    if not FAILS and compile_face():
        verify()
    print()
    if FAILS:
        print('MAKE-FACE: FAIL (%d)' % len(FAILS))
        for f in FAILS:
            print('   - ' + f)
        return 2
    print('MAKE-FACE: PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
