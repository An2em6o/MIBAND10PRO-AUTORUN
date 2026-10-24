# -*- coding: utf-8 -*-
"""把管理器界面**离线渲染成 PNG**。

原理（三步，都不是"重画一遍 UI"，而是**真跑真源再画它记录下来的东西**）：

  ① 真 Lua 解释器(lupa) + 假 lvgl —— 载入真源
     `Watchface/module.autorun.Manager/_Lua/module-autorun-manager.lua`
     假 lvgl 只做一件事：**原样记下每个对象的 opts**（align/x_ofs/y_ofs/
     width/height/bg_color/bg_opa/border_width/border_color/radius/pad_*/text/
     text_color/text_font）以及父子关系。

  ② 切到目标页 —— 真源里 show_* 都是 local（外面拿不到），但**四页本身就是
     内层 root 的直系子对象、数量恰好 4、创建顺序固定 = main/autostart/modules/log**。
     所以按序号把目标页 `align.y_ofs` 改成 0、其余改成 PAGE_HIDE(2000) 即可。
     **只有 y_ofs==0 的页会被画**（离屏页不画）。

  ③ 用 PIL 把对象树画出来 —— 按 z 序（OBJS 的插入顺序就是 LVGL 的创建顺序），
     每个对象先画自己的底（bg_color/bg_opa/radius/border），再画子对象。
     ★ 几何两坑（都踩过）：CENTER 是**相对父容器内容区**居中（逐层累加 px/py/pw/ph），
       不是相对屏幕；没写 width 的 Label 要按**文字自然宽度**走（否则 CENTER 算出负偏移、
       文字跑出框外）。

★ 这是**几何近似**，不是像素级复刻：假 lvgl 里没有真实 LVGL 的布局引擎，
  文字也不会按固件字体度量折行。所以它**能**用来看"大概长什么样 / 有没有重叠 /
  颜色与层级对不对"，**不能**当作"真机观感的判据"（那是本项目一贯的规矩：
  UI 观感一律以真机为准）。用途是：写文档配图、给 PR 附截图、肉眼查重叠。

用法：
  python tool/render_manager_ui.py                    # 四页都出（空设备状态）
  python tool/render_manager_ui.py --seed             # 四页都出（预置一台典型设备，配图用）
  python tool/render_manager_ui.py --page main        # 只出主页
  python tool/render_manager_ui.py --out docs/img     # 换输出目录
  python tool/render_manager_ui.py --scale 2          # 2 倍图（写文档更好看）

★ 为什么需要 --seed：空设备画出来是"什么都没装"（扫描 0 项、模块页空白），
  配文档没信息量。--seed 会在载入真源**之前**往假文件系统里放一台**典型设备**：
  装了 chaos + shellpp2 两个模块、闸开着(.autorun.on)、上次开机跑到底
  (.autorun.log 末行 cleared)、/data/rc 已被生成过（生成 2 行）⇒ 面板全绿。
  ⚠️ 假 os.execute 必须支持 shell 重定向（`cmd > 文件` 再读回），因为管理器没有
     popen——它靠 `ls /data/rc.d > .ls.tmp` 再读文件拿目录列表。不实现重定向 ⇒
     扫描永远 0 项（这个坑踩过：表现为"seed 了但模块页还是空的"）。
"""
import argparse
import os
import sys

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                      # 仓库根
SRC = os.path.join(ROOT, "Watchface", "module.autorun.Manager",
                   "_Lua", "module-autorun-manager.lua")
OUT_DEFAULT = os.path.join(ROOT, "docs", "img")

W, H = 336, 480                                   # 屏幕（真源里 W,H）
PAGE_HIDE = 2000

LUPA_PY = (r"C:\Users\Administrator\.workbuddy\binaries\python"
           r"\envs\default\Scripts\python.exe")

# 字体：真源用 MiSans（仓库里没有，也不该分发），本机拿微软雅黑近似。
#   名字里带 Demi/Bold 的用粗体那份。
FONT_REG = r"C:\Windows\Fonts\msyh.ttc"
FONT_BOLD = r"C:\Windows\Fonts\msyhbd.ttc"


