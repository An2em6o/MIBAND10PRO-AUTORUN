# -*- coding: utf-8 -*-
"""行为仿真门: 用真 Lua 解释器(lupa) + 假 lvgl / 假 io / 假 os.execute,
把改造后的 Chaos 安装器**真跑一遍**, 点按钮, 然后逐字节核产物。

★ 这一版对应"新标准"(2026-10-04 定): 模块**只投文件** —— 不碰 /data/rc、不碰 flash。
  两个直接后果:
    · 假 shell 里**不再需要实现 dd**: 安装器一个 dd 都不发(dd 只作为**文本**出现在它
      生成的 chaos.sh 里, 那串文本由 C 组逐行比对);
    · 假 io.open 必须**真的**遵守"父目录不在 => 打不开" —— 否则 F 组会变成假通过。
      (write_file 不建父目录, 这正是"管理器没装"能被判出来的机制本身。)

判据(全部硬断言, 没有"跳过"):
  A 载入        —— 整个脚本 load + 执行到底不报错; 6 个按钮都在
  B 投文件      —— /data/rc.d/chaos.sh + boot.bin(16B) 落盘; **不再建任何闸**
  C chaos.sh    —— 9 行逐条比对; **反向钉死"模块脚本里不许有机制"**(无 if/fi/sleep/rm);
                   行首词白名单比旧版更窄; 每行 ≤255B; 安装时清掉旧版残留的模块闸
  D 不碰产物    —— /data/rc **一个字节没动**(连别人原有的内容也不动)
  E 幂等        —— 再点一次「安装」, 两个文件内容不变
  F 管理器没装  —— 没有 /data/rc.d => 报「管理器没装」且 **/data 一个字节都不写**
  G 删除        —— 两个文件都撤掉, /data/rc 仍未被动, 主功能文件一个不少
  H 旧版残留    —— 预置旧二跳 + /data/chaos/rc + 旧版模块闸 => 装/删都清掉, 别人的行仍在

★ 2026-10-04 第三次改（用户定的职责边界: 管理器和模块要分开）:
  模块脚本 = **纯干活**。闸(防砖)与计时(8s 前置 / 15s 安全窗)整段上移到 /data/rc,
  由管理器生成。模块里出现任何机制都算越界 —— C2/C2b/C2c 就是钉这个的。
  I 反向        —— 源码里**没有** flash / ORIG_HEX / hook_ / 二跳 这些字样
                   (写 flash 的能力已整段交给管理器, 本包不许再带)
  J 清除重置    —— rc.d 条目 + 数据目录都清掉, 别人的行仍在
"""
import os
import re
import sys

LUPA_PY = r"C:\Users\Administrator\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
INSTALLER = r"C:\zcode\chaos-autostart\Chaos-Module\installer\chaos_installer.lua"

FAILS = []
NCHK = [0]


def check(cond, label, extra=""):
    NCHK[0] += 1
    if cond:
        print("  ok   %s" % label)
    else:
        print("  FAIL %s  %s" % (label, extra))
        FAILS.append(label)


