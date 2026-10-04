-- ============================================================================
--  shellpp2-autorun 离线门（真 Lua + 假 lvgl/io/os）
--
--  用真 Lua 加载 _Lua/main.lua，把 lvgl / io / os.execute 换成假件：
--    * 假 lvgl : 记对象、记 Label 文本、把 onClicked 的回调存起来供本门调用
--    * 假 io/os: 内存 FS（文件/目录，**写文件要求父目录已存在** —— 这正是真设备的行为，
--                也是"管理器没装"能被判出来的机制）+ 假 nsh 子集
--                            (dd / rm / mkdir / ls / getprop / insmod / reboot)
--    * 假 flash: ★ **故意不实现** —— 新规范下模块不碰 flash。
--                本门反过来钉住：安装/删除全程**没有任何**对 /dev/ap、/dev/bes_flash 的写入，
--                也没有把 main.lua 里的 32 KB 原块搬进来（包体积那 32 KB 就不该在）。
--
--  检查：语法 → 主页键位 → 切页 → 管理器没装(零写盘) → 安装(逐字节) → 幂等 →
--        不写 /data/rc → 不碰 flash → 旧雷清理 → 删除 → 开机脚本形态 ★ 纯命令 →
--        反向静态判据。
--  ★ v2 起脚本形态**翻面**：脚本里**不许有 if / sleep / autostart.on** ——
--    闸与安全窗全部上移 /data/rc（管理器生成），模块脚本零机制。
--  期望末行： SIM TOTAL: PASS (n/n)
-- ============================================================================

local real_io = io
local real_print = print

local PACK = SIM_PACK
local MAIN = SIM_MAIN

local function slurp(path)
  local f = real_io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local main_src = slurp(MAIN)
assert(main_src, "读不到 " .. MAIN)

