# -*- coding: utf-8 -*-
"""行为仿真门: 用真 Lua 解释器(lupa) + 假 lvgl / 假 io / 假 os.execute + **假文件系统**,
把 10pro.autorun 管理器**真跑一遍**, 点按钮, 然后逐字节核 /data/rc 与配置文件。

★ 这个门必须**真的**实现 ls / rm / mkdir: 管理器全靠 os.execute 落盘与列目录,
  如果假 shell 只记命令不落地, "第一次按不该动盘"这类判据会被误报成通过(假阳性)。

判据:
  A 载入      —— 整个脚本 load + 执行到底; 四页 + 主页 4 键 + 自启动页 4 键 +
                 模块页 3 个功能键 + ROW_POOL 个模块行都在; 删掉的旧键一个都不在
  B 配置路径  —— **配置就在注册目录里** /data/rc.d/autorun.json（只有一个落点，没有兜底）;
                 没有就创建(含建目录); 已存在不重写; `autorun.json` 不被当成模块;
                 **建不出来 -> 拒绝重建**且 /data/rc 一字节不动
  C 合并且登记—— rc.d 切片 ∪ 策略; 新切片自动补登记并**回写**; 已有策略不被默认值覆盖
  D 重建 rc   —— 别人的行原样在前; 生成区 = **心跳**(echo gate_off >> .autorun.log, 在 if 外面)
                 + 门(if) + **扣闸**(rm -f .autorun.on) + sleep 8 + 模块行(**不带 &**,
                 行间 sleep 1) + sleep 15 + **cleared** + **放行**(echo on > .autorun.on) + fi;
                 禁止的**不出现**; 首行 set +e; 且只有**一层 if**（nsh 没验过嵌套）
  E 幂等      —— 内容没变时**一个字节都不写盘**
  F 批量开关  —— 模块页 全部启用/全部禁止, 但 core 模块不动
  G 单项开关  —— core 拒绝; 缺脚本拒绝(标"缺脚本"且不进 rc)
  H 总开关    —— [4 关闭] 只删闸文件、**不写** /data/rc; [3 开启] 建回来并重建;
                 rc 里还没有门的老设备按 [1] 会**自动补建**闸(默认开) + 关着时有警告
  I JSON      —— 与 Python json 互校: 中文/引号/反斜杠/emoji/代理对, 往返一致不滚雪球
  K 不自动重建—— 重开管理器、零按钮时 /data/rc **一字节不写**;
                 但必须提示「●待重建」并说明按哪个键; 改开关也不落盘; 按 [1] 才落;
                 坏配置留底 .bad; 以及反向静态判据(删掉的自动重建/接管不许回来)
  L init rc   —— **假 flash**: 三个候选块真读真写。两段式(第一下零改动)、
                 写后回读==载荷、还原回读==原块、邻居 adler 不变、认不出块就不写
  M/P 日志小窗—— 两个框各按自己的高度铺到框底(9/13 行), 都跟着最新一条;
                 自启动页那块 = 状态面板(开关/心跳/安装/模块/rc/配置/重载) + 日志;
                 「是否安装」只能来自 flash, 且面板**不许**跟 log_append 刷新(否则每写
                 一行日志就 dd 6 次)。
  N 三态+落点 —— /data/rc 不存在 -> **建出来**；读不出来 -> **拒绝重建**（一字节不写）;
                 日志只落 /data/10pro.autorun/manager.log，**一个字节都不落 /data/chaos**
  O 列表来源  —— 模块页条目 = rc.d 的 .sh ∪ /data/rc 的生成行；配置**不决定显示**。
                 两处都空 -> 一条不显示（并说清为什么空）；缺脚本只在「rc 有行、文件不在」
                 时出现；按 [重建] 删掉多余行、那条随即消失；配置不留陈年条目
  R 闸的信任  —— [4 关闭] 之后"禁->重建->启->重建"**不许**把闸自己开回来;
                 ★ 心跳末行 gate_off(= 上次没跑到底) 时 [重建] **不补建**闸 —— 防砖
                 不许被绕过, 恢复只走明确动作 [3 开启]/[1 安装]; 但没有心跳日志的
                 老设备/新设备照旧补建(不许修过头)
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# ★ flash 段的原块/载荷**推导规则只有一份**（在移植器里）—— 这里 import 它,
#   用它算出来的 ORIG/PAY 去核对"管理器真的往假 flash 里写了什么"。
import _port_flash_to_manager as pf          # noqa: E402

LUPA_PY = r"C:\Users\Administrator\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
MGR = r"C:\zcode\chaos-autostart\manager\app\_lua\_Lua\dotui.lua"

FAILS = []
NCHK = [0]


def check(cond, label, extra=""):
    NCHK[0] += 1
    if cond:
        print("  ok   %s" % label)
    else:
        print("  FAIL %s  %s" % (label, extra))
        FAILS.append(label)


# ============================================================================
# 假环境（Lua 侧）
# ============================================================================
FAKE = r'''
-- ===================== 假文件系统 =====================
FS = {}
WCOUNT = {}          -- path -> 写入次数（用来判"幂等: 没变就不写盘"）
BLOCK = {}           -- 路径前缀 -> true 时该前缀下**写入一律失败**（模拟"建不出来"）
UNREAD = {}          -- 路径 -> true 时"文件在（ls 列得出来）但读不出来"
                     --   ★ 用来测那条**必须拒绝重建**的分支：io.open 读失败时
                     --     分不清"不在"和"在但打不开"，而两者处置完全相反。
function UNREAD_set(p) UNREAD[p] = true end
function FS_reset(t)
  for k in pairs(FS) do FS[k] = nil end
  for k in pairs(WCOUNT) do WCOUNT[k] = nil end
  for k in pairs(UNREAD) do UNREAD[k] = nil end
  for k, v in pairs(t or {}) do FS[k] = v end
  DEV_reset()                    -- 假 flash 也要一起清（它是"设备"，不是"磁盘"）
  for i = #DDLOG, 1, -1 do DDLOG[i] = nil end
end
function FS_keys()
  local a = {}
  for k in pairs(FS) do a[#a + 1] = k end
  table.sort(a)
  return table.concat(a, "\n")
end

-- ===================== 假 lvgl =====================
OBJS = {}
LABELSET = {}
function LABELSET_all() return LABELSET end
function LASTTEXT() return LABELSET[#LABELSET] or "" end
function OBJS_all() return OBJS end

local function newobj(parent, opts)
  local o = { opts = opts or {}, clicks = {}, kids = {}, parent = parent, is_label = false }
  function o:set(t)
    for k, v in pairs(t) do self.opts[k] = v end
    if self.is_label and t.text ~= nil then
      self.label = tostring(t.text)
      LABELSET[#LABELSET + 1] = tostring(t.text)
    end
  end
  function o:clear_flag(_) end
  function o:add_flag(f) self.flags = self.flags or {} self.flags[f] = true end
  function o:onClicked(fn) self.clicks[#self.clicks + 1] = fn end
  function o:delete() end
  function o:scroll_by_bounded() end
  if parent and parent.kids then parent.kids[#parent.kids + 1] = o end
  OBJS[#OBJS + 1] = o
  return o
end

lvgl = {
  Object = function(p, o) return newobj(p, o) end,
  Label = function(p, o)
    local x = newobj(p, o)
    x.is_label = true
    x.label = (o and o.text) and tostring(o.text) or ""
    return x
  end,
  Font = function(name, size) return { name = name, size = size } end,
  OPA = function(v) return v end,
  HOR_RES = function() return 336 end,
  VER_RES = function() return 480 end,
  ALIGN = { CENTER = 1, TOP_LEFT = 2, TOP_MID = 3, RIGHT_MID = 4 },
  FLAG = { SCROLLABLE = "s", CLICKABLE = "c", EVENT_BUBBLE = "b" },
}

function require(n) if n == "lvgl" then return lvgl end error("no module " .. n) end

-- ===================== 假 shell =====================
-- ★ 真实现 ls / rm / mkdir: 管理器全靠 os.execute 列目录与落盘。
CMDS = {}
function CMDS_all() return CMDS end

-- ===================== 假 flash(块级) =====================
-- ★ 只按 32KB 块建模: DEV[dev][块起始字节] = 32KB 字符串。
--   管理器读/写 flash 只有两种形态(dd bs=32768 skip=/seek=), 正好够。
-- ★ 为什么比对必须在 **Lua 侧**做: lupa 把 Lua 字符串按 UTF-8 解回 Python str,
--   而 flash 里的字节根本不是 UTF-8 ⇒ 传回 Python 会抛 UnicodeDecodeError。
--   所以对外只给两种 ASCII 视图: DEV_hex(逐字节的 hex) 与 DEV_adler(校验和)。
DEV = {}
FWV = nil                      -- 非 nil 时 getprop 能读到这个版本号
DDLOG = {}
function DEV_set(dev, off, blk) DEV[dev] = DEV[dev] or {} DEV[dev][off] = blk end
function DEV_get(dev, off) local t = DEV[dev] if not t then return nil end return t[off] end
function DEV_seed_hex(dev, off, hx)
  DEV_set(dev, off, (hx:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end)))
end
function DEV_hex(dev, off)
  local t = DEV_get(dev, off)
  if not t then return "" end
  local o = {}
  for i = 1, #t do o[#o + 1] = string.format("%02x", t:byte(i)) end
  return table.concat(o)
end
function DEV_adler(dev, off)
  local t = DEV_get(dev, off)
  if not t then return "----" end
  local a, b = 1, 0
  for i = 1, #t do a = (a + t:byte(i)) % 65521 b = (b + a) % 65521 end
  return string.format("%08X", b * 65536 + a)
end
function DEV_map()
  local a = {}
  for d, t in pairs(DEV) do for off in pairs(t) do a[#a + 1] = d .. "@" .. off end end
  table.sort(a)
  return table.concat(a, "\n")
end
function DEV_reset() for k in pairs(DEV) do DEV[k] = nil end end
function DD_join() return table.concat(DDLOG, " ;; ") end
function DD_count() return #DDLOG end

os = { execute = function(c)
  CMDS[#CMDS + 1] = c

  -- ls <dir> > <out>
  local dir, out = c:match("^ls%s+(%S+)%s+>%s+(%S+)$")
  if dir then
    local pre = dir .. "/"
    local seen = {}
    for k in pairs(FS) do
      if k:sub(1, #pre) == pre then
        local rest = k:sub(#pre + 1)
        local n = rest:match("^([^/]+)")
        if n then seen[n] = true end
      end
    end
    local a = {}
    for n in pairs(seen) do a[#a + 1] = n end
    table.sort(a)
    FS[out] = (#a > 0) and (table.concat(a, "\n") .. "\n") or ""
    return 0
  end
  local d2 = c:match("^ls%s+(%S+)$")
  if d2 then return 0 end

  -- rm -f <paths...>
  local rm = c:match("^rm%s+%-[%a]*f[%a]*%s+(.+)$")
  if rm then
    for p in rm:gmatch("%S+") do FS[p] = nil end
    return 0
  end

  -- mkdir -p <paths...>
  local mk = c:match("^mkdir%s+%-p%s+(.+)$")
  if mk then
    for p in mk:gmatch("%S+") do
      if FS[p] == nil then FS[p] = "" end
      -- 连带把所有父目录也建出来（真实 mkdir -p 的语义）
      local acc = ""
      for seg in p:gmatch("[^/]+") do
        acc = acc .. "/" .. seg
        if FS[acc] == nil then FS[acc] = "" end
      end
    end
    return 0
  end
  -- getprop <prop> > <out>   （flash_fw_code 用它读固件版本）
  -- ★ 这个模式只有**一个**捕获组（输出路径）。写成 `local gp, gout = c:match(...)`
  --   会让 gout 永远是 nil，整个分支静默不执行 —— 这就是"flash 门永远过不了"的原因。
  local gout = c:match("^getprop%s+%S+%s+>%s+(%S+)$")
  if gout then
    if FWV then FS[gout] = FWV .. "\n" end      -- 读不到就不落文件（真实 getprop 失败）
    return 0
  end

  -- dd if=A of=B bs=N [skip=K] [seek=K] count=1 [conv=notrunc]
  -- ★ 读 /dev/* 走 DEV 表；写 /dev/* 覆盖 DEV 的那一块。读不到就什么都不产出
  --   （真实 dd 读不到也会失败 —— 这里"失败"必须表现为"目标文件不出现"）。
  if c:match("^dd%s") then
    DDLOG[#DDLOG + 1] = c
    local isrc, odst = c:match("if=(%S+)"), c:match("of=(%S+)")
    local bs = tonumber(c:match("bs=(%d+)")) or 512
    local skip = tonumber(c:match("skip=(%d+)")) or 0
    local seek = tonumber(c:match("seek=(%d+)")) or 0
    if not (isrc and odst) then return 0 end
    local data
    if isrc:sub(1, 5) == "/dev/" then data = DEV_get(isrc, skip * bs)
    else data = FS[isrc] end
    if data == nil or #data ~= bs then return 0 end
    if odst:sub(1, 5) == "/dev/" then DEV_set(odst, seek * bs, data)
    else FS[odst] = data end
    return 0
  end

  return 0
end }

-- ===================== 假 io =====================
io = {
  open = function(path, mode)
    mode = mode or "rb"
    if mode:sub(1, 1) == "r" then
      local d = FS[path]
      -- ★ UNREAD: "文件在但打不开" —— 键还在 FS 里（所以 ls 列得出来），但读失败。
      if d == nil or UNREAD[path] then return nil end
      local done = false
      return {
        read = function(_, _fmt) if done then return nil end done = true return d end,
        close = function() return true end,
        write = function() error("write on read handle") end,
      }
    end
    return {
      write = function(_, s)
        for p in pairs(BLOCK) do
          if path:sub(1, #p) == p then return nil end    -- 模拟"这个路径写不进去"
        end
        if mode:sub(1, 1) == "a" then FS[path] = (FS[path] or "") .. s
        else FS[path] = s end
        WCOUNT[path] = (WCOUNT[path] or 0) + 1
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

# ============================================================================
# 测试侧的小工具（Lua 侧：造 JSON / 读 WCOUNT）
# ============================================================================
TOOLS = r'''
function FSpath(p) return FS[p] end
function W(p) return WCOUNT[p] or 0 end
function FShas(p) return FS[p] ~= nil end
function SET(p, v) FS[p] = v end
function UNSET(p) FS[p] = nil end

-- 直接调引擎里的 JSON（dotui.lua 里的 json_encode / json_decode 都是 local，
-- 拿不到；所以这里用"落盘再读回"的方式间接验 —— 见 I 组）
function JSONPROBE(text)
  SET("/data/10pro.autorun/.probe.json", text)
end
function JSONOUT() return FS["/data/10pro.autorun/.probe.json"] or "" end
'''

# 一条"别人的" rc: 模拟上位平台已经装好的自启链
OTHERS_RC = ("set +e\n"
             "if [ -f /data/shellpp-ii/autostart.on ];then\n"
             "rm -f /data/shellpp-ii/autostart.on\n"
             "sleep 5\n"
             "insmod /data/shellpp-ii/shellpp_ii.bin shellpp_ii\n"
             "echo on > /data/shellpp-ii/autostart.on\n"
             "fi\n")


def main():
    import lupa
    runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = runtime.globals()
    runtime.execute(FAKE)
    runtime.execute(TOOLS)

    src = open(MGR, encoding="utf-8").read()

    loader = runtime.eval(
        "function(s, n) local f, e = load(s, n); if f then return true end; return false, e end")
    ok = loader(src, "@manager/dotui.lua")
    check(ok is True or (isinstance(ok, tuple) and ok[0]), "A1 语法 load 通过",
          "" if ok is True else str(ok))
    if ok is not True:
        print("\nSIM-MANAGER: FAIL (%d)" % len(FAILS))
        return 2

    # ---------- 预置场景 ----------
    runtime.execute("FS_reset()")
    runtime.execute("SET('/data/rc', %r)" % OTHERS_RC)
    runtime.execute("SET('/data/rc.d/chaos.sh', 'sh /data/chaos/rc &\\n')")
    runtime.execute("SET('/data/rc.d/shellpp2.sh', 'sh /data/shellpp-ii/rc &\\n')")
    runtime.execute("SET('/data/rc.d/autorun.json', "
                    "'{\\n  \"version\": 1,\\n  \"modules\": {\\n"
                    "    \"shellpp2\": {\\n      \"enable\": false,\\n      \"order\": 20\\n    }\\n"
                    "  }\\n}\\n')")

    runner = runtime.eval("function(s) local f = assert(load(s, '@run')); return f end")
    fn = runner(src)
    r = fn()
    check(r is None, "A2 执行到底(假 lvgl 下不报错)", repr(r))

    objs = runtime.eval("OBJS_all()")
    n = len(objs)

    def kids_text(o):
        out = []
        for i in range(1, len(o.kids) + 1):
            k = o.kids[i]
            if k.is_label:
                out.append(str(k.label))
        return out

    all_labels = []
    for i in range(1, n + 1):
        o = objs[i]
        if getattr(o, "is_label", False):
            all_labels.append(str(o.label))

    # ★ 行池/小窗行数不从测试里 hardcode —— 从**源**里读常量，两边一起漂。
    #   小窗行数更不是写死的：它由**框高**决定（(h − 2×pad) / 行距），这里按同一个式子复算。
    ROW_POOL = int(re.search(r"local ROW_POOL\s*=\s*(\d+)", src).group(1))
    MAX_UNITS = int(re.search(r"local MAX_UNITS\s*=\s*(\d+)", src).group(1))
    MINI_PAD = int(re.search(r"local MINI_PAD\s*=\s*(\d+)", src).group(1))
    MINI_LINE_H = int(re.search(r"local MINI_LINE_H\s*=\s*(\d+)", src).group(1))
    BOX_H_MAIN = int(re.search(r"local MINI_BOX_H_MAIN\s*=\s*(\d+)", src).group(1))
    BOX_H_AS = int(re.search(r"local MINI_BOX_H_AS\s*=\s*(\d+)", src).group(1))
    LINES_MAIN = (BOX_H_MAIN - MINI_PAD * 2) // MINI_LINE_H
    LINES_AS = (BOX_H_AS - MINI_PAD * 2) // MINI_LINE_H
    check(ROW_POOL >= 6 and MAX_UNITS >= 16 and LINES_MAIN >= 2 and LINES_AS > LINES_MAIN,
          "A0 行池/小窗常量合理",
          "ROW_POOL=%d MAX_UNITS=%d 主页%d行(框%d) 自启动%d行(框%d) pad=%d 行距=%d"
          % (ROW_POOL, MAX_UNITS, LINES_MAIN, BOX_H_MAIN, LINES_AS, BOX_H_AS,
             MINI_PAD, MINI_LINE_H))

    def opt(o, k, d=None):
        try:
            return o.opts[k]
        except Exception:
            return d

    def align_v(o, k, d=None):
        """读 opts.align[k]。★ align 是**嵌套** LuaTable —— 写成 opts.x_ofs 会静默返回
        None，让一整组判据变成假阴性（这个坑在 row_state 里踩过一次）。"""
        try:
            return o.opts["align"][k]
        except Exception:
            return d

    def obj_w(o):
        return opt(o, "w")

    def obj_h(o):
        return opt(o, "h")

    def labels_of(o):
        return [str(o.kids[j].label) for j in range(1, len(o.kids) + 1)
                if getattr(o.kids[j], "is_label", False)]

    # 主页 4 键 / 自启动页 4 键 / 模块页 3 键 —— 文案与用户给的清单逐字对齐
    HAVE = ("10pro.autorun", "多模块开机自启管理",
            "1  自启动管理", "2  重建自启动", "3  模块管理", "4  日志",
            "自启动", "1  安装", "2  卸载", "3  开启", "4  关闭",
            "全部启用", "重建", "全部禁止",
            "< 返回", "清空", "日志", "模块管理 2")
    for want in HAVE:
        check(want in all_labels, "A3 控件存在: %s" % want)

    # ★ 反向：这一版**删掉 / 搬走**的控件一个都不许还在（判据是"整条文本相等"）。
    GONE = ("2  接管", "5  模块管理", "6  日志",
            "3  全部允许", "4  全部禁止", "上一页", "下一页")
    for bad in GONE:
        check(bad not in all_labels, "A3b 已删除的控件不在了: %s" % bad)

    rows = []
    for i in range(1, n + 1):
        o = objs[i]
        w, h = opt(o, "w"), opt(o, "h")
        if w == 312 and h == 50 and len(o.clicks) > 0:
            rows.append(o)
    check(len(rows) == ROW_POOL,
          "A4 模块页有 %d 个预建行（可滚动，不再分页）" % ROW_POOL,
          "实际 %d" % len(rows))

    # ★ A6 行内对齐（用户 2026-10-04 报"chaos 文字 / 允许 文字 / 方框没对齐"）。
    #   根因：行对象**没写 pad_all** ⇒ 平台默认内边距把三个 TOP_LEFT 标签整体推向右下，
    #   而"允许"原本 x=204 宽 96 ⇒ 到 300，越过内容区右边界。
    #   ⚠️ 假 lvgl **不建模几何**（没有位置/内边距），所以这一组只能在**源码/opts** 上判
    #      "该写的写了没有"，真正的对齐全貌**只能真机看**。这条要说清，别当它是真机判据。
    check(len(rows) == ROW_POOL and all(opt(r, "pad_all") == 0 for r in rows),
          "A6 每个模块行都显式 pad_all = 0（不赌平台默认内边距）",
          str([opt(r, "pad_all") for r in rows[:3]]))

    def row_kids0():
        r = rows[0]
        return [r.kids[j] for j in range(1, len(r.kids) + 1)]

    rk = row_kids0()
    check(len(rk) == 3, "A6b 行里有 3 个标签（名字 / 描述 / 状态）", str(len(rk)))
    check(all(opt(l, "align") is not None and align_v(l, "type") == 1 for l in rk),
          "A6c 三个标签都用 CENTER 对齐（位置由方框中心反推，不靠字体度量）",
          str([align_v(l, "type") for l in rk]))
    check(all(opt(l, "height") is not None for l in rk),
          "A6d 三个标签都写了显式 height（垂直位置可控）",
          str([opt(l, "height") for l in rk]))
    # 312×50 的方框、中心 (156,25)：名字/描述 12..192、状态 204..300 ⇒ 左右边距各 12
    spans = []
    for l in rk:
        lw = opt(l, "width") or 0
        left = 156 + (align_v(l, "x_ofs") or 0) - lw // 2
        spans.append((left, left + lw))
    check(spans[0][0] == spans[1][0] == 12 and spans[2][1] == 300,
          "A6e 行内左右边距各 12（名字 12..192 / 状态 204..300）", str(spans))
    check(align_v(rk[2], "y_ofs") == 0,
          "A6f 状态字**垂直居中**（和名字/描述在同一个方框里各就各位）",
          str(align_v(rk[2], "y_ofs")))

    # 两个「铺满下屏」的日志小窗：定宽 288 的标签，主页一个、自启动页一个
    minis = [objs[i] for i in range(1, n + 1)
             if getattr(objs[i], "is_label", False) and opt(objs[i], "width") == 288]
    check(len(minis) == 2, "A5 两个日志小窗都在（主页 + 自启动页）", "实际 %d" % len(minis))
    check(all(opt(m, "height") is None for m in minis),
          "A5b 小窗标签不设固定高度（否则行数一变就被切）",
          str([opt(m, "height") for m in minis]))

    def find_btn(text):
        for i in range(1, n + 1):
            o = objs[i]
            if len(o.clicks) > 0 and text in kids_text(o):
                return o
        return None

    def click(text, times=1):
        b = find_btn(text)
        assert b is not None, "找不到按钮 " + text
        for _ in range(times):
            b.clicks[1]()
        return b

    def find_bar(text):
        """模块页底下那三个功能键：100×46。★ 不能按文本找 —— "重建" 是
        "2  重建自启动" 的**子串**，按文本找会命中主页那个键（先创建）。"""
        for i in range(1, n + 1):
            o = objs[i]
            if len(o.clicks) == 0:
                continue
            if obj_w(o) == 100 and obj_h(o) == 46 and text in labels_of(o):
                return o
        return None

    def click_bar(text, times=1):
        b = find_bar(text)
        assert b is not None, "找不到模块页功能键 " + text
        for _ in range(times):
            b.clicks[1]()
        return b

    def fs(path):
        return g.FS[path]

    def last():
        return str(runtime.eval("LASTTEXT()"))

    def showed_in(rt, sub):
        """LABELSET 是"所有曾经上过屏的文本"的流水，所以用它断言"某句话被显示过"。
        不能用 LASTTEXT()：动作函数里 log_append 之后还会 refresh_status()，
        最后一条 set 往往是状态行，不是日志行。
        ★ str() 会按 UTF-8 解码，截断到半个汉字时会抛 UnicodeDecodeError —— 这里吞掉，
          因为"字符串非法 UTF-8"本身该由 I 组的判据去咬，不该把整个门打崩。
        ★ 指定 rt 是为了 K 组：那里要在一个**全新的**运行时上判上屏，"上一次运行留下的
          文本流水"会让判据变成假阳性。"""
        tbl = rt.eval("LABELSET_all()")
        for i in range(1, len(tbl) + 1):
            try:
                v = str(tbl[i])
            except UnicodeDecodeError:
                continue
            if sub in v:
                return True
        return False

    def showed(sub):
        return showed_in(runtime, sub)

    def wcount(path):
        return int(runtime.eval("W(%r)" % path))

    def FS_keys_of(rt, prefix):
        """按前缀列出假文件系统里的**路径**（FS_keys() 是 Lua 侧拼好的多行串）。
        ★ 不能在 Python 直接迭代 LuaTable 拿值 —— 拿到的是键；而这里正好要键，
          但仍然统一走 Lua 侧拼串，少一种迭代写法就少一处静默错。"""
        raw = str(rt.eval("FS_keys()"))
        return [p for p in raw.split("\n") if p.startswith(prefix)]

    def row_state(i):
        """第 i 行的 (名字, 状态字)。★ 位置在 opts.align 里，不是 opts.x_ofs ——
        写错会静默返回空串，让一整组判据变成假阴性。
        ★ v0.6 行内改成 CENTER 对齐（修"文字和方框没对齐"），偏移也跟着变：
           名字 x=-54 y=-11 / 描述 x=-54 y=13 / 状态 x=+96 y=0。"""
        o = rows[i - 1]
        nm, st = "", ""
        for j in range(1, len(o.kids) + 1):
            k = o.kids[j]
            if not k.is_label:
                continue
            try:
                x = k.opts["align"]["x_ofs"]
                y = k.opts["align"]["y_ofs"]
            except Exception:
                continue
            if x == -54 and y == -11 and nm == "":
                nm = str(k.label)
            if x == 96:
                st = str(k.label)
        return nm, st

    # ================= B 配置路径（就在注册目录里，只有一个落点） =================
    CFG = "/data/rc.d/autorun.json"
    # 闸（自启动页 [3 开启]/[4 关闭]）= /data/rc.d/.autorun.on 在不在，
    # 以及 /data/rc 生成区里那几句**固定句**（整行一字不差）。
    # ★ 2026-10-04 新方案：闸的**扣与放**、两个安全窗口、心跳日志全部归 /data/rc 这一层
    #   （模块脚本里一个字节都不许有 —— 那边由 chaos 的 _sim_autostart.py C 组钉死）。
    GATE = "/data/rc.d/.autorun.on"
    AS_LOG = "/data/rc.d/.autorun.log"
    HB_LINE = "echo gate_off >> " + AS_LOG          # 心跳（在 if 外面）
    IF_LINE = "if [ -f " + GATE + " ];then"
    RM_GATE = "rm -f " + GATE                       # 扣闸
    CLEAR_LINE = "echo cleared >> " + AS_LOG        # 只跑到底才写
    ON_GATE = "echo on > " + GATE                   # 放行
    # ★ 判"文件在不在"必须用 `is not None`，不能用 `str(x) != ""`：
    #   假 FS 里文件不存在时返回 None，而 str(None) == "None" 是**非空**的 ——
    #   那种写法会让"没写成功"被判成通过（假阳性）。
    check(fs(CFG) is not None, "B0 场景就绪: 注册目录里那份配置在")
    check(showed(CFG), "B1 用的是注册目录里的配置路径")
    check("data/files" not in src, "B1b 源码里**没有** data/files（快应用那条线整个去掉）")

    # ---- "没有就创建"：把配置和目录一起删掉，看它会不会自己建出来 ----
    runtime.execute("UNSET(%r)" % CFG)
    runtime.execute("UNSET('/data/rc.d')")
    runtime.execute("WCOUNT[%r] = nil" % CFG)
    click("2  重建自启动")
    created = str(fs(CFG))
    check(fs(CFG) is not None, "B2 配置不存在时自动创建（含建目录）")
    # 注意：建完立刻会被 merge 补登记（rc.d 里有两个切片），所以它不是空的 ——
    # 这一点由 I10 单独判。这里只要求"是合法 JSON 且 modules 是对象"。
    try:
        j = json.loads(created)
        check(isinstance(j.get("modules"), dict) and j.get("version") == 1,
              "B3 新建出来的是合法 JSON", repr(created[:200]))
    except Exception as e:
        check(False, "B3 新建出来的是合法 JSON", "%s | %r" % (e, created))
    check(showed("配置已新建"), "B4 日志标明这份是新建的")
    w0 = wcount(CFG)
    click("2  重建自启动")
    check(wcount(CFG) == w0, "B5 已存在时不再重写配置", "%d -> %d" % (w0, wcount(CFG)))

    # ---- 配置文件**不能被当成一个模块**（它就在注册目录里，后缀是 .json）----
    mod_names = [row_state(i)[0] for i in range(1, ROW_POOL + 1)]
    check("autorun" not in mod_names and "autorun.json" not in mod_names,
          "B6 autorun.json 没被当成模块（后缀过滤）", str(mod_names))
    # ★ 判据要判**配置文件**没被当成模块行 —— 不能只判 "autorun" 这个子串：
    #   总开关 /data/rc.d/.autorun.on 的名字里也含 autorun（那是我们自己的门）。
    check("autorun.json" not in str(fs("/data/rc")) and "autorun.sh" not in str(fs("/data/rc")),
          "B6b 生成区里没有配置文件那一行（只有门里的 .autorun.on）",
          str(fs("/data/rc"))[:120])

    # ---- 配置建不出来 -> **拒绝重建**（不再有兜底路径）----
    # 这条是这次改动的核心安全属性：以前会退到别的落点继续跑，
    # 现在只有一个落点 —— 写不进去就必须**什么都不做**，因为这时候 MODS 是空壳，
    # 重建出来会是一份"什么都不启动"的 /data/rc，等于把开机链悄悄改掉。
    rc_before = str(fs("/data/rc"))
    w_rc = wcount("/data/rc")
    runtime.execute("BLOCK['/data/rc.d'] = true")
    runtime.execute("UNSET(%r)" % CFG)
    click("2  重建自启动")
    check(showed("拒绝重建"), "B7 配置建不出来时日志说「拒绝重建」")
    check(str(fs("/data/rc")) == rc_before, "B7b 并且 /data/rc 一个字节都没动")
    check(wcount("/data/rc") == w_rc, "B7c 而且根本没写盘")
    # ★ 落点判据：管理器是**独立项目**（用户 2026-10-04 明确），自己的东西只许在
    #   /data/10pro.autorun 下 —— 不许再借 /data/chaos（那家的日志会跟我们混在一起）。
    check(FS_keys_of(runtime, "/data/chaos") == [],
          "B7d 一个字节都不落在 /data/chaos（自己有一个落点）",
          str(FS_keys_of(runtime, "/data/chaos")))
    # ---- 恢复可写 -> 立刻又能用（"降级"从来没发生过）----
    runtime.execute("BLOCK = {}")
    click("2  重建自启动")
    check(fs(CFG) is not None, "B8 恢复可写后配置自己建起来了")
    check(showed("配置已新建"), "B9 并且报了新建")

    # ---- 重设场景（B 组把预设的配置冲掉了），给 C/D 组用 ----
    runtime.execute("SET(%r, %r)" % (
        CFG, '{\n  "version": 1,\n  "modules": {\n    "shellpp2": {\n'
             '      "enable": false,\n      "order": 20\n    }\n  }\n}\n'))
    click("2  重建自启动")

    # ================= C 合并且登记 =================
    cfg = str(fs("/data/rc.d/autorun.json"))
    check('"chaos"' in cfg, "C1 新切片 chaos 被自动补登记进配置")
    check('"shellpp2"' in cfg, "C2 原有条目 shellpp2 保留")
    check('"enable": false' in cfg, "C3 已写好的 enable=false 没被默认值覆盖")

    # ================= D 重建（生成区新形态） =================
    click("2  重建自启动")
    rc = str(fs("/data/rc"))
    check(rc.startswith("set +e\n"), "D1 首行是 set +e", repr(rc[:20]))
    lines = [x for x in rc.split("\n") if x.strip()]
    check(lines[1].startswith("if [ -f /data/shellpp-ii/autostart.on ]"),
          "D2 别人的行原样在前", repr(lines[1]))
    check("sh /data/rc.d/chaos.sh" in lines, "D3 chaos 的生成行在（★ 不带 &）")
    check("sh /data/rc.d/shellpp2.sh" not in lines,
          "D4 被禁止的 shellpp2 **没有**生成行")
    gen = [x for x in lines if x.startswith("sh /data/rc.d/")]
    check(gen == ["sh /data/rc.d/chaos.sh"], "D5 生成区只有 chaos 一行", str(gen))
    # ★ 生成区形状（不变量 5 + 6 —— 2026-10-04 把闸与延时上移到这一层之后）：
    #     心跳 → 门 if → 扣闸 rm → sleep 8 → 模块行（之间 sleep 1）→ sleep 15
    #     → echo cleared → echo on > GATE → fi
    #   顺序不许换：rm 必须在模块行**之前**（它就是防砖的全部依据）；
    #   `echo on >` 必须在 sleep 15 **之后**（= "全部模块加载完、又过了 15 秒才放行"）。
    check(lines.count(IF_LINE) == 1, "D6 生成区只有一道门（只一层 if —— nsh 没验过嵌套）",
          str(lines))
    i0 = lines.index(IF_LINE)
    check(lines[i0 - 1] == HB_LINE,
          "D6b 心跳在门**外面**（闸关着也要留痕，否则「没跑到」和「闸关」分不清）",
          repr(lines[i0 - 1:i0 + 1]))
    check(lines[i0 + 1] == RM_GATE and lines[i0 + 2] == "sleep 8",
          "D7 门后第一件事 = 扣闸 + 窗口 1（rm 必须排在模块行之前）", str(lines[i0:i0 + 3]))
    check(lines[i0 + 3] == "sh /data/rc.d/chaos.sh",
          "D7b 扣闸 + 窗口 1 之后才是模块行", str(lines[i0:i0 + 5]))
    check(lines[-4:] == ["sleep 15", CLEAR_LINE, ON_GATE, "fi"],
          "D7c 尾巴：窗口 2 -> cleared -> 放行 -> fi（顺序不许换）", str(lines[-5:]))
    check(lines.count(RM_GATE) == 1 and lines.count(CLEAR_LINE) == 1
          and lines.count(ON_GATE) == 1 and lines.count(HB_LINE) == 1,
          "D7d 扣闸 / cleared / 放行 / 心跳 各只有一次",
          str([x for x in lines if x in (RM_GATE, CLEAR_LINE, ON_GATE, HB_LINE)]))
    check(lines[-1] == "fi", "D8 最后一行是收尾 fi", repr(lines[-1]))
    check(not [x for x in lines if x.endswith("&")],
          "D9 生成区一行都不带 & （脚本不许后台跑）",
          str([x for x in lines if x.endswith("&")]))
    check(not [x for x in lines if x.endswith("& ")],
          "D9b 也没有'行尾带 & 再跟空'那种写法",
          str([x for x in lines if x.endswith("& ")]))
    # ★ 别人的 rc 里**自己也有一个 fi**（它自己那个 if 块的收尾）—— 所以全文件应该是
    #   两个 fi：别人的那个（原样保留）+ 我们生成区那个（最后一行）。
    check(lines.count("fi") == 2, "D10 两个 fi：别人的 + 我们生成区的收尾",
          str([x for x in lines if x == "fi"]))
    check(lines.index("fi") < len(lines) - 1,
          "D10b 别人的 fi 还在原位（不在最后）")

    # ================= E 幂等 =================
    w_before = wcount("/data/rc")
    click("2  重建自启动")
    w_after = wcount("/data/rc")
    check(w_before == w_after, "E1 内容没变时 /data/rc 一个字节都没写",
          "%d -> %d" % (w_before, w_after))

    # ================= F 批量开关（已搬进模块页） =================
    # ★ 从主页搬到模块页之后，"全部启用/全部禁止"是模块页底下的 100×46 功能键。
    click_bar("全部禁止")
    cfg = str(fs("/data/rc.d/autorun.json"))
    check('"enable": false' in cfg, "F1 全部禁止已回写")
    check('"core": true' not in cfg, "F2 当前没有 core（接管已删）")
    click("2  重建自启动")
    rc = str(fs("/data/rc"))
    check("sh /data/rc.d/chaos.sh" not in rc, "F3 全部禁止后 rc 里没有生成行")
    click_bar("全部启用")
    click("2  重建自启动")
    rc = str(fs("/data/rc"))
    check("sh /data/rc.d/chaos.sh" in rc, "F4 全部启用后生成行回来了")
    check("sh /data/rc.d/shellpp2.sh" in rc, "F5 shellpp2 也回来了")
    # ★ 串行（不变量 5）：两个模块行之间**有且只有**一行 sleep 1，且没有 &
    gl = [x for x in rc.split("\n") if x.startswith("sh /data/rc.d/")]
    check(len(gl) == 2, "F6 两行模块行", str(gl))
    mid = rc[rc.index(gl[0]) + len(gl[0]):rc.index(gl[1])]
    check(mid == "\nsleep 1\n", "F7 两行之间正好夹一行 sleep 1", repr(mid))
    check(rc.count("sleep 1\n") == 1, "F8 只有我们自己那一行 sleep 1",
          str([x for x in rc.split("\n") if "sleep" in x]))
    check("sleep 5" in rc, "F8b 别人的 sleep 5 一个字没动")

    # ================= G 单项开关 =================
    # ★ 行号按 order 升序排出来的，不能假设 chaos 在第 1 行
    #   （preset 里 shellpp2 有 order=20，chaos 是自动补登记的默认 order=100）。
    def row_of(name):
        for i in range(1, ROW_POOL + 1):
            if row_state(i)[0] == name:
                return i
        return 0

    ri = row_of("chaos")
    check(ri > 0, "G0 列表里能找到 chaos", str([row_state(i) for i in range(1, ROW_POOL + 1)]))
    check(row_state(ri)[1] == "允许", "G1 chaos 行显示 允许", row_state(ri)[1])
    rows[ri - 1].clicks[1]()                       # 点 chaos 行 -> 禁止
    check(row_state(ri)[1] == "禁止", "G2 点一下变成 禁止", row_state(ri)[1])
    rows[ri - 1].clicks[1]()                       # 再点 -> 允许
    check(row_state(ri)[1] == "允许", "G3 再点回到 允许", row_state(ri)[1])

    # 缺脚本的项：把 shellpp2 的脚本删掉 —— 此刻 /data/rc 里**那一行还在**，
    # 所以它显示"缺脚本"；而这一下的 [重建] 会顺手把那行删掉（删多余行）。
    # ★ 语义 2026-10-04 改过：以前是"配置登记过但文件不在"就显示缺脚本（永远消不掉），
    #   现在只在「/data/rc 有那一行」时显示。判据见 O 组。
    runtime.execute("UNSET('/data/rc.d/shellpp2.sh')")
    click("2  重建自启动")
    si = row_of("shellpp2")
    check(si > 0, "G4 列表里仍能找到 shellpp2（/data/rc 里那一行还在）",
          str([row_state(i) for i in range(1, ROW_POOL + 1)]))
    check(row_state(si)[1] == "缺脚本", "G4b 脚本被删但 rc 有行 -> 标 缺脚本", row_state(si)[1])
    rc = str(fs("/data/rc"))
    check("sh /data/rc.d/shellpp2.sh" not in rc, "G5 缺脚本的项不进 rc（这一下重建把它删了）")

    # ================= H 总开关（自启动页 [3 开启] / [4 关闭]） =================
    # ★ 这一组是**反着**重写的：上一版测"接管两段式"，接管已按用户要求删掉，
    #   改成测那个新加的独立闸 —— 开关文件在不在。
    runtime.execute("SET('/data/rc.d/shellpp2.sh', 'sh /data/shellpp-ii/rc &\\n')")
    click("2  重建自启动")
    rc_before = str(fs("/data/rc"))
    cfg_before = str(fs("/data/rc.d/autorun.json"))
    check("sh /data/rc.d/chaos.sh" in rc_before, "H0 前置: rc 里有生成行")
    check("if [ -f /data/shellpp-ii/autostart.on ]" in rc_before,
          "H0b 前置: 别人的行也还在（没人再动它）")

    # ---- [4 关闭]：只删开关文件；**不写** /data/rc ----
    runtime.execute("SET(%r, 'on\\n')" % GATE)
    check(fs(GATE) is not None, "H1 前置: 总开关文件在")
    w_rc = wcount("/data/rc")
    runtime.execute("LABELSET = {}")
    click("4  关闭")
    check(fs(GATE) is None, "H2 [4 关闭] 删掉了总开关文件")
    check(str(fs("/data/rc")) == rc_before,
          "H3 关闭**不写** /data/rc（门就是文件在不在）")
    check(wcount("/data/rc") == w_rc, "H4 而且一个字节都没写盘",
          "%d -> %d" % (w_rc, wcount("/data/rc")))
    check(str(fs("/data/rc.d/autorun.json")) == cfg_before, "H5 配置也没动")
    check(showed("总开关: 关"), "H6 日志说清了总开关已关")
    check(showed("自启关"), "H7 状态行里看得见「自启关」")

    # ---- 关着的时候按 [重建]：rc 照旧重建，但必须警告"这些行不会跑" ----
    runtime.execute("LABELSET = {}")
    click("2  重建自启动")
    check(showed("总开关是关的"), "H8 关着时重建会警告「这次重建出来的模块行不会跑」")

    # ---- [3 开启]：建回来 + 顺手重建（老 rc 里可能还没有那道门） ----
    runtime.execute("LABELSET = {}")
    click("3  开启")
    check(fs(GATE) is not None, "H9 [3 开启] 建回了总开关文件")
    check(showed("自启动总开关: 开"), "H10 日志说清已开")
    rc = str(fs("/data/rc"))
    check("sh /data/rc.d/chaos.sh" in rc, "H11 开启顺手重建，模块行回来了")
    check(IF_LINE in rc, "H11b 门也在（否则等于没开）")
    check(showed("自启开"), "H12 状态行变成「自启开」")

    # ---- 老设备迁移：rc 里还没有那道门 -> [重建] **自动补建**开关（默认开） ----
    runtime.execute("UNSET(%r)" % GATE)
    runtime.execute("SET('/data/rc', 'set +e\\n')")
    runtime.execute("LABELSET = {}")
    click("2  重建自启动")
    check(fs(GATE) is not None, "H13 老设备（rc 里没有门）按重建会**自动补建**总开关")
    check(showed("总开关已补建"), "H14 并且把这件事报出来")
    rc = str(fs("/data/rc"))
    check("sh /data/rc.d/chaos.sh" in rc and IF_LINE in rc,
          "H15 补建之后生成行在门里（开机真的会跑）")

    # ---- 反向：关掉之后**再开回来**必须恢复原样（可逆、且不开天窗） ----
    runtime.execute("SET(%r, 'on\\n')" % GATE)
    click("2  重建自启动")
    rc_on1 = str(fs("/data/rc"))
    click("4  关闭")
    check(str(fs("/data/rc")) == rc_on1, "H16 关闭那一下没改 rc")
    click("3  开启")
    check(str(fs("/data/rc")) == rc_on1, "H16b 关->开 之后 rc 逐字节回到原样")
    check(fs(GATE) is not None, "H16c 开关文件又在了")

    # ---- core 模块不给禁（配置里手写 core:true 的模块） ----
    runtime.execute("SET(%r, %r)" % (
        CFG, '{"version":1,"modules":{"chaos":{"core":true,"enable":true,"order":10},'
             '"shellpp2":{"core":false,"enable":true,"order":20}}}'))
    click("2  重建自启动")
    ci = row_of("chaos")
    check(ci > 0, "H20 列表里能找到 chaos", str([row_state(i) for i in range(1, ROW_POOL + 1)]))
    check(row_state(ci)[1] == "核心", "H21 core 行显示「核心」", row_state(ci)[1])
    rows[ci - 1].clicks[1]()
    check(row_state(ci)[1] == "核心", "H22 core 模块点了不给禁")
    check(showed("核心模块") or showed("不给禁"), "H23 提示文案")

    # ================= I JSON 往返 =================
    # 拉一份"真实字符串" -> Python json 编码 -> 管理器读进来 -> 回写 ->
    # Python json 解码 -> 比。这样是**两个独立实现互校**，比在输出里找子串强得多。
    # 之前的版本只用 %r 注入 + 子串断言，结果漏掉了"解码器用错表"这个真 bug。
    tricky_desc = '中文 "引号" \\ 😀\tTab 与\n换行'
    payload = {"version": 1,
               "modules": {"chaos": {"core": True, "delay": 3, "desc": tricky_desc,
                                     "enable": True, "order": 10}}}
    raw_json = json.dumps(payload, ensure_ascii=True)
    check("\\u" in raw_json, "I0 输入确实带 \\uXXXX 转义(顺手测代理对)", raw_json[:70])
    runtime.execute("UNSET('/data/rc.d/legacy.sh')")
    runtime.execute("SET('/data/rc.d/chaos.sh', 'x')")
    runtime.execute("SET('/data/rc.d/shellpp2.sh', 'x')")
    # 用长括号串注入：不做任何转义处理，注入内容就是 JSON 原文
    runtime.execute("SET('/data/rc.d/autorun.json', [==[%s]==])" % raw_json)
    click("2  重建自启动")
    out = str(fs("/data/rc.d/autorun.json"))
    back = None
    try:
        back = json.loads(out)
        check(True, "I1 回写出来的仍是合法 JSON")
    except Exception as e:
        check(False, "I1 回写出来的仍是合法 JSON", "%s  |  %r" % (e, out))
    if back is not None:
        d = back.get("modules", {}).get("chaos", {})
        check(d.get("desc") == tricky_desc,
              "I2 desc 往返一致(引号/反斜杠/emoji/Tab/换行)", repr(d.get("desc")))
        check(d.get("order") == 10 and not isinstance(d.get("order"), float),
              "I3 order 是整数 10 不是 10.0", repr(d.get("order")))
        check(d.get("core") is True, "I4 core 是布尔 true 不是字符串", repr(d.get("core")))
        check(d.get("delay") == 3, "I5 delay 保持", repr(d.get("delay")))
        check(back.get("version") == 1, "I6 version 保持", repr(back.get("version")))
        check("shellpp2" in back.get("modules", {}), "I7 自动补登记的 shellpp2 也在")
        check('"order": 10' in out, "I8 整数写成 10 而不是 10.0")
        # 幂等：同一份内容再走一遍，字节必须完全一样（转义不会越滚越多）
        click("2  重建自启动")
        out2 = str(fs("/data/rc.d/autorun.json"))
        check(out2 == out, "I9 二次往返字节不变(转义不滚雪球)", "变了")

    # modules 为空 + 有切片 => 自动补登记，且产物仍合法
    runtime.execute("SET('/data/rc.d/autorun.json', "
                    r"'{\"version\": 1, \"modules\": {}}')")
    click("2  重建自启动")
    out = str(fs("/data/rc.d/autorun.json"))
    try:
        back = json.loads(out)
        check(sorted(back["modules"].keys()) == ["chaos", "shellpp2"],
              "I10 modules 为空时两个切片都被补登记", str(back.get("modules")))
    except Exception as e:
        check(False, "I10 modules 为空时产物仍合法", str(e))

    # 坏 JSON: 必须不崩，且能被覆盖回合法内容
    runtime.execute("SET('/data/rc.d/autorun.json', '{ bad json')")
    try:
        click("2  重建自启动")
        check(True, "I11 坏 JSON 不崩")
        try:
            json.loads(str(fs("/data/rc.d/autorun.json")))
            check(True, "I12 坏 JSON 被覆盖回合法内容")
        except Exception as e:
            check(False, "I12 坏 JSON 被覆盖回合法内容", str(e))
    except Exception as e:
        check(False, "I11 坏 JSON 不崩", str(e))

    # 静态判据：空表写成 {} 的那条守卫在运行时到不了（merge 总会带至少一项），
    # 只能静态咬。这是**有意**用静态判据，不是偷懒。
    check('if #ks == 0 then return "{}" end' in src,
          "I13 空表写成 {} 的守卫在源码里（静态判据）")

    # ================= K 不自动重建 + 「待重建」提示 =================
    # 这一组是这一轮**反着**重写的：上一版判的是"打开表盘就自动对账"，
    # 现在按用户要求去掉了自动重建，判的变成"**零按钮时一个字节都不许写**"，
    # 而且"改了但没落盘"必须**看得见**（状态行的 ● 待重建）。
    # ★ 必须用**全新的 Lua 运行时**跑：在同一个运行时里再 load 一次会多出一整套控件，
    #   按文本找按钮会命中第一次那套闭包 —— 测出来的就变成"再点一次"，不是"重开"。
    def boot(env, blocks=()):
        rt = lupa.LuaRuntime(unpack_returned_tuples=True)
        rt.execute(FAKE)
        rt.execute(TOOLS)
        rt.execute("FS_reset()")
        for k, v in env.items():
            rt.execute("SET(%r, %r)" % (k, v))
        for b in blocks:
            rt.execute("BLOCK[%r] = true" % b)
        rt.eval("function(s) local f = assert(load(s, '@run')); return f end")(src)()
        return rt

    def fs_of(rt, path):
        return rt.eval("FS[%r]" % path)

    def w_of(rt, path):
        return int(rt.eval("W(%r)" % path))

    def kids_in(o):
        out = []
        for j in range(1, len(o.kids) + 1):
            k = o.kids[j]
            if getattr(k, "is_label", False):
                out.append(str(k.label))
        return out

    def find_in(rt, text, w=None, h=None):
        """在指定运行时里按文本找可点对象；给了 w/h 就按尺寸找（模块行）。"""
        objs = rt.eval("OBJS_all()")
        for i in range(1, len(objs) + 1):
            o = objs[i]
            if len(o.clicks) == 0:
                continue
            if w is not None:
                try:
                    if o.opts["w"] != w or o.opts["h"] != h:
                        continue
                except Exception:
                    continue
                return o
            if any(text in t for t in kids_in(o)):
                return o
        return None

    def click_in(rt, text, times=1):
        b = find_in(rt, text)
        assert b is not None, "找不到按钮 " + text
        for _ in range(times):
            b.clicks[1]()
        return b

    CFG1 = ('{"version": 1, "modules": {"chaos": {"core": true, '
            '"enable": true, "order": 10}}}')

    # K1 配置和 /data/rc **不一致**（别的模块刚投了脚本）-> 重开管理器，零按钮
    rt = boot({"/data/rc": "set +e\nsleep 2\n",
               "/data/rc.d/chaos.sh": "sh /data/chaos/rc &\n",
               CFG: CFG1})
    rc = str(fs_of(rt, "/data/rc"))
    check("sh /data/rc.d/chaos.sh" not in rc,
          "K1 重开管理器、零按钮：/data/rc **没有**被自动改", repr(rc))
    check(w_of(rt, "/data/rc") == 0, "K1b 而且一次都没写盘",
          "w=%d" % w_of(rt, "/data/rc"))
    check(showed_in(rt, "待重建"),
          "K2 但状态行必须提示「●待重建」（不写盘不等于可以不说话）")
    check(showed_in(rt, "按 [2 重建自启动] 落盘"), "K2b 日志里也写明了该按哪个键")
    check(fs_of(rt, GATE) is None,
          "K2c 而且没有偷偷替老设备补建总开关（补建只在 [重建]/[安装] 里发生）")

    # K3 别人的行：重开管理器同样一个字节不动（不变量①）
    rt = boot({"/data/rc": OTHERS_RC, "/data/rc.d/chaos.sh": "x", CFG: CFG1})
    check(str(fs_of(rt, "/data/rc")) == OTHERS_RC, "K3 重开管理器后别人的行逐字节未动")

    # K4 按 [重建] 才落盘；落盘后提示要消失
    rt = boot({"/data/rc": "set +e\nsleep 2\n",
               "/data/rc.d/chaos.sh": "sh /data/chaos/rc &\n",
               CFG: CFG1})
    click_in(rt, "2  重建自启动")
    rc = str(fs_of(rt, "/data/rc"))
    check("sh /data/rc.d/chaos.sh" in rc, "K4 按 [2 重建自启动] 之后才落盘")
    check(IF_LINE in rc, "K4b 生成区带上了门")
    check(showed_in(rt, "已重建 /data/rc"), "K4c 日志说已重建")
    # 再按一次，这次内容没变 -> 幂等那句话 + 状态行不该再有"待重建"
    rt.execute("LABELSET = {}")         # 清空上屏流水，只看这一轮说的话（eval 只吃表达式）
    click_in(rt, "2  重建自启动")
    check(showed_in(rt, "内容未变"), "K4d 第二次按是「内容未变, 未写盘」")
    check(not showed_in(rt, "待重建"), "K4e 落盘之后不再提示「待重建」")

    # K5 改开关**不**落盘（这就是"去掉自动重建"的实际含义），且明确告诉你按哪个键
    #   ★ 场景里两个脚本都要有：点一个"缺脚本"的模块会走另一条早退路径
    #     （"[x] 没有 …sh, 不算注册"），那就测不到"改开关"这条线了。
    rt = boot({"/data/rc": "set +e\nsh /data/rc.d/chaos.sh\n",
               "/data/rc.d/chaos.sh": "x",
               "/data/rc.d/shellpp2.sh": "x",
               CFG: '{"version":1,"modules":{"chaos":{"enable":true,"order":10},'
                    '"shellpp2":{"enable":true,"order":20}}}'})
    # 先按一次 [重建] 让 /data/rc 与配置一致
    click_in(rt, "2  重建自启动")
    rc_ok = str(fs_of(rt, "/data/rc"))
    check("sh /data/rc.d/shellpp2.sh" in rc_ok, "K5 前置: 两个模块都在 rc 里")
    w_rc = w_of(rt, "/data/rc")
    row = find_in(rt, None, w=312, h=50)      # 第 1 行 = order 最小的那个
    assert row is not None, "找不到模块行"
    row.clicks[1]()                            # 翻转一个模块
    check(str(fs_of(rt, "/data/rc")) == rc_ok,
          "K5b 翻转模块后 /data/rc **没有**被自动改")
    check(w_of(rt, "/data/rc") == w_rc, "K5c 也没写盘")
    check(showed_in(rt, "按 [2 重建自启动] 才落到 /data/rc"),
          "K5d 并且告诉你「按 [重建自启动] 才落到 /data/rc」")
    click_in(rt, "2  重建自启动")
    check(str(fs_of(rt, "/data/rc")) != rc_ok, "K5e 按了之后才变")

    # K6 坏配置：留底 .bad，不崩
    rt = boot({"/data/rc": "set +e\n", "/data/rc.d/chaos.sh": "x",
               CFG: "{ 坏掉的 json"})
    check(fs_of(rt, CFG + ".bad") is not None,
          "K6 坏配置留了一份 .bad 原样副本")
    check(showed_in(rt, "配置解析失败"), "K6b 并且在上屏明说解析失败")

    # K7 反向静态判据：删掉的自动重建**不许**回来（剥注释行再判）
    code = "\n".join(ln for ln in src.split("\n")
                     if not ln.strip().startswith("--"))
    check("sync_rc_auto" not in code, "K7 代码里没有 sync_rc_auto（不自动重建）")
    check("CFG_HOW" not in code and "FALLBACK" not in code,
          "K7b 代码里没有 CFG_HOW / FALLBACK（一个落点，没有兜底）")
    # ★ 这一版**删掉/搬走**的东西，一个都不许留代码：
    check("do_adopt" not in code, "K7c 接管（do_adopt）整个删掉了")
    check("legacy.sh" not in code, "K7d 不再往 legacy.sh 搬别人的行")
    check("PER_PAGE" not in code and "page_no" not in code,
          "K7e 分页那套（PER_PAGE/page_no）删干净了")
    check("<<<<<<<" not in src and ">>>>>>>" not in src, "K7f 没有 git 冲突残留")
    # 正向：flash 那一段必须真的在（而且是整段搬进来的）
    check("hook_install" in code and "hook_restore" in code,
          "K7g flash 装/卸函数在（init rc 那一页要用）")
    check("ORIG_HEX" in code and "FLASH_CAND" in code,
          "K7h 32KB 原块与三个候选块都在")
    check("18" in code and "flash_adler" in code, "K7i 四道门的基本件在")
    # ★ 心跳日志（/data/rc 写的）本页**只读不写**。这条只能静态咬（假件里"谁写的"分不清），
    #   而它的后果不小：本页只要往那份日志里写过一字节，"连着两行 gate_off = 上次被打断"
    #   这个判据就被插进了杂质，日志也不再是"开机链的证词"。
    check("AS_LOG" in code and "write_file(AS_LOG" not in code
          and "io.open(AS_LOG" not in code and "log_persist(AS_LOG" not in code,
          "K7j 心跳日志本页只读不写（只准 /data/rc 往里追加）")

    # ================= L init rc（假 flash：真读真写 32KB 块） =================
    # ★ 这是**唯一会砖设备**的一条路，所以仿真里给的是一块"真 flash"：
    #   三个候选按 (dev, byteoff) 建模，dd 真读真写；管理器写下去的每个字节都由
    #   **Python 侧独立推导**的 ORIG/PAY 逐字节核对。
    #   ★ 比对必须在 Lua 侧做：lupa 把 Lua 字符串按 UTF-8 解回 Python str，
    #     flash 里那些字节根本不是 UTF-8 ⇒ 只能传 hex / adler 这种 ASCII 视图。
    blk = pf.source_block()
    d = pf.derive(blk)
    HEX_ORIG, HEX_PAY = d["ORIG"].hex(), d["PAY"].hex()
    ORIG_ADLER = pf.adler32(d["ORIG"])
    PAY_ADLER = pf.adler32(d["PAY"])
    AA = b"\xaa" * d["BS"]
    AA_HEX, AA_ADLER = AA.hex(), pf.adler32(AA)
    WIN_OFF, WIN_LEN = d["WIN_OFF"], d["WIN_LEN"]
    HOOK_BYTES = b"sh /data/rc &\n" + b"\x00" * 4
    DEV_OFF = 13369344                      # 第三个候选（前两个这边读不到）
    check(len(d["ORIG"]) == d["BS"] and len(d["PAY"]) == d["BS"],
          "L0 真值就绪: 原块/载荷各 %d B" % d["BS"],
          "ORIG=%s PAY=%s" % (ORIG_ADLER, PAY_ADLER))

    def seed_flash(rt, with_block=True, fw="3.101.043"):
        rt.execute("DEV_reset()")
        rt.execute("FWV = %r" % fw)
        if with_block:
            # 目标块 = 干净的原始块；前后邻居 = 0xAA 填充（用来证明"只动了这一块"）
            rt.execute("DEV_seed_hex('/dev/bes_flash', %d, %r)" % (DEV_OFF, HEX_ORIG))
            rt.execute("DEV_seed_hex('/dev/bes_flash', %d, %r)" % (DEV_OFF - d["BS"], AA_HEX))
            rt.execute("DEV_seed_hex('/dev/bes_flash', %d, %r)" % (DEV_OFF + d["BS"], AA_HEX))

    # ---- L1 两段式：第一下只探测，一个字节都不许写 ----
    rt = boot({"/data/rc": "set +e\n", "/data/rc.d/chaos.sh": "x", CFG: CFG1})
    seed_flash(rt)
    before_adler = rt.eval("DEV_adler('/dev/bes_flash', %d)" % DEV_OFF)
    rt.execute("LABELSET = {}")
    click_in(rt, "1  安装")
    check(rt.eval("DEV_adler('/dev/bes_flash', %d)" % DEV_OFF) == before_adler == ORIG_ADLER,
          "L1 第一下之后目标块还是原块（== %s）" % ORIG_ADLER)
    check(showed_in(rt, "再按一次"), "L1b 文案要求二次确认")
    check(showed_in(rt, "flash-abs"), "L1c 探测报出了认出的候选名",
          str(rt.eval("DD_count()")))
    check(rt.eval("DEV_map()") == "/dev/bes_flash@%d\n/dev/bes_flash@%d\n/dev/bes_flash@%d"
          % (DEV_OFF - d["BS"], DEV_OFF, DEV_OFF + d["BS"]),
          "L1d 没有凭空多出别的块", repr(str(rt.eval("DEV_map()"))))

    # ---- L2 第二下：真写。写下去的必须**逐字节**等于独立推导的载荷 ----
    rt.execute("LABELSET = {}")
    click_in(rt, "1  安装")
    got = rt.eval("DEV_hex('/dev/bes_flash', %d)" % DEV_OFF)
    check(len(got) == d["BS"] * 2, "L2 块长度还是 %d B" % d["BS"], str(len(got)))
    check(got == HEX_PAY, "L2b 写下去的块 **逐字节 == 独立推导的载荷**")
    check(rt.eval("DEV_adler('/dev/bes_flash', %d)" % DEV_OFF) == PAY_ADLER,
          "L2c adler == 源里写死的 %s" % PAY_ADLER)
    check(got[WIN_OFF * 2:(WIN_OFF + WIN_LEN) * 2] == HOOK_BYTES.hex(),
          "L2d 0x%04X 那 18 字节就是那句开机钩子" % WIN_OFF,
          got[WIN_OFF * 2:(WIN_OFF + WIN_LEN) * 2])
    check(got[:d["HEAD_END"] * 2] == HEX_ORIG[:d["HEAD_END"] * 2],
          "L2e 前段与原块逐字节相同（size/ck 那 8 字节之外没动）")
    check(got[d["BODY_END"] * 2:] == HEX_ORIG[d["BODY_END"] * 2:],
          "L2f 后段与原块逐字节相同")
    check(rt.eval("DEV_adler('/dev/bes_flash', %d)" % (DEV_OFF - d["BS"])) == AA_ADLER
          and rt.eval("DEV_adler('/dev/bes_flash', %d)" % (DEV_OFF + d["BS"])) == AA_ADLER,
          "L2g 前后邻居块的 adler 没变（只动了这一块）")
    check(showed_in(rt, "init rc: 装好"), "L2h 日志说装好了")
    # 同时文件那半也要落地：目录/配置/总开关/rc
    check(fs_of(rt, GATE) is not None, "L2i 顺手把总开关建好了")
    check(IF_LINE in str(fs_of(rt, "/data/rc")), "L2j /data/rc 也重建了（门在）")

    # ---- L3 幂等：已经是载荷再按一次，不该再写 ----
    rt.execute("LABELSET = {}")
    click_in(rt, "1  安装")
    click_in(rt, "1  安装")
    check(showed_in(rt, "已是载荷") or showed_in(rt, "装好"),
          "L3 已经是载荷 -> 直接报「已是载荷」，不再写")
    check(rt.eval("DEV_adler('/dev/bes_flash', %d)" % DEV_OFF) == PAY_ADLER,
          "L3b 块还是载荷")
    # ★ 否定式（"没说过某句"）在这个假件里**判不了**：日志小窗每次刷新都会把整条尾巴
    #   重新 set 一遍 ⇒ 旧行会被重新推进 LABELSET。所以这里用**肯定式**（新文案是独有的）
    #   + **行为断言**（按一次就该把文件那半走完）—— 两条都伪造不出来。
    check(showed_in(rt, "已经装着了"),
          "L3c 已经装好时按 [1 安装] 直接说清「hook 已经装着了」（不再要求二次确认）")
    rt.execute("UNSET(%r)" % GATE)
    rt.execute("SET('/data/rc', 'set +e\\n')")
    rt.execute("LABELSET = {}")
    click_in(rt, "1  安装")                     # ★ 只按一次
    check(fs_of(rt, GATE) is not None,
          "L3d hook 已是载荷时按**一次** [1 安装] 就把文件那半走完（不用二次确认）")

    # ---- L4 卸载：也两段式；还原回原块 ----
    rt.execute("LABELSET = {}")
    click_in(rt, "2  卸载")
    check(rt.eval("DEV_adler('/dev/bes_flash', %d)" % DEV_OFF) == PAY_ADLER,
          "L4 卸载第一下不动 flash")
    check(showed_in(rt, "再按一次"), "L4b 卸载也要求二次确认")
    rt.execute("LABELSET = {}")
    click_in(rt, "2  卸载")
    check(rt.eval("DEV_hex('/dev/bes_flash', %d)" % DEV_OFF) == HEX_ORIG,
          "L4c 还原回原块（逐字节）")
    check(rt.eval("DEV_adler('/dev/bes_flash', %d)" % DEV_OFF) == ORIG_ADLER,
          "L4d 原块 adler == %s" % ORIG_ADLER)
    check(fs_of(rt, GATE) is None, "L4e 总开关也删了")
    check(fs_of(rt, CFG) is not None, "L4f 但配置**没删**（策略要留住）")
    check(str(fs_of(rt, "/data/rc")) != "", "L4g /data/rc 也留着（没被清空）")
    # ---- L4h：flash 已经是原样时按 [2 卸载] 直接说清（不再要求二次确认） ----
    rt.execute("LABELSET = {}")
    click_in(rt, "2  卸载")
    check(showed_in(rt, "无需还原"),
          "L4h 已经还原过时按 [2 卸载] 直接说清「无需还原」")
    check(fs_of(rt, GATE) is None, "L4i 而且总开关照样被删（文件那半没被跳过）")

    # ---- L5 认不出块 -> 一个字节都不写 ----
    rt = boot({"/data/rc": "set +e\n", "/data/rc.d/chaos.sh": "x", CFG: CFG1})
    rt.execute("DEV_reset()")
    rt.execute("FWV = '3.101.043'")
    rt.execute("LABELSET = {}")
    click_in(rt, "1  安装")
    click_in(rt, "1  安装")
    check(rt.eval("DEV_map()") == "", "L5 认不出块 -> 假 flash 里一个块都没被写过",
          repr(str(rt.eval("DEV_map()"))))
    check(showed_in(rt, "没认出块") or showed_in(rt, "没有认出的块"),
          "L5b 日志说清了没认出块")
    check(fs_of(rt, GATE) is not None,
          "L5c 但文件那半照装（装不上 hook 也要把文件摆好）")

    # ---- L6 固件版本门：不符 -> flash 那半整体停用，文件那半照装 ----
    rt = boot({"/data/rc": "set +e\n", "/data/rc.d/chaos.sh": "x", CFG: CFG1})
    seed_flash(rt, with_block=True, fw="9.9.9")
    rt.execute("LABELSET = {}")
    click_in(rt, "1  安装")                       # 门不过 -> 一次按下就走完文件那半
    check(rt.eval("DEV_adler('/dev/bes_flash', %d)" % DEV_OFF) == ORIG_ADLER,
          "L6 门不过 -> flash 一个字节都没动")
    check(showed_in(rt, "flash 那半停用"), "L6b 日志说清 flash 那半停用了")
    check(showed_in(rt, "固件"), "L6c 报的是固件版本不符")
    check(fs_of(rt, GATE) is not None and showed_in(rt, "目录/配置"),
          "L6d 文件那半照样装（这才是「降级」，不是「什么都不做」）")

    # ===== M 日志小窗（2026-10-04：各自**铺到自己框的底部**；自启动页 = 状态 + 日志）=====
    # 用户原话：「把日志显示范围延长，到框的底部」「两个框都延长」。
    # 旧版是两边共用 MINI_LINES=6 ⇒ 框的下半截一直是空的；现在行数由**框高**算。
    import unicodedata

    def units(s):
        return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)

    rt = boot({"/data/rc": "set +e\nsh /data/rc.d/chaos.sh\nsh /data/rc.d/shellpp2.sh\n",
               "/data/rc.d/chaos.sh": "x",
               "/data/rc.d/shellpp2.sh": "x",
               CFG: '{"version":1,"modules":{"chaos":{"enable":true,"order":10},'
                    '"shellpp2":{"enable":true,"order":20}}}'})
    row = find_in(rt, None, w=312, h=50)
    assert row is not None, "找不到模块行"
    for _ in range(10):                     # 每次翻转产生 2 条日志 -> 攒够 20 条
        row.clicks[1]()
    objs2 = rt.eval("OBJS_all()")
    mtexts = []
    for i in range(1, len(objs2) + 1):
        o = objs2[i]
        if getattr(o, "is_label", False) and opt(o, "width") == 288:
            mtexts.append(str(o.label))
    check(len(mtexts) == 2, "M0 两个小窗都取到了", str(len(mtexts)))
    # ★ 两个小窗的内容**不再一样**：主页是纯日志，自启动页**以「开关:」开头**（状态面板）。
    #   用这个把它俩分开，而不是靠创建顺序（那种写法会被"谁先建"悄悄改掉）。
    main_txt = [t for t in mtexts if not t.startswith("开关:")]
    as_txt = [t for t in mtexts if t.startswith("开关:")]
    check(len(main_txt) == 1 and len(as_txt) == 1,
          "M0b 一个是纯日志（主页）/ 一个是状态面板（自启动页）",
          str([t[:12] for t in mtexts]))
    mlines = main_txt[0].split("\n") if main_txt else []
    alines = as_txt[0].split("\n") if as_txt else []
    check(len(mlines) == LINES_MAIN,
          "M1 主页小窗铺到框底：正好 %d 行（框高 %d）" % (LINES_MAIN, BOX_H_MAIN),
          "实际 %d 行: %r" % (len(mlines), mlines[:3]))
    check(len(alines) == LINES_AS,
          "M2 自启动页小窗铺到框底：正好 %d 行（框高 %d）" % (LINES_AS, BOX_H_AS),
          "实际 %d 行: %r" % (len(alines), alines[:3]))
    check(alines and mlines and alines[-1] == mlines[-1],
          "M3 两个小窗的**最后一行是同一条日志**（都跟着最新那条走）",
          "%r vs %r" % (alines[-1:], mlines[-1:]))
    check("-- 日志 --" in alines,
          "M3b 状态面板里有分隔行，下面是日志", str(alines[:8]))
    alllines = mlines + alines
    check(max([units(x) for x in alllines] or [0]) <= MAX_UNITS + 1,
          "M4 每条都按像素宽度截断过，不会折行",
          str(sorted(set(units(x) for x in alllines))[-3:]))
    check(max([units(x) for x in alllines] or [0]) * 7.5 <= 288,
          "M5 最宽那条也塞得进 288px 的标签",
          str(max([units(x) for x in alllines] or [0]) * 7.5))
    seqs = [int(x.split("  ")[0]) for x in mlines if x[:2].isdigit()]
    check(len(seqs) == len(mlines) and seqs == sorted(seqs),
          "M6 主页小窗按时间正序排（新的在底部，不是倒着的）", str(seqs))
    check("配置已改" in mlines[-1],
          "M6b 最后一行**就是**最新那条（seq %s）" % (seqs[-1] if seqs else "?"),
          repr(mlines[-1]))

    # ===== P 自启动页状态面板（照 shellpp2 的自启动页，2026-10-04）=====
    # 用户原话：「把自启动页面日志内容改成 shellpp2 那样 —— 显示开关状态，是否安装，
    #   模块状态（安装几个，启动几个）等」。
    # 实现：as_status_lines() 出 6 行摘要，前面接进小窗（as_box_text），只在**明确时刻**刷：
    #   开机 / 进自启动页 / 装·卸·开关之后 —— **不跟 log_append**（里面要读 flash）。
    # ★ 这里必须判两件容易写错的事：
    #   ① "是否安装" 只能来自 flash（按过 [2 卸载] 之后文件一个都没少 ⇒ 光看文件分不出）；
    #   ② 面板**不许**跟着每次日志刷新 —— 否则每写一行日志就要 dd 6 次读 flash。

    def panel_of(rt):
        """取自启动页那块面板的文本（两个小窗里以 '开关:' 开头的那块）。"""
        objs = rt.eval("OBJS_all()")
        for i in range(1, len(objs) + 1):
            o = objs[i]
            if getattr(o, "is_label", False) and opt(o, "width") == 288:
                t = str(o.label)
                if t.startswith("开关:"):
                    return t
        return ""

    def line_of(p, head):
        for x in p.split("\n"):
            if x.startswith(head):
                return x
        return ""

    rt = boot({"/data/rc": "set +e\nsh /data/rc.d/chaos.sh\n",
               "/data/rc.d/chaos.sh": "x", CFG: CFG1})
    p = panel_of(rt)
    check(line_of(p, "开关:").startswith("开关: 总开关"),
          "P1 面板第一行是「开关状态」", repr(line_of(p, "开关:")))
    check(line_of(p, "模块:") == "模块: 装了 1 个, 会跑 1 个",
          "P2 面板有「模块状态：装了 N 个 / 会跑 M 个」（N=rc.d 里的 .sh 数，M=/data/rc 生成行数）",
          repr(line_of(p, "模块:")))
    check(line_of(p, "rc:").startswith("rc:   "), "P3 面板有 rc 状态行",
          repr(line_of(p, "rc:")))
    check(line_of(p, "重载:").startswith("重载: "), "P4 面板有「重载：已同步 / ● 待重建」",
          repr(line_of(p, "重载:")))
    check(line_of(p, "安装:").startswith("安装: "), "P5 面板有「是否安装」这一行",
          repr(line_of(p, "安装:")))

    # ---- "是否安装"必须是**flash 的真话**：装之前不说已装、装完立刻说已装、卸完又说未装 ----
    rt = boot({"/data/rc": "set +e\n", "/data/rc.d/chaos.sh": "x", CFG: CFG1})
    seed_flash(rt)
    check("已装" not in panel_of(rt), "P6 还没装 -> 面板不说「已装」",
          repr(line_of(panel_of(rt), "安装:")))
    click_in(rt, "1  安装")
    click_in(rt, "1  安装")
    check(line_of(panel_of(rt), "安装:").startswith("安装: init rc 已装"),
          "P7 装完之后面板**立刻**变成「已装」（这就是「是否安装」的真相来源）",
          repr(line_of(panel_of(rt), "安装:")))
    click_in(rt, "2  卸载")
    click_in(rt, "2  卸载")
    check("已装" not in panel_of(rt), "P8 卸载之后面板不再说「已装」",
          repr(line_of(panel_of(rt), "安装:")))

    # ---- ★ 反向：面板**不许**跟着 log_append 刷新（否则每行日志 = 一次 flash 探测）----
    # 数 dd 次数：写 20 条日志（点 10 下模块行，每下 2 条）期间，dd 必须**一次都不涨**。
    # 这条挡的是"图省事把 refresh_as_state 塞进 log_append" —— 那会变成每次写日志都
    # 读 3 个候选块（6 次 dd），在真机上就是把界面拖慢。
    rt = boot({"/data/rc": "set +e\nsh /data/rc.d/chaos.sh\n",
               "/data/rc.d/chaos.sh": "x", CFG: CFG1})
    seed_flash(rt)
    row = find_in(rt, None, w=312, h=50)
    assert row is not None, "找不到模块行"
    dd0 = int(rt.eval("DD_count()"))
    for _ in range(10):
        row.clicks[1]()                 # 20 条日志 -> 面板会被重画 20 次
    dd1 = int(rt.eval("DD_count()"))
    check(dd1 == dd0,
          "P9 ★ 写 20 条日志期间一次 flash 都不读（面板不跟 log_append 刷新）",
          "%d -> %d 次 dd" % (dd0, dd1))

    # ---- ★ 启动判定（用户 2026-10-04 要求）：**只要有闸是关的，就显示「未启动」，
    #      要跑得手动开**。判定 = 闸在不在 × 心跳日志末行（/data/rc 写的那本账）。
    #      面板第一行就是这件事，所以它必须三种情况都说对：
    #        闸在            -> 已启动
    #        闸不在 + gate_off -> 未启动（被打断 / 被关 —— 由心跳行说清是哪种）
    #        闸不在 + 无日志   -> 未启动（全新设备，从没开过机）
    #   ★ 日志里存的是 `echo` 的**输出**（一行一个词：gate_off / cleared），
    #     不是命令行本身 —— 这里预设的就是 /data/rc 跑过之后那个文件的样子。
    #   （R 组那几个常量在这后面才定义，所以这里自己拼一份同形状的 /data/rc。）
    RC1 = "set +e\n" + IF_LINE + "\nsh /data/rc.d/chaos.sh\nfi\n"
    rt = boot({"/data/rc": RC1, GATE: "on\n", "/data/rc.d/chaos.sh": "x", CFG: CFG1,
               AS_LOG: "gate_off\ncleared\n"})
    p = panel_of(rt)
    check("已启动" in line_of(p, "开关:"), "P10 闸在 -> 面板说「已启动」",
          repr(line_of(p, "开关:")))
    check(line_of(p, "心跳:") == "心跳: 上次开机 跑到底",
          "P10b 心跳末行 cleared -> 那一行说「跑到底」", repr(line_of(p, "心跳:")))

    rt = boot({"/data/rc": RC1, "/data/rc.d/chaos.sh": "x", CFG: CFG1,
               AS_LOG: "gate_off\n"})
    p = panel_of(rt)
    check("未启动" in line_of(p, "开关:"), "★ P11 闸不在 -> 面板说「未启动」（用户要求）",
          repr(line_of(p, "开关:")))
    check("按[3]开" in line_of(p, "开关:"), "P11b 并且给出恢复动作（按 [3] 开），不让人猜",
          repr(line_of(p, "开关:")))
    check(line_of(p, "心跳:") == "心跳: 上次开机 没跑到底 -> 闸被扣住",
          "P11c 心跳行说清「没跑到底」——这是「被打断」的唯一证据",
          repr(line_of(p, "心跳:")))

    rt = boot({"/data/rc": RC1, "/data/rc.d/chaos.sh": "x", CFG: CFG1})
    p = panel_of(rt)
    check("未启动" in line_of(p, "开关:"), "P12 闸不在（从没开过机）-> 也是「未启动」",
          repr(line_of(p, "开关:")))
    check(line_of(p, "心跳:") == "心跳: 没有记录 (还没开过机)",
          "P12b 但没有日志时**不胡说**「被打断」（nil = 没证据，不许当证据）",
          repr(line_of(p, "心跳:")))

    # ============ N 落点 + /data/rc 的三态（用户 2026-10-04 报的 bug） ============
    # 报的现象：按 [1 安装] 之后日志只剩一行 `读不到 /data/rc`，而 hook 已经装进 flash
    #   ⇒ 设备重启会去跑一句 `sh /data/rc`，而那个文件**根本不存在**。
    # 根因：do_rebuild 把"文件不存在"和"文件在但读不出来"混成一件事，都直接 return。
    # 现在必须分开：不在 ⇒ 别人的行 = 0，**建出来**（新设备本来就没有 /data/rc）
    #               在但读不出 ⇒ **拒绝**（重建会把别人的行抹掉，不变量 1）
    # 靠什么分辨：`ls /data` 按**整词**找 `rc` —— 本项目已在用、设备上验过的探针
    #   （load_slices 就靠它）。假 io 不建模这个，所以专门给假 io 加了一档 UNREAD。

    # N1 /data/rc **不存在** -> 重建必须把它建出来
    rt = boot({"/data/rc.d/chaos.sh": "x\n", CFG: CFG1})
    check(fs_of(rt, "/data/rc") is None, "N1 场景就绪：/data/rc 一开始不存在")
    click_in(rt, "2  重建自启动")
    nrc = fs_of(rt, "/data/rc")
    check(isinstance(nrc, str) and nrc.startswith("set +e\n"),
          "N2 /data/rc 不在 -> 被**建出来**（不再放弃；这就是那个 bug 的回归判据）",
          repr(nrc)[:80])
    check(isinstance(nrc, str) and "sh /data/rc.d/chaos.sh" in nrc,
          "N2b 建出来的 rc 里有模块行")
    check(showed_in(rt, "不在 -> 当成空的"),
          "N2c 日志说清了「不在 -> 当成空的」")
    check(not showed_in(rt, "读不到"),
          "N2d 日志里**不该**再出现「读不到 /data/rc」（那句话把两种状态混成一种）")

    # N3 文件**在**但读不出来 -> 拒绝重建，一个字节都不写
    rt = boot({"/data/rc": OTHERS_RC, "/data/rc.d/chaos.sh": "x\n", CFG: CFG1})
    rt.execute("UNREAD_set('/data/rc')")
    n_before = w_of(rt, "/data/rc")
    raw_before = fs_of(rt, "/data/rc")
    click_in(rt, "2  重建自启动")
    check(w_of(rt, "/data/rc") == n_before,
          "N3 读不出来 -> **一个字节都不写**（拒绝重建）",
          "%d -> %d" % (n_before, w_of(rt, "/data/rc")))
    check(fs_of(rt, "/data/rc") == raw_before, "N3b 内容也没被改")
    check(showed_in(rt, "拒绝重建"), "N3c 日志明说拒绝了")
    check(showed_in(rt, "怕抹掉别人的行"), "N3d 而且说清了理由（不变量 1）")

    # N4 落点：管理器自己的东西只许在 /data/10pro.autorun，一个字节都不落 /data/chaos
    rt = boot({"/data/rc.d/chaos.sh": "x\n", CFG: CFG1})
    click_in(rt, "2  重建自启动")
    keys = FS_keys_of(rt, "/data/10pro.autorun")
    check("/data/10pro.autorun/manager.log" in keys,
          "N4 日志落在 /data/10pro.autorun/manager.log（自己的目录）", str(keys))
    check(FS_keys_of(rt, "/data/chaos") == [],
          "N4b 一个字节都不落在 /data/chaos（管理器是独立项目）",
          str(FS_keys_of(rt, "/data/chaos")))

    # ============ O 列表来源（用户 2026-10-04 新规） ============
    # 用户原话：「当没有安装的时候，模块管理页面直接不显示。只有当 /data/rc 存在脚本
    #            但 rc.d 里没脚本才显示缺脚本。（按重建就把多余的 rc 脚本删掉）」
    # 落到实现上 = merge() 的列表来源**只有两路**：
    #     rc.d 里的 .sh  ∪  /data/rc 里的生成行引用
    #   配置（autorun.json）**只提供 enable/core/order/desc，不决定显示**。
    # 三条要判：
    #   (a) 两处都空 ⇒ 列表**一条都不显示**（且要说明为什么空）
    #   (b) 「缺脚本」只在那一种情况下出现（rc 有行 + 文件不在），配置里的陈年条目不算
    #   (c) 按 [重建] 删掉指向不存在脚本的多余行；删完那条缺脚本不再显示；
    #       配置里也不许留着"文件早没了"的条目

    def rt_rows(rt):
        objs = rt.eval("OBJS_all()")
        out = []
        for i in range(1, len(objs) + 1):
            o = objs[i]
            try:
                if o.opts["w"] == 312 and o.opts["h"] == 50:
                    out.append(o)
            except Exception:
                pass
        return out

    def rt_row_text(rt, i):
        """第 i 行的 (名字, 状态字)。偏移与 row_state 同一套（CENTER+显式宽高）。"""
        o = rt_rows(rt)[i - 1]
        nm, st = "", ""
        for j in range(1, len(o.kids) + 1):
            k = o.kids[j]
            if not getattr(k, "is_label", False):
                continue
            try:
                x = k.opts["align"]["x_ofs"]
                y = k.opts["align"]["y_ofs"]
            except Exception:
                continue
            if x == -54 and y == -11 and nm == "":
                nm = str(k.label)
            if x == 96:
                st = str(k.label)
        return nm, st

    def rt_list(rt):
        return [rt_row_text(rt, i) for i in range(1, ROW_POOL + 1)]

    def rt_names(rt):
        return [nm for nm, _ in rt_list(rt) if nm]

    CFG_LEGACY = '{"version":1,"modules":{"legacy":{"enable":true,"order":5}}}'

    # ---- (a) 没装：rc.d 里只有配置、没有 .sh；/data/rc 也不在 ----
    rt = boot({"/data/rc.d/autorun.json": CFG_LEGACY})
    check(all(nm == "" and st == "" for nm, st in rt_list(rt)),
          "O1 没装模块时列表**一条都不显示**（连配置里登记过的也不显示）",
          str(rt_list(rt)[:4]))
    click_in(rt, "3  模块管理")
    check(showed_in(rt, "模块列表为空"),
          "O1b 而且明说了「模块列表为空」（一片空白要说清为什么）")

    # ---- (b) 缺脚本的新语义 ----
    rt = boot({"/data/rc": "set +e\nsh /data/rc.d/chaos.sh\nsh /data/rc.d/ghost.sh\n",
               "/data/rc.d/chaos.sh": "x\n",
               "/data/rc.d/autorun.json": CFG_LEGACY})
    st = dict([(nm, s) for nm, s in rt_list(rt) if nm])
    check(st.get("ghost") == "缺脚本",
          "O2 /data/rc 有那一行、rc.d 里没那个文件 -> 显示「缺脚本」", str(st))
    check(st.get("chaos") == "允许",
          "O2b 文件在的那个照常显示状态（这里没被禁过 -> 允许）", str(st))
    check("legacy" not in st,
          "O2c 只在配置里登记过、rc 与 rc.d 都没有的项**不显示**（陈年条目不常驻）",
          str(st))

    # ---- (c) 重建删多余行 ----
    w_rc = w_of(rt, "/data/rc")
    click_in(rt, "2  重建自启动")
    rc2 = str(fs_of(rt, "/data/rc"))
    check("sh /data/rc.d/ghost.sh" not in rc2,
          "O3 按 [重建] 删掉了指向不存在脚本的**多余行**", repr(rc2))
    check("sh /data/rc.d/chaos.sh" in rc2,
          "O3b 文件在的那一行照旧保留", repr(rc2))
    check(w_of(rt, "/data/rc") == w_rc + 1, "O3c 这一下真的写盘了（内容确实变了）")
    # 再按一次：先重扫（ghost 已经不在 rc 里了）-> 列表里不该再有它，且幂等不写盘
    w_after = w_of(rt, "/data/rc")
    click_in(rt, "2  重建自启动")
    check("ghost" not in rt_names(rt),
          "O3d 重建之后再扫，那条缺脚本从列表里**消失**（不再常驻）", str(rt_names(rt)))
    check(w_of(rt, "/data/rc") == w_after,
          "O3e 第二次重建内容没变 -> 不写盘（幂等）",
          "%d -> %d" % (w_after, w_of(rt, "/data/rc")))
    cfg2 = json.loads(str(fs_of(rt, CFG)))
    check("legacy" not in cfg2.get("modules", {}),
          "O3f 配置里不留『文件早没了』的陈年条目", str(sorted(cfg2.get("modules", {}))))
    check("ghost" not in cfg2.get("modules", {}),
          "O3g 缺脚本的残留项也不落进配置（配置只记录文件在的模块）",
          str(sorted(cfg2.get("modules", {}))))

    # ============ R 总开关的「信任」（2026-10-04 用户报的 bug 的回归判据） ============
    # ★ 用户原话：「模块管理的页面有bug，禁止之后再启用会导致自启动失效」。
    #   查下来根因**不在模块开关本身**：禁止 -> [重建] -> 启用 -> [重建] 这条链产出的
    #   /data/rc 内容是对的（R1~R3 把它钉住）。此前门只在 G2/G3 验了「屏幕上翻回允许」，
    #   **两次翻转之间从没按过 [重建]**，所以这一层一直是空白。
    #   真凶是 ensure_gate()：它拿「/data/rc 里有没有 IF_LINE」当「这台是不是从没建过
    #   总开关的老设备」的判据 —— 而 IF_LINE 是 build_rc 在 **#run > 0** 时才写的，
    #   它是「**有没有模块在跑**」的函数，与「用户关没关过总开关」毫无关系。
    #   ⇒ 只要出现「所有模块都不出行」，下一次 [重建] 就会把用户关掉的总开关
    #     **静默补建为开** —— 用户设的「关」凭空失效，这就是"自启动失效"。
    #   修法：set_gate(false) / [2 卸载] 落持久凭据 GATE_OFF；ensure_gate 见它就不补建；
    #         set_gate(true) / [1 安装] 撤掉它。R5~R11 咬住这套语义。
    GATE_OFF = "/data/rc.d/.autorun.off"
    RC_FULL = "set +e\n" + IF_LINE + "\nsh /data/rc.d/shellpp2.sh\nfi\n"
    JSON_ON = '{"version": 1, "modules": {"shellpp2": {"enable": true, "order": 20}}}\n'
    SH_X = "x\n"

    def mod_row_in(rt, name):
        """点模块页里名为 name 的那一行（名字 Label 是行内第一个标签）。"""
        objs = rt.eval("OBJS_all()")
        for i in range(1, len(objs) + 1):
            o = objs[i]
            if len(o.clicks) == 0:
                continue
            try:
                if o.opts["w"] != 312 or o.opts["h"] != 50:
                    continue
            except Exception:
                continue
            labs = kids_in(o)
            if labs and labs[0] == name:
                o.clicks[1]()
                return True
        return False

    def bar_in(rt, text):
        """模块页底下那三个 100x46 功能键。
        ★ find_in 给了 w/h 就**只按尺寸找、不看文本**，而这三个尺寸完全相同
          ⇒ 会永远点到第一个。所以必须尺寸 + 文本一起判。"""
        objs = rt.eval("OBJS_all()")
        for i in range(1, len(objs) + 1):
            o = objs[i]
            if len(o.clicks) == 0:
                continue
            try:
                if o.opts["w"] != 100 or o.opts["h"] != 46:
                    continue
            except Exception:
                continue
            if text in kids_in(o):
                o.clicks[1]()
                return True
        return False

    def gen_in_rc(rt):
        rc = fs_of(rt, "/data/rc")
        return rc is not None and "sh /data/rc.d/shellpp2.sh" in str(rc)

    # ---- R1~R4：禁 -> [重建] -> 启 -> [重建]，rc 内容必须原样回来 ----
    rt = boot({"/data/rc": RC_FULL, GATE: "on\n", "/data/rc.d/shellpp2.sh": SH_X,
               CFG: JSON_ON})
    check(gen_in_rc(rt), "R1 起点: /data/rc 里有生成行")
    mod_row_in(rt, "shellpp2")
    bar_in(rt, "重建")
    check(not gen_in_rc(rt), "R2 禁止 + [重建] -> 生成行消失")
    mod_row_in(rt, "shellpp2")
    bar_in(rt, "重建")
    check(gen_in_rc(rt), "R3 启用 + [重建] -> 生成行**原样回来**（这一层本来就是对的）")
    check(fs_of(rt, GATE) is not None, "R4 全程总开关还在（用户没关过）")

    # ---- R5~R9：用户 [4 关闭] 之后，"禁->重建->启->重建"不许把开关开回来 ----
    rt = boot({"/data/rc": RC_FULL, GATE: "on\n", "/data/rc.d/shellpp2.sh": SH_X,
               CFG: JSON_ON})
    click_in(rt, "4  关闭")
    check(fs_of(rt, GATE) is None, "R5 [4 关闭] -> 总开关文件被删")
    check(fs_of(rt, GATE_OFF) is not None, "R5b 同时留下『用户显式关过』的凭据")
    check(str(fs_of(rt, "/data/rc")) == RC_FULL,
          "R5c 关闭**不写** /data/rc（逐模块开关一个字节没动, 开回来即恢复）")
    mod_row_in(rt, "shellpp2")
    bar_in(rt, "重建")
    check(not gen_in_rc(rt), "R6 禁止 + [重建] -> 生成行消失（rc 里那道门的文本证据也没了）")
    mod_row_in(rt, "shellpp2")
    bar_in(rt, "重建")
    check(gen_in_rc(rt), "R7 启用 + [重建] -> 生成行回来")
    check(fs_of(rt, GATE) is None,
          "★ R8 但总开关**不许自己回来**（用户关着就是关着 —— 这就是那个 bug）")
    click_in(rt, "3  开启")
    check(fs_of(rt, GATE) is not None, "R9 [3 开启] 才把总开关打开")
    check(fs_of(rt, GATE_OFF) is None, "R9b 并且撤掉了『关过』的凭据（下次不会再被挡住）")

    # ---- R10：老设备迁移这条原有行为不能被修过头 ----
    rt = boot({"/data/rc": "set +e\nsleep 2\n",
               "/data/rc.d/chaos.sh": "sh /data/chaos/rc &\n", CFG: CFG1})
    bar_in(rt, "重建")
    check(fs_of(rt, GATE) is not None,
          "R10 老设备（rc 里从来没有门、也没有凭据）仍然补建总开关, 默认开")

    # ---- R11：[2 卸载] 也要留凭据（卸载 = 明确不要自启动） ----
    rt = boot({"/data/rc": RC_FULL, GATE: "on\n", "/data/rc.d/shellpp2.sh": SH_X,
               CFG: JSON_ON})
    click_in(rt, "2  卸载")
    click_in(rt, "2  卸载")
    check(fs_of(rt, GATE) is None, "R11 [2 卸载] -> 总开关被删")
    check(fs_of(rt, GATE_OFF) is not None, "R11b 卸载也留凭据")
    mod_row_in(rt, "shellpp2")
    bar_in(rt, "重建")
    check(fs_of(rt, GATE) is None, "R11c 之后 [重建] 不会把开关补回来")

    # ---- R12：★ 2026-10-04 真机报的"自启动不生效" —— [4 关闭] 之后按 [1 安装]，
    #      总开关必须**真的**打开（改前：日志说"打开"、实际还是关的 ⇒ 开机不跑）。
    #      根因与 R5~R9 同源：ensure_gate 拿 rc 里的 IF_LINE 反推用户意图；而 [4 关闭]
    #      **刻意**把门的文本留在 rc 里（开回来才可逆）⇒ 那条判据把它误读成"开关已管好"。
    #      v0.6.5 修法：① 删掉 ensure_gate 里那条 IF_LINE 判据；② [1 安装] **直接写**总开关。
    rt = boot({"/data/rc": RC_FULL, GATE: "on\n", "/data/rc.d/shellpp2.sh": SH_X,
               CFG: JSON_ON})
    click_in(rt, "4  关闭")
    check(fs_of(rt, GATE) is None and fs_of(rt, GATE_OFF) is not None,
          "R12a 前置：[4 关闭] 之后开关关、凭据在（rc 里那道门**还在**）")
    check(IF_LINE in str(fs_of(rt, "/data/rc")),
          "R12b 前置：关闭不动 rc，门的文本留在原地（正是被误读的那条证据）")
    click_in(rt, "1  安装", times=2)      # 固件门未过/已过都按两次，两条路都能走完
    check(fs_of(rt, GATE) is not None,
          "★ R12 [4 关闭] 之后按 [1 安装] -> 总开关**真的被打开**（不是只有日志说打开）")
    check(fs_of(rt, GATE_OFF) is None, "R12c 并且撤掉了『关过』的凭据")
    check(gen_in_rc(rt), "R12d 重建出来的模块行还在门里 -> 开机会跑")

    # ---- R13：★★ 2026-10-04 新方案的**核心** —— 开机被看门狗打断之后闸停在【关】，
    #      这时按 [重建] **绝不许**把闸补回来：补回来 = 防砖作废 = 下一次开机
    #      又去跑那批把设备搞崩的模块。
    #      识别「被打断」的**唯一**证据 = 心跳日志末行 `gate_off`（/data/rc 扣闸那刻写的）。
    #      ⇒ [重建] 只报状态；恢复必须走**明确动作** [3 开启] / [1 安装]。
    rt = boot({"/data/rc": RC_FULL, GATE: "on\n", "/data/rc.d/shellpp2.sh": SH_X,
               CFG: JSON_ON})
    rt.execute("UNSET(%r)" % GATE)                     # 闸被开机脚本扣走了
    rt.execute("SET(%r, %r)" % (AS_LOG, "gate_off\n"))  # 心跳末行 = 扣闸那一刻留下的
    bar_in(rt, "重建")
    check(fs_of(rt, GATE) is None,
          "★ R13 心跳末行 gate_off（上次没跑到底）-> [重建] **不补建**闸（防砖不许被绕过）")
    check(showed_in(rt, "总开关是关的") and showed_in(rt, "上次开机没跑到底"),
          "R13b 而且把原因说清（光说「关」不够 —— 要分清用户关的还是被打断的）")
    check(showed_in(rt, "未启动"), "R13c 方向上也报「未启动」")
    click_in(rt, "3  开启")
    check(fs_of(rt, GATE) is not None,
          "R13d 恢复只能靠明确动作 [3 开启]（这一下才把闸加回来）")
    check(gen_in_rc(rt), "R13e 开回来之后生成行还在门里 -> 下次开机会跑")

    # ---- R14：老设备迁移**不许被修过头** —— 从没跑过的 rc（没有心跳日志）照旧补建。
    #      与 R10 是同一件事，但这里用「有模块行 + 闸不在 + 无日志」再咬一遍：
    #      防止有人把防砖判据写宽成"闸不在就不补建"（那会让新设备永远起不来）。
    rt = boot({"/data/rc": RC_FULL, "/data/rc.d/shellpp2.sh": SH_X, CFG: JSON_ON})
    bar_in(rt, "重建")
    check(fs_of(rt, GATE) is not None,
          "R14 没有心跳日志（从没开过机）-> [重建] 仍然补建闸（新设备要起得来）")

    print()
    if FAILS:
        print("SIM-MANAGER: FAIL (%d/%d)" % (len(FAILS), NCHK[0]))
        for f in FAILS:
            print("   - " + f)
        return 2
    print("SIM-MANAGER: PASS (%d)" % NCHK[0])
    return 0


if __name__ == "__main__":
    if os.path.realpath(sys.executable).lower() != os.path.realpath(LUPA_PY).lower():
        try:
            import lupa  # noqa
        except ImportError:
            print("请用这个解释器跑: %s" % LUPA_PY)
            sys.exit(3)
    sys.exit(main())
