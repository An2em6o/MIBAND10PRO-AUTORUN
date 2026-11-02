-- Host regression tests for Watchface/module.autorun.canopus/_Lua/main.lua.
--
-- The installer is a watchface Lua chunk, so these tests load the real chunk
-- with a small LVGL double and an in-memory /data filesystem.  Real .036/.043
-- supervisor binaries and manager_icon.bin are read-only fixtures; no package
-- or source file is modified.
-- Run from the repository root: lua tool/test_canopus_autorun.lua

local native_io = io

local root = os.getenv("MIBAND10PRO_AUTORUN_ROOT") or "."
local lua_dir = root .. "/Watchface/module.autorun.canopus/_Lua/"
local main_path = lua_dir .. "main.lua"
local property_output = "/data/canopus-installer-firmware-version.tmp"
local device_path = "/dev/canopus"
local rc_dir = "/data/rc.d"
local rc_path = "/data/rc"
local script_path = rc_dir .. "/canopus.sh"
local staged_module_path = "/data/canopus/canopus_supervisor.bin"
local frame_path = "/data/canopus/boot.bin"

local function native_read(path)
    local file = assert(native_io.open(path, "rb"), path)
    local body = file:read("*a")
    file:close()
    return body
end

local resources = {
    [lua_dir .. "manager_icon.bin"] = native_read(lua_dir .. "manager_icon.bin"),
}
for _, version in ipairs({ "3.101.036", "3.101.043" }) do
    local path = lua_dir .. "canopus_supervisor-xiaomi-band-10-pro-" .. version .. ".bin"
    resources[path] = native_read(path)
end

local function reader(content)
    local position = 1
    return {
        read = function(_, amount)
            if amount == "*a" then
                local result = content:sub(position)
                position = #content + 1
                return result
            end
            assert(type(amount) == "number", "unexpected read mode")
            local result = content:sub(position, position + amount - 1)
            position = position + #result
            return result
        end,
        seek = function(_, where, offset)
            offset = offset or 0
            if where == "end" then
                position = #content + 1 + offset
            elseif where == "set" then
                position = 1 + offset
            else
                error("unsupported seek: " .. tostring(where))
            end
            return position - 1
        end,
        close = function() return true end,
    }
end