-- 剥掉注释后的**纯代码**视图：反向静态判据一律判它。
-- 理由：头部那些"解释为什么不再写 flash / 为什么没有 rcS hook"的注释是**有用**的说明，
-- 用整篇源文本去咬 "rcS" 只会逼着人把说明删掉（管理器项目踩过同一个坑）。
local function strip_comments(src)
  local out = {}
  for ln in src:gmatch("([^\n]*)\n?") do
    if not ln:match("^%s*%-%-") and #ln > 0 then
      out[#out + 1] = (ln:gsub("%s+%-%-.*$", ""))
    end
  end
  return table.concat(out, "\n")
end
local code_text = strip_comments(main_src)

-- ---------- 假件 ----------
local fs = { files = {}, dirs = {} }
local sim = { dev = {}, dq = {}, execs = {}, log = {}, writes = {} }

local function parent_of(p)
  local i = p:match("^(.*)/[^/]*$")
  if i == "" then return "/" end
  return i
end

local function sim_write(p, s) fs.files[p] = s end
local function sim_mkdir(p) fs.dirs[p] = true end
local function sim_unlink(p)
  fs.files[p] = nil
  if fs.dirs[p] then
    fs.dirs[p] = nil
    local prefix = p .. "/"
    for k in pairs(fs.files) do if k:sub(1, #prefix) == prefix then fs.files[k] = nil end end
    for k in pairs(fs.dirs) do if k:sub(1, #prefix) == prefix then fs.dirs[k] = nil end end
  end
end

local function unquote(v)
  v = v:gsub("^'(.*)'$", "%1")
  return (v:gsub("'\\''", "'"))
end

local FLASH_DEVS = { ["/dev/ap"] = true, ["/dev/bes_flash"] = true }

local function sim_dd(rest)
  local a = {}
  for k, v in rest:gmatch("(%w+)=(%S+)") do a[k] = unquote(v) end
  local src, dst = a["if"], a["of"]
  if not src or not dst then return 1 end
  local data
  if src:sub(1, 5) == "/dev/" then
    local d = sim.dev[src] or {}
    data = d[tonumber(a.skip) or 0] or ""
  else
    data = fs.files[src] or ""
  end
  if dst:sub(1, 5) == "/dev/" then
    if dst == "/dev/shellpp" then
      sim.dq[#sim.dq + 1] = data
    else
      sim.dev[dst] = sim.dev[dst] or {}
      sim.dev[dst][tonumber(a.seek) or 0] = data
      sim.writes[#sim.writes + 1] = dst
    end
  else
    fs.files[dst] = data
  end
  return 0
end

local function fake_exec(cmd)
  cmd = tostring(cmd):gsub("^%s+", ""):gsub("%s+$", "")
  sim.execs[#sim.execs + 1] = cmd
  local prog, rest = cmd:match("^(%S+)%s*(.*)$")
  if prog == "dd" then return sim_dd(rest) end
  if prog == "rm" then
    rest = rest:gsub("^%-[%w]+%s*", "")
    for path in rest:gmatch("%S+") do sim_unlink(unquote(path)) end
    return 0
  end
  if prog == "mkdir" then
    sim_mkdir(unquote((rest:gsub("^%-%w+%s*", ""))))
    return 0
  end
  if prog == "getprop" then
    local out = rest:match(">%s*'?([^'%s]+)'?")
    if out then sim_write(unquote(out), "3.101.043\n") end
    return 0
  end
  if prog == "ls" or prog == "insmod" or prog == "reboot" or prog == "sh" then return 0 end
  error("sim: 未实现的 nsh 命令: " .. cmd)
end

local function fake_open(path, mode)
  mode = mode or "r"
  if mode == "r" or mode == "rb" then
    if fs.dirs[path] then
      return { read = function() return nil end, seek = function() return 0 end,
        close = function() end }
    end
    local content = fs.files[path]
    if content == nil then return nil end
    return {
      read = function(_, what)
        if what == "*a" or what == "a" then return content end
        return content:sub(1, tonumber(what) or #content)
      end,
      seek = function(_, whence) if whence == "end" then return #content end return 0 end,
      close = function() end,
    }
  end
  -- ★ 写模式：父目录不存在 ⇒ 返回 nil。这正是真设备（NuttX）上 io.open 的行为，
  --   也是 rc_dir_ready() 能判出"管理器没装"的机制。
  if not fs.dirs[parent_of(path)] then return nil end
  local buf = {}
  local handle = {}
  handle.write = function(_, s) buf[#buf + 1] = tostring(s) return handle end
  handle.close = function()
    local joined = table.concat(buf)
    if mode == "a" or mode == "ab" then
      fs.files[path] = (fs.files[path] or "") .. joined
    else
      fs.files[path] = joined
    end
    return true          -- 真 Lua 的 file:close() 返回 true；被测代码会检查它
  end
  return handle
end

-- ---------- 假 lvgl ----------
local objects = {}
local buttons = {}   -- 按钮 Label 文本 -> 按钮对象

local function new_obj(props)
  local o = { props = props or {}, label = nil, onclick = nil, sets = {} }
  objects[#objects + 1] = o
  function o:set(t)
    self.sets[#self.sets + 1] = t
    for k, v in pairs(t or {}) do self.props[k] = v end
    if type(t) == "table" and type(t.text) == "string" then
      sim.log[#sim.log + 1] = t.text
    end
  end
  function o:clear_flag() end
  function o:add_flag() end
  function o:scroll_by_bounded() end
  function o:onClicked(fn)
    self.onclick = fn
    local text = self.props and self.props.__label
    if text then buttons[text] = self end
  end
  return o
end

local fake_lvgl = {}
fake_lvgl.HOR_RES = function() return 336 end
fake_lvgl.VER_RES = function() return 480 end
fake_lvgl.OPA = function(v) return v end
fake_lvgl.Font = function(name, size) return { name = name, size = size } end
fake_lvgl.FLAG = { SCROLLABLE = 1, CLICKABLE = 2 }
fake_lvgl.ALIGN = { CENTER = "C", TOP_LEFT = "TL", TOP_MID = "TM" }
fake_lvgl.Object = function(parent, props)
  local o = new_obj(props)
  o.parent = parent
  return o
end
fake_lvgl.Label = function(parent, props)
  local o = new_obj(props)
  o.parent = parent
  o.label = props and props.text
  if parent and parent.props then parent.props.__label = o.label end
  return o
end

-- ---------- 装假件 ----------
package.loaded.lvgl = fake_lvgl
_G.SCRIPT_PATH = PACK .. "/_Lua/"
io = { open = fake_open }
os = { execute = fake_exec, remove = sim_unlink, time = os.time, clock = os.clock }
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  sim.log[#sim.log + 1] = table.concat(parts, " ")
end

-- 先把包内资源灌进假 FS（用真 io 读）
for _, name in ipairs({ "shellpp_ii-3.101.036.bin", "shellpp_ii-3.101.043.bin",
  "shellpp_ii_icon.bin", "shellpp_ii_settings_icon.bin" }) do
  local data = slurp(_G.SCRIPT_PATH .. name)
  assert(data, "包内资源缺失: " .. name)
  sim_write(_G.SCRIPT_PATH .. name, data)
end
sim_mkdir("/")
sim_mkdir("/data")
sim_mkdir("/tmp")

-- ---------- 断言 ----------
local pass, fail = 0, 0
local function ok(cond, name, detail)
  if cond then
    pass = pass + 1
    real_print(string.format("  PASS  %s", name))
  else
    fail = fail + 1
    real_print(string.format("  FAIL  %s   %s", name, tostring(detail or "")))
  end
end

local function reset_side_effects()
  sim.execs = {}
  sim.dq = {}
  sim.writes = {}
end

-- ---------- 加载被测 main.lua ----------
local chunk, err = load(main_src, "@main.lua")
assert(chunk, "main.lua 语法错误: " .. tostring(err))
local ran, run_err = pcall(chunk)
assert(ran, "main.lua 执行出错: " .. tostring(run_err))

real_print("== A 载入 / UI ==")
ok(#objects > 0, "A1 假 lvgl 收到了对象（脚本执行到底）")
local want_btn = { "Run (Both)", "Run (Launcher)", "Run (Settings)",
  "Uninstall", "Clear Env", "Reboot", "自启动", "1 安装", "2 删除", "< Back" }
for _, t in ipairs(want_btn) do
  ok(buttons[t] ~= nil, "A2 有按钮 " .. t)
end

-- ---------- 切页 ----------
local function as_page_obj()
  -- 自启动页 = 「1 安装」按钮的父页面
  return buttons["1 安装"].parent
end
local function main_page_obj()
  return buttons["自启动"].parent
end

real_print("== B 切页 ==")
buttons["自启动"].onclick()
ok(as_page_obj().props.align.y_ofs == 0, "B1 点「自启动」后自启动页上移（y_ofs==0）")
ok(main_page_obj().props.align.y_ofs ~= 0, "B2 主页同时被移出屏幕")
buttons["< Back"].onclick()
ok(main_page_obj().props.align.y_ofs == 0, "B3 点「< Back」回主页")

-- ---------- 管理器没装 ----------
real_print("== C 管理器没装（/data/rc.d 不在）==")
reset_side_effects()
sim.log = {}
buttons["1 安装"].onclick()
local installed_before = {}
for k in pairs(fs.files) do installed_before[k] = true end
ok(fs.files["/data/rc.d/shellpp2.sh"] == nil, "C1 没投脚本")
ok(fs.files["/data/shellpp-ii/shellpp_ii.bin"] == nil, "C2 没释放模块（一个字节都不写）")
ok(fs.files["/data/shellpp-ii/autostart.on"] == nil, "C3 没建闸（模块已无闸）")
local banner = sim.log[#sim.log]
ok(table.concat(sim.log, "\n"):find("管理器没装", 1, true) ~= nil,
  "C4 上屏说清楚「管理器没装」(banner=" .. tostring(banner) .. ")")

-- ---------- 管理器在（/data/rc.d 存在）----------
real_print("== D 安装（管理器在）==")
sim_mkdir("/data/rc.d")
-- 预置：别的模块的行 + 一条**旧版 shellpp2 的二跳行**（旧做法留下的雷）
--       + **v1 残留的模块自带闸**（现在必须被安装过程清掉）
sim_write("/data/rc", "set +e\necho other-module\nsh /data/shellpp-ii/rc &\n")
sim_write("/data/shellpp-ii/rc", "#!/bin/sh\necho legacy\n")
sim_write("/data/shellpp-ii/autostart.on", "on\n")
reset_side_effects()
sim.log = {}
buttons["1 安装"].onclick()

local rc_sh = fs.files["/data/rc.d/shellpp2.sh"]
ok(type(rc_sh) == "string", "D1 投了 /data/rc.d/shellpp2.sh")
ok(type(rc_sh) == "string" and rc_sh:sub(-1) == "\n", "D2 脚本以换行结尾")

-- 模块逐字节 == 包内
local pkg_mod = slurp(_G.SCRIPT_PATH .. "shellpp_ii-3.101.043.bin")
ok(fs.files["/data/shellpp-ii/shellpp_ii.bin"] == pkg_mod,
  "D3 释放的模块与包内**逐字节**相同")

-- cmds.bin: 6 × 16 B，帧头独立复算
local cmds = fs.files["/data/shellpp-ii/cmds.bin"]
ok(type(cmds) == "string" and #cmds == 96, "D4 cmds.bin = 96 B (6 x 16)", #(cmds or ""))
local function u32(s, off)
  local a, b, c, d = s:byte(off, off + 3)
  return a + b * 0x100 + c * 0x10000 + d * 0x1000000
end
local want_cmds = { 0x5351000A, -- restore-after-boot（空操作）
                    0x53510002, -- install stage 0（空操作）
                    0x53510012, -- install stage 1（DQ）
                    0x53510012, -- install stage 2 launcher（DQ）
                    0x5351001B, -- settings（DQ）
                    0x53510014 } -- notify（DQ）
local cmd_ok = type(cmds) == "string" and #cmds == 96
if cmd_ok then
  for i = 1, 6 do
    local base = (i - 1) * 16
    if u32(cmds, base + 1) ~= 0x53505331 or u32(cmds, base + 5) ~= want_cmds[i] then
      cmd_ok = false
    end
  end
end
ok(cmd_ok, "D5 6 条命令帧的 magic/命令号与规范一致（stage1/2 与 settings/notify 全是 DQ）")

ok(fs.files["/data/shellpp-ii/autostart.on"] == nil,
  "D6 ★ 安装清掉了 v1/v2 残留的模块闸（不再建它，闸归管理器）")

-- ---------- 不写 /data/rc ----------
real_print("== E 不写 /data/rc（它是管理器的产物）==")
local rc_after = fs.files["/data/rc"]
ok(rc_after == "set +e\necho other-module\n", "E1 旧版二跳行被摘掉")
ok(rc_after ~= nil and rc_after:find("other-module", 1, true) ~= nil,
  "E2 别人的行一字不动")
ok(rc_after ~= nil and rc_after:find("sh /data/shellpp-ii/rc", 1, true) == nil,
  "E3 没有留下任何二跳/追加动作")
ok(fs.files["/data/shellpp-ii/rc"] == nil, "E4 旧版自带 rc 文件已删")
-- 再确认整个过程没有"往 /data/rc 追加"的动作：执行过的命令里不许有 io.open(RC,\"a\")
ok(not code_text:find('io.open(RC_PATH, "a")', 1, true), "E5 代码里没有追加 /data/rc 的写法")
ok(not code_text:find('RC_HOP', 1, true), "E6 代码里没有 RC_HOP 二跳常量")

-- ---------- 不碰 flash ----------
real_print("== F 不碰 flash ==")
ok(next(sim.writes) == nil, "F1 全程没有任何块设备写入（sim.writes 空）")
ok(sim.dev["/dev/ap"] == nil, "F2 没碰 /dev/ap")
ok(sim.dev["/dev/bes_flash"] == nil, "F3 没碰 /dev/bes_flash")
ok(not code_text:find("ORIG_HEX", 1, true), "F4 包里没有 32 KB 原块（ORIG_HEX 不在）")
ok(not code_text:find("/dev/ap", 1, true) and not code_text:find("/dev/bes_flash", 1, true),
  "F5 代码里没有 flash 设备路径")
ok(not code_text:find("rcS", 1, true), "F6 代码里没有 rcS（不自己写 rcS hook）")

-- ---------- 幂等 ----------
real_print("== G 幂等 ==")
local before = {}
for k, v in pairs(fs.files) do before[k] = v end
buttons["1 安装"].onclick()
local same = true
for k, v in pairs(before) do if fs.files[k] ~= v then same = false end end
for k in pairs(fs.files) do if before[k] == nil then same = false end end
ok(same, "G1 再按一次「1 安装」：文件字节完全不变")

-- ---------- 开机脚本形态（★ v2：纯命令，零机制）----------
real_print("== H 开机脚本形态（/data/rc.d/shellpp2.sh）—— 纯命令 ==")
local sh = fs.files["/data/rc.d/shellpp2.sh"] or ""
local lines = {}
for ln in sh:gmatch("([^\n]+)") do lines[#lines + 1] = ln end
ok(lines[1] == "set +e", "H1 首行 set +e（nsh 子集：不要指望 && / ||）")
ok(lines[2] == "echo start > /data/shellpp-ii/autostart.log",
  "H2 第二行直接开干（★ 没有闸判句了）", lines[2])
ok(lines[#lines] == "echo done >> /data/shellpp-ii/autostart.log",
  "H3 末行是收尾打点（★ 没有 fi）", lines[#lines])
ok(sh:find("insmod /data/shellpp-ii/shellpp_ii.bin shellpp_ii", 1, true) ~= nil,
  "H4 insmod 的是**固定名**（开机时随机安装目录不存在）")
local dd_count = 0
for _, ln in ipairs(lines) do
  if ln:match("^dd if=/data/shellpp%-ii/cmds%.bin of=/dev/shellpp bs=16 skip=%d+ count=1 conv=notrunc$") then
    dd_count = dd_count + 1
  end
end
ok(dd_count == 6, "H5 6 条命令帧的 dd 平铺展开（无 for 循环）", dd_count)
local amp = false
for _, ln in ipairs(lines) do if ln:find("&", 1, true) then amp = true end end
ok(not amp, "H6 脚本里一行都不带 &（模块行由管理器前台串行调起）")
-- ★★ v2 翻面：闸与安全窗全部上移 /data/rc，脚本里一个字节都不许有。
ok(sh:find("sleep", 1, true) == nil, "H7 ★ 脚本里没有 sleep（等待归 /data/rc）")
ok(sh:find("autostart.on", 1, true) == nil, "H8 ★ 脚本里不碰 autostart.on（闸归 /data/rc）")
local has_if, has_fi = false, false
for _, ln in ipairs(lines) do
  if ln:match("^%s*if%s") then has_if = true end
  if ln:match("^%s*fi%s*$") then has_fi = true end
end
ok(not has_if and not has_fi, "H9 ★ 脚本里没有 if / fi（单层判句也归 /data/rc）")
ok(sh:find("rm -f /data/rc", 1, true) == nil, "H10 脚本不碰 /data/rc")
ok(not code_text:find("AS_DELAY", 1, true) and not code_text:find("AS_SAFETY_S", 1, true),
  "H11 代码里没有 AS_DELAY / AS_SAFETY_S（延时不再由模块管）")

-- ---------- 删除 ----------
real_print("== I 删除 ==")
-- 预置一份 v1 残留的模块闸：验证「删除」也会把它清掉（旧设备升级路径）。
sim_write("/data/shellpp-ii/autostart.on", "on\n")
reset_side_effects()
sim.log = {}
buttons["2 删除"].onclick()
ok(fs.files["/data/rc.d/shellpp2.sh"] == nil, "I1 脚本已撤销")
ok(fs.files["/data/shellpp-ii/autostart.on"] == nil, "I2 v1/v2 残留的模块闸也一并清掉")
ok(fs.files["/data/rc"] == "set +e\necho other-module\n", "I3 **不碰 /data/rc**")
ok(fs.files["/data/shellpp-ii/shellpp_ii.bin"] ~= nil,
  "I4 不删运行依赖（那是 App 本体的东西，归主视图 Uninstall）")
ok(next(sim.writes) == nil, "I5 删除全程也不碰 flash")

-- ---------- 反向静态判据 ----------
real_print("== J 反向静态（剥注释后判）==")
for _, bad in ipairs({ "ORIG_HEX", "flash_gate", "flash_probe", "hook_install",
  "hook_restore", "do_flash_write", "do_flash_restore", "classified", "classify" }) do
  ok(code_text:find(bad, 1, true) == nil, "J1 代码里没有 " .. bad)
end
ok(code_text:find("io.open(RC_PATH", 1, true) == nil,
  "J2 代码里没有任何直接开 /data/rc 的常量路径（只有 legacy_cleanup 里的 LEGACY_RC_PATH）")

real_print(string.format("SIM TOTAL: %s (%d/%d)",
  fail == 0 and "PASS" or "FAIL", pass, pass + fail))
SIM_FAILED = fail
