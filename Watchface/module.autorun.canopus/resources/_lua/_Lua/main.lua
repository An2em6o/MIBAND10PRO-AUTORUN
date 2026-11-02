-- Production Canopus installer for Xiaomi Band 10.
--
-- Run performs, in order:
--   supervisor LOAD -> INSTALL 0 (Manager app) -> INSTALL 2 (Manager Launcher)
--   -> apply restored boot intents (third-party modules) -> INSTALL 1 -> INSTALL 2.
-- Prioritizing Manager ensures the Canopus Manager UI is always accessible,
-- even if an individual third-party module encounters an activation error.
--
-- Autostart (10pro.autorun manager contract, REGISTER.md): the module only
-- drops a pure-command script into /data/rc.d; the manager owns /data/rc,
-- the anti-brick gate and both safety windows. The 36-byte boot frame below
-- carries a CPC2 CANOPUS_CMD_START_BOOT (25) request — the supervisor's
-- native delayed start (ADR-CAN-012): the write path only arms a
-- foreground LVGL-owner heartbeat (one stage per second); the shell write
-- only arms it, so the registration chain never runs in the sh task. The old
-- CPC1 "3PC1" DQ patch is gone — command 25 now uses the same owner context.
-- Gate/sleep/flash policy deliberately absent from this file.

local lvgl = require("lvgl")

local TARGET_ID_PREFIX = "xiaomi-band-10-pro-"
local FIRMWARE_VERSION_PROPERTY = "ro.build.version"
local FIRMWARE_VERSION_OUTPUT = "/data/canopus-installer-firmware-version.tmp"
local MODULE_PATH
local MODULE_NAME = "canopus_supervisor"
local MANAGER_ICON_RESOURCE = SCRIPT_PATH .. "manager_icon.bin"
local MANAGER_ICON_PATH = "/data/canopus/manager_icon.bin"
local DEVICE_PATH = "/dev/canopus"
local MODULE_MIN_SIZE = 512
local MODULE_MAX_SIZE = 262144
local CPC2_MAGIC = 0x43504332
local CPC2_HEADER = 36
local CPC2_ABI_MAJOR = 2
local CMD_QUERY_DEVICE = 9
local CMD_INSTALL = 13           -- NATIVE_STAGE: payload-free INSTALL stages 0..2
local CMD_RESTORE_AFTER_BOOT = 14
local CMD_START_BOOT = 25        -- arms the supervisor's foreground boot sequence
local RESULT_COMPLETED = 5
local request_id = 0

-- Boot-autorun surfaces. Everything lives under the module's own /data/canopus
-- directory; /data/rc.d is the manager's territory and is only probed, never
-- created. The staged module copy uses a fixed name because the boot script
-- cannot know the versioned resource name inside the watchface container.
local RC_DIR = "/data/rc.d"
local RC_PATH = "/data/rc"
local AUTOSTART_SCRIPT = RC_DIR .. "/canopus.sh"
local CANOPUS_DIR = "/data/canopus"
local STAGED_MODULE_PATH = CANOPUS_DIR .. "/canopus_supervisor.bin"
local BOOT_FRAME_PATH = CANOPUS_DIR .. "/boot.bin"
local BOOT_REPLY_PATH = CANOPUS_DIR .. "/boot_reply.bin"
local AUTOSTART_LOG = CANOPUS_DIR .. "/autostart.log"
local LEGACY_RC_HOP = "sh /data/canopus/rc &" -- pre-manager era; must not stay

local status
local run_timer
local run_phase = 1
local run_attempted = false
local clear_armed = false
local module_warning = nil

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function run(command)
    print("[canopus-installer-prod] exec: " .. command)
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
    return SCRIPT_PATH .. "canopus_supervisor-" .. TARGET_ID_PREFIX
        .. version .. ".bin"
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
        return false, "missing or invalid manager_icon.bin"
    end
    local width = content:byte(5) + content:byte(6) * 0x100
    local height = content:byte(7) + content:byte(8) * 0x100
    if width < 1 or height < 1 or #content ~= 12 + width * height * 4 then
        return false, "manager_icon.bin size mismatch"
    end
    local output = io.open(MANAGER_ICON_PATH, "wb")
    if not output then
        if not run("mkdir /data/canopus") then
            return false, "cannot create /data/canopus"
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
    run("mkdir /data/canopus/inbox")
    return true
end

local function signed32(value)
    if value >= 0x80000000 then return value - 0x100000000 end
    return value
end

local function u32le(raw, offset)
    return (string.unpack("<I4", raw, offset + 1))
