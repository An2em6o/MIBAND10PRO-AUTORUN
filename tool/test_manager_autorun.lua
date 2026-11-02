-- Host-only regression tests for the 10pro.autorun Manager Lua core.
--
-- This deliberately reuses the in-memory FAKE fixture from the historical
-- manager simulator, but loads both production source mirrors directly.  It
-- never opens a device node and never writes resource.bin.
-- Run with: /opt/homebrew/opt/lua/bin/lua tool/test_manager_autorun.lua

local host_io = io
local host_os = os
local host_print = print

local function read_host(path)
  local f, err = host_io.open(path, "rb")
  assert(f, err or path)
  local s = f:read("*a")
  f:close()
  return s
end

local failures = 0
local checks = 0
local function check(ok, label, detail)
  checks = checks + 1
  if ok then
    host_print("PASS " .. label)
  else
    failures = failures + 1
    host_print("FAIL " .. label .. (detail and (": " .. tostring(detail)) or ""))
  end
end

local function contains(s, needle)
  return type(s) == "string" and s:find(needle, 1, true) ~= nil
end

local function index_of(s, needle)
  return type(s) == "string" and s:find(needle, 1, true) or nil
end

-- Load the existing simulator fixture without depending on Python/lupa.
local sim_py = read_host("other/old_watchface/manager/tools/_sim_manager.py")
local fake_lua = assert(sim_py:match("FAKE = r'''(.-)'''"), "FAKE fixture not found")
local tools_lua = assert(sim_py:match("TOOLS = r'''(.-)'''"), "TOOLS fixture not found")
assert(load(fake_lua, "@manager-fake-fixture"))()
assert(load(tools_lua, "@manager-fake-tools"))()
-- Keep production prints quiet; assertions report the relevant persisted log.
-- Exact-path write failures must not also block /data/rc.d via a prefix match.
local fake_open = io.open
local deny_write = {}
io.open = function(path, mode)
  if deny_write[path] and mode and mode:sub(1, 1) == "w" then return nil end
  return fake_open(path, mode)
end

local function clear_fake_fs()
  FS_reset()
  for k in pairs(BLOCK) do BLOCK[k] = nil end
  for k in pairs(UNREAD) do UNREAD[k] = nil end
  for k in pairs(deny_write) do deny_write[k] = nil end
  FWV = nil
end

local function load_core(source, label)
  local marker = "-- ===================== UI ====================="
  local stop = assert(source:find(marker, 1, true), label .. ": UI marker missing")
  local prefix = source:sub(1, stop - 1)
  -- UI-only callbacks are intentionally replaced by no-ops.  The returned
  -- table exposes locals for tests without changing production source.
  local suffix = [[
render_rows = render_rows or function() end
refresh_as_state = refresh_as_state or function() end
return {
  build_rc = build_rc,
  split_others = split_others,
  ensure_gate = ensure_gate,
  do_rebuild = do_rebuild,
  do_init_install = do_init_install,
  set_gate = set_gate,
  trace_status = TRACE.status,
  status = as_status_lines,
  orig = ORIG,
  pay = PAY,
  reset_state = function()
    armed = ""
    log_lines = {}; log_seq = 0
    if FM ~= nil then FM.gate = nil; FM.probe = nil end
  end,
}
]]
  local chunk, err = load(prefix .. suffix, "@" .. label)
  assert(chunk, err)
  local api = chunk()
  return api
end

local source_paths = {
  "Watchface/module.autorun.Manager/_Lua/module-autorun-manager.lua",
  "Watchface/module.autorun.Manager/resources/_lua/_Lua/module-autorun-manager.lua",
}
local sources, cores = {}, {}
for i, path in ipairs(source_paths) do
  sources[i] = read_host(path)
  cores[i] = load_core(sources[i], path)
  check(true, "load Manager core " .. path)
end

