-- Shell++ II installer for Xiaomi Band 10 Pro —— **适配 10pro.autorun 管理器规范**。
--
-- 基座 = 上游原版安装器（544 行）：Run（Both/Launcher/Settings）/ Uninstall / Clear Env /
--        Reboot 的逻辑与文案**一字未改**，只把原本铺在一个 root 上的控件改成挂在 main_page 上，
--        以便多加一张页面。
-- 本版只做一件事：**新增一张「自启动」页**，按 10pro.autorun 管理器的新标准注册。
--
-- ★ 新标准（见 chaos-autostart/REGISTER.md，本页就是照它实现的）：
--   ① 模块**只投文件** —— 把开机要跑的命令写进 /data/rc.d/shellpp2.sh，注册就完了；
--   ② **没有 /data/rc.d ⇒ 报错「管理器没装」** —— 不自己建目录、不退老做法，一个字节都不写；
--   ③ `/data/rc` 是**产物**，由管理器生成 —— 模块**永不**碰它；
--   ④ 模块**不碰 flash** —— flash 里那句 `sh /data/rc &` 归管理器的 [1 安装]；
--   ⑤ ★★ **模块脚本零机制**（2026-10-04 用户定的职责边界）：**闸、安全窗、心跳全部归
--      管理器生成的 /data/rc**。所以 /data/rc.d/shellpp2.sh 里**没有 `if`、没有 `sleep`、
--      不碰 autostart.on** —— 它只是"一串要跑的纯命令"。
--      v1 那套"模块自带闸 + 自带 5s/10s 延时"**已废弃**：闸写进每个模块 = N 份互相打架的
--      副本；更要命的是"被打断"只在模块自己的小圈子里留痕，管理器看不见。
--   所以本文件里**没有**任何写 /data/rc、写 flash、写 autostart.on 的代码。
--
-- ★ 与老做法的差别（必须知道，否则会以为自己漏了什么）：
--   老：rc 脚本落 /data/shellpp-ii/rc，再往 /data/rc **追加一行** `sh /data/shellpp-ii/rc &`，
--       并自己 dd 写 AP /etc ROMFS 的 rcS hook；
--   新：脚本直接落 /data/rc.d/shellpp2.sh，那一行由管理器生成，flash 也由管理器写。
--       **二跳没了、自带 flash hook 没了**。旧版留下的那行由 legacy_cleanup() 摘掉。
--
-- ★ 开机脚本为什么能用（这条决定了「可以适当修改 elf 模块」这句话）：
--   开机的 /data/rc 跑在 sh 任务里。写 /dev/shellpp 的 16 B 命令帧里，
--   **只有 DQ（延迟命令号）是"入环即返回"** —— 真正的框架调用（APP_INSTALL）交给
--   模块自己的 UI 线程定时器派发。非 DQ 的 RESTORE / INSTALL(stage 0) 在模块里
--   **就是 `rc = 0` 的空操作**（见 module/src/supervisor.c 的 control_write），所以也能从 sh 写。
--   ⇒ 开机脚本里的 6 条帧全部是 DQ 或空操作；本版内置的模块 bin 就是带 DQ 的那个
--   （落点 /data/shellpp-ii/shellpp_ii.bin，源 = Shellpp-II-App/module/src/supervisor.c）。

local lvgl = require("lvgl")

local FIRMWARE_VERSION_PROPERTY = "ro.build.version"
local FIRMWARE_VERSION_OUTPUT = "/data/shellpp-installer-firmware-version.tmp"
local MODULE_PATH
local MODULE_NAME = "shellpp_ii"
local MANAGER_ICON_RESOURCE = SCRIPT_PATH .. "shellpp_ii_icon.bin"
local MANAGER_ICON_PATH = "/data/shellpp-ii/shellpp_ii_icon.bin"
local SETTINGS_ICON_RESOURCE = SCRIPT_PATH .. "shellpp_ii_settings_icon.bin"
local SETTINGS_ICON_PATH = "/data/shellpp-ii/shellpp_ii_settings_icon.bin"
local DEVICE_PATH = "/dev/shellpp"
local MODULE_MIN_SIZE = 512
local MODULE_MAX_SIZE = 262144
local STATUS_SIZE = 384
local EXPECTED_MAGIC = 0x53505331 -- Shell++ status/control magic
local EXPECTED_STATUS_ABI = 3
local EXPECTED_FIRMWARE_CODE
local EXPECTED_CMD_MAGIC = 0x53505331 -- Shell++ control magic
local CMD_INSTALL = 0x53510002
local CMD_SETTINGS_START = 0x5351000B
local SETTINGS_BUILD = 0x04350901
local CMD_NOTIFY_LOADED = 0x53510004
-- Canopus uses command suffix 0x0A for its restore-after-boot phase. Keep
-- Shell++ on the same CPC1 command family while retaining its own magic.
local CMD_RESTORE_AFTER_BOOT = 0x5351000A
local CMD_UNINSTALL = 0x53510003
local RESULT_COMPLETED = 5