end

-- One CPC2 request and its reply, kept together: /dev/canopus has a shared
-- result mailbox, so nothing may yield between the write and the read.
local function exchange(command, payload, reply_size)
    payload = payload or ""
    request_id = request_id + 1
    local request = string.pack("<I4I2I2I2I2I4I4I4I4I4I4", CPC2_MAGIC, CPC2_HEADER,
        1, CPC2_ABI_MAJOR, 0, CPC2_HEADER + #payload, command, request_id, 0, 0, #payload) .. payload
    local file = io.open(DEVICE_PATH, "wb")
    if not file then return nil, "cannot open /dev/canopus" end
    local write_ok, write_result, write_error = pcall(file.write, file, request)
    -- Closing a character device only reports libc's close status and returns
    -- no value here, so it carries no protocol meaning. The reply check below
    -- is what decides whether the request landed.
    pcall(file.close, file)
    if not write_ok then return nil, "write: " .. tostring(write_error) end
    if write_result == nil then
        return nil, "write: " .. tostring(write_error or "rejected")
    end
    file = io.open(DEVICE_PATH, "rb")
    if not file then return nil, "cannot open /dev/canopus" end
    local reply = file:read(reply_size)
    file:close()
    if type(reply) ~= "string" or #reply ~= reply_size
        or u32le(reply, 0) ~= CPC2_MAGIC or u32le(reply, 16) ~= command
        or u32le(reply, 20) ~= request_id then
        return nil, string.format("supervisor reply ABI mismatch (want %d, got %s)",
            reply_size, type(reply) == "string" and #reply or type(reply))
    end
    return reply
end

local function device_error()
    local reply = exchange(CMD_QUERY_DEVICE, nil, CPC2_HEADER + 88)
    return reply and signed32(u32le(reply, CPC2_HEADER + 24)) or 0
end

local ERROR_HINTS = {
    [-21] = "内存不足：模块镜像过大，请缩小模块体积",
    [-22] = "模块启动失败，已自动回退到上一版本",
    [-25] = "模块连续崩溃，已被安全隔离并停用",
    [-11] = "注册表数据异常，已自动保护",
    [-6]  = "模块加载失败，请检查模块与设备固件是否兼容",
}

local function execute_step(command, arg0)
    local reply, message = exchange(command,
        command == CMD_INSTALL and string.pack("<I4", arg0 or 0) or nil, CPC2_HEADER)
    if not reply then return false, message end
    local result = u32le(reply, 28)
    if result ~= RESULT_COMPLETED then
        local err = device_error()
        local hint = ERROR_HINTS[err]
        return false, string.format("result=%d error=%d%s", result, err, hint and ("\n" .. hint) or "")
    end
    return true
end

-- 注册顺序：以注册管理器原生应用为最高优先级！
-- 1. 先注册 Manager (Stage 0) 并发布 Launcher 入口 (Stage 2)
-- 2. 随后再恢复与加载已启用的第三方模块 (即使模块故障，管理器也已就位，不发生死锁)
-- 3. 最后刷新各模块的原生应用页面与桌面图标
local steps = {
    { command = CMD_INSTALL, arg0 = 0,
      progress = "Registering Manager...", critical = true },
    { command = CMD_INSTALL, arg0 = 2,
      progress = "Publishing Launcher entries...", critical = true },
    { command = CMD_RESTORE_AFTER_BOOT, arg0 = 0,
      progress = "Loading enabled modules...", critical = false },
    { command = CMD_INSTALL, arg0 = 1,
      progress = "Registering module apps...", critical = false },
    { command = CMD_INSTALL, arg0 = 2,
      progress = "Updating Launcher entries...", critical = false },
}

local function finish_run(timer, success, message)
    timer:delete()
    if run_timer == timer then run_timer = nil end
    set_status(message, success and 0x8FF0A4 or 0xFF9A9A)
end

local function run_next_step(timer)
    local step = steps[run_phase]
    if not step then
        if module_warning then
            finish_run(timer, true, "Manager registered!\nWarning: " .. tostring(module_warning)
                .. "\nCheck Manager app to fix module.")
        else
            finish_run(timer, true, "Run completed")
        end
        return
    end
    set_status(step.progress)
    local ok, message = execute_step(step.command, step.arg0)
    if not ok then
        if step.critical then
            finish_run(timer, false, "Run failed: " .. tostring(message)
                .. "\nReboot before retrying.")
            return
        else
            print("[canopus-installer-prod] non-critical step failed: " .. tostring(message))
            module_warning = message
        end
    end
    run_phase = run_phase + 1
    if run_phase > #steps then
        if module_warning then
            finish_run(timer, true, "Manager registered!\nWarning: " .. tostring(module_warning)
                .. "\nCheck Manager app to fix module.")
        else
            finish_run(timer, true, "Run completed")
        end
    else
        timer:ready()
    end
end

local function start_run_timer()
    run_phase = 1
    module_warning = nil
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

-- ---- boot autorun (10pro.autorun manager contract) --------------------
-- Files-only registration: every write is /data-only and reversible, so
-- there is no two-stage arming here. The manager owns /data/rc, the gate
-- and both safety windows; this file never touches them (REGISTER.md).

local function write_file(path, content)
    local file = io.open(path, "wb")
    if not file then return false, "cannot open " .. path end
    local write_ok, write_result = pcall(file.write, file, content)
    local close_ok, close_result = pcall(file.close, file)
    if not write_ok or write_result == nil
        or not close_ok or close_result == nil then
        return false, "write failed: " .. path
    end
    if read_all(path, "rb") ~= content then
        return false, "verification failed: " .. path
    end
    return true
end

-- Probe for the manager's rc.d directory. Test-writes a probe file instead
-- of checking directory existence: on NuttX io.open on a directory yields
-- nil even when the directory exists. A missing /data/rc.d means the
-- 10pro.autorun manager is not installed, and per contract not a single
-- byte is written anywhere else.
local function rc_dir_ready()
    local probe = RC_DIR .. "/.probe"
    if write_file(probe, "probe") then
        run("rm -f " .. shell_quote(probe))
        return true
    end
    if write_file("/data/.probe", "probe") then
        run("rm -f /data/.probe")
        return false, "manager missing: no /data/rc.d"
    end
    return false, "/data not writable"
end

-- Copy the exact-firmware supervisor resource to a fixed name under
-- /data/canopus: the boot script insmods this copy because it cannot see
-- inside the watchface container. Idempotent; verified by readback.
local function stage_module_to_data()
    local content = read_all(MODULE_PATH, "rb")
    if type(content) ~= "string" or #content < MODULE_MIN_SIZE then
        return false, "cannot read supervisor resource"
    end
    return write_file(STAGED_MODULE_PATH, content)
end

-- 36-byte CPC2 CANOPUS_CMD_START_BOOT request, byte-identical to what the
-- upstream pinned-start boot.lua sends: the write only arms the supervisor's
-- foreground LVGL-owner state machine (one stage per second), never runs the
-- registration chain in the caller's shell task. Screen-off pauses the LVGL
-- heartbeat until the owner resumes. request_id is 1 because the boot branch never touches
-- the pending-request table.
local function build_boot_frame()
    local payload = string.pack("<I4I2I2I2I2I4I4I4I4I4I4",
        CPC2_MAGIC, CPC2_HEADER, 1, CPC2_ABI_MAJOR, 0, CPC2_HEADER,
        CMD_START_BOOT, 1, 0, 0, 0)
    return write_file(BOOT_FRAME_PATH, payload)
end

-- The boot script is pure commands (REGISTER.md v0.6.6): no gate, no sleep,
-- no /data/rc access, no flash. The manager's generated /data/rc provides
-- the anti-brick gate and both safety windows around this line. There is no
-- pre-write status read: the CPC2 mailbox only exists after the first write.
-- The post-write 36-byte readback is the START_BOOT response (result=5).
local function build_canopus_sh()
    local lines = {
        "set +e",
        "echo start > " .. AUTOSTART_LOG,
        "insmod " .. STAGED_MODULE_PATH .. " " .. MODULE_NAME,
        "echo insmod >> " .. AUTOSTART_LOG,
        "dd if=" .. BOOT_FRAME_PATH .. " of=" .. DEVICE_PATH
            .. " bs=36 count=1 conv=notrunc",
        "echo boot_cmd_sent >> " .. AUTOSTART_LOG,
        "dd if=" .. DEVICE_PATH .. " of=" .. BOOT_REPLY_PATH
            .. " bs=36 count=1 conv=notrunc",
        "echo done >> " .. AUTOSTART_LOG,
    }
    return write_file(AUTOSTART_SCRIPT, table.concat(lines, "\n") .. "\n")
end

-- Remove this module's legacy two-hop line from /data/rc, if a pre-manager
-- era build ever wrote one. Line-filtered: only the exact match is dropped,
-- every other byte of /data/rc is preserved verbatim.
local function legacy_cleanup()
    local current = read_all(RC_PATH, "r")
    if type(current) ~= "string" then return true end
    local kept = {}
    local changed = false
    for line in (current .. "\n"):gmatch("(.-)\n") do
        if line == LEGACY_RC_HOP then
            changed = true
        else
            kept[#kept + 1] = line
        end
    end
    if not changed then return true end
    return write_file(RC_PATH, table.concat(kept, "\n") .. "\n")
end

local function autostart_install()
    local ready, ready_error = rc_dir_ready()
    if not ready then return false, ready_error end
    local icon_ok, icon_error = stage_manager_icon()
    if not icon_ok then return false, icon_error end
    local module_ok, module_error = stage_module_to_data()
    if not module_ok then return false, module_error end
    local frame_ok, frame_error = build_boot_frame()
    if not frame_ok then return false, frame_error end
    local script_ok, script_error = build_canopus_sh()
    if not script_ok then return false, script_error end
    return legacy_cleanup()
end

local function autostart_remove()
    run("rm -f " .. shell_quote(AUTOSTART_SCRIPT))
    run("rm -f " .. shell_quote(BOOT_FRAME_PATH))
    run("rm -f " .. shell_quote(BOOT_REPLY_PATH))
    -- keep canopus_supervisor.bin / manager_icon.bin: the Manager app
    -- itself depends on them; autostart removal must not break it
    legacy_cleanup()
    return true
end

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

local function make_button(text, y, color, on_clicked)
    local button = lvgl.Object(root, {
        w = 220, h = 52, bg_color = color, bg_opa = lvgl.OPA(100),
        radius = 16,
        align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = y },
    })
    button:clear_flag(lvgl.FLAG.SCROLLABLE)
    button:add_flag(lvgl.FLAG.CLICKABLE)
    lvgl.Label(button, {
        text = text, text_color = 0xFFFFFF, align = lvgl.ALIGN.CENTER,
    })
    button:onClicked(function()
        local ok, message = pcall(on_clicked)
        if not ok then set_status("Error: " .. tostring(message), 0xFF9A9A) end
    end)
    return button
end

local firmware_version = detect_firmware_version()
if firmware_version then MODULE_PATH = module_path_for(firmware_version) end
local module_supported = false
if MODULE_PATH then module_supported = verify_module_file() end
if not module_supported then
    status = lvgl.Label(root, {
        text = "Firmware version not supported\n"
            .. tostring(firmware_version or "Unknown"),
        text_color = 0xFF9A9A, width = 300, height = 96,
        align = lvgl.ALIGN.CENTER,
    })
    return
end

local run_button
run_button = make_button("Run", -128, 0x14508A, function()
    clear_armed = false
    if run_attempted then
        set_status("Run can only be used once; reboot before retrying")
        return
    end
    run_attempted = true
    run_button:clear_flag(lvgl.FLAG.CLICKABLE)
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
    local icon_ok, icon_error = stage_manager_icon()
    if not icon_ok then
        set_status("Run failed: " .. tostring(icon_error), 0xFF9A9A)
        return
    end
    local started, timer_error = start_run_timer()
    if not started then
        set_status("Run failed: " .. tostring(timer_error), 0xFF9A9A)
    else
        set_status("Supervisor loaded; scheduling Manager registration...")
    end
end)

make_button("Autostart Install", -68, 0x1F5C2A, function()
    local ok, message = autostart_install()
    if ok then
        -- Registering a script does not reopen the manager's anti-brick gate.
        local gate_on = read_all(RC_DIR .. "/.autorun.on", "rb") ~= nil
        set_status("Autostart files updated\n"
            .. (gate_on and "Manager: [2 Apply]"
                or "Manager: [3 Enable] + [2 Apply]"), 0x8FF0A4)
    else
        set_status("Autostart failed: " .. tostring(message), 0xFF9A9A)
    end
end)

make_button("Autostart Remove", -8, 0x8A5A14, function()
    autostart_remove()
    set_status("Autostart removed"
        .. "\nRebuild /data/rc in Manager", 0xFFD27A)
end)

make_button("Clear Env", 52, 0x8A1F14, function()
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
    if run("rm -rf /data/canopus") then
        set_status("Environment cleared; reboot before Run", 0x8FF0A4)
    else
        set_status("Clear Env failed", 0xFF9A9A)
    end
end)

status = lvgl.Label(root, {
    text = "Ready\nFirmware " .. firmware_version,
    text_color = 0xBFD9FF, width = 300, height = 96,
    align = { type = lvgl.ALIGN.CENTER, x_ofs = 0, y_ofs = 132 },
})