local GATE = "/data/rc.d/.autorun.on"
local GATE_OFF = "/data/rc.d/.autorun.off"
local TRACE = "/data/rc.d/.autorun.trace"
local RC = "/data/rc"
local RC_DIR = "/data/rc.d"
local CANOPUS = RC_DIR .. "/canopus.sh"

local function reset_seed(seed)
  clear_fake_fs()
  for p, v in pairs(seed or {}) do SET(p, v) end
end

local function log_text()
  return FS["/data/10pro.autorun/manager.log"] or ""
end

local function table_has(xs, value)
  for _, x in ipairs(xs) do if x == value then return true end end
  return false
end

local modules = {
  { name = "top", enable = true, present = true, top = true, delay = 99 },
  { name = "canopus", enable = true, present = true, delay = 2 },
  { name = "shellpp2", enable = true, present = true, delay = 4 },
}
local foreign = {
  "echo foreign >> /data/foreign.log",
  "sleep 15",
  "sh /data/foreign.sh",
}

-- Static generation, trace order, #top and delay ordering, migration, and
-- idempotent rebuilding are checked for both production mirrors.
local generated = {}
for i, api in ipairs(cores) do
  local rc = api.build_rc(modules, foreign)
  generated[i] = rc
  check(contains(rc, "echo check > " .. TRACE), "trace check marker " .. i)
  check(contains(rc, "echo entered >> " .. TRACE), "trace entered marker " .. i)
  check(contains(rc, "echo start_top >> " .. TRACE)
      and contains(rc, "echo return_top >> " .. TRACE)
      and contains(rc, "echo start_canopus >> " .. TRACE)
      and contains(rc, "echo return_canopus >> " .. TRACE),
    "per-module trace markers " .. i)
  check(contains(rc, "echo finished >> " .. TRACE), "trace finished marker " .. i)
  local p_rm = index_of(rc, "rm -f " .. GATE)
  local p_enter = index_of(rc, "echo entered >> " .. TRACE)
  local p_top = index_of(rc, "sh " .. RC_DIR .. "/top.sh")
  local p_pre = index_of(rc, "sleep 8")
  local p_d2 = index_of(rc, "sleep 2")
  local p_can = index_of(rc, "sh " .. RC_DIR .. "/canopus.sh")
  local p_d4 = index_of(rc, "sleep 4")
  local p_shell = index_of(rc, "sh " .. RC_DIR .. "/shellpp2.sh")
  local p_clear = index_of(rc, "echo cleared >> " .. RC_DIR .. "/.autorun.log")
  local p_on = index_of(rc, "echo on > " .. GATE)
  local p_finished = index_of(rc, "echo finished >> " .. TRACE)
  check(p_rm and p_enter and p_rm < p_enter, "trace enters after gate removal " .. i)
  check(p_top and p_pre and p_top < p_pre, "#top precedes normal pre-window " .. i)
  check(p_pre and p_d2 and p_can and p_pre < p_d2 and p_d2 < p_can,
    "canopus delay ordering " .. i)
  check(p_can and p_d4 and p_shell and p_can < p_d4 and p_d4 < p_shell,
    "shellpp delay ordering " .. i)
  check(p_clear and p_on and p_finished and p_clear < p_on and p_on < p_finished,
    "clear/on/finished ordering " .. i)
  local other_after = api.split_others(rc)
  check(table_has(other_after, foreign[1]) and table_has(other_after, foreign[2])
      and table_has(other_after, foreign[3]), "foreign rc lines preserved " .. i)
  check(not table_has(other_after, "echo check > " .. TRACE)
      and not table_has(other_after, "echo entered >> " .. TRACE),
    "trace lines excluded by split_others " .. i)
  local rebuilt = api.build_rc(modules, other_after)
  check(rebuilt == rc, "generated rc is idempotent " .. i)
  local legacy = table.concat({ "set +e", foreign[1], foreign[2], foreign[3],
    "echo gate_off >> /data/rc.d/.autorun.log",
    "if [ -f " .. GATE .. " ];then", "rm -f " .. GATE,
    "sh /data/rc.d/top.sh", "sleep 8", "sleep 2", "sh " .. CANOPUS,
    "sleep 4", "sh /data/rc.d/shellpp2.sh", "sleep 15",
    "echo cleared >> /data/rc.d/.autorun.log", "echo on > " .. GATE, "fi", "" }, "\n")
  check(api.build_rc(modules, api.split_others(legacy)) == rc,
    "legacy rc migrates without duplicating windows or foreign lines " .. i)
  local lookalikes = { "echo check > /data/foreign.trace",
    "echo foreign >> " .. TRACE, "echo start_canopus >> " .. TRACE .. ".backup" }
  local with_lookalikes = rc .. table.concat(lookalikes, "\n") .. "\n"
  local kept = api.split_others(with_lookalikes)
  check(table_has(kept, lookalikes[1]) and table_has(kept, lookalikes[2])
      and table_has(kept, lookalikes[3]), "trace recognition preserves lookalike foreign lines " .. i)
  local blank = api.build_rc({ { name = "off", enable = false, present = true },
    { name = "missing", enable = true, present = false } }, {})
  check(blank == "set +e\n", "no enabled present modules emits no gate or trace block " .. i)