# ===========================================================================
# ① 假环境（Lua 侧）：只记录，不做任何真渲染
# ===========================================================================
FAKE_LVGL = r'''
-- ============================ 记录容器 ============================
OBJS   = {}            -- 按创建顺序
BY_ID  = {}
NEXTID = 0
TIMERS = {}            -- lvgl.Timer 创建出来的（测试用：手动调 cb 模拟到点）

local function newobj(parent, opts)
  NEXTID = NEXTID + 1
  local o = {
    id      = NEXTID,
    opts    = {},
    parent  = parent,
    kids    = {},
    clicks  = {},
    is_label= false,
  }
  -- 原样拷 opts（含嵌套的 align 表、text_font 表 —— 都当**引用**收下，
  -- 后面 set{} 改的就是它本身，正好反映"最终状态"）
  if type(opts) == "table" then
    for k, v in pairs(opts) do o.opts[k] = v end
  end
  function o:set(t)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do self.opts[k] = v end
  end
  function o:clear_flag(_) end
  function o:add_flag(_) end
  function o:onClicked(fn) self.clicks[#self.clicks + 1] = fn end
  function o:delete() end
  function o:scroll_by_bounded(...) end
  function o:scroll_to_y(...) end
  if parent and parent.kids then parent.kids[#parent.kids + 1] = o end
  OBJS[#OBJS + 1] = o
  BY_ID[o.id] = o
  -- ★ 设备上的 lv_obj 是 **userdata**，给它挂自定义字段会当场报
  --   "attempt to index a lv_obj value"。假 lvgl 用 table 模拟，天生允许挂字段 ——
  --   那就等于**帮着隐藏 bug**（2026-10-24 真机上就是这么炸的：b.lbl = …）。
  --   这里加个门：构造完再写任何新字段一律报错，逼着用侧表存引用。
  setmetatable(o, { __newindex = function(_, k)
    error("假 lvgl: lv_obj 不能挂字段（" .. tostring(k) .. "）—— 真机会崩", 2)
  end })
  return o
end

lvgl = {
  Object = function(p, o) return newobj(p, o) end,
  Label  = function(p, o)
    local x = newobj(p, o)
    x.is_label = true
    return x
  end,
  Font   = function(name, size) return { name = name, size = size } end,
  OPA    = function(v) return v end,
  HOR_RES= function() return 336 end,
  VER_RES= function() return 480 end,
  -- ★ 只暴露**平台上真有先例**的三个（全仓统计：CENTER 170 / TOP_LEFT 66 / TOP_MID 23）。
  --   别的常量在真机上可能是 nil，而假环境"什么都有"会把这种 bug 藏住
  --   （2026-10-24 踩过：toast 用 BOTTOM_MID ⇒ 真机上面板被摆到屏幕外，完全不显示）。
  ALIGN  = setmetatable({ CENTER = 1, TOP_LEFT = 2, TOP_MID = 3 },
             { __index = function(_, k)
                 error("假 lvgl: ALIGN." .. tostring(k)
                   .. " 在本平台没有先例（真机未验），请用 CENTER/TOP_LEFT/TOP_MID", 2)
               end }),
  FLAG   = { SCROLLABLE = "s", CLICKABLE = "c", EVENT_BUBBLE = "b",
             HIDDEN = "h" },
  -- 平台真有这个 API（Canopus / Shell++ 安装器在用）；假环境只记录，不自动触发。
  Timer  = function(props)
    function props:resume() self.paused = false end
    function props:delete() self.deleted = true end
    function props:ready() end
    TIMERS[#TIMERS + 1] = props
    return props
  end,
}
function require(n) if n == "lvgl" then return lvgl end error("no module: "..n) end

-- ============================ 假文件系统 ============================
-- 管理器在**载入时**就会 mkdir / 扫目录 / 读配置 —— 全部走 os.execute 与 io。
-- 这里给一个够用的内存 FS（能建能读能列），让启动序列跑到底。
FS = {}
DIRS = { ["/data"] = true, ["/data/rc.d"] = true, ["/data/10pro.autorun"] = true }
WCOUNT = {}

local function norm(p)
  p = tostring(p or "")
  p = p:gsub("//+", "/")
  if #p > 1 and p:sub(-1) == "/" then p = p:sub(1, -2) end
  return p
end
function FS_set(p, v) FS[norm(p)] = v end
function FS_get(p) return FS[norm(p)] end
function FS_list() local a = {} for k in pairs(FS) do a[#a+1]=k end table.sort(a) return a end
function FS_keys() return table.concat(FS_list(), "\n") end
function FS_reset(t)
  for k in pairs(FS) do FS[k] = nil end
  for k in pairs(WCOUNT) do WCOUNT[k] = nil end
  for k, v in pairs(t or {}) do FS[norm(k)] = v end
end

-- 假 io：只支持管理器实际用到的 open/read/write/close
local function make_fh(path, mode)
  local fh = { path = norm(path), mode = mode, buf = "", pos = 1, closed = false }
  if mode:find("r") then
    local v = FS[fh.path]
    fh.buf = (type(v) == "string") and v or nil
    if fh.buf == nil then return nil end
  else
    fh.buf = ""
  end
  function fh:read(fmt, n)
    local s = self.buf
    if s == nil then return nil end
    if fmt == "*a" or fmt == "a" then
      local r = s:sub(self.pos)
      self.pos = #s + 1
      return r
    end
    n = tonumber(fmt) or n or 1
    local r = s:sub(self.pos, self.pos + n - 1)
    self.pos = self.pos + #r
    if #r == 0 then return nil end
    return r
  end
  function fh:write(...)
    local parts = { ... }
    for i = 1, #parts do self.buf = self.buf .. tostring(parts[i]) end
    return self
  end
  function fh:seek(whence, off)
    if whence == "set" then self.pos = (off or 0) + 1
    elseif whence == "cur" then self.pos = self.pos + (off or 0)
    elseif whence == "end" then self.pos = #(self.buf or "") + (off or 0) + 1
    end
    return self.pos
  end
  function fh:close()
    if self.mode:find("w") or self.mode:find("a") then
      if self.mode:find("a") then
        FS[self.path] = (FS[self.path] or "") .. self.buf
      else
        FS[self.path] = self.buf
      end
      WCOUNT[self.path] = (WCOUNT[self.path] or 0) + 1
    end
    self.closed = true
    return true
  end
  return fh
end
io = {
  open = function(p, m) return make_fh(p, m or "r") end,
  read = function() return nil end,
  write = function(...) return io end,
}

-- 假 os：execute 只认几条安全命令（mkdir -p / rm -f / ls / getprop），
-- ★ 必须支持 shell 重定向：管理器没有 popen，它靠 `cmd > 中转文件` 再读文件拿输出
--   （TEMP_LIST = /data/10pro.autorun/.ls.tmp）。不实现重定向 => 扫描永远 0 项。
os = os or {}
local real_getenv = os.getenv

-- 把重定向从命令里剥出来：返回 (纯命令, 目标文件, 是否追加)
local function split_redir(cmd)
  local append = false
  local target = nil
  -- 先去 stderr 重定向（2>/dev/null 之类），这些不影响 stdout 结果
  cmd = cmd:gsub("2>%s*/dev/null", "")
  cmd = cmd:gsub("2>%s*&1", "")
  local head, target = cmd:match("^(.-)%s*>>%s*(.+)$")
  if head then append = true
  else
    head, target = cmd:match("^(.-)%s*>%s*(.+)$")
  end
  if head then
    target = target:gsub("^%s+", ""):gsub("%s+$", "")
    return head:gsub("%s+$", ""), target, append
  end
  return cmd:gsub("%s+$", ""), nil, false
end

local function run_cmd(c)   -- 返回 (输出文本, 退出码)
  local d = c:match("^mkdir%s+%-p%s+(.+)$")
  if d then DIRS[norm(d)] = true return "", 0 end
  local f = c:match("^rm%s+%-f%s+(.+)$")
  if f then FS[norm(f)] = nil return "", 0 end
  local l = c:match("^ls%s+(.+)$")
  if l then
    l = norm((l:gsub("^%s+", ""):gsub("%s+$", "")))
    local hits = {}
    for _, p in ipairs(FS_list()) do
      if p:sub(1, #l + 1) == l .. "/" and not p:sub(#l + 2):find("/") then
        hits[#hits + 1] = p:sub(#l + 2)
      end
    end
    if #hits == 0 and not DIRS[l] then return "", 1 end
    return table.concat(hits, "\n") .. "\n", 0
  end
  local g = c:match("^getprop%s+(.+)$")
  if g then
    -- flash 探针：夹具里没有 flash，恒返回"未知版本"（真机上有值）
    return "", 0
  end
  return "", 0
end

os.execute = function(raw)
  local cmd, target, append = split_redir(tostring(raw or ""))
  local outp, code = run_cmd(cmd)
  if target then
    target = norm(target)
    if append then FS[target] = (FS[target] or "") .. outp
    else FS[target] = outp end
    -- 顺带把目录项也记进去（万一重定向目标是新路径）
  else
    if #outp > 0 then print(outp:gsub("\n$", "")) end
  end
  return code
end
os.getenv = function(k)
  if k == "PATH" or k == "HOME" or k == "PWD" then return "/data" end
  return real_getenv and real_getenv(k) or nil
end

-- ============================ 收尾：暴露快照 ============================
-- 只回传 ASCII 安全的东西；中文字符串要按 UTF-8 传回去，用 unescape 还原。
function SNAP()
  local lines = {}
  for i = 1, #OBJS do
    local o = OBJS[i]
    lines[#lines + 1] = tostring(o.id)
  end
  return table.concat(lines, ",")
end
'''