local function make_lvgl(objects)
    local lvgl = {
        FLAG = { SCROLLABLE = 1, CLICKABLE = 2 },
        ALIGN = { CENTER = 1 },
        OPACITY = 100,
    }
    lvgl.OPA = function(value) return value end
    lvgl.HOR_RES = function() return 336 end
    lvgl.VER_RES = function() return 480 end

    local methods = {}
    function methods:clear_flag() return self end
    function methods:add_flag() return self end
    function methods:onClicked(callback)
        self._clicked = callback
        return self
    end
    function methods:set(properties)
        for key, value in pairs(properties or {}) do self[key] = value end
        return self
    end
    function methods:delete() self._deleted = true end
    function methods:resume() self._running = true end
    function methods:ready() self._ready = true end

    local function object(parent, properties)
        local value = setmetatable({ parent = parent }, { __index = methods })
        for key, item in pairs(properties or {}) do value[key] = item end
        objects[#objects + 1] = value
        return value
    end

    function lvgl.Object(parent, properties)
        return object(parent, properties)
    end
    function lvgl.Label(parent, properties)
        local value = object(parent, properties)
        value._is_label = true
        if parent and properties and properties.text then
            parent._label_text = properties.text
        end
        return value
    end
    function lvgl.Timer(properties)
        local value = object(nil, properties)
        return value
    end
    return lvgl
end

local function make_case(version, options)
    options = options or {}
    local state = {
        version = version,
        rc_dir = options.rc_dir ~= false,
        property_ok = options.property_ok ~= false,
        files = {},
        commands = {},
        write_paths = {},
        corrupt_path = options.corrupt_path,
        fail_open = options.fail_open,
        fail_write = options.fail_write,
        fail_close = options.fail_close,
        objects = {},
    }
    if options.initial_rc ~= nil then state.files[rc_path] = options.initial_rc end
    if options.gate_on then state.files[rc_dir .. "/.autorun.on"] = "on\n" end

    local function writer(path)
        local chunks = {}
        return {
            write = function(_, body)
                if path == state.fail_write then return nil, "write failed" end
                chunks[#chunks + 1] = body
                return true
            end,
            close = function()
                if path == state.fail_close then return nil, "close failed" end
                local body = table.concat(chunks)
                if path == state.corrupt_path then body = "corrupted" end
                state.files[path] = body
                return true
            end,
        }
    end

    local fake_io = {}
    fake_io.open = function(path, mode)
        mode = mode or "r"
        if mode:sub(1, 1) == "w" then
            state.write_paths[#state.write_paths + 1] = path
            if path == state.fail_open then return nil end
            if path == rc_dir .. "/.probe" and not state.rc_dir then return nil end
            if path:sub(1, #rc_dir + 1) == rc_dir .. "/" and not state.rc_dir then
                return nil
            end
            return writer(path)
        end
        if path == property_output and state.property_ok then
            return reader(state.version .. "\n")
        end
        local body = state.files[path]
        if body == nil then body = resources[path] end
        if body ~= nil then return reader(body) end
        return nil
    end

    local function fake_execute(command)
        state.commands[#state.commands + 1] = command
        local output = command:match("^getprop 'ro%.build%.version' > '([^']+)'$")
        if output then return state.property_ok and 0 or false end
        local quoted = command:match("^rm %-f '([^']+)'$")
        local plain = command:match("^rm %-f (.+)$")
        local path = quoted or plain
        if path then state.files[path] = nil end
        return 0
    end

    local function fake_remove(path)
        if path == property_output then state.files[path] = nil end
        return true
    end

    local lvgl = make_lvgl(state.objects)
    local environment = setmetatable({
        io = fake_io,
        os = { execute = fake_execute, remove = fake_remove },
        SCRIPT_PATH = lua_dir,
        require = function(name)
            assert(name == "lvgl", "unexpected module: " .. name)
            return lvgl
        end,
        print = function() end,
    }, { __index = _G })
    assert(loadfile(main_path, "t", environment))()
    state.status = state.objects[#state.objects]
    return state
end

local function find_button(state, label)
    for _, value in ipairs(state.objects) do
        if value._label_text == label then return value end
    end
    error("button not found: " .. label)
end

local function find_status(state)
    assert(state.status._is_label, "status label not found")
    return state.status
end

local function assert_not_written(state, path)
    for _, written in ipairs(state.write_paths) do
        assert(written ~= path, "unexpected write: " .. path)
    end
end

local function assert_no_gate_or_flash(state)
    assert_not_written(state, rc_path)
    assert_not_written(state, rc_dir .. "/.autorun.on")
    assert_not_written(state, device_path)
    local allowed = {
        [rc_dir .. "/.probe"] = true,
        ["/data/.probe"] = true,
        ["/data/canopus/manager_icon.bin"] = true,
        [staged_module_path] = true,
        [frame_path] = true,
        [script_path] = true,
    }
    for _, path in ipairs(state.write_paths) do
        assert(allowed[path], "unexpected write: " .. path)
    end
    for _, command in ipairs(state.commands) do
        assert(command == "getprop 'ro.build.version' > '" .. property_output .. "'"
            or command == "rm -f '/data/rc.d/.probe'"
            or command == "rm -f /data/.probe"
            or command == "mkdir /data/canopus"
            or command == "mkdir /data/canopus/inbox",
            "unexpected install command: " .. command)
    end
end

local function assert_write_attempt(state, path)
    for _, written in ipairs(state.write_paths) do
        if written == path then return end
    end
    error("expected write attempt: " .. path)
end

local function test_install(version, gate_on)
    local state = make_case(version, {
        initial_rc = "foreign line\n",
        gate_on = gate_on,
    })
    find_button(state, "Autostart Install")._clicked()
    local status = find_status(state)
    local expected_status = gate_on
        and "Autostart files updated\nManager: [2 Apply]"
        or "Autostart files updated\nManager: [3 Enable] + [2 Apply]"
    assert(status.text == expected_status, status.text)

    local expected_module = resources[lua_dir .. "canopus_supervisor-xiaomi-band-10-pro-" .. version .. ".bin"]
    assert(state.files[staged_module_path] == expected_module)
    assert(state.files["/data/canopus/manager_icon.bin"] == resources[lua_dir .. "manager_icon.bin"])

    local frame = assert(state.files[frame_path])
    assert(#frame == 36, "START_BOOT frame must be 36 bytes")
    local magic, header, protocol, abi, flags, total, command, request, arg0, arg1, arg2 =
        string.unpack("<I4I2I2I2I2I4I4I4I4I4I4", frame)
    assert(magic == 0x43504332 and header == 36 and protocol == 1 and abi == 2)
    assert(flags == 0 and total == 36 and command == 25 and request == 1)
    assert(arg0 == 0 and arg1 == 0 and arg2 == 0)

    local script = assert(state.files[script_path])
    local expected_script = table.concat({
        "set +e",
        "echo start > /data/canopus/autostart.log",
        "insmod /data/canopus/canopus_supervisor.bin canopus_supervisor",
        "echo insmod >> /data/canopus/autostart.log",
        "dd if=/data/canopus/boot.bin of=/dev/canopus bs=36 count=1 conv=notrunc",
        "echo boot_cmd_sent >> /data/canopus/autostart.log",
        "dd if=/dev/canopus of=/data/canopus/boot_reply.bin bs=36 count=1 conv=notrunc",
        "echo done >> /data/canopus/autostart.log",
        "",
    }, "\n")
    assert(script == expected_script, "boot script changed or reordered")
    for line in script:gmatch("[^\n]+") do
        assert(#line <= 255, "NSH line length limit exceeded")
    end
    assert(state.files[rc_path] == "foreign line\n", "foreign /data/rc changed")
    if gate_on then
        assert(state.files[rc_dir .. "/.autorun.on"] == "on\n")
    else
        assert(state.files[rc_dir .. "/.autorun.on"] == nil)
    end
    assert_no_gate_or_flash(state)
end

local function test_missing_manager()
    local state = make_case("3.101.043", { rc_dir = false })
    find_button(state, "Autostart Install")._clicked()
    local status = find_status(state)
    assert(status.text == "Autostart failed: manager missing: no /data/rc.d", status.text)
    assert(state.files["/data/.probe"] == nil)
    assert(state.files[staged_module_path] == nil)
    assert(state.files[script_path] == nil)
    assert_no_gate_or_flash(state)
end

local function test_writeback_failure()
    local state = make_case("3.101.036", { corrupt_path = frame_path })
    find_button(state, "Autostart Install")._clicked()
    local status = find_status(state)
    assert(status.text:match("^Autostart failed: verification failed: /data/canopus/boot%.bin$"), status.text)
    assert(state.files[script_path] == nil, "script must not be published after frame verification failure")
    assert_no_gate_or_flash(state)
end

local function test_unknown_firmware()
    local state = make_case("3.101.999")
    local status = find_status(state)
    assert(status.text == "Firmware version not supported\n3.101.999", status.text)
    for _, value in ipairs(state.objects) do
        assert(value._label_text ~= "Autostart Install")
        assert(value._label_text ~= "Autostart Remove")
    end
    assert(state.files[staged_module_path] == nil)
    assert_no_gate_or_flash(state)
end

local function test_write_stage_failure(version, path, mode)
    local state = make_case(version, { [mode] = path })
    find_button(state, "Autostart Install")._clicked()
    local status = find_status(state)
    assert(status.text:match("^Autostart failed:"), status.text)
    if path ~= script_path then assert(state.files[script_path] == nil) end
    assert(state.files[rc_path] == nil)
    assert_no_gate_or_flash(state)
end

local function test_legacy_cleanup_failure()
    local legacy = "keep this line\nsh /data/canopus/rc &\n"
    local state = make_case("3.101.043", {
        initial_rc = legacy,
        fail_open = rc_path,
    })
    find_button(state, "Autostart Install")._clicked()
    local status = find_status(state)
    assert(status.text == "Autostart failed: cannot open /data/rc", status.text)
    assert(state.files[rc_path] == legacy)
    assert(state.files[script_path] ~= nil, "staged files should remain, only legacy cleanup failed")
    assert_write_attempt(state, rc_path)
    assert(state.files[rc_dir .. "/.autorun.on"] == nil)
    for _, command in ipairs(state.commands) do
        assert(not command:find("flash", 1, true), "flash command: " .. command)
    end
end

test_install("3.101.036", false)
test_install("3.101.043", true)
test_missing_manager()
test_writeback_failure()
test_unknown_firmware()
for _, path in ipairs({ "/data/canopus/manager_icon.bin", staged_module_path, frame_path, script_path }) do
    for _, mode in ipairs({ "fail_open", "fail_write", "fail_close", "corrupt_path" }) do
        test_write_stage_failure("3.101.036", path, mode)
    end
end
test_legacy_cleanup_failure()

print("canopus autorun host tests: PASS (22 cases; .036/.043, CPC2, script, gate, failures, legacy cleanup)")