-- ===================== 自启动（10pro.autorun 规范）相关常量 =====================
local STAGE_DIR       = "/data/shellpp-ii/"           -- 固定 staging 目录（开机时随机安装目录不存在）
local STAGE_DIR_BARE  = "/data/shellpp-ii"            -- 给 mkdir / ls 用（不带尾斜杠）
local STAGED_MODULE   = STAGE_DIR .. "shellpp_ii.bin" -- 开机脚本 insmod 的就是这个**固定名**
local CMDS_PATH       = STAGE_DIR .. "cmds.bin"       -- 6 条 16 B DQ 命令帧（开机脚本逐条 dd）
local LEGACY_FLAG     = STAGE_DIR .. "autostart.on"   -- v1/v2 残留的"模块自带闸"（已废弃；安装/删除时清掉）
local AS_LOG          = STAGE_DIR .. "autostart.log"
local RC_DIR          = "/data/rc.d"                  -- 管理器的注册目录（新标准唯一入口）
local RC_SH           = RC_DIR .. "/shellpp2.sh"      -- 本模块的注册脚本
-- 旧做法的残留（老安装器干过的事）：/data/shellpp-ii/rc + /data/rc 里追加的那一行。
-- 留着就是个雷：那一行还在，每次开机都会去跑一个已经被删掉的文件。
local LEGACY_RC_PATH  = "/data/rc"
local LEGACY_HOP      = "sh /data/shellpp-ii/rc &"
local LEGACY_RC_FILE  = "/data/shellpp-ii/rc"
-- DQ（延迟命令号）：写进 /dev/shellpp 只入环即返回，真正的框架调用交给模块 UI 线程定时器。
local CMD_INSTALL_DQ  = 0x53510012
local CMD_NOTIFY_DQ   = 0x53510014
local CMD_SETTINGS_DQ = 0x5351001B
local AS_MODE         = "both"   -- launcher + settings 都注册
-- ★ 不再有 AS_DELAY / AS_SAFETY_S —— 等待与安全窗归 /data/rc（管理器生成），模块零机制。

local function describe_error(code)
    if code == -95 then
        return "native App removal requires reboot on this firmware"
    elseif code == -22 then
        return "invalid supervisor command"
    elseif code == -19 then
        return "device is unavailable"
    end
    return "error " .. tostring(code)
end

local status
local log_panel
local run_timer
local run_phase = 1
local run_attempted = false
local clear_armed = false

-- 自启动页的两个刷新函数要**前向声明**：主页那个「自启动」入口键比它们先建，
-- 而闭包只认"声明在自己之前"的局部量（写成 `local function` 会捕获 nil）。
local as_refresh
local as_report

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function run(command)
    print("[shellpp-ii-installer] exec: " .. command)
    local ok = os.execute(command)
    return ok == true or ok == 0
end

local function set_status(text, color)
    status:set { text = tostring(text), text_color = color or 0xBFD9FF }
end