# ===========================================================================
# ② 取一页：跑真源 + 切页 + 导出对象树
# ===========================================================================
LUA_DRIVER = r'''
%(fake)s

-- ============================ 预置一盘"已装好的设备" ============================
-- 空设备画出来是"什么都没装"，配文档不好看也没信息量。
-- %(seed)s = 1 时造一台**典型设备**：装了 chaos + shellpp2 两个模块、闸开着、
--   上次开机跑到底（心跳末行 cleared）、flash 那边认出来是"已装"。
if %(seed)d == 1 then
  FS_set("/data/rc.d/chaos.sh", "set +e\necho start > /data/chaos/autostart.log\n")
  FS_set("/data/rc.d/shellpp2.sh", "set +e\necho start > /data/shellpp-ii/autostart.log\n")
  FS_set("/data/rc.d/legacy-notes.txt", "not a module\n")   -- 不该被当成模块
  FS_set("/data/rc.d/.autorun.on", "on\n")                  -- 闸：开
  FS_set("/data/rc.d/.autorun.log", "gate_off\ncleared\n")  -- 心跳：跑到底
  FS_set("/data/rc.d/autorun.json",
    '{"version":1,"modules":[{"name":"chaos","enable":true,"core":false,' ..
    '"order":10,"delay":8,"desc":"Chaos 模块"},{' ..
    '"name":"shellpp2","enable":true,"core":false,' ..
    '"order":20,"delay":8,"desc":"Shell++ II"}]}')
  FS_set("/data/rc",
    "set +e\n" ..
    "echo gate_off >> /data/rc.d/.autorun.log\n" ..
    "if [ -f /data/rc.d/.autorun.on ];then\n" ..
    "rm -f /data/rc.d/.autorun.on\n" ..
    "sleep 8\n" ..
    "sh /data/rc.d/chaos.sh\n" ..
    "sleep 1\n" ..
    "sh /data/rc.d/shellpp2.sh\n" ..
    "sleep 15\n" ..
    "echo cleared >> /data/rc.d/.autorun.log\n" ..
    "echo on > /data/rc.d/.autorun.on\n" ..
    "fi\n")
end

local SRC = %(src)s

local ok, err = pcall(function()
  local chunk = assert(load(SRC, "@manager"))
  chunk()
end)
if not ok then
  print("LOADERR: " .. tostring(err))
  return
end

-- 切到目标页。真源里 show_* 都是 local，拿不到；但四页本身在 OBJS 里，
-- 它们都是"内层 root"（#2，w/h=336/480、parent 是外框 #1）的直系子对象，
-- 且数量恰好 4、按创建顺序 = main/autostart/modules/log（真源建页顺序固定）。
local want = %(page)d          -- 0=main 1=autostart 2=modules 3=log

-- 找外框（没有 parent 的那个）
local outer = nil
for i = 1, #OBJS do if OBJS[i].parent == nil then outer = OBJS[i] break end end
if outer == nil then print("LOADERR: no outer root") return end

-- 内层 root = 外框的第一个 kid
local inner = outer.kids[1]
if inner == nil then print("LOADERR: no inner root") return end

-- 内层 root 的直系子里，尺寸等于整屏的下标 1..4 就是四页
local pages = {}
for _, k in ipairs(inner.kids) do
  local o = k.opts
  if o.w == 336 and o.h == 480 then
    pages[#pages + 1] = k
  end
end
if #pages < 4 then print("LOADERR: pages=" .. #pages) return end
for i = 1, 4 do
  local y = (i == want + 1) and 0 or 2000
  pages[i].opts.align = { type = 1, x_ofs = 0, y_ofs = y }
end

-- 导出（UTF-8 逐字节 hex，Python 侧还原）
local out = {}
local function esc(s)
  s = tostring(s or "")
  local t = {}
  for i = 1, #s do t[#t + 1] = string.format("%%02X", s:byte(i)) end
  return table.concat(t)
end
local function num(v) if v == nil then return "N" end return tostring(v) end

for i = 1, #OBJS do
  local o = OBJS[i]
  local p = o.opts or {}
  -- ★ align 可能是表（正常），也可能是数字/nil（假 lvgl 在某些写法下收进来的形态）。
  --   一律取成三个独立标量，别让导出在类型上翻车。
  local at, ax, ay = nil, nil, nil
  local al = p.align
  if type(al) == "table" then
    at, ax, ay = al.type, al.x_ofs, al.y_ofs
  elseif type(al) == "number" then
    at = al
  end
  local fnt = nil
  if type(p.text_font) == "table" then fnt = p.text_font.size end
  local rec = {
    o.id,
    o.parent and o.parent.id or -1,
    o.is_label and 1 or 0,
    num(p.w), num(p.h),
    num(p.x), num(p.y),                    -- 直接给的坐标（少数对象用）
    num(at), num(ax), num(ay),
    num(p.bg_color), num(p.bg_opa), num(p.radius),
    num(p.border_width), num(p.border_color),
    num(p.pad_all), num(p.pad_left), num(p.pad_right), num(p.pad_top), num(p.pad_bottom),
    num(fnt),
    esc(p.text),
    num(p.text_color),
  }
  out[#out + 1] = table.concat(rec, "|")
end
print("OBJSREC-BEGIN")
print(table.concat(out, "\n"))
print("OBJSREC-END")
'''