FAKE = r'''
-- ===================== 假文件系统 =====================
FS = {}
function FS.reset(t)
  -- ★ 不能把自己也抹掉: 下面那行清空 FS 里**所有**键, 包括 FS.reset 本身 ——
  --   第一次调用后就再也进不来了(踩过: F 组直接 nil call)。
  local keep = FS.reset
  for k in pairs(FS) do FS[k] = nil end
  FS.reset = keep
  for k, v in pairs(t or {}) do FS[k] = v end
end

local OBJS = {}
function OBJS_all() return OBJS end

-- 状态文案流水(每次 label:set{text=...} 都记一笔), 用来断言按钮到底报了什么。
local LABELSET = {}
function LABELSET_all() return LABELSET end
function LASTTEXT() return LABELSET[#LABELSET] or "" end

local function newobj(parent, opts)
  local o = { opts = opts or {}, label = nil, clicks = {}, children = {} }
  function o:set(t)
    for k, v in pairs(t) do self.opts[k] = v end
    if self.is_label and t.text ~= nil then LABELSET[#LABELSET + 1] = tostring(t.text) end
  end
  function o:clear_flag(_) end
  function o:add_flag(_) end
  function o:onClicked(fn) self.clicks[#self.clicks + 1] = fn end
  function o:delete() end
  function o:scroll_by_bounded() end
  if parent and parent.children then parent.children[#parent.children + 1] = o end
  OBJS[#OBJS + 1] = o
  return o
end

lvgl = {
  Object = function(p, o) return newobj(p, o) end,
  Label = function(p, o)
    local x = newobj(p, o)
    x.is_label = true
    if p then p.label = (o or {}).text end
    return x
  end,
  Font = function(n, s) return { name = n, size = s } end,
  OPA = function(v) return v end,
  HOR_RES = function() return 336 end,
  VER_RES = function() return 480 end,
  ALIGN = { CENTER = 1, TOP_LEFT = 2, TOP_MID = 3 },
  FLAG = { SCROLLABLE = "s", CLICKABLE = "c", EVENT_BUBBLE = "b" },
  Timer = function(o)
    local t = newobj(nil, o)
    function t:resume() end
    function t:ready() end
    return t
  end,
}

function require(n) if n == "lvgl" then return lvgl end error("no module " .. n) end

FWPROPS = { ["ro.build.version"] = "3.101.043" }

CMDS = {}
-- 假 shell 只实现"安装器真的会发的命令"。dd **不实现** —— 新标准下安装器一个 dd 都不发,
-- 实现了反而会把"它偷偷发了一条 dd"这种事藏起来。
-- ★ rm 必须**忠实**: 真 rm -rf <目录> 会连目录里的东西一起删。
--   少了这一点, "清除重置把数据目录清空"会被判成假失败(踩过)。
local function rm_targets(rest, rec)
  for p in rest:gmatch("%S+") do
    local star = p:match("^(.*)/%*$")
    local base = star or p
    if rec or star then
      local del = {}
      for k in pairs(FS) do
        if k == base or k:sub(1, #base + 1) == base .. "/" then del[#del + 1] = k end
      end
      for _, k in ipairs(del) do FS[k] = nil end
    else
      FS[p] = nil
    end
  end
end
os = { execute = function(c)
  CMDS[#CMDS + 1] = c
  local rmcmd = c:match("^rm%s+(.+)$")
  if rmcmd then
    local flags, rest = rmcmd:match("^(%-[%a]+)%s+(.*)$")
    if not flags then flags, rest = "", rmcmd end
    rm_targets(rest, flags:find("[rR]") ~= nil)
  end
  local mk = c:match("^mkdir %-p%s+(.+)$")
  if mk then for p in mk:gmatch("%S+") do if FS[p] == nil then FS[p] = "" end end end
  local gp, out = c:match("^getprop%s+(%S+)%s+>%s+(%S+)$")
  if gp then FS[out] = (FWPROPS[gp] or "") .. "\n" return 0 end
  local out2 = c:match("^getprop%s+>%s+(%S+)$")
  if out2 then FS[out2] = "" return 0 end
  return 0
end }
function CMDS_all() return CMDS end
-- ★ 必须用 Lua 侧拼串: 从 Python 迭代 LuaTable 拿到的是**键**(1,2,3...)不是值,
--   那样 "命令里有没有 dd" 这种判据会永远通过(踩过, 是个假阳性)。
function CMDS_join()
  local t = {}
  for i = 1, #CMDS do t[#t + 1] = CMDS[i] end
  return table.concat(t, " ;; ")
end

io = {
  open = function(path, mode)
    mode = mode or "rb"
    if mode:sub(1, 1) == "r" then
      local d = FS[path]
      if d == nil then return nil end
      local done = false
      return {
        read = function(_, _fmt) if done then return nil end done = true return d end,
        close = function() return true end,
        write = function() error("write on read handle") end,
      }
    end
    -- ★ 写: 父目录不在 => 打不开。这条**必须**实现 ——
    --   write_file 不建父目录, "管理器没装"就是靠这个判出来的。少了它 F 组会假通过。
    local parent = path:match("^(.*)/[^/]*$")
    if parent and FS[parent] == nil then return nil end
    return {
      write = function(_, s)
        if mode == "a" then FS[path] = (FS[path] or "") .. s else FS[path] = s end
        return true
      end,
      close = function() return true end,
      read = function() return "" end,
    }
  end,
}

SCRIPT_PATH = "/data/quickapp/mass/deadbeef/_lua/_Lua/"
function print(...) end
'''


def find_button(runtime, text):
    objs = runtime.eval("OBJS_all()")
    for i in range(1, len(objs) + 1):
        o = objs[i]
        if o.label == text and len(o.clicks) > 0:
            return o
    return None