local function read_all(path, mode)
    if type(io) ~= "table" or type(io.open) ~= "function" then return nil end
    local file = io.open(path, mode or "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function detect_firmware_version()
    local command = string.format("getprop %s > %s",
        shell_quote(FIRMWARE_VERSION_PROPERTY),
        shell_quote(FIRMWARE_VERSION_OUTPUT))
    local command_ok = run(command)
    local raw
    if command_ok then raw = read_all(FIRMWARE_VERSION_OUTPUT, "r") end
    if type(os.remove) == "function" then
        pcall(os.remove, FIRMWARE_VERSION_OUTPUT)
    end
    if not command_ok or type(raw) ~= "string" then return nil end
    local version = raw:match("^%s*(.-)%s*$")
    if not version or not version:match("^%d+%.%d+%.%d+$") then return nil end
    return version
end

local function module_path_for(version)
    return SCRIPT_PATH .. "shellpp_ii-" .. version .. ".bin"
end

local function firmware_code_for(version)
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
    if not major or not minor or not patch or minor > 999 or patch > 999 then
        return nil
    end
    return major * 1000000 + minor * 1000 + patch
end

local function supervisor_present()
    local file = io.open(DEVICE_PATH, "rb")
    if not file then return false end
    file:close()
    return true
end

local function verify_module_file()
    if type(io) ~= "table" or type(io.open) ~= "function" then
        return false, "io.open unavailable"
    end
    local file = io.open(MODULE_PATH, "rb")
    if not file then return false, "missing matching Supervisor" end
    local header = file:read(20)
    local size = file:seek("end")
    file:close()
    if type(header) ~= "string" or #header ~= 20
        or header:sub(1, 4) ~= "\127ELF"
        or header:byte(5) ~= 1 or header:byte(6) ~= 1
        or header:byte(7) ~= 1 then
        return false, "resource is not ELF32 little-endian"
    end
    local elf_type = header:byte(17) + header:byte(18) * 0x100
    local machine = header:byte(19) + header:byte(20) * 0x100
    if elf_type ~= 1 or machine ~= 40 then
        return false, "resource is not relocatable ARM ELF"
    end
    if type(size) ~= "number" or size < MODULE_MIN_SIZE
        or size > MODULE_MAX_SIZE then
        return false, "unexpected supervisor size"
    end
    return true
end

local function stage_manager_icon()
    local content = read_all(MANAGER_ICON_RESOURCE, "rb")
    if type(content) ~= "string" or #content < 13
        or content:byte(1) ~= 0x19 then
        return false, "missing or invalid shellpp_ii_icon.bin"
    end
    local width = content:byte(5) + content:byte(6) * 0x100
    local height = content:byte(7) + content:byte(8) * 0x100
    if width < 1 or height < 1 or #content ~= 12 + width * height * 4 then
        return false, "shellpp_ii_icon.bin size mismatch"
    end
    local output = io.open(MANAGER_ICON_PATH, "wb")
    if not output then
        if not run("mkdir " .. STAGE_DIR_BARE) then
            return false, "cannot create " .. STAGE_DIR_BARE
        end
        output = io.open(MANAGER_ICON_PATH, "wb")
    end
    if not output then return false, "cannot stage Manager icon" end
    local write_ok, write_result = pcall(output.write, output, content)
    local close_ok, close_result = pcall(output.close, output)
    if not write_ok or write_result == nil
        or not close_ok or close_result == nil then
        return false, "Manager icon write failed"
    end
    if read_all(MANAGER_ICON_PATH, "rb") ~= content then
        return false, "Manager icon verification failed"
    end
    return true
end

local function stage_settings_icon()
    local content = read_all(SETTINGS_ICON_RESOURCE, "rb")
    if type(content) ~= "string" or #content ~= 16396
        or content:sub(1, 12) ~= string.char(0x19, 0x10, 0, 0,
            64, 0, 64, 0, 0, 1, 0, 0) then
        return false, "Settings icon must be 64x64 ARGB8888"
    end
    local output = io.open(SETTINGS_ICON_PATH, "wb")
    if not output then return false, "cannot stage Settings icon" end
    local write_ok, write_result = pcall(output.write, output, content)
    local close_ok, close_result = pcall(output.close, output)
    if not write_ok or write_result == nil
        or not close_ok or close_result == nil then
        return false, "Settings icon write failed"
    end
    if read_all(SETTINGS_ICON_PATH, "rb") ~= content then
        return false, "Settings icon verification failed"
    end
    return true
end

local function bytes_to_words(content)
    if type(content) ~= "string" or #content ~= STATUS_SIZE then return nil end
    local words = {}
    for offset = 1, STATUS_SIZE, 4 do
        local a, b, c, d = content:byte(offset, offset + 3)
        words[#words + 1] = a + b * 0x100 + c * 0x10000 + d * 0x1000000
    end
    return words
end

local function signed32(value)
    if value >= 0x80000000 then return value - 0x100000000 end
    return value
end

local function read_status()
    local file = io.open(DEVICE_PATH, "rb")
    if not file then return nil, "cannot open /dev/shellpp" end
    local raw = file:read(STATUS_SIZE)
    file:close()
    local words = bytes_to_words(raw)
    if not words or words[1] ~= EXPECTED_MAGIC then
        return nil, "supervisor status ABI mismatch"
    end
    if words[2] ~= EXPECTED_STATUS_ABI then
        return nil, "old Supervisor is resident; reboot and Run this build"
    end
    if words[12] ~= EXPECTED_FIRMWARE_CODE then
        return nil, "Supervisor firmware target mismatch; reboot and Run this build"
    end
    if words[21] ~= SETTINGS_BUILD then
        return nil, "Settings module build mismatch; reboot and Run this build"
    end
    -- Canopus updates status from asynchronous native workers and therefore
    -- needs a sequence-pair consistency check. Shell++ II's control endpoint
    -- completes each command synchronously inside write(), so the returned
    -- 384-byte snapshot is already coherent.
    return {
        pending_op = words[6],
        pending_state = words[7],
        error_code = signed32(words[9]),
        driver_registered = words[13],
        app_id = words[14],
        app_registered = words[15],
        launcher_published = words[16],
        loaded_notified = words[17],
        settings_installed = words[22],
    }
end

local function word(value)
    value = math.floor(value)
    return string.char(value % 0x100, math.floor(value / 0x100) % 0x100,
        math.floor(value / 0x10000) % 0x100,
        math.floor(value / 0x1000000) % 0x100)
end

local function write_command(command, arg0)
    local payload = word(EXPECTED_CMD_MAGIC) .. word(command)
        .. word(arg0 or 0) .. word(0)
    local file = io.open(DEVICE_PATH, "wb")
    if not file then return false, "cannot open /dev/shellpp" end
    local write_ok, write_result, write_error = pcall(file.write, file, payload)
    local close_ok, close_result, close_error = pcall(file.close, file)
    if not write_ok or write_result == nil then
        return false, tostring(write_error or write_result or "write failed")
    end
    if not close_ok or close_result == nil then
        return false, tostring(close_error or close_result or "close failed")
    end
    return true
end

local function execute_step(command, arg0)
    local ok, message = write_command(command, arg0)
    if not ok then return false, message end
    local current, status_error = read_status()
    if not current then return false, status_error end
    if current.pending_op ~= command or current.pending_state ~= RESULT_COMPLETED then
        return false, string.format("result=%d: %s",
            current.pending_state, describe_error(current.error_code))
    end
    if command == CMD_SETTINGS_START and current.settings_installed ~= 1 then
        return false, "Settings template installation was not confirmed"
    end
    return true
end

local base_steps = {
    { command = CMD_RESTORE_AFTER_BOOT, arg0 = 0,
      progress = "Loading enabled modules..." },
    { command = CMD_INSTALL, arg0 = 0,
      progress = "Registering Manager..." },
    { command = CMD_INSTALL, arg0 = 1,
      progress = "Registering module apps..." },
}
local steps = {}

local function finish_run(timer, success, message)
    timer:delete()
    if run_timer == timer then run_timer = nil end
    set_status(message, success and 0x8FF0A4 or 0xFF9A9A)
end

local function run_next_step(timer)
    local step = steps[run_phase]
    if not step then
        finish_run(timer, true, "Run completed")
        return
    end
    set_status(step.progress)
    local ok, message = execute_step(step.command, step.arg0)
    if not ok then
        finish_run(timer, false, "Run failed: " .. tostring(message)
            .. "\nReboot before retrying.")
        return
    end
    run_phase = run_phase + 1
    if run_phase > #steps then
        finish_run(timer, true, "Run completed")
    else
        timer:ready()
    end
end

local function start_run_timer(with_launcher, with_settings)
    steps = {}
    for i, step in ipairs(base_steps) do steps[i] = step end
    if with_launcher then
        steps[#steps + 1] = { command = CMD_INSTALL, arg0 = 2,
            progress = "Publishing Launcher entries..." }
    end
    if with_settings then
        steps[#steps + 1] = { command = CMD_SETTINGS_START,
            arg0 = SETTINGS_BUILD, progress = "Installing Settings entry..." }
    end
    steps[#steps + 1] = { command = CMD_NOTIFY_LOADED,
        arg0 = with_settings and (with_launcher and 2 or 3) or 1,
        progress = "Sending Shell++ loaded notification..." }
    run_phase = 1
    local created = lvgl.Timer {
        period = 1000,
        repeat_count = -1,
        paused = true,
        cb = function(timer)
            local ok, message = pcall(run_next_step, timer)
            if not ok then
                finish_run(timer, false, "Run failed: " .. tostring(message)
                    .. "\nReboot before retrying.")
            end
        end,
    }
    if not created then return false, "cannot create LuaLVGL timer" end
    run_timer = created
    created:resume()
    created:ready()
    return true
end

local function clear_shellpp_environment()
    -- This deliberately matches Canopus's installer cleanup contract.  A
    -- loaded native App retains firmware-owned callback pointers, so its
    -- live registration must be allowed to disappear on reboot rather than
    -- being detached through an unverified reverse ABI.
    return run("rm -rf /data/shellpp-ii")
end

-- ===================== 开机自启动：按管理器规范只投文件 =====================

-- 写整个文件并**回读核对**。自启动那几个文件错一个字节就是"开机什么都不发生"，
-- 而且是静默的 —— 界面看不出来。
-- ★ 它**不建父目录** —— 这正是"管理器没装"能被判出来的原因（见 rc_dir_ready）。
local function write_file(path, body)
    if type(body) ~= "string" then return false, "body not string" end
    local output = io.open(path, "wb")
    if not output then return false, "cannot open " .. path end
    local write_ok, write_result = pcall(output.write, output, body)
    local close_ok, close_result = pcall(output.close, output)
    if not write_ok or write_result == nil
        or not close_ok or close_result == nil then
        return false, "write failed"
    end
    if read_all(path, "rb") ~= body then return false, "read-back mismatch" end
    return true
end

-- 判「管理器装没装」= **试写**。三条理由：
--   1. 不能用 exists(目录)：NuttX 上 open() 开目录返回 -6(ENXIO)，io.open 直接给 nil
--      ⇒ "目录明明在"也会被判成不在；
--   2. write_file 不建父目录 ⇒ 目录不在时，写 <RC_DIR>/.probe 必然失败；
--   3. "能不能往 /data/rc.d 里写"刚好就是我们真正需要的能力，直接试最直接。
-- 还必须**区分**"管理器没装"与"整片 /data 只读"：前者去装管理器，后者是设备/挂载的问题。
local function rc_dir_ready()
    if write_file(RC_DIR .. "/.probe", "ok") then
        run("rm -f " .. RC_DIR .. "/.probe")
        return true
    end
    if write_file("/data/.probe", "ok") then
        run("rm -f /data/.probe")
        print("[shellpp2] " .. RC_DIR .. " 写不进去 -> 判定「管理器没装」"
            .. " (先装 10pro.autorun 表盘, 它会建这个目录)")
        return false, "管理器没装: 无 /data/rc.d"
    end
    print("[shellpp2] /data 也写不进去 -> 可能只读")
    return false, "写不进 /data (只读?)"
end

-- 16 字节命令帧: magic | cmd | arg0 | arg1（arg1 恒 0）。
local function command_packet(command, arg0)
    return word(EXPECTED_CMD_MAGIC) .. word(command) .. word(arg0 or 0) .. word(0)
end

local function mode_flags(mode)
    local launcher = (mode == "both" or mode == "launcher")
    local settings = (mode == "both" or mode == "settings")
    return launcher, settings
end

local function notify_arg(launcher, settings)
    if settings and launcher then return 2 end
    if settings then return 3 end
    return 1
end

-- 开机脚本要逐条 dd 的 6 条帧。
-- ★ 顺序**照跑通过的那一份**：RESTORE 与 INSTALL(stage 0) 在模块里是空操作，
--   stage 1/2 与 settings/notify 全走 DQ（入环即返回，UI 线程定时器派发）。
--   ⇒ 开机时由 sh 任务 dd 出去也不会碰到 APP_INSTALL 那个"非 UI 任务的挂死点"。
local function build_cmds_blob()
    local launcher, settings = mode_flags(AS_MODE)
    local list = {}
    list[#list + 1] = command_packet(CMD_RESTORE_AFTER_BOOT, 0)
    list[#list + 1] = command_packet(CMD_INSTALL, 0)
    list[#list + 1] = command_packet(CMD_INSTALL_DQ, 1)
    if launcher then
        list[#list + 1] = command_packet(CMD_INSTALL_DQ, 2)
    end
    if settings then
        list[#list + 1] = command_packet(CMD_SETTINGS_DQ, SETTINGS_BUILD)
    end
    list[#list + 1] = command_packet(CMD_NOTIFY_DQ, notify_arg(launcher, settings))
    return table.concat(list), #list
end

-- <RC_DIR>/shellpp2.sh 全文 —— 就是"开机要跑的那串**纯命令**"。
-- ★★ 模块脚本零机制（2026-10-04 职责边界，见文件头 ⑤）：**没有 `if`、没有 `sleep`、
--   不碰 autostart.on**。闸（扣 / 放）、两个安全窗、心跳日志全部由**管理器生成的 /data/rc**
--   负责；本脚本只是"一串命令"，投完就完了。
--   语法**逐条**取自同机跑通的子集：set +e / echo > 、>> / insmod / dd / ls。
--   不能用的（没有证据）：if…fi / && || [ -e ] [ ! ] $( ) / sleep —— nsh 是子集解释器。
local function build_shellpp2_sh(count)
    local L = {}
    local function w(s) L[#L + 1] = s end
    w("set +e")
    w("echo start > " .. AS_LOG)
    w("insmod " .. STAGED_MODULE .. " " .. MODULE_NAME)
    w("echo insmod >> " .. AS_LOG)
    w("echo m1 >> " .. AS_LOG)
    w("dd if=" .. DEVICE_PATH .. " of=" .. STAGE_DIR .. "status1.bin bs="
        .. STATUS_SIZE .. " count=1 conv=notrunc")
    w("echo m2 >> " .. AS_LOG)
    for i = 0, count - 1 do
        w("dd if=" .. CMDS_PATH .. " of=" .. DEVICE_PATH
            .. " bs=16 skip=" .. i .. " count=1 conv=notrunc")
        w("echo c" .. i .. " >> " .. AS_LOG)
    end
    w("echo m3 >> " .. AS_LOG)
    w("dd if=" .. DEVICE_PATH .. " of=" .. STAGE_DIR .. "status2.bin bs="
        .. STATUS_SIZE .. " count=1 conv=notrunc")
    w("echo m4 >> " .. AS_LOG)
    w("dd if=" .. DEVICE_PATH .. " of=" .. STAGE_DIR .. "status3.bin bs="
        .. STATUS_SIZE .. " count=1 conv=notrunc")
    w("echo m5 >> " .. AS_LOG)
    w("ls " .. STAGE_DIR_BARE .. " >> " .. AS_LOG)
    w("echo done >> " .. AS_LOG)
    return table.concat(L, "\n") .. "\n"
end

-- 把内置模块释放到**固定名** /data/shellpp-ii/shellpp_ii.bin。
-- 开机时随机安装目录（/data/quickapp/mass/<hex>/_lua/_Lua/）不存在，所以脚本只能引用固定名。
local function stage_module_bin()
    if type(MODULE_PATH) ~= "string" then return false, "固件版本未知" end
    local content = read_all(MODULE_PATH, "rb")
    if type(content) ~= "string" then return false, "读不到内置模块" end
    local ok, err = write_file(STAGED_MODULE, content)
    if not ok then return false, err end
    return true
end

-- 清旧版残留：摘掉 /data/rc 里那一行 + 删掉 /data/shellpp-ii/rc。
-- 这不是"兼容旧模块"，是"不许留雷"：那一行还在，每次开机都会去跑一个已被删掉的文件。
-- 只删**完全等于** LEGACY_HOP 的那一行 —— 别人（别的模块）的内容一字不动。
local function legacy_cleanup()
    local cur = read_all(LEGACY_RC_PATH)
    if type(cur) == "string" and #cur > 0 and cur:find(LEGACY_HOP, 1, true) then
        local scan = cur
        if scan:sub(-1) ~= "\n" then scan = scan .. "\n" end
        local keep = {}
        for line in scan:gmatch("([^\n]*)\n") do
            if line:gsub("%s+$", "") ~= LEGACY_HOP then keep[#keep + 1] = line end
        end
        local out = table.concat(keep, "\n")
        if #out > 0 then out = out .. "\n" end
        local ok, err = write_file(LEGACY_RC_PATH, out)
        if not ok then print("[shellpp2] 旧行没摘掉: " .. tostring(err)) end
    end
    run("rm -f " .. LEGACY_RC_FILE)
end

-- 投完了吗：脚本在 + 内容逐字节对 + 命令帧对 + 内置模块已释放。
-- ★ 不再判"闸"：模块已经没有闸了（闸归 /data/rc 那层），判它就是判一个不存在的东西。
local function autostart_staged()
    local blob, count = build_cmds_blob()
    return read_all(RC_SH) == build_shellpp2_sh(count)
        and read_all(CMDS_PATH) == blob
        and read_all(STAGED_MODULE) ~= nil
end

-- 安装 = 投 <RC_DIR>/shellpp2.sh（+ 模块 + 图标 + cmds.bin）+ 清旧版残留。
-- ★ 不写 /data/rc、不写 flash、不建闸 —— 那三件事都归管理器。
-- 返回 true，或 false + 原因（原因直接上屏，用户要能照着做）。
local function autostart_install()
    local ok, why = rc_dir_ready()
    if not ok then return false, why end          -- ★ 管理器没装就到此为止，一个字节都不写
    run("mkdir " .. STAGE_DIR_BARE)
    local err
    ok, err = stage_module_bin()
    if not ok then return false, err end
    local icon_ok, icon_err = stage_manager_icon()
    if not icon_ok then return false, icon_err end
    local settings_ok, settings_err = stage_settings_icon()
    if not settings_ok then return false, settings_err end
    local blob, count = build_cmds_blob()
    ok, err = write_file(CMDS_PATH, blob)
    if not ok then return false, err end
    ok, err = write_file(RC_SH, build_shellpp2_sh(count))
    if not ok then return false, err end
    -- ★ 清掉 v1/v2 残留的**模块自带闸**：现在它由 /data/rc 那层负责，留着只会让人
    --   以为"模块还有闸"，把排查带偏（旧版还靠它判"要不要干活"，现在是死文件）。
    run("rm -f " .. LEGACY_FLAG)
    legacy_cleanup()
    if not autostart_staged() then return false, "回读核对不过" end
    return true
end

-- 删除 = 撤掉本模块的注册（删 rc.d/shellpp2.sh）+ 清旧版残留（含 v1/v2 的模块闸）。
-- ★ **不碰 /data/rc** —— 那一行是管理器生成的，要等管理器按 [2 重建自启动] 才会消失。
--   所以调用方**必须**把这一步写进提示里，否则用户会以为"删了但还在跑"。
-- ★ 不删 /data/shellpp-ii/ 里的模块与图标 —— 那是 App 本体的运行依赖，
--   归主视图的 Uninstall / Clear Env 管。
local function autostart_remove()
    run("rm -f " .. RC_SH)
    run("rm -f " .. LEGACY_FLAG)
    legacy_cleanup()
    local left = {}
    for _, p in ipairs({ RC_SH, LEGACY_FLAG }) do
        if read_all(p) ~= nil then left[#left + 1] = p end
    end
    if #left > 0 then return false, "有残留 " .. table.concat(left, " ") end
    return true
end

-- 自启动页状态框里的几行（多行，逐行给）。
-- ★ 不再显示"开关: ON/OFF"：闸归 /data/rc（管理器那一层），本页再显示一个开关就是又造一个
--   真相源。要不要跑、上次跑完没有，去管理器看总闸与 /data/rc.d/.autorun.log。
local function autostart_state_lines()
    local lines = {}
    local dir_ok = rc_dir_ready()
    lines[#lines + 1] = "管理器: " .. (dir_ok and ("在 (" .. RC_DIR .. ")") or "没装")
    local sh = read_all(RC_SH)
    lines[#lines + 1] = "脚本: " .. (type(sh) == "string"
        and ("rc.d/shellpp2.sh " .. tostring(#sh) .. "B") or "未投")
    lines[#lines + 1] = "模块: " .. (read_all(STAGED_MODULE) ~= nil and "已释放" or "未释放")
        .. "   开关→管理器"
    local blob, count = build_cmds_blob()
    lines[#lines + 1] = "命令帧: " .. (read_all(CMDS_PATH) == blob
        and ("OK (" .. count .. " 条)") or "未投")
    return lines
end

-- ===================== 界面（原版两页：主页 / 自启动页） =====================

local rootbase = lvgl.Object(nil, {
    w = lvgl.HOR_RES(), h = lvgl.VER_RES(), bg_color = 0x07111F,
    bg_opa = lvgl.OPA(100), border_width = 0,
})
rootbase:clear_flag(lvgl.FLAG.SCROLLABLE)
local root = lvgl.Object(rootbase, {
    w = 336, h = 480, bg_color = 0x07111F, bg_opa = lvgl.OPA(100),
    border_width = 0, pad_all = 0, align = lvgl.ALIGN.CENTER,
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)

-- 切页用 align 的 y_ofs 位移，**不用 hidden 标志**：位移是纯布局，不依赖任何在本设备上
-- 没验证过的属性；被移出屏幕的视图 LVGL 自己就不画了。
local PAGE_HIDE = 2000
local function make_page()
    local page = lvgl.Object(root, {
        w = 336, h = 480, bg_color = 0x07111F, bg_opa = lvgl.OPA(100),
        border_width = 0, pad_all = 0,
        align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 0 },
    })
    page:clear_flag(lvgl.FLAG.SCROLLABLE)
    return page
end
local main_page = make_page()
local as_page   = make_page()
local PAGES = { main_page, as_page }
local function show_only(target)
    for _, page in ipairs(PAGES) do
        page:set { align = { type = lvgl.ALIGN.CENTER, x_ofs = 0,
            y_ofs = (page == target) and 0 or PAGE_HIDE } }
    end
end
local function show_main() show_only(main_page) end
local function show_as() show_only(as_page) end

-- Presentation shell only. The controls below retain their original
-- callbacks and command sequence; this panel only makes long status text
-- readable through native LVGL scrolling.
lvgl.Label(main_page, {
    text = "Shell++ II", text_color = 0xFFFFFF,
    text_font = lvgl.Font("MiSans-Demibold", 32),
    width = 300, height = 44,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -206 },
})
lvgl.Label(main_page, {
    text = "原生应用安装器 For 10 Pro", text_color = 0x9DB7D8,
    text_font = lvgl.Font("MiSans-Regular", 20),
    width = 300, height = 34,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -170 },
})
log_panel = lvgl.Object(main_page, {
    w = 304, h = 80, bg_color = 0x0D1D31, bg_opa = lvgl.OPA(100),
    radius = 14, border_width = 1, border_color = 0x244566,
    pad_left = 14, pad_right = 14, pad_top = 10, pad_bottom = 10,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 196 },
})
log_panel:clear_flag(lvgl.FLAG.SCROLLABLE)

local function make_button(text, y, color, on_clicked)
    local button = lvgl.Object(main_page, {
        w = 304, h = 40, bg_color = color, bg_opa = lvgl.OPA(100),
        radius = 16,
        align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = y },
    })
    button:clear_flag(lvgl.FLAG.SCROLLABLE)
    button:add_flag(lvgl.FLAG.CLICKABLE)
    lvgl.Label(button, {
        text = text, text_color = 0xFFFFFF, align = lvgl.ALIGN.CENTER,
        text_font = lvgl.Font("MiSans-Regular", 20),
    })
    button:onClicked(function()
        local ok, message = pcall(on_clicked)
        if not ok then set_status("Error: " .. tostring(message), 0xFF9A9A) end
    end)
    return button
end

local firmware_version = detect_firmware_version()
if firmware_version then
    EXPECTED_FIRMWARE_CODE = firmware_code_for(firmware_version)
    SETTINGS_BUILD = EXPECTED_FIRMWARE_CODE == 3101036 and 0x03650901 or 0x04350901
    if EXPECTED_FIRMWARE_CODE then
        MODULE_PATH = module_path_for(firmware_version)
    end
end
local module_supported = false
if MODULE_PATH then module_supported = verify_module_file() end
if not module_supported then
    status = lvgl.Label(log_panel, {
        text = "Firmware version not supported\n"
            .. tostring(firmware_version or "Unknown"),
        text_color = 0xFF9A9A, width = 276, height = 60,
        text_font = lvgl.Font("MiSans-Regular", 18),
        align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 0, y_ofs = 0 },
    })
    return
end

local run_buttons = {}
local function start_run(with_launcher, with_settings)
    clear_armed = false
    if with_settings and EXPECTED_FIRMWARE_CODE ~= 3101043 and EXPECTED_FIRMWARE_CODE ~= 3101036 then
        set_status("Settings requires firmware 3.101.036 or 3.101.043", 0xFF9A9A)
        return
    end
    if run_attempted then
        set_status("Run can only be used once; reboot before retrying")
        return
    end
    run_attempted = true
    for _, button in ipairs(run_buttons) do
        button:clear_flag(lvgl.FLAG.CLICKABLE)
    end
    local valid, validation_error = verify_module_file()
    if not valid then
        set_status("LOAD failed: " .. tostring(validation_error)
            .. "\nEnsure the firmware version matches this installer.", 0xFF9A9A)
        return
    end
    if not supervisor_present() then
        set_status("Loading supervisor...")
        local inserted = run(string.format("insmod %s %s",
            shell_quote(MODULE_PATH), MODULE_NAME))
        if not inserted or not supervisor_present() then
            set_status("LOAD failed. Ensure the firmware version matches this installer."
                .. "\nReboot before retrying.", 0xFF9A9A)
            return
        end
    end
    local supervisor_status, supervisor_error = read_status()
    if not supervisor_status or supervisor_status.driver_registered ~= 1 then
        set_status("LOAD failed: " .. tostring(supervisor_error
            or "Supervisor driver did not start")
            .. "\nReboot before retrying.", 0xFF9A9A)
        return
    end
    local icon_ok, icon_error = stage_manager_icon()
    if not icon_ok then
        set_status("Run failed: " .. tostring(icon_error), 0xFF9A9A)
        return
    end
    if with_settings then
        local settings_ok, settings_error = stage_settings_icon()
        if not settings_ok then
            set_status("Run failed: " .. tostring(settings_error), 0xFF9A9A)
            return
        end
    end
    local started, timer_error = start_run_timer(with_launcher, with_settings)
    if not started then
        set_status("Run failed: " .. tostring(timer_error), 0xFF9A9A)
    else
        set_status("Supervisor loaded; scheduling boot restore...")
    end
end

-- 七键（原版六键 + 新增「自启动」入口）。原版间距 44 / 高 40 ⇒ 这里收成间距 42 / 高 40，
-- 才能在最下面那条状态框之上再塞一个全宽键；其余几何按原版比例。
local ROW_Y = { -126, -84, -42, 0, 42, 84, 126 }
run_buttons[1] = make_button("Run (Both)", ROW_Y[1], 0x14508A, function()
    start_run(true, true)
end)
run_buttons[2] = make_button("Run (Launcher)", ROW_Y[2], 0x14508A, function()
    start_run(true, false)
end)
run_buttons[3] = make_button("Run (Settings)", ROW_Y[3], 0x14508A, function()
    start_run(false, true)
end)

make_button("Uninstall", ROW_Y[4], 0x8A1F14, function()
    if run_timer then
        set_status("An installer operation is in progress", 0xFFD27A)
        return
    end
    if clear_shellpp_environment() then
        -- The Supervisor and Launcher callbacks reside in RAM only.  After
        -- reboot, NuttX drops the module and the Launcher entry with it.
        set_status("Uninstalled; reboot to remove Shell++ II", 0x8FF0A4)
    else
        set_status("Uninstall failed", 0xFF9A9A)
    end
end)

make_button("Clear Env", ROW_Y[5], 0x65451A, function()
    if run_timer then
        clear_armed = false
        set_status("Run is in progress; reboot before clearing")
        return
    end
    if not clear_armed then
        clear_armed = true
        set_status("Click again to clear", 0xFFD27A)
        return
    end
    clear_armed = false
    if clear_shellpp_environment() then
        set_status("Environment cleared; reboot before Run", 0x8FF0A4)
    else
        set_status("Clear Env failed", 0xFF9A9A)
    end
end)

make_button("Reboot", ROW_Y[6], 0x3C526B, function()
    set_status("Rebooting device...", 0xBFD9FF)
    run("reboot")
end)

-- ★ 新增：自启动页入口（本版唯一新增的主页控件）
make_button("自启动", ROW_Y[7], 0x1E4D8C, function()
    as_refresh()
    show_as()
end)

-- ===================== 自启动页（版式抄我们改的 Shell++ II：标题栏 + 状态框 + 双列按钮 + 横幅） =====================
local as_banner
local as_label
local as_body

local back_as = lvgl.Object(as_page, {
    w = 120, h = 44, bg_color = 0x3C526B, bg_opa = lvgl.OPA(100), radius = 12,
    align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 12, y_ofs = 10 },
})
back_as:clear_flag(lvgl.FLAG.SCROLLABLE)
back_as:add_flag(lvgl.FLAG.CLICKABLE)
lvgl.Label(back_as, {
    text = "< Back", text_color = 0xFFFFFF, align = lvgl.ALIGN.CENTER,
    text_font = lvgl.Font("MiSans-Regular", 20),
})
back_as:onClicked(show_main)

lvgl.Label(as_page, {
    text = "自启动", text_color = 0xFFFFFF,
    text_font = lvgl.Font("MiSans-Demibold", 26),
    width = 110, align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 214, y_ofs = 17 },
})

as_body = lvgl.Object(as_page, {
    w = 316, h = 170, bg_color = 0x0D1D31, bg_opa = lvgl.OPA(100),
    radius = 12, border_width = 1, border_color = 0x244566,
    pad_left = 12, pad_right = 12, pad_top = 8, pad_bottom = 8,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = -36 },
})
as_body:clear_flag(lvgl.FLAG.SCROLLABLE)
as_label = lvgl.Label(as_body, {
    text = "(status)", text_color = 0xBFD9FF, width = 292,
    text_font = lvgl.Font("MiSans-Regular", 14),
    align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 0, y_ofs = 0 },
})

as_banner = lvgl.Label(as_page, {
    text = "(ready)", text_color = 0x9DB7D8,
    text_font = lvgl.Font("MiSans-Regular", 15),
    width = 316, height = 40,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 196 },
})

-- 自启动页的两栏按钮（与 v2 同款：152×48、圆角 16、字号 16）
local function make_as_button(text, y, x, color, on_clicked)
    local button = lvgl.Object(as_page, {
        w = 152, h = 48, bg_color = color, bg_opa = lvgl.OPA(100), radius = 16,
        align = { type = lvgl.ALIGN.CENTER, x_ofs = x, y_ofs = y },
    })
    button:clear_flag(lvgl.FLAG.SCROLLABLE)
    button:add_flag(lvgl.FLAG.CLICKABLE)
    lvgl.Label(button, {
        text = text, text_color = 0xFFFFFF, align = lvgl.ALIGN.CENTER,
        text_font = lvgl.Font("MiSans-Regular", 16),
    })
    button:onClicked(function()
        local ok, message = pcall(on_clicked)
        if not ok then as_report(text, false, tostring(message)) end
    end)
    return button
end

-- 两个刷新函数（前向声明的定义）。
function as_refresh()
    if as_label then
        as_label:set { text = table.concat(autostart_state_lines(), "\n") }
    end
end

function as_report(title, ok, err)
    if as_banner then
        as_banner:set {
            text = title .. (ok and "  OK" or ("  失败: " .. tostring(err))),
            text_color = ok and 0x8FF0A4 or 0xFF9A9A,
        }
    end
    as_refresh()
end

-- 新标准下这一页只有两件事：**投文件 / 撤文件**。
-- 没有"开/关自启动"按钮 —— 因为"要不要跑"全在这一页之外：
--   · 管理器那边的策略（禁用的模块**那一行根本不生成**）与总闸 `/data/rc.d/.autorun.on`；
--   · 防砖的"扣闸 / 放闸"也在管理器生成的 `/data/rc` 里（模块零机制，见文件头 ⑤）。
-- 所以多一个按钮只会多一个和上面那层打架的状态。
local AS_ROW = 100
make_as_button("1 安装", AS_ROW, -80, 0x1E4D8C, function()
    local ok, err = autostart_install()
    as_report("安装 (投 rc.d/shellpp2.sh)", ok, err)
end)
make_as_button("2 删除", AS_ROW, 80, 0x6B3C3C, function()
    local ok, err = autostart_remove()
    as_report("删除 (撤注册)", ok, err)
end)

show_main()

status = lvgl.Label(log_panel, {
    text = "Ready\nFirmware " .. firmware_version,
    text_color = 0xBFD9FF, width = 276, height = 60,
    text_font = lvgl.Font("MiSans-Regular", 18),
    align = { type = lvgl.ALIGN.TOP_LEFT, x_ofs = 0, y_ofs = 0 },
})