def snapshot(page_index, src_path, seed=False):
    """跑真源、切页、把对象树抓回 Python。"""
    import lupa
    src = open(src_path, "r", encoding="utf-8").read()
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    driver = LUA_DRIVER % {
        "fake": FAKE_LVGL,
        "src": "%r" % src,
        "page": page_index,
        "seed": 1 if seed else 0,
    }
    # print 收集
    captured = []
    lua.globals().print = lambda *a: captured.append(
        " ".join(str(x) for x in a))
    lua.execute(driver)
    text = "\n".join(captured)
    if "LOADERR" in text:
        raise RuntimeError("载入真源失败:\n" + text)
    if "OBJSREC-BEGIN" not in text:
        raise RuntimeError("没拿到对象树:\n" + text[:3000])
    body = text.split("OBJSREC-BEGIN", 1)[1].split("OBJSREC-END", 1)[0]
    recs = []
    for line in body.strip().splitlines():
        f = line.split("|")
        recs.append({
            "id": int(f[0]),
            "parent": int(f[1]),
            "is_label": int(f[2]) == 1,
            "w": parse_num(f[3]), "h": parse_num(f[4]),
            "x": parse_num(f[5]), "y": parse_num(f[6]),
            "at": parse_num(f[7]), "ax": parse_num(f[8]), "ay": parse_num(f[9]),
            "bg": parse_num(f[10]), "bg_opa": parse_num(f[11]),
            "radius": parse_num(f[12]),
            "bw": parse_num(f[13]), "bc": parse_num(f[14]),
            "pad_all": parse_num(f[15]), "pad_l": parse_num(f[16]),
            "pad_r": parse_num(f[17]), "pad_t": parse_num(f[18]),
            "pad_b": parse_num(f[19]),
            "fsize": parse_num(f[20]),
            "text": bytes.fromhex(f[21]).decode("utf-8", "replace") if f[21] else "",
            "tcolor": parse_num(f[22]),
        })
    return recs