SHELLPP_RC = ("set +e\nif [ -f /data/shellpp-ii/autostart.on ];then\n"
              "rm -f /data/shellpp-ii/autostart.on\n"
              "sleep 5\ninsmod /data/shellpp-ii/shellpp_ii.bin shellpp_ii\n"
              "dd if=/data/shellpp-ii/cmds.bin of=/dev/shellpp bs=16 count=1 conv=notrunc\n"
              "echo on > /data/shellpp-ii/autostart.on\nfi\n")

MAIN_FILES = {
    "/data/chaos/sup.ko": "KO",
    "/data/chaos/chaos_icon.bin": "ICON",
    "/data/chaos/font/ChaosWenKai.ttf": "TTF",
    "/data/chaos/icons/37653043/a.bin": "IPK",
}


def fresh(runtime, with_rc_dir=True, extra_rc=""):
    """装一台"干净的设备": /data + /data/chaos + 别人已装好的 /data/rc。"""
    st = {"/data": "", "/data/chaos": "", "/data/rc": SHELLPP_RC + extra_rc}
    st.update(MAIN_FILES)
    if with_rc_dir:
        st["/data/rc.d"] = ""
    runtime.execute("FS.reset(%s)" % _lua_table(st))


def _lua_table(d):
    parts = []
    for k, v in d.items():
        parts.append("[%r] = %r" % (k, v))
    return "{" + ", ".join(parts) + "}"


def fs(runtime, path):
    return runtime.eval("FS[%r]" % path)