end
check(generated[1] == generated[2], "both Manager source mirrors generate identical rc")

-- Small interpreter for the trace subset.  This models only echo/rm/if/fi;
-- it deliberately does not claim to execute nsh or native Canopus.
local function simulate_trace(rc, initially_on, stop_token)
  local trace, on, active = {}, initially_on, true
  local function add(v) trace[#trace + 1] = v end
  for line in rc:gmatch("[^\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "echo check > " .. TRACE then
      trace = { "check" }
    elseif trimmed == "if [ -f " .. GATE .. " ];then" then
      active = on
    elseif trimmed == "fi" then
      active = true
    elseif active and trimmed == "rm -f " .. GATE then
      on = false
    elseif active then
      local v = trimmed:match("^echo ([%w_%-]+) >> " .. TRACE:gsub("%.", "%%.") .. "$")
      if v then add(v) end
      if trimmed == "echo on > " .. GATE then on = true end
    end
    if stop_token and trimmed == stop_token then break end
  end
  return table.concat(trace, "\n"), on
end

local function common_install_seed()
  return { [CANOPUS] = "set +e\n", [RC] = "set +e\n",
    [RC_DIR .. "/autorun.json"] = '{"version":1,"modules":{}}\n' }
end
for i, api in ipairs(cores) do
  local function case(label, ok, detail) check(ok, label .. " " .. i, detail) end
  local function reset(version)
    reset_seed(common_install_seed()); api.reset_state(); FWV = version
  end
  local trace_rc = generated[i]
  local normal_trace, normal_on = simulate_trace(trace_rc, true)
  case("trace normal run ends finished", normal_on and normal_trace:match("finished$") ~= nil,
    normal_trace)
  local closed_trace, closed_on = simulate_trace(trace_rc, false)
  case("trace closed gate stops at check", not closed_on and closed_trace == "check", closed_trace)
  local interrupted_trace, interrupted_on = simulate_trace(trace_rc, true,
    "echo start_canopus >> " .. TRACE)
  case("trace interruption retains stage and closed gate", not interrupted_on
    and interrupted_trace:match("start_canopus$") ~= nil
    and not contains(interrupted_trace, "finished"), interrupted_trace)
  reset()
  SET(TRACE, normal_trace .. "\n")
  case("trace UI describes reached release", contains(api.trace_status(), "执行到放行"))
  SET(TRACE, closed_trace .. "\n")
  case("trace UI describes no entry", contains(api.trace_status(), "未见进入"))
  SET(TRACE, interrupted_trace .. "\n")
  case("trace UI names the interrupted module", contains(api.trace_status(), "canopus 未见返回"))
  SET(TRACE, "check\nentered\nreturn_canopus\n")
  case("trace UI describes return without tail", contains(api.trace_status(), "已返回, 未见收尾"))

  reset()
  SET(RC_DIR .. "/.autorun.log", "gate_off\n")
  case("gate_off does not auto-rearm on rebuild", api.do_rebuild() == true and FS[GATE] == nil)
  SET(GATE_OFF, "off\n")
  api.set_gate(true)
  case("explicit gate on restores gate and removes off credential", FS[GATE] == "on\n"
    and FS[GATE_OFF] == nil)
  local before_rc, before_writes = FS[RC], WCOUNT[RC]
  case("unchanged rebuild reports true without writes", api.do_rebuild() == true
    and FS[RC] == before_rc and WCOUNT[RC] == before_writes)
  api.set_gate(false)
  case("explicit gate off is preserved by rebuild", FS[GATE] == nil and FS[GATE_OFF] ~= nil
    and api.do_rebuild() == true and FS[GATE] == nil and FS[RC] == before_rc)
  local summary = table.concat(api.status(), "\n")
  case("legacy gate_off UI does not claim definite interruption",
    contains(summary, "原本关闭或中断") and not contains(summary, "上次开机 没跑到底"))

  reset("3.101.036")
  api.do_init_install()
  local unsupported_log = log_text()
  case("unsupported firmware gate is visible", contains(unsupported_log, "flash 那半停用"))
  case("unsupported firmware cannot report install complete",
    contains(unsupported_log, "安装: 未完成 (有失败项")
      and not contains(unsupported_log, "安装: 完成"), unsupported_log)
  case("unsupported firmware makes no flash writes", DEV_get("/dev/ap", 0xc00000) == nil)

  reset("3.101.043")
  DEV_set("/dev/ap", 0xc00000, api.pay)
  deny_write[RC] = true
  api.do_init_install()
  local blocked_log = log_text()
  case("isolated rc write failure is visible", contains(blocked_log, "应用失败: 打不开 /data/rc"), blocked_log)
  case("isolated rc failure propagates to install result",
    contains(blocked_log, "安装: 未完成 (有失败项") and not contains(blocked_log, "安装: 完成"), blocked_log)
  case("isolated rc failure preserves old rc and returns false", FS[RC] == "set +e\n"
    and FS[GATE] == "on\n" and api.do_rebuild() == false)

  reset("3.101.043")
  UNREAD[RC] = true
  case("unreadable existing rc is never replaced", api.do_rebuild() == false and FS[RC] == "set +e\n")
  reset("3.101.043")
  FS[RC_DIR .. "/autorun.json"] = nil
  deny_write[RC_DIR .. "/autorun.json"] = true
  case("unwritable configuration refuses rebuild", api.do_rebuild() == false and FS[RC] == "set +e\n")

  reset("3.101.043")
  DEV_set("/dev/ap", 0xc00000, api.orig)
  api.do_init_install()
  case("first install click only arms probe", DEV_get("/dev/ap", 0xc00000) == api.orig
    and FS[GATE] == nil and FS[RC] == "set +e\n")
  api.do_init_install()
  case("second install writes verified payload gate and rc", DEV_get("/dev/ap", 0xc00000) == api.pay
    and FS[GATE] == "on\n" and contains(FS[RC] or "", "sh " .. CANOPUS))
  case("successful second click reports complete", contains(log_text(), "安装: 完成")
    and not contains(log_text(), "安装: 未完成"), log_text())

  reset("3.101.043")
  DEV_set("/dev/ap", 0xc00000, api.pay)
  api.do_init_install()
  case("already installed payload skips confirmation", FS[GATE] == "on\n"
    and contains(FS[RC] or "", "sh " .. CANOPUS) and contains(log_text(), "安装: 完成"))
end

host_print(string.format("MANAGER AUTORUN TESTS: %s (%d checks)",
  failures == 0 and "PASS" or ("FAIL " .. failures), checks))
host_os.exit(failures == 0 and 0 or 1)