def parse_num(s):
    if s is None or s == "N" or s == "":
        return None
    try:
        return int(float(s))
    except ValueError:
        return None


# ===========================================================================
# ③ 用 PIL 画
# ===========================================================================
ALIGN_CENTER = 1
ALIGN_TOP_LEFT = 2
ALIGN_TOP_MID = 3

# 文字自然尺寸缓存（_natural_w 会被 absolute_box 反复调用）
_MEASURE_CACHE = {}


def _measure(text, fsize, bold):
    """量一段（单行）文字的自然宽度（未乘 scale）。"""
    key = (text, fsize, bold)
    if key in _MEASURE_CACHE:
        return _MEASURE_CACHE[key]
    from PIL import ImageFont
    font = None
    for path in ((FONT_BOLD if bold else FONT_REG), FONT_REG):
        try:
            font = ImageFont.truetype(path, max(1, fsize))
            break
        except Exception:
            continue
    if font is None:
        w = len(text) * fsize * 0.6
    else:
        try:
            # 用一个临时 draw 量宽（textbbox 不依赖画布）
            w = font.getlength(text)
        except Exception:
            w = len(text) * fsize * 0.6
    if w <= 0:
        w = max(1, int(len(text) * fsize * 0.6))
    _MEASURE_CACHE[key] = w
    return w