def main():
    import lupa
    runtime = lupa.LuaRuntime(unpack_returned_tuples=True)

    runtime.execute(FAKE)
    fresh(runtime)

    src = open(INSTALLER, encoding="utf-8").read()
    loader = runtime.eval("function(s, n) local f, e = load(s, n); if f then return true end; return false, e end")
    ok = loader(src, "@chaos/chaos_installer.lua")
    check(ok is True or (isinstance(ok, tuple) and ok[0]), "A1 语法 load 通过",
          "" if ok is True else str(ok))
    if not (ok is True):
        print("\nSIM-AUTOSTART: FAIL (%d)" % len(FAILS))
        return 2

    runner = runtime.eval("function(s) local f = assert(load(s, '@run')); return f end")
    fn = runner(src)
    r = fn()
    check(r is None, "A2 执行到底(假 lvgl 下不报错)", repr(r))

    objs = runtime.eval("OBJS_all()")
    labels = [objs[i].label for i in range(1, len(objs) + 1) if objs[i].label]
    for want in ("运行", "自启动", "清除重置", "安装", "删除", "< 返回"):
        check(want in labels, "A3 按钮存在: %s" % want)
    for gone in ("装自启文件", "开自启动", "关自启动", "移除文件"):
        check(gone not in labels, "A4 旧按钮已消失: %s" % gone)

    def click(text):
        b = find_button(runtime, text)
        assert b is not None, "找不到按钮 " + text
        return b.clicks[1]()

    def last():
        return str(runtime.eval("LASTTEXT()"))

    RC_SH = "/data/rc.d/chaos.sh"
    FLAG = "/data/chaos/autostart.on"
    FRAME = "/data/chaos/boot.bin"

    # ================= B 投文件 =================
    click("安装")
    sh = fs(runtime, RC_SH)
    check(isinstance(sh, str) and len(sh) > 0, "B1 /data/rc.d/chaos.sh 已投", repr(sh)[:60])

    frame = fs(runtime, FRAME)
    want = bytes([0x31, 0x43, 0x48, 0x53, 0x33, 0x43, 0x48, 0x53] + [0] * 8)
    got = bytes(ord(c) for c in frame) if isinstance(frame, str) else bytes(frame)
    check(got == want, "B2 boot.bin = 16B '1CHS3CHS'+8x00", got.hex())

    check(fs(runtime, FLAG) is None,
          "B3 模块**没有**自己的闸了(闸归 /data/rc 那一层)")
    check(".probe" not in " ".join(str(k) for k in runtime.eval("FS").keys()),
          "B4 探测用的 .probe 没有残留")

    # ================= C chaos.sh =================
    # ★ 2026-10-04 第三次改（用户定的职责边界）: 模块脚本 = **纯干活**。
    #   判断(闸)与计时(8s 前置 / 15s 安全窗)全部归 /data/rc（管理器）。
    #   所以这里判两件事: ① 逐行对不对; ② **越界的构造一个都不许有**。
    #   为什么钉死 ②: 旧版每个模块自带一个 15s 安全窗 ⇒ N 个模块白等 N×15 秒;
    #   而自带闸则会让"管理器显示开、模块却不跑"这种不一致回来 —— 就是那次血案。
    WANT_SH = [
        "set +e",
        "echo start > /data/chaos/autostart.log",
        "insmod /data/chaos/sup.ko chaos_sup",
        "echo insmod >> /data/chaos/autostart.log",
        "dd if=/dev/chaos of=/data/chaos/stage1.bin bs=192 count=1 conv=notrunc",
        "dd if=/data/chaos/boot.bin of=/dev/chaos bs=16 count=1 conv=notrunc",
        "echo boot_cmd_sent >> /data/chaos/autostart.log",
        "dd if=/dev/chaos of=/data/chaos/stage3.bin bs=192 count=1 conv=notrunc",
        "echo done >> /data/chaos/autostart.log",
    ]
    lines = [l for l in sh.split("\n") if l.strip() != ""]
    check(lines == WANT_SH, "C1 chaos.sh 9 行逐条相同",
          "got %d 行\n    %s" % (len(lines), "\n    ".join(lines)))
    first = [l.split(" ")[0] for l in lines]
    check("if" not in first and "fi" not in first,
          "C2 模块脚本里没有 if/fi（判断归 /data/rc）", str(first))
    check("sleep" not in first,
          "C2b 模块脚本里没有 sleep（8s/15s 延时归 /data/rc）", str(first))
    check("rm" not in first,
          "C2c 模块脚本里没有 rm（闸的扣与放归 /data/rc）", str(first))
    check(not [l for l in lines if "autostart.on" in l],
          "C2d 模块脚本里不再提旧版的闸文件",
          str([l for l in lines if "autostart.on" in l]))
    # ★ 白名单比旧版**更窄**了: 只剩 set / echo(写自己的日志) / insmod / dd。
    vocab = ("set", "echo", "insmod", "dd")
    bad = [l for l in lines if l.split(" ")[0] not in vocab]
    check(not bad, "C3 行首词都在 nsh 已验子集内(比旧版更窄)", str(bad))
    check(not [l for l in lines if ("&&" in l) or ("||" in l) or ("$(" in l)],
          "C4 不含 && / || / $()")
    # ★ C4b 反向：`else` 至今没有证据。凡是"用 else 去补分支"的改法一律不许进包。
    check(not [l for l in lines if l.strip() == "else"],
          "C4b chaos.sh 里没有 else（nsh 无证据）")
    check(max(len(l) for l in lines) <= 255, "C5 每行 ≤255B",
          str(max(len(l) for l in lines)))
    check(sh.endswith("\n"), "C6 以换行收尾")
    # ★ C7 旧版残留的模块闸必须在**安装时**就清掉 —— 它对新版毫无意义,
    #   留着只会让人以为"模块还有闸", 把排查带偏(本轮就差点被它带偏)。
    cmds_text = str(runtime.eval("CMDS_join()"))
    check("rm -f /data/chaos/autostart.on" in cmds_text,
          "C7 安装时清掉旧版残留的模块闸", cmds_text[-160:])

    # ================= D 不碰产物 =================
    rc = fs(runtime, "/data/rc")
    check(rc == SHELLPP_RC, "D1 /data/rc 一个字节没动(连别人原有内容也不动)",
          repr(rc)[:80])
    check("chaos" not in str(rc), "D2 /data/rc 里没有我们添的任何字样")

    # ================= E 幂等 =================
    before = (str(fs(runtime, RC_SH)), str(fs(runtime, FRAME)))
    click("安装")
    after = (str(fs(runtime, RC_SH)), str(fs(runtime, FRAME)))
    check(before == after, "E1 再装一次两个文件内容不变")
    check(last().startswith("已投"), "E2 文案", last())

    # ================= F 管理器没装 => 报错 + 零写盘 =================
    fresh(runtime, with_rc_dir=False)
    files_before = sorted(str(k) for k in runtime.eval("FS").keys())
    click("安装")
    files_after = sorted(str(k) for k in runtime.eval("FS").keys())
    check(files_after == files_before, "F1 没有 /data/rc.d => /data 一个文件没多",
          str(set(files_after) ^ set(files_before)))
    check("管理器没装" in last(), "F2 文案明说「管理器没装」", last())
    check("/data/rc.d" in last(), "F3 文案里带上缺的是哪个目录", last())
    check(fs(runtime, RC_SH) is None, "F4 没有偷偷把脚本写到别处")
    # 补上 /data/rc.d 之后立刻就能用(不是永久状态)
    runtime.execute("FS['/data/rc.d'] = ''")
    click("安装")
    check(fs(runtime, RC_SH) is not None, "F5 补上目录后马上能装")

    # ================= H 旧版残留被清 =================
    fresh(runtime, extra_rc="sh /data/chaos/rc &\n")
    runtime.execute("FS['/data/chaos/rc'] = 'OLD'")
    runtime.execute("FS['/data/chaos/autostart.on'] = 'on\\n'")   # v1/v2 残留的模块闸
    click("安装")
    rc2 = fs(runtime, "/data/rc")
    check(rc2 == SHELLPP_RC, "H1 旧版二跳那一行已摘掉, 别人的行逐字节仍在", repr(rc2)[:80])
    check(fs(runtime, "/data/chaos/rc") is None, "H2 旧版的 /data/chaos/rc 已删")
    check(fs(runtime, FLAG) is None, "H3 旧版残留的模块闸已被清掉")

    # ================= G 删除 =================
    # 此刻是"已装"状态(上一段刚装过)
    check(fs(runtime, RC_SH) is not None, "G0 前置: 现在是已装状态")
    click("删除")
    check(fs(runtime, RC_SH) is None, "G1 rc.d/chaos.sh 已删")
    check(fs(runtime, FLAG) is None, "G2 旧版模块闸没有残留(新版本来就没建过)")
    check(fs(runtime, FRAME) is None, "G3 boot.bin 已删")
    check(fs(runtime, "/data/rc") == SHELLPP_RC, "G4 /data/rc 仍未被动(那行归管理器)")
    check("管理器" in last(), "G5 文案提醒要去管理器重建", last())
    for p in MAIN_FILES:
        check(fs(runtime, p) is not None, "G6 主功能文件未动: %s" % p)

    # ================= J 清除重置 =================
    click("安装")
    check(fs(runtime, RC_SH) is not None, "J0 前置: 重新装好")
    click("清除重置")
    click("清除重置")
    check(fs(runtime, RC_SH) is None, "J1 rc.d 条目已清")
    check(fs(runtime, "/data/chaos") is None, "J2 数据目录已清")
    check(fs(runtime, "/data/rc") == SHELLPP_RC, "J3 别人的行仍在")
    for p in MAIN_FILES:
        check(fs(runtime, p) is None, "J4 主功能文件随目录一起清掉: %s" % p)

    # ================= I 反向: 能力已交管理器 =================
    for bad in ("ORIG_HEX", "FLASH_BS", "flash_probe", "hook_install", "hook_restore",
                "as_armed", "AS_BTN", "io.open(RC_PATH"):
        check(bad not in src, "I1 源码里没有 %s" % bad)
    # 判**代码**不判散文: 先剥掉整行注释 —— 头部那段"老做法是什么"的说明里就写着二跳原文,
    # 不剥的话判据会逼着人把有用的说明删掉(管理器的门踩过同一个坑)。
    code = "\n".join(l for l in src.split("\n") if not l.strip().startswith("--"))
    check(code.count("sh /data/chaos/rc &") == 1,
          "I2 代码里二跳字样只剩 1 处(LEGACY_HOP, 只用于清残留)",
          str(code.count("sh /data/chaos/rc &")))
    cmds = str(runtime.eval("CMDS_join()"))
    check("dd " not in cmds, "I3 安装器一条 dd 都没发过(dd 只作为文本在 chaos.sh 里)",
          cmds[-120:])
    check("mkfs" not in src and "mtd" not in src, "I4 不含裸块设备工具")

    print()
    print("--- 投出去的 /data/rc.d/chaos.sh (%d B) ---" % len(sh.encode("utf-8")))
    print(sh, end="")
    print("--- /data/chaos/boot.bin (16 B) ---")
    print(" ".join("%02x" % b for b in got))
    print("--- 安装器发过的命令 (%d 条) ---" % len(runtime.eval("CMDS_all()")))
    print(str(runtime.eval("CMDS_join()")))
    print()
    if FAILS:
        print("SIM-AUTOSTART: FAIL (%d/%d)" % (len(FAILS), NCHK[0]))
        for f in FAILS:
            print("   - " + f)
        return 2
    print("SIM-AUTOSTART: PASS (%d)" % NCHK[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
