# -*- coding: utf-8 -*-
"""把 10pro.autorun 管理器打成表盘（.face）。

产物: manager/output/10pro.autorun.face

链路（每一步都有判据，任一不过就停）:
  manager/app/_lua/_Lua/dotui.lua   源（唯一真源，直接就是 app/ 里那一份）
  -> flash 移植门 tools/_port_flash_to_manager.py（那整块与源**逐字节**相同 + 独立复算 adler）
  -> 离线行为门 tools/_sim_manager.py（假 NuttX + 假 flash，180+ 条断言）
  -> preview.png / market-preview.png （336x480，照 UI 配色画）
  -> manager.fprj                    （DeviceType=11, Name=app__lua%2F_Lua%2Fdotui.lua）
  -> compile.exe -b <fprj> output <face> <ID>
  -> 验容器：魔数 / 记录表 @0x100 / 终止记录 off==0 且 len==0 / 文件逐字节 == 源
             / 容器里那份 lua 里的符号（正向 + 反向 + flash 反-反向）

★ compile.exe 的两个已知坑（与 chaos 那条链同源）：
  1. 必须给**真控制台**（CREATE_NEW_CONSOLE）。stdout 不是控制台时
     Console.WindowWidth==0 -> Array.Copy 崩，一个字节都不产出。
  2. 终止记录的判据是 `off==0 and len==0`，**不是** uid==0 —— 实测 terminal 记录里
     填的是别的槽号（2 文件填 0x05000000、3 文件填 0x05000002），按 uid 判会多读一条。

用法:
  python build_manager.py            # 打包 + 校验
  python build_manager.py --check    # 只静态自检（跑离线门 + 验 fprj/preview），不调 compile.exe
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LUA_DIR = os.path.join(HERE, "app", "_lua", "_Lua")
LUA_SRC = os.path.join(LUA_DIR, "dotui.lua")
OUT_DIR = os.path.join(HERE, "output")
FACE = os.path.join(OUT_DIR, "10pro.autorun.face")
FPRJ = os.path.join(HERE, "manager.fprj")

TITLE = "10pro.autorun"
# ⚠️ 这个号**只决定命令行参数**，不进容器 —— compile.exe 一律把 0x28 那 12 B 填成
#    "167210065"（见 FACE.md §3.4，实测 probc/ioch/10p043/chaos_inst/本包**全一样**）。
#    所以"取不同的号就不会互相顶掉"这个想法是**错的**（本注释曾是这么写的，已改）。
#    ★ 真正区分两张表盘的是 fprj 的 `Title` -> 容器 0x68 显示名（本条链路里唯一可控的身份字段）。
#    ★ 未被证明的残留风险：固件是否**也**按 0x28 判"同一个包"（FACE.md §5.1）——
#      本机无法构造"不同 0x28"的对照，只能真机回答（MANAGER.md §10 第 0 步 / V2）。
PKG_ID = "37653044"
W, H = 336, 480
CREATE_NEW_CONSOLE = 0x00000010

COMPILE_CAND = [r"C:\Program Files (x86)\Mi Create\compiler\compile.exe",
                r"C:\face_tools\compiler\compile.exe"]
EXE = next((c for c in COMPILE_CAND if os.path.exists(c)), None)

# 颜色（与 dotui.lua 里的 C_* 一致）
C_BG, C_CARD, C_LINE = (0x07, 0x11, 0x1F), (0x0D, 0x1D, 0x31), (0x24, 0x45, 0x66)
C_TXT, C_DIM, C_ACC = (0xFF, 0xFF, 0xFF), (0x9D, 0xB7, 0xD8), (0x8C, 0x1E, 0x1E)

# 容器里必须有的文件（容器内路径 -> 本地源）
WANT = {"_lua/_Lua/dotui.lua": LUA_SRC}

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


def md5f(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()


# ------------------------------------------------------------------ ① 预览图
def draw_preview():
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        check(False, "PIL 可用(画预览图)", "没装 Pillow")
        return
    im = Image.new("RGBA", (W, H), C_BG + (255,))
    d = ImageDraw.Draw(im)

    def font(path, size):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            return ImageFont.load_default()

    f_big = font(r"C:\Windows\Fonts\consolab.ttf", 30)
    f_cn = font(r"C:\Windows\Fonts\msyh.ttc", 26)
    f_sm = font(r"C:\Windows\Fonts\msyh.ttc", 16)

    d.text((22, 92), "10pro.autorun", font=f_big, fill=C_TXT)
    d.rectangle([22, 134, 22 + 96, 138], fill=C_ACC)
    d.text((22, 154), "多模块开机自启管理", font=f_cn, fill=C_TXT)
    d.text((22, 196), "p67tc · 3.101.043", font=f_sm, fill=C_DIM)

    # 底部四行摘要，一眼知道它是干什么的
    # ★ 2026-10-04 起 [2 接管] 已删、flash hook 装/卸归到「自启动」页 ⇒ 摘要要跟着改
    #   （旧版最后一行写的是"★ 不碰 flash"，**现在是错的**，不能再挂着）。
    for i, s in enumerate(["1 自启动：装/卸开机钩子",
                           "2 注册目录 /data/rc.d",
                           "3 闸 .autorun.on（防砖）",
                           "4 生成 /data/rc（串行）"]):
        y = 268 + i * 34
        d.rectangle([22, y + 6, 28, y + 12], fill=C_ACC)
        d.text((40, y), s, font=f_sm, fill=C_DIM)

    d.rectangle([14, 14, W - 14, H - 14], outline=C_LINE + (255,), width=2)

    # ★ compile.exe 会去找 `<proj>/images/`（缺了直接报 "images path is not found" 并
    #   一个字节都不产出），里面至少要有 preview.png。output/ 也必须是已存在的目录。
    for rel in ("preview.png", "market-preview.png", "images/preview.png"):
        p = os.path.join(HERE, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        im.save(p, "PNG")
    os.makedirs(OUT_DIR, exist_ok=True)
    got = Image.open(os.path.join(HERE, "preview.png"))
    check(got.size == (W, H), "preview.png 是 336x480", "%s %s" % (got.size, got.mode))
    check(os.path.exists(os.path.join(HERE, "images", "preview.png")),
          "images/preview.png 在（compile.exe 必需）")


# ------------------------------------------------------------------ ② fprj
def write_fprj():
    body = ('<?xml version="1.0" ?>\n'
            '<FaceProject DeviceType="11">\n'
            '\t<Screen Title="%s" Bitmap="preview.png" Width="%d" Height="%d">\n'
            '\t\t<Widget xmlns:p3="http://www.w3.org/2001/XMLSchema-instance" '
            'p3:type="FaceWidgetContainer" Shape="34" Name="app__lua%%2F_Lua%%2Fdotui.lua" '
            'X="0" Y="0" Width="%d" Height="%d" Alpha="0" Visible_Src="0"/>\n'
            '\t</Screen>\n'
            '</FaceProject>\n') % (TITLE, W, H, W, H)
    with open(FPRJ, "wb") as fh:
        fh.write(body.encode("utf-8"))
    back = open(FPRJ, "rb").read().decode("utf-8")
    check(TITLE in back and 'DeviceType="11"' in back and "dotui.lua" in back,
          "fprj 写好（UTF-8, DeviceType=11, 指向 dotui.lua）",
          "%d B" % len(back.encode("utf-8")))


# ------------------------------------------------------------------ ③ 编译
def compile_face():
    if not EXE:
        check(False, "compile.exe 存在", "两处都没有")
        return False
    os.makedirs(OUT_DIR, exist_ok=True)
    for p in (FACE, os.path.join(OUT_DIR, "10pro.autorun.info")):
        if os.path.exists(p):
            os.replace(p, p + ".prev")       # 不删，只让位（存量闸门/留档）
    inner = 'chcp 936 >nul && "%s" -b "%s" output "%s" %s' % (EXE, FPRJ, FACE, PKG_ID)
    r = subprocess.run(inner, shell=True, cwd=HERE,
                       creationflags=CREATE_NEW_CONSOLE, stdin=subprocess.DEVNULL)
    if not os.path.exists(FACE) or os.path.getsize(FACE) == 0:
        check(False, "compile.exe 产出 .face", "exit=%s, 没产物" % r.returncode)
        return False
    check(True, "compile.exe 产出 .face",
          "exit=%s  %d B" % (r.returncode, os.path.getsize(FACE)))
    return True


# ------------------------------------------------------------------ ④ 验容器
def verify():
    raw = open(FACE, "rb").read()
    check(raw[:4] == b"\x5a\xa5\x34\x12", "容器魔数 5a a5 34 12", raw[:4].hex())

    # ★ 头部两个身份字段（FACE.md §3.4）：0x28 是 compile.exe 写死的常量、**不由我们控制**；
    #   0x68 才由 fprj 的 Title 决定 —— 这是本链路里唯一可控的区分字段。
    #   这两条钉住"我们知道哪个字段可控"，将来 compile.exe 换版就会被咬住。
    check(raw[0x28:0x34] == b"167210065\x00\x00\x00",
          "头部 0x28 = compile.exe 常量 \"167210065\"",
          raw[0x28:0x34].hex())
    disp = raw[0x68:0x88].split(b"\x00")[0].decode("utf-8", "replace")
    check(disp == TITLE, "头部 0x68 显示名 == fprj Title", repr(disp))

    rec_off = 0x100
    hdr = struct.unpack_from("<4I", raw, rec_off)
    check(hdr[0] == 0 and hdr[3] == 0x10, "记录表首条形状 (0,0,tail,0x10)",
          "%08x %08x %08x %08x" % hdr)

    files, off, i = {}, rec_off + 16, 0
    while i < 256:                            # 有界：找不到终止记录就停，不要跑飞
        uid, zero, foff, fsize = struct.unpack_from("<4I", raw, off)
        # ★ 终止记录判据: off==0 且 len==0。**不要**按 uid 判（见文件头注释）
        if foff == 0 and fsize == 0:
            check(off == hdr[2], "终止记录落在首条记的 tail 地址上",
                  "%#x vs %#x" % (off, hdr[2]))
            break
        packed, = struct.unpack_from("<I", raw, foff)
        plen, dlen = packed >> 24, packed & 0xFFFFFF
        path = raw[foff + 20:foff + 20 + plen].decode("ascii")
        files[path] = raw[foff + 20 + plen:foff + 20 + plen + dlen]
        check(fsize == 20 + plen + dlen, "slot %d 记录长度自洽" % i, path)
        off += 16
        i += 1

    check(len(files) == len(WANT), "容器内文件条数 = %d" % len(WANT),
          "%d 条: %s" % (len(files), ", ".join(sorted(files))))
    for path, src in WANT.items():
        if path not in files:
            check(False, "容器里有 %s" % path, "缺")
            continue
        a, b = md5b(files[path]), md5f(src)
        check(a == b, "容器内 %s 逐字节 == 源" % path,
              "%d B  %s" % (len(files[path]), a))

    # ★ 判据读**容器里那份** lua（要证明"进了包"，不是"源码里有"）
    lua = files.get("_lua/_Lua/dotui.lua", b"")
    check_lua_symbols(lua.decode("utf-8", "replace"), "包")

# ------------------------------------------------------------------ ④ 静态符号判据
# ★ 抽成函数是为了**两处都跑**：--check 时跑源、验容器时跑包里那份。
#   （包里那份已经过了 md5 逐字节比对，两处结果必然一样 —— 但 --check 要能**不装
#     compile.exe 就立刻**回答"符号在不在"，否则每次改一行 lua 都得先编译一遍。）
# ★ 一律用 str 比（不是 bytes）—— 判据里有中文，bytes 字面量在 Python 3 里根本写不出来。
def check_lua_symbols(lua_text, where):
    WANT_LUA = [
        # --- 落点 / 路径（只有一个落点：/data/rc.d/autorun.json）---
        ('local RC_DIR    = "/data/rc.d"', "注册目录（新目录，不是 /data/rc）"),
        ('local RC_PATH   = "/data/rc"', "产物就是开机 rc（flash hook 那句跑的就是它）"),
        ('local CFG_FILE  = "autorun.json"', "配置文件名（后缀故意不是 .sh，不会被当模块）"),
        ('local CFG_PATH  = RC_DIR .. "/" .. CFG_FILE', "配置就在注册目录里（只有一个落点）"),
        ("local CFG_OK    = false", "配置读写是否正常（false 时拒绝重建）"),
        ('local GEN_LINE  = "sh " .. RC_DIR .. "/"', "生成区行前缀（别人不会有）"),
        ('local DATA_DIR  = "/data/10pro.autorun"',
         "管理器**自己的落点**（独立项目，不借 chaos 的目录）"),
        # --- 生成区：不变量 1/3/5 + 闸 ---
        ('local GATE      = RC_DIR .. "/.autorun.on"',
         "闸 = 一个文件在不在（既是用户总开关、又是开机链的防砖凭证）"),
        ('local IF_LINE   = "if [ -f " .. GATE .. " ];then', "闸那一层唯一的门（只一层 if）"),
        ('local FI_LINE   = "fi"', "收尾那一行"),
        ('local SLEEP_LINE = "sleep 1"', "两个模块行之间那一秒（不变量 5：串行）"),
        # --- ★ 闸的运行时（2026-10-04 新方案）：扣/放 + 两个窗口 + 心跳日志，全归 /data/rc ---
        ('local AS_LOG     = RC_DIR .. "/.autorun.log"',
         "心跳日志（/data/rc 写；本页**只读不写**）"),
        ('local HB_LINE    = "echo gate_off >> " .. AS_LOG',
         "心跳：写在 if **外面**（闸关着也留痕）"),
        ('local CLEAR_LINE = "echo cleared >> " .. AS_LOG',
         "只有跑到底才写它（缺席 = 上次被打断的唯一证据）"),
        ('local RM_GATE    = "rm -f " .. GATE', "扣闸（必须排在模块行之前）"),
        ('local ON_GATE    = "echo on > " .. GATE', "放行（必须在 sleep 15 之后）"),
        ('local SLEEP_PRE  = "sleep 8"', "窗口 1：扣闸之后、跑模块之前"),
        ('local SLEEP_POST = "sleep 15"', "窗口 2：全部跑完之后、放行之前"),
        ("local function log_last", "心跳日志末行 ⇒ 判「上次有没有跑到底」"),
        ("local function split_others", "别人的行逐行原样摘出来（不变量 1）"),
        ("local function build_rc", "生成 /data/rc"),
        ("local function rc_state", "状态行数别人的行（复用 split_others，否则状态说谎）"),
        ("local function rc_present_by_ls",
         "读不出来时用 `ls /data` 判它到底在不在（不在 -> 当成空的并建出来）"),
        ("local function refs_from_rc",
         "「缺脚本」的唯一来源：/data/rc 里的生成行引用（配置登记不算）"),
        ("local function merge(slices, refs, policy)",
         "列表来源 = rc.d 的 .sh ∪ /data/rc 的生成行；配置**不决定显示**"),
        ("local function gate_on", "读闸"),
        ("local function ensure_gate",
         "老设备迁移才补建闸；用户关过 / 闸已被开机脚本扣住(心跳末行 gate_off) 都**不补**"),
        ("local function set_gate", "闸 开/关（关 = 只删文件，一个字节都不碰 rc）"),
        ("if cur == body then", "幂等：内容没变不写盘（不变量 2）"),
        # --- 配置 / 策略 ---
        ("local function ensure_config", "确保配置在：没有就创建，建不出来退兜底"),
        ("local function merge", "切片 ∪ 策略"),
        ("local function do_rebuild", "重建启动（唯一会写 /data/rc 的入口之一）"),
        ("local function rc_pending", "「● 待重建」是算出来的，不存状态"),
        ("local function toggle_mod", "单项允许/禁止（只改策略，不写 rc）"),
        ("local function set_all", "全部启用 / 全部禁止"),
        # --- JSON（运行时没有 JSON 库）---
        ("local function json_parse", "自带 JSON 解析"),
        ("local function json_escape", "自带 JSON 转义"),
        ("JSON_UNESC", "解码表与编码表分开（否则转义滚雪球）"),
        ('if #ks == 0 then return "{}" end', "空表写成 {} 而不是 []"),
        ('m.core then st_text, st_color = "\u6838\u5fc3"', "core 行显示「核心」"),
        # --- 文本裁剪 / 日志（主页铺满下屏那个框）---
        ("local function one_line(", "按字符边界截断（中文不能切一半）"),
        ("local function one_line_w(", "按像素宽度截断 ⇒ 日志一条一行不折行"),
        ("tail_lines = function(n)", "取最近 n 条"),
        ("local function tail_list(n)", "最近 n 条（按行返回，供面板拼接）"),
        ("local function log_mini(color)", "主页小窗（纯日志）+ 自启动页面板（状态 + 日志）"),
        # --- 两个小窗：行数**按各自框高算** ⇒ 铺到框底（2026-10-04 用户要求）---
        ("local MINI_PAD        = 8", "小窗内边距（与 make_mini_box 里同一个值）"),
        ("local MINI_LINE_H     = 20", "字号 14 的行距（保守估，宁可底部留缝也别切行）"),
        ("local MINI_BOX_H_MAIN = 214", "主页日志框高（行数由它推出来）"),
        ("local MINI_BOX_H_AS   = 290", "自启动页日志框高（行数由它推出来）"),
        ("local function mini_lines_of(h)", "行数 = (框高 − 2×pad) / 行距（只写一份）"),
        # --- 自启动页那块**状态面板**（照 shellpp2 的自启动页）---
        ("local function as_status_lines",
         "状态摘要：启动判定(闸×心跳) / 心跳 / 是否安装 / 模块装了几个·会跑几个"),
        ("local function as_box_text", "面板内容 = 状态 + 分隔 + 日志（总行数 == 框能放的行数）"),
        ("function refresh_as_state", "面板只在明确时刻刷（含一次 flash 只读探测）"),
        ("local refresh_as_state",
         "★ 前向声明：set_gate/do_init_* 在它**定义之前**就调它（写成 local function 会静默失效）"),
        # --- flash hook：自启动页 [1 安装] / [2 卸载] ---
        ("local ORIG_HEX = ([[", "内置原块（65,536 个 hex 字符，原样搬）"),
        ("local FLASH_CAND = {", "三候选 设备/偏移 表"),
        ("local function flash_adler", "独立复算 adler32（不信嘴里说的）"),
        ("local function flash_probe", "只读探测三候选（第一下只报状态）"),
        ("local function flash_gate", "四道门：固件版本 + 载荷自检"),
        ("local function hook_install", "写 AP 分区里那句开机钩子"),
        ("local function hook_restore", "逐字节还原回原块"),
        ("local function do_init_install", "自启动页 [1 安装]（文件那半 + hook 那半）"),
        ("local function do_init_remove", "自启动页 [2 卸载]"),
        ("armed = \"\"", "两段式闸门状态位存在（唯一会刷砖的能力必须二次确认）"),
        # --- UI：四页 ---
        ("local function make_page()", "页面工厂（y_ofs=PAGE_HIDE 藏页）"),
        ("local main_page      = make_page()", "主页"),
        ("local autostart_page = make_page()", "自启动页"),
        ("local modules_page   = make_page()", "模块管理页"),
        ("local log_page       = make_page()", "日志页"),
        ("local function show_autostart", "自启动页入口"),
        ("local function make_button(parent,", "按钮工厂接父页（上一版写死 main_page ⇒ 挂不上）"),
        ("local function make_mini_box(parent,", "「铺满下屏」的日志小窗"),
        ("local ROW_POOL      = 12", "预建行数 = 能显示的模块上限"),
        ("mod_list_top = function()", "模块列表滚回顶部"),
        ('make_bar_button("全部启用"', "模块页功能键 1"),
        ('make_bar_button("重建"', "模块页功能键 2"),
        ('make_bar_button("全部禁止"', "模块页功能键 3"),
        ("add_flag(lvgl.FLAG.SCROLLABLE)", "模块列表可滚 ⇒ 就是用户要的「滚动翻页」"),
    ]
    for need, what in WANT_LUA:
        check(need in lua_text, "[%s] lua 里 %-50s（%s）" % (where, need, what))

    # ★ 反向判据：这几样**不许**出现 —— 管理器是纯文件操作（除了自启动页那唯一的 hook 装卸）。
    #   判的是**代码**不是散文：先剥掉整行注释再判，否则"解释为什么删掉 接管"这种头部
    #   注释会被误咬（而且会逼着人把有用的说明删掉）。
    code = "\n".join(ln for ln in lua_text.split("\n")
                     if not ln.strip().startswith("--"))
    NOT_WANT = [
        # 已删掉的功能（2026-10-04 按用户要求）
        ("do_adopt", "接管（两段式搬别人的行）整个删掉了"),
        ("PER_PAGE", "分页常量没了（改成滚动）"),
        ("page_no", "页码没了（滚动之后 行号 == 模块下标）"),
        ("prev_btn", "「上一页」键没了"),
        ("next_btn", "「下一页」键没了"),
        ("update_page_label", "页码标签没了"),
        ("sync_rc_auto", "不自动重建：打开表盘**不许**写 /data/rc（不变量 4）"),
        # 结构上不该有
        ("insmod", "不自己 insmod（只生成 rc，让 rc 去 insmod）"),
        ("CFG_HOW", "配置只有一个落点，没有「落点状态」那套"),
        ("FALLBACK", "没有兜底路径（一个落点，失败就明说失败）"),
        ("data/files", "不含 quickapp 沙箱路径（那条线已整个去掉）"),
        ("legacy.sh", "没有兼容层脚本（新标准：只认 /data/rc.d/*.sh）"),
        # ★ 2026-10-04 用户明确"管理器是独立项目" ⇒ 自己的日志/临时件不许落在
        #   chaos 的目录里。判的是**代码**（注释已剥）：段内那条"落在 /data/chaos/apblk.bin"
        #   是逐字节搬来的过时注释，**改不得**（改一个字符 PORT-FLASH 就 FAIL），
        #   所以它留在注释里、不参与这条判据。
        ("/data/chaos", "自己的东西不许落在 chaos 的目录里（独立项目）"),
        # ★ 心跳日志（/data/rc 写的）本页**只读不写**：一写就把"连着两行 gate_off =
        #   上次被打断"弄脏，日志也不再是"开机链的证词"。判的是代码（注释已剥）。
        ("write_file(AS_LOG", "心跳日志只读不写（只准 /data/rc 往里追加）"),
        ("io.open(AS_LOG", "心跳日志只读不写（同上）"),
    ]
    for bad, what in NOT_WANT:
        check(bad not in code, "[%s] 代码里**没有** %-16s（%s）" % (where, bad, what))

    # ★ 反-反向：flash 那几样**必须**在（2026-10-04 起它合法进包了 —— 上一版这里是
    #   `not in`，现在是唯一能刷砖的能力，判据要反过来钉住）。
    for need, what in (("rcS", "AP 里那句钩子所在的 inode"),
                       ("/dev/", "直接开块设备"),
                       ("FLASH_BS", "块几何")):
        check(need in code, "[%s] 代码里**有** %s（%s）" % (where, need, what))

    # ★ 反向 UI 文案：这几条路由已经不存在，不许再出现在 lua 里（注释已剥掉）。
    for gone in ("5  模块管理", "6  日志", "3  全部允许", "4  全部禁止"):
        check(gone not in code, "[%s] 文案里**没有** %-10s（旧主页的键位）" % (where, gone))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只静态自检，不调 compile.exe")
    args = ap.parse_args()

    print("== ① 源 ==")
    check(os.path.exists(LUA_SRC), "dotui.lua 在", LUA_SRC)
    if not os.path.exists(LUA_SRC):
        return 2
    print("     %d B  md5 %s" % (os.path.getsize(LUA_SRC), md5f(LUA_SRC)))

    print("== ①b 静态符号（源）==")
    with open(LUA_SRC, "rb") as fh:
        src_text = fh.read().replace(b"\r\n", b"\n").decode("utf-8", "replace")
    check(b"\r\n" not in open(LUA_SRC, "rb").read(), "源是 LF（CRLF 会让逐字节比对假失败）")
    check_lua_symbols(src_text, "源")

    print("== ② 预览图 + fprj ==")
    draw_preview()
    write_fprj()

    print("== ③ flash 移植门 ==")
    port = os.path.join(HERE, "tools", "_port_flash_to_manager.py")
    rp = subprocess.run([sys.executable, port], capture_output=True, text=True)
    ptail = [x for x in rp.stdout.strip().split("\n") if x.strip()][-1:]
    check(rp.returncode == 0, "flash 段与源**逐字节**相同 PORT-FLASH 通过",
          (ptail or [""])[0])

    print("== ④ 离线门 ==")
    sim = os.path.join(HERE, "tools", "_sim_manager.py")
    py = sys.executable
    r = subprocess.run([py, sim], capture_output=True, text=True)
    tail = [x for x in r.stdout.strip().split("\n") if x.strip()][-1:]
    check(r.returncode == 0, "离线门 SIM-MANAGER 通过", (tail or [""])[0])

    if args.check:
        print()
        if FAILS:
            print("BUILD-MANAGER: FAIL (%d/%d)  [--check]" % (len(FAILS), NCHK[0]))
            return 2
        print("BUILD-MANAGER: PASS (%d)  [--check]" % NCHK[0])
        return 0

    print("== ⑤ compile.exe ==")
    if not compile_face():
        print("\nBUILD-MANAGER: FAIL (%d/%d)" % (len(FAILS), NCHK[0]))
        return 2

    print("== ⑥ 验容器 ==")
    verify()

    print()
    if FAILS:
        print("BUILD-MANAGER: FAIL (%d/%d)" % (len(FAILS), NCHK[0]))
        for f in FAILS:
            print("   - " + f)
        return 2
    print("BUILD-MANAGER: PASS (%d)" % NCHK[0])
    print("   %s" % FACE)
    print("   %d B  md5 %s" % (os.path.getsize(FACE), md5f(FACE)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