def _natural_w(r):
    """Label 的自然宽度：取最长一行。"""
    if not r["is_label"] or not r["text"]:
        return 0
    fsize = r["fsize"] or 16
    bold = _looks_bold(r)
    lines = r["text"].split("\n")
    return max(_measure(s, fsize, bold) for s in lines)


def argb(v):
    """真源里颜色是 0xRRGGBB（24 位），不是 lvgl 的 BGR。"""
    if v is None:
        return None
    return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)


def render(recs, scale=1, bg=(7, 17, 31)):
    from PIL import Image, ImageDraw, ImageFont

    Wp, Hp = W * scale, H * scale
    img = Image.new("RGB", (Wp, Hp), bg)
    dr = ImageDraw.Draw(img, "RGBA")

    by_id = {r["id"]: r for r in recs}

    def absolute_box(r):
        """算出对象的屏幕绝对框 (left, top, w, h)。

        ★ 两条必须搞对的东西（都踩过）：

        ① **没有显式 w/h 的 Label 要按文字自然尺寸走** —— 真源里 make_button 的文字
           Label 不写 width（让它在按钮里居中）；当成 w=0 的话 CENTER 会算成负偏移，
           文字整个跑到框外。

        ② **CENTER 是"相对父容器居中"，不是"相对屏幕"** —— LVGL 里子对象的
           align 是拿父对象的**内容区**当参照。按屏幕居中会让所有按钮文字/图标
           整体错位（真机上看不出来，离线渲染一眼就露）。

        实现：从最外层往里，逐层把"父的左上角"累加，同时记下"当前父的内容区尺寸"，
        每一层的 align 都在**它的父**那个尺寸里算。
        """
        chain = []
        cur = r
        while cur is not None:
            chain.append(cur)
            cur = by_id.get(cur["parent"])
        chain.reverse()                      # 外 -> 内

        # 外框（最外层，无 parent）的内容区就是整屏
        px, py, pw, ph = 0, 0, W, H
        for node in chain:
            w = node["w"]
            h = node["h"]
            if w is None:
                w = _natural_w(node) if node["is_label"] else pw
            if h is None:
                h = (node["fsize"] or 16) * 1.25 if node["is_label"] else ph
            ax, ay = node["ax"] or 0, node["ay"] or 0
            at = node["at"]
            if at == ALIGN_CENTER:
                nx = px + (pw - w) // 2 + ax
                ny = py + (ph - h) // 2 + ay
            elif at == ALIGN_TOP_LEFT:
                nx = px + ax
                ny = py + ay
            elif at == ALIGN_TOP_MID:
                nx = px + (pw - w) // 2 + ax
                ny = py + ay
            else:
                nx = px + (node["x"] or 0)
                ny = py + (node["y"] or 0)
            # 这一层成为下一层的"父"
            px, py, pw, ph = nx, ny, w, h

        w = r["w"] if r["w"] is not None else (
            _natural_w(r) if r["is_label"] else pw)
        h = r["h"] if r["h"] is not None else (
            (r["fsize"] or 16) * 1.25 if r["is_label"] else ph)
        return px, py, w, h

    def visible(r):
        x, y, w, h = absolute_box(r)
        if y >= PAGE_HIDE or y <= -PAGE_HIDE:
            return None
        return (x, y, w, h)

    # 按创建顺序画（= LVGL 的 z 序）
    for r in recs:
        box = visible(r)
        if box is None:
            continue
        x, y, w, h = box
        x, y, w, h = x * scale, y * scale, w * scale, h * scale

        # --- 底色 ---
        bgc = argb(r["bg"])
        opa = r["bg_opa"]
        if bgc is not None and (opa is None or opa > 0):
            radius = (r["radius"] or 0) * scale
            if opa is not None and opa < 100:
                # 近似：按透明度混合到底
                a = opa / 100.0
                bgc = tuple(int(bgc[i] * a + bg[i] * (1 - a)) for i in range(3))
            if radius > 0:
                dr.rounded_rectangle([x, y, x + w - 1, y + h - 1],
                                     radius=radius, fill=bgc)
            else:
                dr.rectangle([x, y, x + w - 1, y + h - 1], fill=bgc)

        # --- 边框 ---
        bw = (r["bw"] or 0) * scale
        bc = argb(r["bc"])
        if bw > 0 and bc is not None and w > 0 and h > 0:
            radius = (r["radius"] or 0) * scale
            if radius > 0:
                dr.rounded_rectangle([x, y, x + w - 1, y + h - 1],
                                     radius=radius, outline=bc, width=max(1, bw))
            else:
                dr.rectangle([x, y, x + w - 1, y + h - 1],
                             outline=bc, width=max(1, bw))

        # --- 文字 ---
        if r["is_label"] and r["text"]:
            fsize = (r["fsize"] or 16)
            use_bold = _looks_bold(r)
            try:
                font = ImageFont.truetype(
                    FONT_BOLD if use_bold else FONT_REG, fsize * scale)
            except Exception:
                font = ImageFont.load_default()

            fc = argb(r["tcolor"]) or (255, 255, 255)
            lines = r["text"].split("\n")

            def line_w(s):
                try:
                    return dr.textlength(s, font=font)
                except Exception:
                    return len(s) * fsize * scale * 0.6

            tw = max((line_w(s) for s in lines), default=0)
            line_h = fsize * scale * 1.25
            th = line_h * len(lines)

            if r["at"] == ALIGN_CENTER or r["at"] is None:
                tx = x + (w - tw) / 2
                ty = y + (h - th) / 2
            else:  # TOP_LEFT
                tx = x
                ty = y
            # 多行时逐行画，行距按字号 1.25 倍
            for i, s in enumerate(lines):
                ly = ty + i * line_h
                if ly > Hp:
                    break
                dr.text((tx, ly), s, font=font, fill=fc)

    return img


# 真源里标题/按钮用 F_BOLD（24-30 号），正文用 F_BODY（13-20）。
# 假 lvgl 只回传字号，所以用"字号 >= 22"当作粗体的近似判据。
def _looks_bold(r):
    return (r["fsize"] or 0) >= 22


# ===========================================================================
# CLI
# ===========================================================================
PAGES = [
    ("main", 0, "主页"),
    ("autostart", 1, "自启动"),
    ("modules", 2, "模块管理"),
    ("log", 3, "日志"),
]


def main():
    ap = argparse.ArgumentParser(description="离线渲染管理器界面")
    ap.add_argument("--page", choices=[p[0] for p in PAGES] + ["all"],
                    default="all")
    ap.add_argument("--out", default=OUT_DEFAULT)
    ap.add_argument("--scale", type=int, default=1)
    ap.add_argument("--src", default=SRC)
    ap.add_argument("--seed", action="store_true",
                    help="预置一台典型设备（装了 chaos + shellpp2、闸开着、上次跑到底），"
                         "图更像真实使用状态")
    args = ap.parse_args()

    if not os.path.isfile(args.src):
        print("找不到真源: %s" % args.src)
        return 2

    os.makedirs(args.out, exist_ok=True)
    todo = PAGES if args.page == "all" else [p for p in PAGES if p[0] == args.page]

    for name, idx, zh in todo:
        recs = snapshot(idx, args.src, seed=args.seed)
        img = render(recs, scale=args.scale)
        suffix = "-seeded" if args.seed else ""
        path = os.path.join(args.out, "manager-%s%s.png" % (name, suffix))
        img.save(path)
        # 统计一下画了多少个可见对象，便于判断"是不是空页"
        print("%-10s %-6s %3d objs -> %s"
              % (name, zh, len(recs), path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
