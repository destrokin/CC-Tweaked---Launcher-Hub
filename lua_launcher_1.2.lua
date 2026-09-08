-- =========================================================
--                   LUA LAUNCHER
-- Standalone CC:Tweaked touch GUI
--
-- Features:
--   * Recursively scans the whole computer for .lua files
--   * Styled main menu
--   * Touch selection
--   * Scroll buttons
--   * RUN button
--   * RESCAN button
--   * Automatic monitor size detection
--   * Adjustable GUI scale
--   * Returns to launcher when launched program exits
-- =========================================================

-- Read the preferred launcher monitor before the GUI starts.
local PRESET_LAUNCHER_MONITOR = nil

if fs.exists("lua_launcher_settings.txt") then
    local presetFile = fs.open("lua_launcher_settings.txt", "r")

    if presetFile then
        while true do
            local line = presetFile.readLine()
            if not line then break end

            local key, value = line:match("^%s*([^=]+)%s*=%s*(.*)$")

            if key and value then
                key = key:gsub("^%s+", ""):gsub("%s+$", "")
                value = value:gsub("^%s+", ""):gsub("%s+$", "")

                if key == "LauncherMonitor" and value ~= "" then
                    PRESET_LAUNCHER_MONITOR = value
                end
            end
        end

        presetFile.close()
    end
end

local monitor = nil
local monitorPeripheralName = nil

if PRESET_LAUNCHER_MONITOR
   and peripheral.isPresent(PRESET_LAUNCHER_MONITOR)
   and peripheral.getType(PRESET_LAUNCHER_MONITOR) == "monitor" then

    monitor = peripheral.wrap(PRESET_LAUNCHER_MONITOR)
    monitorPeripheralName = PRESET_LAUNCHER_MONITOR
end

if not monitor then
    monitor, monitorPeripheralName = peripheral.find("monitor")
end

if not monitor then
    error("No monitor found. Connect an Advanced Monitor.")
end

-- =========================================================
-- SETTINGS
-- =========================================================

local GUI_SCALE = 0.5

-- Hide the launcher itself from the list.
local HIDE_SELF = true

-- =========================================================
-- PROGRAM EXIT BUTTON
-- =========================================================
-- The launcher automatically detects ALL connected
-- Redstone Relays and watches ALL SIX SIDES of each relay.
--
-- Put a button on any side of any connected relay.
-- Pressing it while a program is running will kill the
-- launched program and restore the launcher GUI.
--
-- Set this false if you want to use redstone directly on
-- the computer instead of a relay.
local USE_REDSTONE_RELAYS = true

-- If using the computer directly, this is the side watched.
local COMPUTER_KILL_SIDE = "back"

local REDSTONE_SIDES = {
    "top",
    "bottom",
    "left",
    "right",
    "front",
    "back"
}

-- Optional directories to ignore.
local IGNORE_DIRS = {
    ["rom"] = true
}

-- =========================================================
-- COLORS
-- =========================================================

local C = {
    bg = colors.black,
    panel = colors.gray,
    panel2 = colors.lightGray,
    border = colors.cyan,
    title = colors.cyan,
    text = colors.white,
    dim = colors.lightGray,
    selected = colors.blue,
    selectedText = colors.white,
    run = colors.green,
    runText = colors.black,
    rescan = colors.orange,
    rescanText = colors.black,
    scroll = colors.gray,
    scrollText = colors.white,
    danger = colors.red
}

-- =========================================================
-- SCALE / MONITOR
-- =========================================================

local function normalizeScale(scale)
    scale = math.floor(scale * 2 + 0.5) / 2
    if scale < 0.5 then scale = 0.5 end
    if scale > 5.0 then scale = 5.0 end
    return scale
end

GUI_SCALE = normalizeScale(GUI_SCALE)

monitor.setTextScale(GUI_SCALE)
monitor.setCursorBlink(false)

local width, height = monitor.getSize()

-- =========================================================
-- STATE
-- =========================================================

local files = {}
local selectedIndex = nil
local scrollOffset = 0
local statusMessage = "Scanning for Lua files..."
local statusColor = C.dim

-- Launcher screens:
--   programs  = normal Lua launcher
--   crashlogs = list of saved crash logs
--   crashview = opened crash log
local launcherMode = "programs"

local crashFiles = {}
local crashSelectedFile = nil
local crashLines = {}
local crashScrollOffset = 0

-- Settings / relay management
local RSGUIC_DATA_FILE = "rsguic_data.txt"
local MONITOR_NAMES_FILE = "monitornames.txt"
local LAUNCHER_SETTINGS_FILE = "lua_launcher_settings.txt"

local relayRecords = {}
local relayScrollOffset = 0
local selectedResetPeripheral = nil
local selectedRelayRecord = nil

local monitorRecords = {}
local monitorScrollOffset = 0
local selectedLauncherMonitor = monitorPeripheralName
local selectedMonitorRecord = nil

local renameRelay = nil
local renameMonitor = nil
local renameBuffer = ""
local renameOriginal = ""
local renameUppercase = true
local renameScreenMessage = nil
local renameScreenMessageColor = C.dim

-- Disk manager
local diskFiles = {}
local diskScrollOffset = 0
local diskSelectedFile = nil

local computerTransferFiles = {}
local computerTransferScrollOffset = 0
local computerSelectedFile = nil

local fileRenameTarget = nil
local fileRenameReturnMode = nil

local launcherPath = shell.getRunningProgram() or ""

-- =========================================================
-- HELPERS
-- =========================================================

local function clamp(v, minV, maxV)
    if v < minV then return minV end
    if v > maxV then return maxV end
    return v
end

local function clear(bg)
    monitor.setBackgroundColor(bg or C.bg)
    monitor.clear()
end

local function writeAt(x, y, text, fg, bg)
    if y < 1 or y > height then return end
    if x > width then return end

    monitor.setCursorPos(math.max(1, x), y)
    monitor.setTextColor(fg or C.text)
    monitor.setBackgroundColor(bg or C.bg)

    if x < 1 then
        text = text:sub(2 - x)
        x = 1
        monitor.setCursorPos(x, y)
    end

    local maxLen = width - x + 1
    if maxLen <= 0 then return end

    monitor.write(text:sub(1, maxLen))
end

local function centerText(y, text, fg, bg)
    local x = math.floor((width - #text) / 2) + 1
    writeAt(x, y, text, fg, bg)
end

local function fillRect(x1, y1, x2, y2, bg, char, fg)
    char = char or " "
    fg = fg or C.text

    x1 = clamp(x1, 1, width)
    x2 = clamp(x2, 1, width)
    y1 = clamp(y1, 1, height)
    y2 = clamp(y2, 1, height)

    if x2 < x1 or y2 < y1 then return end

    local line = string.rep(char, x2 - x1 + 1)

    for y = y1, y2 do
        writeAt(x1, y, line, fg, bg)
    end
end

local function drawBox(x1, y1, x2, y2, borderColor, bgColor)
    if x2 <= x1 or y2 <= y1 then return end

    fillRect(x1 + 1, y1 + 1, x2 - 1, y2 - 1, bgColor, " ")

    writeAt(x1, y1, "+" .. string.rep("-", math.max(0, x2 - x1 - 1)) .. "+", borderColor, C.bg)
    writeAt(x1, y2, "+" .. string.rep("-", math.max(0, x2 - x1 - 1)) .. "+", borderColor, C.bg)

    for y = y1 + 1, y2 - 1 do
        writeAt(x1, y, "|", borderColor, C.bg)
        writeAt(x2, y, "|", borderColor, C.bg)
    end
end

local function drawButton(x1, y1, x2, y2, label, bg, fg)
    fillRect(x1, y1, x2, y2, bg, " ", fg)

    local labelY = y1 + math.floor((y2 - y1) / 2)
    local labelX = x1 + math.floor(((x2 - x1 + 1) - #label) / 2)

    writeAt(labelX, labelY, label, fg, bg)
end

local function inRect(x, y, x1, y1, x2, y2)
    return x >= x1 and x <= x2 and y >= y1 and y <= y2
end

local function basename(path)
    return fs.getName(path)
end

local function pathDir(path)
    local d = fs.getDir(path)
    if d == "" then return "/" end
    return "/" .. d
end

local function isIgnoredPath(path)
    local first = path:match("^/?([^/]+)")
    return first and IGNORE_DIRS[first] == true
end

local function stripLuaExtension(name)
    if name:lower():sub(-4) == ".lua" then
        return name:sub(1, #name - 4)
    end
    return name
end

local function sanitizeCrashName(name)
    name = stripLuaExtension(name)
    name = name:gsub("[^%w_%-]", "_")

    if name == "" then
        name = "Unknown"
    end

    return name
end

local function isCrashLogName(name)
    return name:match("^Crash_.+%d+%.txt$") ~= nil
end

local function scanCrashLogs()
    crashFiles = {}

    local ok, entries = pcall(fs.list, "")
    if not ok then
        statusMessage = "Could not scan crash logs."
        statusColor = C.danger
        return
    end

    for _, name in ipairs(entries) do
        if not fs.isDir(name) and isCrashLogName(name) then
            table.insert(crashFiles, name)
        end
    end

    table.sort(crashFiles, function(a, b)
        return a:lower() < b:lower()
    end)

    if #crashFiles == 0 then
        statusMessage = "No crash logs."
        statusColor = C.dim
    else
        statusMessage = tostring(#crashFiles) .. " crash log(s)"
        statusColor = C.dim
    end
end

local function nextCrashLogName(programPath)
    local base = sanitizeCrashName(basename(programPath))
    local number = 1

    while true do
        local name = "Crash_" .. base .. tostring(number) .. ".txt"

        if not fs.exists(name) then
            return name
        end

        number = number + 1
    end
end

local function saveCrashLog(programPath, errorText, capturedOutput)
    local filename = nextCrashLogName(programPath)
    local file = fs.open(filename, "w")

    if not file then
        return nil
    end

    file.writeLine("LUA LAUNCHER CRASH LOG")
    file.writeLine("======================")
    file.writeLine("Program: " .. tostring(programPath))
    file.writeLine("File: " .. basename(programPath))
    file.writeLine("Error: " .. tostring(errorText or "Unknown error"))
    file.writeLine("")
    file.writeLine("LAST TERMINAL OUTPUT")
    file.writeLine("--------------------")

    if capturedOutput and #capturedOutput > 0 then
        for _, line in ipairs(capturedOutput) do
            file.writeLine(line)
        end
    else
        file.writeLine("(No terminal output was captured.)")
    end

    file.close()
    return filename
end

local function loadCrashFile(path)
    crashLines = {}
    crashScrollOffset = 0

    local file = fs.open(path, "r")

    if not file then
        statusMessage = "Could not open crash log."
        statusColor = C.danger
        return false
    end

    while true do
        local line = file.readLine()
        if line == nil then break end
        table.insert(crashLines, line)
    end

    file.close()

    crashSelectedFile = path
    launcherMode = "crashview"
    statusMessage = basename(path)
    statusColor = C.text
    return true
end

local function deleteCrashFile(path)
    if not path or not fs.exists(path) then
        statusMessage = "Crash log no longer exists."
        statusColor = C.danger
        return
    end

    fs.delete(path)

    crashSelectedFile = nil
    crashLines = {}
    crashScrollOffset = 0

    scanCrashLogs()
    launcherMode = "crashlogs"

    statusMessage = "Crash log deleted."
    statusColor = C.rescan
end

-- Proxy a terminal to the monitor while remembering recent text output.
-- CC:Tweaked's shell normally prints runtime errors to the active terminal
-- and returns false, so capturing writes lets the crash log preserve the
-- actual error message instead of only "Program returned false".
local function makeCaptureTerminal(base)
    local captured = {}
    local proxy = {}

    local function remember(text)
        text = tostring(text or "")

        -- Keep only the most recent output so games which redraw constantly
        -- cannot create enormous crash logs.
        table.insert(captured, text)

        while #captured > 120 do
            table.remove(captured, 1)
        end
    end

    proxy.write = function(text)
        remember(text)
        return base.write(text)
    end

    proxy.blit = function(text, fg, bg)
        remember(text)
        return base.blit(text, fg, bg)
    end

    setmetatable(proxy, {
        __index = function(_, key)
            return base[key]
        end
    })

    return proxy, captured
end


-- =========================================================
-- RELAY SETTINGS / RSGUIC DATA
-- =========================================================

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function loadLauncherSettings()
    selectedResetPeripheral = nil

    if not fs.exists(LAUNCHER_SETTINGS_FILE) then
        return
    end

    local f = fs.open(LAUNCHER_SETTINGS_FILE, "r")
    if not f then return end

    while true do
        local line = f.readLine()
        if not line then break end

        local key, value = line:match("^%s*([^=]+)%s*=%s*(.*)$")
        if key and value then
            key = trim(key)
            value = trim(value)

            if key == "ResetPeripheral" and value ~= "" then
                selectedResetPeripheral = value
            elseif key == "LauncherMonitor" and value ~= "" then
                selectedLauncherMonitor = value
            end
        end
    end

    f.close()
end

local function saveLauncherSettings()
    local f = fs.open(LAUNCHER_SETTINGS_FILE, "w")
    if not f then return false end

    f.writeLine("ResetPeripheral = " .. tostring(selectedResetPeripheral or ""))
    f.writeLine("LauncherMonitor = " .. tostring(selectedLauncherMonitor or ""))
    f.close()
    return true
end

local function parseRsguicData()
    relayRecords = {}

    if not fs.exists(RSGUIC_DATA_FILE) then
        return
    end

    local f = fs.open(RSGUIC_DATA_FILE, "r")
    if not f then return end

    local record = nil

    while true do
        local line = f.readLine()
        if not line then break end

        if line == "---" then
            if record and record.peripheral then
                table.insert(relayRecords, record)
            end
            record = nil
        else
            local key, value = line:match("^%s*([^=]+)%s*=%s*(.*)$")

            if key and value then
                key = trim(key)
                value = trim(value)

                if not record then
                    record = {}
                end

                if key == "Peripheral" then
                    record.peripheral = value
                elseif key == "ID" then
                    record.id = tonumber(value) or 0
                elseif key == "Name" then
                    record.name = value
                end
            end
        end
    end

    if record and record.peripheral then
        table.insert(relayRecords, record)
    end

    f.close()

    table.sort(relayRecords, function(a, b)
        return (a.id or 0) < (b.id or 0)
    end)
end

local function getSavedRelayByPeripheral(peripheralName)
    for _, relay in ipairs(relayRecords) do
        if relay.peripheral == peripheralName then
            return relay
        end
    end

    return nil
end

local function getRelayDisplayName(peripheralName)
    local saved = getSavedRelayByPeripheral(peripheralName)

    if saved and saved.name and saved.name ~= "" then
        return saved.name
    end

    return peripheralName
end

local function appendMissingRelayRecord(peripheralName)
    parseRsguicData()

    -- If the relay is already stored, do nothing.
    for _, relay in ipairs(relayRecords) do
        if relay.peripheral == peripheralName then
            return true
        end
    end

    local relayId =
        tonumber(tostring(peripheralName):match("^redstone_relay_(%-?%d+)$"))

    if relayId == nil then
        relayId = 0

        for _, relay in ipairs(relayRecords) do
            relayId = math.max(relayId, (tonumber(relay.id) or 0) + 1)
        end
    end

    local defaultName = "Relay " .. tostring(relayId)

    local file

    if fs.exists(RSGUIC_DATA_FILE) then
        file = fs.open(RSGUIC_DATA_FILE, "a")
    else
        file = fs.open(RSGUIC_DATA_FILE, "w")
    end

    if not file then
        return false
    end

    -- Keep compatibility with the other rsguic script.
    -- Launcher only uses Peripheral / ID / Name, but the
    -- remaining fields are included so the other script
    -- can safely load the same file.
    file.writeLine("Peripheral = " .. peripheralName)
    file.writeLine("ID = " .. tostring(relayId))
    file.writeLine("Name = " .. defaultName)
    file.writeLine("Type = pulse")
    file.writeLine("State = Off")
    file.writeLine("Channel = 0")
    file.writeLine("Hidden = No")
    file.writeLine("---")

    file.close()

    parseRsguicData()
    return true
end

local function syncConnectedRelaysToDataFile()
    local changed = false

    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheral.getType(peripheralName) == "redstone_relay" then
            local found = false

            for _, relay in ipairs(relayRecords) do
                if relay.peripheral == peripheralName then
                    found = true
                    break
                end
            end

            if not found then
                if appendMissingRelayRecord(peripheralName) then
                    changed = true
                end
            end
        end
    end

    if changed then
        parseRsguicData()
    end
end

local function getConnectedRelays()
    parseRsguicData()

    -- Automatically add any newly connected relays which are
    -- missing from rsguic_data.txt.
    syncConnectedRelaysToDataFile()

    local result = {}

    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheral.getType(peripheralName) == "redstone_relay" then
            local saved = getSavedRelayByPeripheral(peripheralName)

            table.insert(result, {
                peripheral = peripheralName,
                id = saved
                    and saved.id
                    or tonumber(peripheralName:match("(%-?%d+)$"))
                    or 0,
                name = saved
                    and saved.name
                    or ("Relay " .. tostring(
                        tonumber(peripheralName:match("(%-?%d+)$")) or 0
                    ))
            })
        end
    end

    table.sort(result, function(a, b)
        if a.id == b.id then
            return a.peripheral < b.peripheral
        end

        return a.id < b.id
    end)

    return result
end

local function rewriteRelayName(peripheralName, relayId, newName)
    if not fs.exists(RSGUIC_DATA_FILE) then
        return false, "rsguic_data.txt not found"
    end

    newName = trim(newName)

    if newName == "" then
        return false, "Name cannot be blank"
    end

    local f = fs.open(RSGUIC_DATA_FILE, "r")

    if not f then
        return false, "Could not read rsguic_data.txt"
    end

    local lines = {}

    while true do
        local line = f.readLine()
        if line == nil then break end
        table.insert(lines, line)
    end

    f.close()

    local recordStart = 1
    local changed = false

    local function tryRecord(firstLine, lastLine)
        local recordPeripheral = nil
        local recordId = nil
        local nameLine = nil

        for i = firstLine, lastLine do
            local key, value = lines[i]:match("^%s*([^=]+)%s*=%s*(.*)$")

            if key and value then
                key = trim(key)
                value = trim(value)

                if key == "Peripheral" then
                    recordPeripheral = value
                elseif key == "ID" then
                    recordId = tonumber(value)
                elseif key == "Name" then
                    nameLine = i
                end
            end
        end

        local peripheralMatches =
            peripheralName ~= nil
            and recordPeripheral == peripheralName

        local idMatches =
            relayId ~= nil
            and recordId ~= nil
            and tonumber(recordId) == tonumber(relayId)

        if nameLine and (peripheralMatches or idMatches) then
            lines[nameLine] = "Name = " .. newName
            return true
        end

        return false
    end

    for i = 1, #lines do
        if lines[i] == "---" then
            if tryRecord(recordStart, i - 1) then
                changed = true
                break
            end

            recordStart = i + 1
        end
    end

    -- Handle a final record without a trailing ---.
    if not changed and recordStart <= #lines then
        changed = tryRecord(recordStart, #lines)
    end

    if not changed then
        return false,
            "Could not match relay Peripheral="
            .. tostring(peripheralName)
            .. " ID="
            .. tostring(relayId)
    end

    local outFile = fs.open(RSGUIC_DATA_FILE, "w")

    if not outFile then
        return false, "Could not write rsguic_data.txt"
    end

    for _, line in ipairs(lines) do
        outFile.writeLine(line)
    end

    outFile.close()
    parseRsguicData()

    return true
end


-- =========================================================
-- MONITOR NAMES / SELECTION
-- =========================================================

local function monitorNumericId(peripheralName)
    local n = tostring(peripheralName or ""):match("^monitor_(%-?%d+)$")
    return tonumber(n)
end

local function loadMonitorNames()
    monitorRecords = {}

    if not fs.exists(MONITOR_NAMES_FILE) then
        return
    end

    local f = fs.open(MONITOR_NAMES_FILE, "r")
    if not f then return end

    local record = nil

    while true do
        local line = f.readLine()
        if not line then break end

        if line == "---" then
            if record and record.peripheral then
                table.insert(monitorRecords, record)
            end
            record = nil
        else
            local key, value = line:match("^%s*([^=]+)%s*=%s*(.*)$")

            if key and value then
                key = trim(key)
                value = trim(value)

                if not record then
                    record = {}
                end

                if key == "Peripheral" then
                    record.peripheral = value
                elseif key == "ID" then
                    record.id = tonumber(value) or 0
                elseif key == "Name" then
                    record.name = value
                end
            end
        end
    end

    if record and record.peripheral then
        table.insert(monitorRecords, record)
    end

    f.close()

    table.sort(monitorRecords, function(a, b)
        return (a.id or 0) < (b.id or 0)
    end)
end

local function saveMonitorNames()
    table.sort(monitorRecords, function(a, b)
        return (a.id or 0) < (b.id or 0)
    end)

    local f = fs.open(MONITOR_NAMES_FILE, "w")
    if not f then return false end

    for _, record in ipairs(monitorRecords) do
        f.writeLine("Peripheral = " .. tostring(record.peripheral))
        f.writeLine("ID = " .. tostring(record.id or 0))
        f.writeLine("Name = " .. tostring(record.name or record.peripheral))
        f.writeLine("---")
    end

    f.close()
    return true
end

local function getSavedMonitor(peripheralName)
    for _, record in ipairs(monitorRecords) do
        if record.peripheral == peripheralName then
            return record
        end
    end

    return nil
end

local function refreshMonitorRecords()
    loadMonitorNames()

    local changed = false

    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheral.getType(peripheralName) == "monitor" then
            local saved = getSavedMonitor(peripheralName)

            if not saved then
                local id = monitorNumericId(peripheralName)

                if id == nil then
                    id = 0
                    for _, record in ipairs(monitorRecords) do
                        id = math.max(id, (record.id or 0) + 1)
                    end
                end

                table.insert(monitorRecords, {
                    peripheral = peripheralName,
                    id = id,
                    name = "Monitor " .. tostring(id)
                })

                changed = true
            end
        end
    end

    if changed then
        saveMonitorNames()
    end

    table.sort(monitorRecords, function(a, b)
        return (a.id or 0) < (b.id or 0)
    end)
end

local function getConnectedMonitors()
    refreshMonitorRecords()

    local result = {}

    for _, record in ipairs(monitorRecords) do
        if peripheral.isPresent(record.peripheral)
           and peripheral.getType(record.peripheral) == "monitor" then

            table.insert(result, {
                peripheral = record.peripheral,
                id = record.id or 0,
                name = record.name or record.peripheral
            })
        end
    end

    return result
end

local function renameMonitorRecord(peripheralName, newName)
    newName = trim(newName)

    if newName == "" then
        return false, "Name cannot be blank"
    end

    refreshMonitorRecords()

    local record = getSavedMonitor(peripheralName)

    if not record then
        return false, "Monitor record not found"
    end

    record.name = newName

    if not saveMonitorNames() then
        return false, "Could not write monitornames.txt"
    end

    refreshMonitorRecords()
    return true
end

local function switchLauncherMonitor(peripheralName)
    if not peripheralName
       or not peripheral.isPresent(peripheralName)
       or peripheral.getType(peripheralName) ~= "monitor" then

        return false, "Monitor is not connected"
    end

    local newMonitor = peripheral.wrap(peripheralName)

    if not newMonitor then
        return false, "Could not open monitor"
    end

    -- Clear the old launcher screen so it is obvious the GUI moved.
    pcall(function()
        monitor.setBackgroundColor(C.bg)
        monitor.clear()
    end)

    monitor = newMonitor
    monitorPeripheralName = peripheralName
    selectedLauncherMonitor = peripheralName

    monitor.setTextScale(GUI_SCALE)
    monitor.setCursorBlink(false)

    width, height = monitor.getSize()

    saveLauncherSettings()

    return true
end

-- =========================================================
-- FILE SCANNING
-- =========================================================

local function scanDirectory(path, output)
    if isIgnoredPath(path) then
        return
    end

    local ok, entries = pcall(fs.list, path)
    if not ok then
        return
    end

    table.sort(entries, function(a, b)
        return a:lower() < b:lower()
    end)

    for _, name in ipairs(entries) do
        local fullPath

        if path == "" or path == "/" then
            fullPath = name
        else
            fullPath = fs.combine(path, name)
        end

        if fs.isDir(fullPath) then
            scanDirectory(fullPath, output)
        else
            if name:lower():sub(-4) == ".lua" then
                local shouldAdd = true

                if HIDE_SELF and launcherPath ~= "" then
                    local a = fs.combine("", fullPath)
                    local b = fs.combine("", launcherPath)

                    if a == b then
                        shouldAdd = false
                    end
                end

                if shouldAdd then
                    table.insert(output, fullPath)
                end
            end
        end
    end
end

local function rescan()
    statusMessage = "Scanning..."
    statusColor = C.dim

    files = {}
    scanDirectory("", files)

    table.sort(files, function(a, b)
        return a:lower() < b:lower()
    end)

    selectedIndex = nil
    scrollOffset = 0

    if #files == 0 then
        statusMessage = "No Lua files found."
        statusColor = C.danger
    else
        statusMessage = tostring(#files) .. " Lua file(s) found"
        statusColor = C.dim
    end
end

-- =========================================================
-- LAYOUT
-- =========================================================

local function layout()
    width, height = monitor.getSize()

    local topY = 1
    local titleY = 2

    local panelX1 = 2
    local panelX2 = math.max(panelX1 + 10, width - 1)

    local listY1 = 5
    local controlsHeight = 6
    local listY2 = math.max(listY1 + 2, height - controlsHeight)

    local footerY1 = listY2 + 1
    local footerY2 = height

    local scrollButtonWidth = math.min(5, math.max(3, math.floor(width / 8)))

    local buttonY1 = math.max(listY2 + 2, height - 3)
    local buttonY2 = math.min(height - 1, buttonY1 + 1)

    -- Four compact bottom buttons:
    -- RESCAN | CRASH LOGS | SETTINGS | RUN
    local buttonGap = 1
    local controlsX1 = 2
    local controlsX2 = math.max(controlsX1, width - 2)
    local available = math.max(24, controlsX2 - controlsX1 + 1 - buttonGap * 3)
    local buttonWidth = math.max(6, math.floor(available / 4))

    local rescanX1 = controlsX1
    local rescanX2 = math.min(controlsX2, rescanX1 + buttonWidth - 1)

    local crashX1 = math.min(controlsX2, rescanX2 + buttonGap + 1)
    local crashX2 = math.min(controlsX2, crashX1 + buttonWidth - 1)

    local settingsX1 = math.min(controlsX2, crashX2 + buttonGap + 1)
    local settingsX2 = math.min(controlsX2, settingsX1 + buttonWidth - 1)

    local runX2 = controlsX2
    local runX1 = math.max(controlsX1, runX2 - buttonWidth + 1)

    -- Manage Disk gets its own row above the four launcher controls.
    -- Manage Disk sits directly underneath RESCAN.
    -- Use the already-calculated control coordinates rather than
    -- the return-table names, which do not exist as locals yet.
    local diskWidth = math.max(1, rescanX2 - rescanX1 + 1)
    local diskX1 = rescanX1
    local diskX2 = rescanX2
    local diskY1 = math.min(height, buttonY2 + 1)
    local diskY2 = diskY1

    return {
        topY = topY,
        titleY = titleY,

        panelX1 = panelX1,
        panelX2 = panelX2,

        listX1 = panelX1 + 1,
        listX2 = panelX2 - 1,
        listY1 = listY1,
        listY2 = listY2,

        footerY1 = footerY1,
        footerY2 = footerY2,

        upX1 = panelX2 - scrollButtonWidth,
        upX2 = panelX2 - 1,
        upY1 = listY1,
        upY2 = listY1,

        downX1 = panelX2 - scrollButtonWidth,
        downX2 = panelX2 - 1,
        downY1 = listY2,
        downY2 = listY2,

        runX1 = runX1,
        runX2 = runX2,
        runY1 = buttonY1,
        runY2 = buttonY2,

        crashX1 = crashX1,
        crashX2 = crashX2,
        crashY1 = buttonY1,
        crashY2 = buttonY2,

        settingsX1 = settingsX1,
        settingsX2 = settingsX2,
        settingsY1 = buttonY1,
        settingsY2 = buttonY2,

        diskX1 = diskX1,
        diskX2 = diskX2,
        diskY1 = diskY1,
        diskY2 = diskY2,

        rescanX1 = rescanX1,
        rescanX2 = rescanX2,
        rescanY1 = buttonY1,
        rescanY2 = buttonY2
    }
end

-- =========================================================
-- DRAWING
-- =========================================================

local function getVisibleCount(L)
    return math.max(1, L.listY2 - L.listY1 + 1)
end

local function keepSelectionVisible()
    if not selectedIndex then return end

    local L = layout()
    local visible = getVisibleCount(L)

    if selectedIndex <= scrollOffset then
        scrollOffset = selectedIndex - 1
    elseif selectedIndex > scrollOffset + visible then
        scrollOffset = selectedIndex - visible
    end

    local maxOffset = math.max(0, #files - visible)
    scrollOffset = clamp(scrollOffset, 0, maxOffset)
end

local function drawHeader()
    monitor.setBackgroundColor(C.bg)

    centerText(1, "==============================", C.border, C.bg)
    centerText(2, "L U A   L A U N C H E R", C.title, C.bg)
    if width >= 34 then
        centerText(3, "Select program - Redstone button exits", C.dim, C.bg)
    else
        centerText(3, "Select a program to run", C.dim, C.bg)
    end
end

local function drawFileList(L)
    drawBox(
        L.panelX1,
        L.listY1 - 1,
        L.panelX2,
        L.listY2 + 1,
        C.border,
        C.bg
    )

    local visible = getVisibleCount(L)

    for row = 0, visible - 1 do
        local index = scrollOffset + row + 1
        local y = L.listY1 + row

        fillRect(L.listX1, y, L.listX2, y, C.bg, " ")

        if files[index] then
            local selected = (index == selectedIndex)

            local bg = selected and C.selected or C.bg
            local fg = selected and C.selectedText or C.text

            fillRect(L.listX1, y, L.listX2, y, bg, " ")

            local marker = selected and ">" or " "
            local number = tostring(index) .. "."
            local name = basename(files[index])

            local prefix = marker .. " " .. number .. " "
            local available = math.max(0, L.listX2 - L.listX1 + 1 - #prefix)

            writeAt(
                L.listX1,
                y,
                prefix .. name:sub(1, available),
                fg,
                bg
            )
        end
    end

    -- Scroll indicators
    if scrollOffset > 0 then
        drawButton(
            L.upX1, L.upY1,
            L.upX2, L.upY2,
            " UP ",
            C.scroll,
            C.scrollText
        )
    end

    local visibleBottom = scrollOffset + visible

    if visibleBottom < #files then
        drawButton(
            L.downX1, L.downY1,
            L.downX2, L.downY2,
            "DOWN",
            C.scroll,
            C.scrollText
        )
    end
end

local function drawSelectedInfo(L)
    -- Keep selected-file text completely separate from the
    -- RESCAN/RUN buttons so the first letters cannot be painted over.
    local infoY = L.listY2 + 1

    -- Only use the horizontal space between the left/right margins.
    local maxLen = math.max(0, width - 4)

    fillRect(2, infoY, width - 1, infoY, C.bg, " ")

    if selectedIndex and files[selectedIndex] then
        local file = files[selectedIndex]
        local nameLine = "Selected: " .. basename(file)

        if #nameLine > maxLen then
            nameLine = nameLine:sub(1, math.max(0, maxLen - 3)) .. "..."
        end

        writeAt(2, infoY, nameLine, C.text, C.bg)
    else
        writeAt(2, infoY, "Select a Lua file.", C.dim, C.bg)
    end
end

local function drawControls(L)
    if L.rescanX2 >= L.rescanX1 then
        drawButton(
            L.rescanX1, L.rescanY1,
            L.rescanX2, L.rescanY2,
            "RESCAN",
            C.rescan,
            C.rescanText
        )
    end

    drawButton(
        L.crashX1, L.crashY1,
        L.crashX2, L.crashY2,
        "CRASH LOGS",
        C.panel2,
        colors.black
    )

    drawButton(
        L.settingsX1, L.settingsY1,
        L.settingsX2, L.settingsY2,
        "SETTINGS",
        colors.blue,
        colors.white
    )

    drawButton(
        L.diskX1, L.diskY1,
        L.diskX2, L.diskY2,
        "MANAGE DISK",
        colors.purple,
        colors.white
    )

    local runBg = selectedIndex and C.run or C.panel
    local runFg = selectedIndex and C.runText or C.dim

    drawButton(
        L.runX1, L.runY1,
        L.runX2, L.runY2,
        "RUN",
        runBg,
        runFg
    )
end

local function drawStatus()
    local statusY = height

    fillRect(1, statusY, width, statusY, C.bg, " ")

    local text = statusMessage
    if #text > width then
        text = text:sub(1, width)
    end

    centerText(statusY, text, statusColor, C.bg)
end

local function drawCrashHeader(title, subtitle)
    monitor.setBackgroundColor(C.bg)

    centerText(1, "==============================", C.border, C.bg)
    centerText(2, title, C.title, C.bg)
    centerText(3, subtitle, C.dim, C.bg)
end

local function drawCrashList()
    local L = layout()

    drawCrashHeader(
        "C R A S H   L O G S",
        "Touch a log to open it"
    )

    drawBox(
        L.panelX1,
        L.listY1 - 1,
        L.panelX2,
        L.listY2 + 1,
        C.border,
        C.bg
    )

    local visible = getVisibleCount(L)
    local maxOffset = math.max(0, #crashFiles - visible)
    crashScrollOffset = clamp(crashScrollOffset, 0, maxOffset)

    for row = 0, visible - 1 do
        local index = crashScrollOffset + row + 1
        local y = L.listY1 + row

        fillRect(L.listX1, y, L.listX2, y, C.bg, " ")

        if crashFiles[index] then
            local prefix = tostring(index) .. ". "
            local name = basename(crashFiles[index])
            local available = math.max(0, L.listX2 - L.listX1 + 1 - #prefix)

            writeAt(
                L.listX1,
                y,
                prefix .. name:sub(1, available),
                C.text,
                C.bg
            )
        end
    end

    if crashScrollOffset > 0 then
        drawButton(
            L.upX1, L.upY1,
            L.upX2, L.upY2,
            " UP ",
            C.scroll,
            C.scrollText
        )
    end

    if crashScrollOffset + visible < #crashFiles then
        drawButton(
            L.downX1, L.downY1,
            L.downX2, L.downY2,
            "DOWN",
            C.scroll,
            C.scrollText
        )
    end

    local infoY = L.listY2 + 1
    fillRect(2, infoY, width - 1, infoY, C.bg, " ")
    writeAt(2, infoY, "Logs: " .. tostring(#crashFiles), C.dim, C.bg)

    drawButton(
        L.rescanX1, L.rescanY1,
        L.rescanX2, L.rescanY2,
        "BACK",
        C.panel,
        C.text
    )

    drawButton(
        L.crashX1, L.crashY1,
        L.crashX2, L.crashY2,
        "RESCAN",
        C.rescan,
        C.rescanText
    )

    drawStatus()
end

local function drawCrashViewer()
    local L = layout()

    drawCrashHeader(
        "C R A S H   V I E W E R",
        crashSelectedFile and basename(crashSelectedFile) or "Crash log"
    )

    drawBox(
        L.panelX1,
        L.listY1 - 1,
        L.panelX2,
        L.listY2 + 1,
        C.border,
        C.bg
    )

    local visible = getVisibleCount(L)
    local maxOffset = math.max(0, #crashLines - visible)
    crashScrollOffset = clamp(crashScrollOffset, 0, maxOffset)

    for row = 0, visible - 1 do
        local index = crashScrollOffset + row + 1
        local y = L.listY1 + row

        fillRect(L.listX1, y, L.listX2, y, C.bg, " ")

        if crashLines[index] ~= nil then
            writeAt(
                L.listX1,
                y,
                crashLines[index],
                C.text,
                C.bg
            )
        end
    end

    if crashScrollOffset > 0 then
        drawButton(
            L.upX1, L.upY1,
            L.upX2, L.upY2,
            " UP ",
            C.scroll,
            C.scrollText
        )
    end

    if crashScrollOffset + visible < #crashLines then
        drawButton(
            L.downX1, L.downY1,
            L.downX2, L.downY2,
            "DOWN",
            C.scroll,
            C.scrollText
        )
    end

    local infoY = L.listY2 + 1
    fillRect(2, infoY, width - 1, infoY, C.bg, " ")
    writeAt(
        2,
        infoY,
        "Line " .. tostring(math.min(#crashLines, crashScrollOffset + 1)) ..
        "/" .. tostring(#crashLines),
        C.dim,
        C.bg
    )

    drawButton(
        L.rescanX1, L.rescanY1,
        L.rescanX2, L.rescanY2,
        "BACK",
        C.panel,
        C.text
    )

    drawButton(
        L.runX1, L.runY1,
        L.runX2, L.runY2,
        "DELETE",
        C.danger,
        colors.white
    )

    drawStatus()
end


local function simpleListVisibleCount()
    local L = layout()
    return getVisibleCount(L)
end

local function drawSettingsMenu()
    drawCrashHeader(
        "S E T T I N G S",
        "Relay and monitor settings"
    )

    local buttonW = math.min(22, math.max(12, width - 8))
    local x1 = math.floor((width - buttonW) / 2) + 1
    local x2 = x1 + buttonW - 1
    local firstY = math.max(6, math.floor(height / 3))

    drawButton(
        x1, firstY,
        x2, firstY + 2,
        "RELAYS",
        colors.blue,
        colors.white
    )

    drawButton(
        x1, firstY + 4,
        x2, firstY + 6,
        "MONITORS",
        colors.cyan,
        colors.black
    )

    local resetText = selectedResetPeripheral
        and ("Reset Relay: " .. getRelayDisplayName(selectedResetPeripheral))
        or "Reset Relay: ALL (legacy)"

    local monitorName = selectedLauncherMonitor or monitorPeripheralName or "Unknown"
    local savedMonitor = getSavedMonitor(monitorName)

    if savedMonitor and savedMonitor.name then
        monitorName = savedMonitor.name
    end

    centerText(
        math.min(height - 5, firstY + 8),
        resetText:sub(1, math.max(1, width - 2)),
        C.dim,
        C.bg
    )

    centerText(
        math.min(height - 4, firstY + 9),
        ("Launcher Monitor: " .. monitorName):sub(1, math.max(1, width - 2)),
        C.dim,
        C.bg
    )

    local L = layout()

    drawButton(
        L.rescanX1, L.rescanY1,
        L.rescanX2, L.rescanY2,
        "BACK",
        C.panel,
        C.text
    )

    drawStatus()
end

local function settingsMenuButtons()
    local buttonW = math.min(22, math.max(12, width - 8))
    local x1 = math.floor((width - buttonW) / 2) + 1
    local x2 = x1 + buttonW - 1
    local firstY = math.max(6, math.floor(height / 3))

    return
        {x1=x1,y1=firstY,x2=x2,y2=firstY+2},
        {x1=x1,y1=firstY+4,x2=x2,y2=firstY+6}
end

drawRelayList = function()
    local L = layout()
    local relays = getConnectedRelays()
    local visible = getVisibleCount(L)
    local maxOffset = math.max(0, #relays - visible)
    relayScrollOffset = clamp(relayScrollOffset, 0, maxOffset)

    drawCrashHeader(
        "R E L A Y S",
        "Select a relay"
    )

    drawBox(
        L.panelX1,
        L.listY1 - 1,
        L.panelX2,
        L.listY2 + 1,
        C.border,
        C.bg
    )

    for row = 0, visible - 1 do
        local index = relayScrollOffset + row + 1
        local y = L.listY1 + row
        local relay = relays[index]

        fillRect(L.listX1, y, L.listX2, y, C.bg, " ")

        if relay then
            local active = selectedResetPeripheral == relay.peripheral
            local markerText = active and "> " or "  "
            local idText = "[" .. tostring(relay.id) .. "] "

            local available = math.max(
                0,
                L.listX2 - L.listX1 + 1 - #markerText - #idText
            )

            local bg = active and C.selected or C.bg
            local fg = active and C.selectedText or C.text

            fillRect(L.listX1, y, L.listX2, y, bg, " ")

            writeAt(
                L.listX1,
                y,
                markerText .. idText .. tostring(relay.name):sub(1, available),
                fg,
                bg
            )
        end
    end

    if relayScrollOffset > 0 then
        drawButton(
            L.upX1, L.upY1,
            L.upX2, L.upY2,
            " UP ",
            C.scroll,
            C.scrollText
        )
    end

    if relayScrollOffset + visible < #relays then
        drawButton(
            L.downX1, L.downY1,
            L.downX2, L.downY2,
            "DOWN",
            C.scroll,
            C.scrollText
        )
    end

    local infoY = L.listY2 + 1
    fillRect(2, infoY, width - 1, infoY, C.bg, " ")

    if #relays == 0 then
        writeAt(2, infoY, "No connected redstone relays.", C.danger, C.bg)
    else
        writeAt(2, infoY, "Touch a relay for options.", C.dim, C.bg)
    end

    drawButton(
        L.rescanX1, L.rescanY1,
        L.rescanX2, L.rescanY2,
        "BACK",
        C.panel,
        C.text
    )

    drawStatus()
end

local function relayDetailButtons()
    local bw = math.min(12, math.max(8, math.floor((width - 8) / 3)))
    local gap = 1
    local total = bw * 3 + gap * 2
    local sx = math.floor((width - total) / 2) + 1
    local y1 = math.max(8, math.floor(height / 2) + 2)

    return
        {x1=sx,y1=y1,x2=sx+bw-1,y2=y1+2},
        {x1=sx+bw+gap,y1=y1,x2=sx+bw+gap+bw-1,y2=y1+2},
        {x1=sx+(bw+gap)*2,y1=y1,x2=sx+(bw+gap)*2+bw-1,y2=y1+2}
end

drawRelayDetail = function()
    drawCrashHeader(
        "R E L A Y",
        selectedRelayRecord and selectedRelayRecord.peripheral or ""
    )

    if not selectedRelayRecord then
        centerText(
            math.floor(height / 2),
            "Relay not found.",
            C.danger,
            C.bg
        )
        return
    end

    centerText(
        math.max(6, math.floor(height / 3)),
        selectedRelayRecord.name,
        C.title,
        C.bg
    )

    centerText(
        math.max(7, math.floor(height / 3) + 2),
        "ID: " .. tostring(selectedRelayRecord.id),
        C.dim,
        C.bg
    )

    local active = selectedResetPeripheral == selectedRelayRecord.peripheral

    centerText(
        math.max(8, math.floor(height / 3) + 3),
        active and "CURRENT RESET RELAY" or "AVAILABLE RELAY",
        active and C.run or C.dim,
        C.bg
    )

    local useB, renameB, backB = relayDetailButtons()

    drawButton(
        useB.x1,useB.y1,useB.x2,useB.y2,
        active and "USING" or "USE RESET",
        active and C.panel or C.run,
        active and C.dim or C.runText
    )

    drawButton(
        renameB.x1,renameB.y1,renameB.x2,renameB.y2,
        "RENAME",
        colors.cyan,
        colors.black
    )

    drawButton(
        backB.x1,backB.y1,backB.x2,backB.y2,
        "BACK",
        C.panel,
        C.text
    )

    drawStatus()
end

local RENAME_ROWS = {
    {"Q","W","E","R","T","Y","U","I","O","P"},
    {"A","S","D","F","G","H","J","K","L"},
    {"Z","X","C","V","B","N","M"}
}

local function renameKeyboardLayout()
    local keys = {}

    local keyW = width >= 46 and 4 or 3
    local keyH = 2
    local gap = 1

    -- Reserve the bottom two rows for CANCEL / CONFIRM.
    local footerY1 = math.max(1, height - 2)
    local footerY2 = height

    -- CAPS / SPACE / BACK live immediately above the footer.
    local actionY2 = math.max(2, footerY1 - 1)
    local actionY1 = math.max(1, actionY2 - 1)

    -- Letter keyboard must finish above the action buttons.
    local keyboardBottom = actionY1 - 1

    -- Three letter rows, each two rows tall with one-row spacing.
    -- Start as high as possible, but keep the name box clear.
    local startY = math.max(8, keyboardBottom - 8)

    for rowIndex, row in ipairs(RENAME_ROWS) do
        local rowWidth = (#row * keyW) + ((#row - 1) * gap)
        local sx = math.max(1, math.floor((width - rowWidth) / 2) + 1)
        local y1 = startY + (rowIndex - 1) * 3
        local y2 = math.min(keyboardBottom, y1 + keyH - 1)

        if y1 <= keyboardBottom then
            for i, label in ipairs(row) do
                local x1 = sx + (i - 1) * (keyW + gap)

                table.insert(keys, {
                    label = label,
                    kind = "char",
                    x1 = x1,
                    y1 = y1,
                    x2 = x1 + keyW - 1,
                    y2 = y2
                })
            end
        end
    end

    local actions = {
        {label="CAPS",kind="caps",w=7},
        {label="SPACE",kind="space",w=9},
        {label="BACK",kind="back",w=7}
    }

    local total = actions[1].w + actions[2].w + actions[3].w + 2
    local sx = math.floor((width - total) / 2) + 1
    local x = sx

    for _, a in ipairs(actions) do
        a.x1 = x
        a.y1 = actionY1
        a.x2 = x + a.w - 1
        a.y2 = actionY2

        table.insert(keys, a)

        x = a.x2 + 2
    end

    local cancelW = math.min(12, math.max(8, math.floor((width - 4) / 2)))
    local gap2 = 2
    local totalFooter = cancelW * 2 + gap2
    local footerX = math.max(1, math.floor((width - totalFooter) / 2) + 1)

    local cancel = {
        x1 = footerX,
        y1 = footerY1,
        x2 = footerX + cancelW - 1,
        y2 = footerY2
    }

    local confirm = {
        x1 = cancel.x2 + gap2 + 1,
        y1 = footerY1,
        x2 = math.min(width, cancel.x2 + gap2 + cancelW),
        y2 = footerY2
    }

    return keys, cancel, confirm
end


local function drawMonitorList()
    local L = layout()
    local monitors = getConnectedMonitors()
    local visible = getVisibleCount(L)
    local maxOffset = math.max(0, #monitors - visible)
    monitorScrollOffset = clamp(monitorScrollOffset, 0, maxOffset)

    drawCrashHeader(
        "M O N I T O R S",
        "Select a monitor"
    )

    drawBox(
        L.panelX1,
        L.listY1 - 1,
        L.panelX2,
        L.listY2 + 1,
        C.border,
        C.bg
    )

    for row = 0, visible - 1 do
        local index = monitorScrollOffset + row + 1
        local y = L.listY1 + row
        local entry = monitors[index]

        fillRect(L.listX1, y, L.listX2, y, C.bg, " ")

        if entry then
            local active = entry.peripheral == monitorPeripheralName
            local markerText = active and "> " or "  "
            local idText = "[" .. tostring(entry.id) .. "] "

            local available = math.max(
                0,
                L.listX2 - L.listX1 + 1 - #markerText - #idText
            )

            local bg = active and C.selected or C.bg
            local fg = active and C.selectedText or C.text

            fillRect(L.listX1, y, L.listX2, y, bg, " ")

            writeAt(
                L.listX1,
                y,
                markerText .. idText .. tostring(entry.name):sub(1, available),
                fg,
                bg
            )
        end
    end

    if monitorScrollOffset > 0 then
        drawButton(
            L.upX1, L.upY1,
            L.upX2, L.upY2,
            " UP ",
            C.scroll,
            C.scrollText
        )
    end

    if monitorScrollOffset + visible < #monitors then
        drawButton(
            L.downX1, L.downY1,
            L.downX2, L.downY2,
            "DOWN",
            C.scroll,
            C.scrollText
        )
    end

    local infoY = L.listY2 + 1
    fillRect(2, infoY, width - 1, infoY, C.bg, " ")

    if #monitors == 0 then
        writeAt(2, infoY, "No connected monitors.", C.danger, C.bg)
    else
        writeAt(2, infoY, "Touch a monitor for options.", C.dim, C.bg)
    end

    drawButton(
        L.rescanX1, L.rescanY1,
        L.rescanX2, L.rescanY2,
        "BACK",
        C.panel,
        C.text
    )

    drawStatus()
end

local function monitorDetailButtons()
    local bw = math.min(12, math.max(8, math.floor((width - 8) / 3)))
    local gap = 1
    local total = bw * 3 + gap * 2
    local sx = math.floor((width - total) / 2) + 1
    local y1 = math.max(8, math.floor(height / 2) + 2)

    return
        {x1=sx,y1=y1,x2=sx+bw-1,y2=y1+2},
        {x1=sx+bw+gap,y1=y1,x2=sx+bw+gap+bw-1,y2=y1+2},
        {x1=sx+(bw+gap)*2,y1=y1,x2=sx+(bw+gap)*2+bw-1,y2=y1+2}
end

local function drawMonitorDetail()
    drawCrashHeader(
        "M O N I T O R",
        selectedMonitorRecord and selectedMonitorRecord.peripheral or ""
    )

    if not selectedMonitorRecord then
        centerText(
            math.floor(height / 2),
            "Monitor not found.",
            C.danger,
            C.bg
        )
        return
    end

    centerText(
        math.max(6, math.floor(height / 3)),
        selectedMonitorRecord.name,
        C.title,
        C.bg
    )

    centerText(
        math.max(7, math.floor(height / 3) + 2),
        "ID: " .. tostring(selectedMonitorRecord.id),
        C.dim,
        C.bg
    )

    local active = selectedMonitorRecord.peripheral == monitorPeripheralName

    centerText(
        math.max(8, math.floor(height / 3) + 3),
        active and "CURRENT LAUNCHER MONITOR" or "AVAILABLE MONITOR",
        active and C.run or C.dim,
        C.bg
    )

    local useB, renameB, backB = monitorDetailButtons()

    drawButton(
        useB.x1,useB.y1,useB.x2,useB.y2,
        active and "USING" or "USE",
        active and C.panel or C.run,
        active and C.dim or C.runText
    )

    drawButton(
        renameB.x1,renameB.y1,renameB.x2,renameB.y2,
        "RENAME",
        colors.cyan,
        colors.black
    )

    drawButton(
        backB.x1,backB.y1,backB.x2,backB.y2,
        "BACK",
        C.panel,
        C.text
    )

    drawStatus()
end

drawRenameRelay = function()
    local isMonitorRename = launcherMode == "monitorrename"
    local target = isMonitorRename and renameMonitor or renameRelay

    drawCrashHeader(
        isMonitorRename and "R E N A M E   M O N I T O R" or "R E N A M E   R E L A Y",
        target and (target.peripheral .. "  ID " .. tostring(target.id)) or ""
    )

    local boxX1 = 3
    local boxX2 = math.max(boxX1 + 10, width - 2)
    local boxY = 5

    fillRect(boxX1, boxY, boxX2, boxY + 1, colors.white)

    local shown = renameBuffer
    local room = math.max(1, boxX2 - boxX1 - 1)

    if #shown > room then
        shown = shown:sub(#shown - room + 1)
    end

    writeAt(boxX1 + 1, boxY, shown, colors.black, colors.white)

    if renameScreenMessage then
        centerText(
            math.min(height, boxY + 2),
            renameScreenMessage:sub(1, math.max(1, width - 2)),
            renameScreenMessageColor,
            C.bg
        )
    end

    local keys, cancel, confirm = renameKeyboardLayout()

    for _, key in ipairs(keys) do
        local label = key.label
        local bg = C.panel
        local fg = C.text

        if key.kind == "char" then
            label = renameUppercase and label:upper() or label:lower()
        elseif key.kind == "caps" then
            bg = C.rescan
            fg = colors.black
            label = renameUppercase and "UPPER" or "LOWER"
        elseif key.kind == "space" then
            bg = C.panel2
            fg = colors.black
        elseif key.kind == "back" then
            bg = C.danger
            fg = colors.white
        end

        drawButton(
            key.x1, key.y1,
            key.x2, key.y2,
            label,
            bg,
            fg
        )
    end

    drawButton(
        cancel.x1, cancel.y1,
        cancel.x2, cancel.y2,
        "CANCEL",
        C.panel,
        C.text
    )

    local confirmBG = renameBuffer ~= "" and C.run or C.panel
    local confirmFG = renameBuffer ~= "" and C.runText or C.dim

    drawButton(
        confirm.x1, confirm.y1,
        confirm.x2, confirm.y2,
        "CONFIRM",
        confirmBG,
        confirmFG
    )
end


-- =========================================================
-- DISK MANAGER
-- =========================================================

local function pointInRect(x, y, rect)
    return rect
       and x >= rect.x1 and x <= rect.x2
       and y >= rect.y1 and y <= rect.y2
end

local function isTransferFile(path)
    local lower = tostring(path or ""):lower()
    return lower:sub(-4) == ".lua" or lower:sub(-4) == ".txt"
end

local function getInsertedDisk()
    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheral.getType(peripheralName) == "drive" then
            local drive = peripheral.wrap(peripheralName)

            if drive then
                local okPresent, present = pcall(drive.isDiskPresent)

                if okPresent and present then
                    local okMount, mountPath = pcall(drive.getMountPath)

                    if okMount and mountPath then
                        return {
                            peripheral = peripheralName,
                            mount = mountPath
                        }
                    end
                end
            end
        end
    end

    return nil
end

local function scanTransferTree(rootPath, relativePath, output, skipMounts)
    relativePath = relativePath or ""

    local fullPath =
        relativePath == ""
        and rootPath
        or fs.combine(rootPath, relativePath)

    if not fs.exists(fullPath) or not fs.isDir(fullPath) then
        return
    end

    local ok, entries = pcall(fs.list, fullPath)
    if not ok then return end

    table.sort(entries, function(a, b)
        return a:lower() < b:lower()
    end)

    for _, name in ipairs(entries) do
        local rel =
            relativePath == ""
            and name
            or fs.combine(relativePath, name)

        local full =
            rootPath == ""
            and rel
            or fs.combine(rootPath, rel)

        local skip = false

        if skipMounts then
            if rel == "rom" or rel:sub(1, 4) == "rom/" then
                skip = true
            end

            for _, mount in ipairs(skipMounts) do
                if rel == mount or rel:sub(1, #mount + 1) == mount .. "/" then
                    skip = true
                    break
                end
            end
        end

        if not skip then
            if fs.isDir(full) then
                scanTransferTree(rootPath, rel, output, skipMounts)

            elseif isTransferFile(name) then
                table.insert(output, {
                    relative = rel,
                    full = full,
                    name = basename(rel)
                })
            end
        end
    end
end

local function refreshDiskFiles()
    diskFiles = {}

    local diskInfo = getInsertedDisk()
    if not diskInfo then
        diskScrollOffset = 0
        return nil
    end

    scanTransferTree(diskInfo.mount, "", diskFiles, nil)

    table.sort(diskFiles, function(a, b)
        return a.relative:lower() < b.relative:lower()
    end)

    local visible = getVisibleCount(layout())
    diskScrollOffset = clamp(
        diskScrollOffset,
        0,
        math.max(0, #diskFiles - visible)
    )

    return diskInfo
end

local function refreshComputerTransferFiles()
    computerTransferFiles = {}

    local mounts = {}

    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheral.getType(peripheralName) == "drive" then
            local drive = peripheral.wrap(peripheralName)

            if drive then
                local ok, mount = pcall(drive.getMountPath)
                if ok and mount then
                    table.insert(mounts, mount)
                end
            end
        end
    end

    scanTransferTree("", "", computerTransferFiles, mounts)

    table.sort(computerTransferFiles, function(a, b)
        return a.relative:lower() < b.relative:lower()
    end)

    local visible = getVisibleCount(layout())
    computerTransferScrollOffset = clamp(
        computerTransferScrollOffset,
        0,
        math.max(0, #computerTransferFiles - visible)
    )
end

local function ensureParentDirectory(path)
    local dir = fs.getDir(path)

    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function overwriteCopy(sourcePath, destinationPath)
    if not fs.exists(sourcePath) or fs.isDir(sourcePath) then
        return false, "Source file no longer exists."
    end

    if sourcePath == destinationPath then
        return true
    end

    ensureParentDirectory(destinationPath)

    if fs.exists(destinationPath) then
        fs.delete(destinationPath)
    end

    local ok, err = pcall(fs.copy, sourcePath, destinationPath)

    if not ok then
        return false, tostring(err)
    end

    return true
end

local function renameTransferFile(item, newBaseName)
    if not item or not item.full or not fs.exists(item.full) then
        return false, "File no longer exists."
    end

    newBaseName = trim(newBaseName)

    if newBaseName == "" then
        return false, "Name cannot be blank."
    end

    local ext = item.name:lower():sub(-4)
    local dir = fs.getDir(item.full)
    local destination = fs.combine(dir, newBaseName .. ext)

    if destination == item.full then
        return true
    end

    if fs.exists(destination) then
        return false, "A file with that name already exists."
    end

    local ok, err = pcall(fs.move, item.full, destination)

    if not ok then
        return false, tostring(err)
    end

    return true
end

local function transferActionButtons()
    local w = math.min(22, math.max(14, width - 8))
    local x1 = math.floor((width - w) / 2) + 1
    local x2 = x1 + w - 1
    local firstY = math.max(6, math.floor(height / 4))

    local function button(n)
        local y = firstY + (n - 1) * 3
        return {x1=x1,y1=y,x2=x2,y2=y+1}
    end

    return {
        rename = button(1),
        copy = button(2),
        delete = button(3),
        cancel = button(4)
    }
end

local function drawTransferList(title, subtitle, list, offset, computerMode)
    local L = layout()

    drawCrashHeader(title, subtitle)

    drawBox(
        L.panelX1,
        L.listY1 - 1,
        L.panelX2,
        L.listY2 + 1,
        C.border,
        C.bg
    )

    local visible = getVisibleCount(L)
    local maxOffset = math.max(0, #list - visible)
    offset = clamp(offset, 0, maxOffset)

    for row = 0, visible - 1 do
        local index = offset + row + 1
        local y = L.listY1 + row

        fillRect(L.listX1, y, L.listX2, y, C.bg, " ")

        if list[index] then
            local prefix = tostring(index) .. ". "
            local available =
                math.max(1, L.listX2 - L.listX1 + 1 - #prefix)

            writeAt(
                L.listX1,
                y,
                prefix .. list[index].relative:sub(1, available),
                C.text,
                C.bg
            )
        end
    end

    if offset > 0 then
        drawButton(
            L.upX1,L.upY1,L.upX2,L.upY2,
            " UP ",C.scroll,C.scrollText
        )
    end

    if offset + visible < #list then
        drawButton(
            L.downX1,L.downY1,L.downX2,L.downY2,
            "DOWN",C.scroll,C.scrollText
        )
    end

    if computerMode then
        writeAt(
            2,
            L.listY2 + 1,
            #list == 0 and "No .lua or .txt files found."
                or "Select a computer file.",
            #list == 0 and C.dim or C.text,
            C.bg
        )
    else
        writeAt(
            2,
            L.listY2 + 1,
            #list == 0 and "Disk has no .lua or .txt files."
                or "Select a disk file.",
            #list == 0 and C.dim or C.text,
            C.bg
        )
    end
end

local function diskManagerBottomButtons()
    local back = {
        x1=2,
        y1=height-2,
        x2=math.min(width, 11),
        y2=height-1
    }

    local fromComputer = {
        x1=math.max(1, width-18),
        y1=height-2,
        x2=width,
        y2=height-1
    }

    return back, fromComputer
end

local function drawDiskManager()
    local diskInfo = refreshDiskFiles()

    if not diskInfo then
        drawCrashHeader(
            "M A N A G E   D I S K",
            "Floppy disk manager"
        )

        centerText(
            math.floor(height / 2),
            "NO DISK INSERTED",
            C.danger,
            C.bg
        )

        local back, fromComputer = diskManagerBottomButtons()

        drawButton(
            back.x1,back.y1,back.x2,back.y2,
            "BACK",
            C.panel,
            C.text
        )

        drawButton(
            fromComputer.x1,fromComputer.y1,
            fromComputer.x2,fromComputer.y2,
            "FROM COMPUTER",
            C.panel,
            C.dim
        )

        return
    end

    drawTransferList(
        "M A N A G E   D I S K",
        "Disk: " .. diskInfo.peripheral,
        diskFiles,
        diskScrollOffset,
        false
    )

    local back, fromComputer = diskManagerBottomButtons()

    drawButton(
        back.x1,back.y1,back.x2,back.y2,
        "BACK",
        C.panel,
        C.text
    )

    drawButton(
        fromComputer.x1,fromComputer.y1,
        fromComputer.x2,fromComputer.y2,
        "FROM COMPUTER",
        colors.blue,
        colors.white
    )
end

local function drawComputerTransferList()
    local diskInfo = getInsertedDisk()

    if not diskInfo then
        drawCrashHeader(
            "C O M P U T E R   F I L E S",
            "Insert a floppy disk first"
        )

        centerText(
            math.floor(height / 2),
            "NO DISK INSERTED",
            C.danger,
            C.bg
        )

        local L = layout()

        drawButton(
            L.rescanX1,L.rescanY1,
            L.rescanX2,L.rescanY2,
            "BACK",
            C.panel,
            C.text
        )

        return
    end

    refreshComputerTransferFiles()

    drawTransferList(
        "C O M P U T E R   F I L E S",
        "Select .lua or .txt",
        computerTransferFiles,
        computerTransferScrollOffset,
        true
    )

    local L = layout()

    drawButton(
        L.rescanX1,L.rescanY1,
        L.rescanX2,L.rescanY2,
        "BACK",
        C.panel,
        C.text
    )
end

local function drawTransferAction(item, fromComputer)
    drawCrashHeader(
        fromComputer and "C O M P U T E R   F I L E" or "D I S K   F I L E",
        item and item.relative or "File"
    )

    local b = transferActionButtons()

    drawButton(
        b.rename.x1,b.rename.y1,b.rename.x2,b.rename.y2,
        "RENAME",
        colors.cyan,
        colors.black
    )

    drawButton(
        b.copy.x1,b.copy.y1,b.copy.x2,b.copy.y2,
        fromComputer and "COPY TO DRIVE" or "COPY TO COMPUTER",
        C.run,
        C.runText
    )

    drawButton(
        b.delete.x1,b.delete.y1,b.delete.x2,b.delete.y2,
        "DELETE",
        C.danger,
        colors.white
    )

    drawButton(
        b.cancel.x1,b.cancel.y1,b.cancel.x2,b.cancel.y2,
        "CANCEL",
        C.panel,
        C.text
    )

    drawStatus()
end

local function beginFileRename(item, returnMode)
    if not item then return end

    fileRenameTarget = item
    fileRenameReturnMode = returnMode

    local name = item.name
    local ext = name:lower():sub(-4)

    renameBuffer = name:sub(1, #name - #ext)
    renameOriginal = renameBuffer
    renameUppercase = true
    renameScreenMessage = nil

    launcherMode = "filerename"
end

local function drawFileRename()
    drawCrashHeader(
        "R E N A M E   F I L E",
        fileRenameTarget and fileRenameTarget.name or ""
    )

    local boxX1 = 3
    local boxX2 = math.max(boxX1 + 10, width - 2)
    local boxY = 5

    fillRect(boxX1, boxY, boxX2, boxY + 1, colors.white)

    local shown = renameBuffer
    local room = math.max(1, boxX2 - boxX1 - 1)

    if #shown > room then
        shown = shown:sub(#shown - room + 1)
    end

    writeAt(boxX1 + 1, boxY, shown, colors.black, colors.white)

    if fileRenameTarget then
        local ext = fileRenameTarget.name:lower():sub(-4)

        writeAt(
            math.max(1, boxX2 - #ext),
            boxY + 1,
            "Extension: " .. ext,
            C.dim,
            C.bg
        )
    end

    if renameScreenMessage then
        centerText(
            math.min(height, boxY + 2),
            renameScreenMessage:sub(1, math.max(1, width - 2)),
            renameScreenMessageColor,
            C.bg
        )
    end

    local keys, cancel, confirm = renameKeyboardLayout()

    for _, key in ipairs(keys) do
        local label = key.label
        local bg = C.panel
        local fg = C.text

        if key.kind == "char" then
            label = renameUppercase and label:upper() or label:lower()
        elseif key.kind == "caps" then
            bg = C.rescan
            fg = colors.black
            label = renameUppercase and "UPPER" or "LOWER"
        elseif key.kind == "space" then
            bg = C.panel2
            fg = colors.black
        elseif key.kind == "back" then
            bg = C.danger
            fg = colors.white
        end

        drawButton(
            key.x1,key.y1,key.x2,key.y2,
            label,bg,fg
        )
    end

    drawButton(
        cancel.x1,cancel.y1,cancel.x2,cancel.y2,
        "CANCEL",
        C.panel,
        C.text
    )

    drawButton(
        confirm.x1,confirm.y1,confirm.x2,confirm.y2,
        "CONFIRM",
        renameBuffer ~= "" and C.run or C.panel,
        renameBuffer ~= "" and C.runText or C.dim
    )
end

local function draw()
    width, height = monitor.getSize()

    clear(C.bg)

    if launcherMode == "crashlogs" then
        drawCrashList()
        return
    elseif launcherMode == "crashview" then
        drawCrashViewer()
        return
    elseif launcherMode == "settings" then
        drawSettingsMenu()
        return
    elseif launcherMode == "relaylist" then
        drawRelayList()
        return
    elseif launcherMode == "relaydetail" then
        drawRelayDetail()
        return
    elseif launcherMode == "relayrename" then
        drawRenameRelay()
        return
    elseif launcherMode == "monitorlist" then
        drawMonitorList()
        return
    elseif launcherMode == "monitordetail" then
        drawMonitorDetail()
        return
    elseif launcherMode == "monitorrename" then
        drawRenameRelay()
        return
    elseif launcherMode == "diskmanage" then
        drawDiskManager()
        return
    elseif launcherMode == "diskfile" then
        drawTransferAction(diskSelectedFile, false)
        return
    elseif launcherMode == "computertransfer" then
        drawComputerTransferList()
        return
    elseif launcherMode == "computerfile" then
        drawTransferAction(computerSelectedFile, true)
        return
    elseif launcherMode == "filerename" then
        drawFileRename()
        return
    end

    drawHeader()

    local L = layout()

    drawFileList(L)
    drawSelectedInfo(L)
    drawControls(L)
    drawStatus()
end

local function getAllRedstoneRelays()
    local relays = {}

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "redstone_relay" then
            if selectedResetPeripheral == nil or name == selectedResetPeripheral then
                local relay = peripheral.wrap(name)

                if relay then
                    table.insert(relays, {
                        name = name,
                        peripheral = relay
                    })
                end
            end
        end
    end

    return relays
end

local function anyRelayInputActive()
    local relays = getAllRedstoneRelays()

    for _, entry in ipairs(relays) do
        local relay = entry.peripheral

        for _, side in ipairs(REDSTONE_SIDES) do
            local ok, active = pcall(relay.getInput, side)

            if ok and active then
                return true, entry.name, side
            end
        end
    end

    return false
end

local function setupKillInput()
    if USE_REDSTONE_RELAYS then
        local relays = getAllRedstoneRelays()

        if #relays == 0 then
            return false, "No Redstone Relay found"
        end

        return true, tostring(#relays) .. " relay(s) detected"
    end

    return true
end

local function getKillInput()
    if USE_REDSTONE_RELAYS then
        return anyRelayInputActive()
    end

    return redstone.getInput(COMPUTER_KILL_SIDE)
end

local function waitForKillButton()
    -- If a button happens to be held while the program starts,
    -- first wait for all watched inputs to become inactive.
    while true do
        local active = getKillInput()

        if not active then
            break
        end

        os.pullEvent("redstone")
    end

    -- Now wait for a NEW redstone change and check every relay
    -- and every side. This avoids needing to know orientation.
    while true do
        os.pullEvent("redstone")

        local active = getKillInput()

        if active then
            return
        end
    end
end

local function restoreLauncherDisplay()
    monitor.setTextScale(GUI_SCALE)
    monitor.setCursorBlink(false)

    width, height = monitor.getSize()

    monitor.setBackgroundColor(C.bg)
    monitor.setTextColor(C.text)
    monitor.clear()
end

-- =========================================================
-- RUN PROGRAM
-- =========================================================

local function runSelected()
    if not selectedIndex then
        statusMessage = "Select a Lua file first."
        statusColor = C.danger
        return
    end

    local path = files[selectedIndex]

    if not path or not fs.exists(path) then
        statusMessage = "File no longer exists."
        statusColor = C.danger
        rescan()
        return
    end

    local inputOK, inputError = setupKillInput()
    if not inputOK then
        statusMessage = inputError
        statusColor = C.danger
        return
    end

    clear(C.bg)
    centerText(math.max(1, math.floor(height / 2) - 1), "Launching...", C.title, C.bg)
    centerText(math.max(1, math.floor(height / 2) + 1), basename(path), C.text, C.bg)

    sleep(0.15)

    -- The launcher now stops touching the monitor.
    -- The selected program is free to completely take over.
    --
    -- We run two cooperative tasks:
    --   1. The selected Lua program.
    --   2. The physical redstone exit-button watcher.
    --
    -- parallel.waitForAny stops the remaining task as soon
    -- as either one finishes, so pressing the button kills
    -- the launched program without rebooting the computer.
    local oldTerminal = term.current()

    -- Make normal terminal-based programs draw on the monitor
    -- too, while remembering recent terminal text for crash logs.
    -- Programs which explicitly use peripheral.find("monitor")
    -- continue to work normally.
    local captureTerminal, capturedOutput = makeCaptureTerminal(monitor)
    term.redirect(captureTerminal)

    local programFinished = false
    local programOK = true
    local programError = nil

    local function runProgram()
        local callOK, result = pcall(function()
            return shell.run(path)
        end)

        programFinished = true

        if not callOK then
            programOK = false
            programError = tostring(result)
        elseif result == false then
            programOK = false
            programError = "Program returned false"
        end
    end

    local function exitWatcher()
        waitForKillButton()
    end

    parallel.waitForAny(
        runProgram,
        exitWatcher
    )

    -- Restore the computer terminal and the launcher's own
    -- monitor scale/UI after the child program is gone.
    term.redirect(oldTerminal)
    restoreLauncherDisplay()

    if programFinished then
        if programOK then
            statusMessage = "Program exited: " .. basename(path)
            statusColor = C.dim
        else
            local crashFile = saveCrashLog(
                path,
                programError or "Unknown error",
                capturedOutput
            )

            if crashFile then
                statusMessage = "Crash logged: " .. crashFile
            else
                statusMessage = "Program error: " .. tostring(programError or "unknown")
            end

            statusColor = C.danger
        end
    else
        statusMessage = "Stopped: " .. basename(path)
        statusColor = C.rescan
    end
end

-- =========================================================
-- TOUCH HANDLING
-- =========================================================

local function handleCrashListTouch(x, y)
    local L = layout()
    local visible = getVisibleCount(L)

    if x >= L.listX1 and x <= L.listX2
       and y >= L.listY1 and y <= L.listY2 then

        local row = y - L.listY1
        local index = crashScrollOffset + row + 1

        if crashFiles[index] then
            loadCrashFile(crashFiles[index])
        end

        return
    end

    if inRect(x, y, L.upX1, L.upY1, L.upX2, L.upY2) then
        crashScrollOffset = math.max(0, crashScrollOffset - 1)
        return
    end

    if inRect(x, y, L.downX1, L.downY1, L.downX2, L.downY2) then
        local maxOffset = math.max(0, #crashFiles - visible)
        crashScrollOffset = math.min(maxOffset, crashScrollOffset + 1)
        return
    end

    if inRect(
        x, y,
        L.rescanX1, L.rescanY1,
        L.rescanX2, L.rescanY2
    ) then
        launcherMode = "programs"
        statusMessage = tostring(#files) .. " Lua file(s) found"
        statusColor = C.dim
        return
    end

    if inRect(
        x, y,
        L.crashX1, L.crashY1,
        L.crashX2, L.crashY2
    ) then
        scanCrashLogs()
        crashScrollOffset = 0
        return
    end
end

local function handleCrashViewerTouch(x, y)
    local L = layout()
    local visible = getVisibleCount(L)

    if inRect(x, y, L.upX1, L.upY1, L.upX2, L.upY2) then
        crashScrollOffset = math.max(0, crashScrollOffset - 1)
        return
    end

    if inRect(x, y, L.downX1, L.downY1, L.downX2, L.downY2) then
        local maxOffset = math.max(0, #crashLines - visible)
        crashScrollOffset = math.min(maxOffset, crashScrollOffset + 1)
        return
    end

    if inRect(
        x, y,
        L.rescanX1, L.rescanY1,
        L.rescanX2, L.rescanY2
    ) then
        launcherMode = "crashlogs"
        crashSelectedFile = nil
        crashLines = {}
        crashScrollOffset = 0
        scanCrashLogs()
        return
    end

    if inRect(
        x, y,
        L.runX1, L.runY1,
        L.runX2, L.runY2
    ) then
        deleteCrashFile(crashSelectedFile)
        return
    end
end


local function handleSettingsTouch(x, y)
    local relaysButton, monitorsButton = settingsMenuButtons()
    local L = layout()

    if x >= relaysButton.x1 and x <= relaysButton.x2
       and y >= relaysButton.y1 and y <= relaysButton.y2 then

        relayScrollOffset = 0
        selectedRelayRecord = nil
        launcherMode = "relaylist"
        statusMessage = "Select relay."
        statusColor = C.dim
        return
    end

    if x >= monitorsButton.x1 and x <= monitorsButton.x2
       and y >= monitorsButton.y1 and y <= monitorsButton.y2 then

        monitorScrollOffset = 0
        selectedMonitorRecord = nil
        refreshMonitorRecords()
        launcherMode = "monitorlist"
        statusMessage = "Select monitor."
        statusColor = C.dim
        return
    end

    if inRect(
        x, y,
        L.rescanX1, L.rescanY1,
        L.rescanX2, L.rescanY2
    ) then
        launcherMode = "programs"
        statusMessage = tostring(#files) .. " Lua file(s) found"
        statusColor = C.dim
        return
    end
end

local function handleRelayListTouch(x, y)
    local L = layout()
    local relays = getConnectedRelays()
    local visible = getVisibleCount(L)

    if x >= L.listX1 and x <= L.listX2
       and y >= L.listY1 and y <= L.listY2 then

        local row = y - L.listY1
        local index = relayScrollOffset + row + 1
        local relay = relays[index]

        if relay then
            selectedRelayRecord = relay
            launcherMode = "relaydetail"
            statusMessage = relay.name
            statusColor = C.dim
        end

        return
    end

    if inRect(x, y, L.upX1, L.upY1, L.upX2, L.upY2) then
        relayScrollOffset = math.max(0, relayScrollOffset - 1)
        return
    end

    if inRect(x, y, L.downX1, L.downY1, L.downX2, L.downY2) then
        local maxOffset = math.max(0, #relays - visible)
        relayScrollOffset = math.min(maxOffset, relayScrollOffset + 1)
        return
    end

    if inRect(
        x, y,
        L.rescanX1, L.rescanY1,
        L.rescanX2, L.rescanY2
    ) then
        launcherMode = "settings"
        selectedRelayRecord = nil
        return
    end
end

local function handleRelayDetailTouch(x, y)
    if not selectedRelayRecord then
        launcherMode = "relaylist"
        return
    end

    local useB, renameB, backB = relayDetailButtons()

    if x >= useB.x1 and x <= useB.x2
       and y >= useB.y1 and y <= useB.y2 then

        selectedResetPeripheral = selectedRelayRecord.peripheral
        saveLauncherSettings()

        statusMessage = "Reset relay: " .. selectedRelayRecord.name
        statusColor = C.run
        return
    end

    if x >= renameB.x1 and x <= renameB.x2
       and y >= renameB.y1 and y <= renameB.y2 then

        renameRelay = {
            peripheral = selectedRelayRecord.peripheral,
            id = selectedRelayRecord.id,
            name = selectedRelayRecord.name
        }

        renameOriginal = selectedRelayRecord.name or selectedRelayRecord.peripheral
        renameBuffer = renameOriginal
        renameUppercase = true
        renameScreenMessage = nil
        launcherMode = "relayrename"
        return
    end

    if x >= backB.x1 and x <= backB.x2
       and y >= backB.y1 and y <= backB.y2 then

        selectedRelayRecord = nil
        launcherMode = "relaylist"
        return
    end
end

local function handleMonitorListTouch(x, y)
    local L = layout()
    local monitors = getConnectedMonitors()
    local visible = getVisibleCount(L)

    if x >= L.listX1 and x <= L.listX2
       and y >= L.listY1 and y <= L.listY2 then

        local row = y - L.listY1
        local index = monitorScrollOffset + row + 1
        local entry = monitors[index]

        if entry then
            selectedMonitorRecord = entry
            launcherMode = "monitordetail"
            statusMessage = entry.name
            statusColor = C.dim
        end

        return
    end

    if inRect(x,y,L.upX1,L.upY1,L.upX2,L.upY2) then
        monitorScrollOffset = math.max(0, monitorScrollOffset - 1)
        return
    end

    if inRect(x,y,L.downX1,L.downY1,L.downX2,L.downY2) then
        local maxOffset = math.max(0, #monitors - visible)
        monitorScrollOffset = math.min(maxOffset, monitorScrollOffset + 1)
        return
    end

    if inRect(
        x,y,
        L.rescanX1,L.rescanY1,
        L.rescanX2,L.rescanY2
    ) then
        launcherMode = "settings"
        selectedMonitorRecord = nil
        return
    end
end

local function handleMonitorDetailTouch(x, y)
    if not selectedMonitorRecord then
        launcherMode = "monitorlist"
        return
    end

    local useB, renameB, backB = monitorDetailButtons()

    if x>=useB.x1 and x<=useB.x2 and y>=useB.y1 and y<=useB.y2 then
        if selectedMonitorRecord.peripheral ~= monitorPeripheralName then
            local ok, err = switchLauncherMonitor(selectedMonitorRecord.peripheral)

            if ok then
                statusMessage = "Launcher moved to: " .. selectedMonitorRecord.name
                statusColor = C.run
            else
                statusMessage = tostring(err or "Monitor switch failed")
                statusColor = C.danger
            end
        end

        return
    end

    if x>=renameB.x1 and x<=renameB.x2 and y>=renameB.y1 and y<=renameB.y2 then
        renameMonitor = selectedMonitorRecord
        renameOriginal = selectedMonitorRecord.name
        renameBuffer = renameOriginal
        renameUppercase = true
        renameScreenMessage = nil
        launcherMode = "monitorrename"
        return
    end

    if x>=backB.x1 and x<=backB.x2 and y>=backB.y1 and y<=backB.y2 then
        selectedMonitorRecord = nil
        launcherMode = "monitorlist"
        return
    end
end

local function handleRenameTouch(x, y)
    local keys, cancel, confirm = renameKeyboardLayout()

    -- IMPORTANT:
    -- Test CANCEL / CONFIRM before keyboard keys.
    -- On small monitors this guarantees footer buttons can never
    -- be swallowed by an overlapping keyboard hitbox.
    if x >= cancel.x1 and x <= cancel.x2
       and y >= cancel.y1 and y <= cancel.y2 then

        renameBuffer = renameOriginal

        if launcherMode == "monitorrename" then
            renameMonitor = nil
            launcherMode = "monitordetail"
        else
            renameRelay = nil

            if selectedRelayRecord then
                launcherMode = "relaydetail"
            else
                launcherMode = "relaylist"
            end
        end

        statusMessage = "Rename cancelled."
        statusColor = C.dim
        return
    end

    if x >= confirm.x1 and x <= confirm.x2
       and y >= confirm.y1 and y <= confirm.y2 then

        if trim(renameBuffer) == "" then
            statusMessage = "Name cannot be blank."
            statusColor = C.danger
            return
        end

        local ok, err

        if launcherMode == "monitorrename" and renameMonitor then
            local peripheralName = renameMonitor.peripheral

            ok, err = renameMonitorRecord(
                peripheralName,
                renameBuffer
            )

            if ok then
                statusMessage = "Renamed to: " .. trim(renameBuffer)
                statusColor = C.run

                refreshMonitorRecords()
                selectedMonitorRecord = nil

                for _, record in ipairs(getConnectedMonitors()) do
                    if record.peripheral == peripheralName then
                        selectedMonitorRecord = record
                        break
                    end
                end

                renameMonitor = nil
                launcherMode = selectedMonitorRecord and "monitordetail" or "monitorlist"
            end

        elseif launcherMode == "relayrename"
           and renameRelay
           and renameRelay.peripheral then

            local peripheralName = renameRelay.peripheral
            local relayId = renameRelay.id

            ok, err = rewriteRelayName(
                peripheralName,
                relayId,
                renameBuffer
            )

            if ok then
                statusMessage = "Renamed to: " .. trim(renameBuffer)
                statusColor = C.run
                renameScreenMessage = nil

                parseRsguicData()
                selectedRelayRecord = nil

                for _, record in ipairs(getConnectedRelays()) do
                    if record.peripheral == peripheralName
                       or tonumber(record.id) == tonumber(relayId) then

                        selectedRelayRecord = record
                        break
                    end
                end

                renameRelay = nil
                launcherMode = selectedRelayRecord and "relaydetail" or "relaylist"
            end

        else
            ok = false
            err = "No rename target selected."
        end

        if not ok then
            statusMessage = tostring(err or "Rename failed")
            statusColor = C.danger
            renameScreenMessage = tostring(err or "Rename failed")
            renameScreenMessageColor = C.danger
        end

        return
    end

    -- Keyboard keys are checked only after footer buttons.
    for _, key in ipairs(keys) do
        if x >= key.x1 and x <= key.x2
           and y >= key.y1 and y <= key.y2 then

            if key.kind == "char" then
                if #renameBuffer < 32 then
                    local ch = renameUppercase
                        and key.label:upper()
                        or key.label:lower()

                    renameBuffer = renameBuffer .. ch
                end

            elseif key.kind == "caps" then
                renameUppercase = not renameUppercase

            elseif key.kind == "space" then
                if #renameBuffer < 32 then
                    renameBuffer = renameBuffer .. " "
                end

            elseif key.kind == "back" then
                if #renameBuffer > 0 then
                    renameBuffer = renameBuffer:sub(1, #renameBuffer - 1)
                end
            end

            return
        end
    end
end


local function handleDiskManagerTouch(x, y)
    local diskInfo = refreshDiskFiles()
    local back, fromComputer = diskManagerBottomButtons()

    if pointInRect(x,y,back) then
        launcherMode = "programs"
        diskSelectedFile = nil
        return
    end

    if pointInRect(x,y,fromComputer) then
        if diskInfo then
            computerTransferScrollOffset = 0
            computerSelectedFile = nil
            refreshComputerTransferFiles()
            launcherMode = "computertransfer"
        else
            statusMessage = "No disk inserted."
            statusColor = C.danger
        end
        return
    end

    if not diskInfo then return end

    local L = layout()
    local visible = getVisibleCount(L)

    if x >= L.listX1 and x <= L.listX2
       and y >= L.listY1 and y <= L.listY2 then

        local index = diskScrollOffset + (y - L.listY1) + 1

        if diskFiles[index] then
            diskSelectedFile = diskFiles[index]
            launcherMode = "diskfile"
        end

        return
    end

    if inRect(x,y,L.upX1,L.upY1,L.upX2,L.upY2) then
        diskScrollOffset = math.max(0,diskScrollOffset-1)
        return
    end

    if inRect(x,y,L.downX1,L.downY1,L.downX2,L.downY2) then
        diskScrollOffset = math.min(
            math.max(0,#diskFiles-visible),
            diskScrollOffset+1
        )
        return
    end
end

local function handleComputerTransferTouch(x, y)
    if not getInsertedDisk() then
        local L = layout()

        if inRect(
            x,y,
            L.rescanX1,L.rescanY1,
            L.rescanX2,L.rescanY2
        ) then
            launcherMode = "diskmanage"
        end

        return
    end

    refreshComputerTransferFiles()

    local L = layout()
    local visible = getVisibleCount(L)

    -- IMPORTANT:
    -- Navigation buttons are checked BEFORE file rows so
    -- clicking DOWN/UP/BACK can never select the file underneath.
    if inRect(x,y,L.upX1,L.upY1,L.upX2,L.upY2) then
        computerTransferScrollOffset =
            math.max(0, computerTransferScrollOffset - 1)
        return
    end

    if inRect(x,y,L.downX1,L.downY1,L.downX2,L.downY2) then
        computerTransferScrollOffset = math.min(
            math.max(0, #computerTransferFiles - visible),
            computerTransferScrollOffset + 1
        )
        return
    end

    if inRect(
        x,y,
        L.rescanX1,L.rescanY1,
        L.rescanX2,L.rescanY2
    ) then
        launcherMode = "diskmanage"
        computerSelectedFile = nil
        return
    end

    -- Only check file rows after control buttons.
    if x >= L.listX1 and x <= L.listX2
       and y >= L.listY1 and y <= L.listY2 then

        local index =
            computerTransferScrollOffset
            + (y - L.listY1)
            + 1

        if computerTransferFiles[index] then
            computerSelectedFile = computerTransferFiles[index]
            launcherMode = "computerfile"
        end

        return
    end
end

local function handleDiskFileActionTouch(x, y)
    local b = transferActionButtons()

    if pointInRect(x,y,b.rename) then
        beginFileRename(diskSelectedFile,"diskfile")
        return
    end

    if pointInRect(x,y,b.copy) then
        local diskInfo = getInsertedDisk()

        if not diskInfo or not diskSelectedFile then
            launcherMode = "diskmanage"
            statusMessage = "Disk removed."
            statusColor = C.danger
            return
        end

        local destination = diskSelectedFile.relative

        local ok, err = overwriteCopy(
            diskSelectedFile.full,
            destination
        )

        if ok then
            statusMessage = "Copied to computer: " .. destination
            statusColor = C.run
        else
            statusMessage = tostring(err)
            statusColor = C.danger
        end

        launcherMode = "diskmanage"
        diskSelectedFile = nil
        return
    end

    if pointInRect(x,y,b.delete) then
        if diskSelectedFile
           and fs.exists(diskSelectedFile.full) then

            fs.delete(diskSelectedFile.full)
            statusMessage = "Disk file deleted."
            statusColor = C.rescan
        end

        diskSelectedFile = nil
        launcherMode = "diskmanage"
        return
    end

    if pointInRect(x,y,b.cancel) then
        diskSelectedFile = nil
        launcherMode = "diskmanage"
        return
    end
end

local function handleComputerFileActionTouch(x, y)
    local b = transferActionButtons()

    if pointInRect(x,y,b.rename) then
        beginFileRename(computerSelectedFile,"computerfile")
        return
    end

    if pointInRect(x,y,b.copy) then
        local diskInfo = getInsertedDisk()

        if not diskInfo then
            statusMessage = "No disk inserted."
            statusColor = C.danger
            launcherMode = "computertransfer"
            return
        end

        if not computerSelectedFile then
            launcherMode = "computertransfer"
            return
        end

        local destination =
            fs.combine(
                diskInfo.mount,
                computerSelectedFile.relative
            )

        local ok, err = overwriteCopy(
            computerSelectedFile.full,
            destination
        )

        if ok then
            statusMessage =
                "Copied to drive: "
                .. computerSelectedFile.relative
            statusColor = C.run
        else
            statusMessage = tostring(err)
            statusColor = C.danger
        end

        computerSelectedFile = nil
        launcherMode = "computertransfer"
        return
    end

    if pointInRect(x,y,b.delete) then
        if computerSelectedFile
           and fs.exists(computerSelectedFile.full) then

            fs.delete(computerSelectedFile.full)
            statusMessage = "Computer file deleted."
            statusColor = C.rescan
        end

        computerSelectedFile = nil
        launcherMode = "computertransfer"
        return
    end

    if pointInRect(x,y,b.cancel) then
        computerSelectedFile = nil
        launcherMode = "computertransfer"
        return
    end
end

local function handleFileRenameTouch(x, y)
    local keys, cancel, confirm = renameKeyboardLayout()

    if pointInRect(x,y,cancel) then
        renameBuffer = renameOriginal
        renameScreenMessage = nil
        launcherMode = fileRenameReturnMode or "diskmanage"
        return
    end

    if pointInRect(x,y,confirm) then
        local ok, err =
            renameTransferFile(
                fileRenameTarget,
                renameBuffer
            )

        if ok then
            statusMessage = "File renamed."
            statusColor = C.run
            renameScreenMessage = nil

            if fileRenameReturnMode == "diskfile" then
                diskSelectedFile = nil
                launcherMode = "diskmanage"
            else
                computerSelectedFile = nil
                launcherMode = "computertransfer"
            end

            fileRenameTarget = nil
            fileRenameReturnMode = nil
        else
            renameScreenMessage = tostring(err)
            renameScreenMessageColor = C.danger
        end

        return
    end

    for _, key in ipairs(keys) do
        if pointInRect(x,y,key) then
            if key.kind == "char" then
                if #renameBuffer < 48 then
                    renameBuffer =
                        renameBuffer
                        .. (
                            renameUppercase
                            and key.label:upper()
                            or key.label:lower()
                        )
                end

            elseif key.kind == "caps" then
                renameUppercase = not renameUppercase

            elseif key.kind == "space" then
                if #renameBuffer < 48 then
                    renameBuffer = renameBuffer .. " "
                end

            elseif key.kind == "back" then
                if #renameBuffer > 0 then
                    renameBuffer =
                        renameBuffer:sub(1,#renameBuffer-1)
                end
            end

            return
        end
    end
end

local function handleTouch(x, y)
    if launcherMode == "settings" then
        handleSettingsTouch(x, y)
        return
    elseif launcherMode == "relaylist" then
        handleRelayListTouch(x, y)
        return
    elseif launcherMode == "relaydetail" then
        handleRelayDetailTouch(x, y)
        return
    elseif launcherMode == "relayrename" then
        handleRenameTouch(x, y)
        return
    elseif launcherMode == "monitorlist" then
        handleMonitorListTouch(x, y)
        return
    elseif launcherMode == "monitordetail" then
        handleMonitorDetailTouch(x, y)
        return
    elseif launcherMode == "monitorrename" then
        handleRenameTouch(x, y)
        return
    elseif launcherMode == "crashlogs" then
        handleCrashListTouch(x, y)
        return
    elseif launcherMode == "crashview" then
        handleCrashViewerTouch(x, y)
        return
    elseif launcherMode == "diskmanage" then
        handleDiskManagerTouch(x, y)
        return
    elseif launcherMode == "diskfile" then
        handleDiskFileActionTouch(x, y)
        return
    elseif launcherMode == "computertransfer" then
        handleComputerTransferTouch(x, y)
        return
    elseif launcherMode == "computerfile" then
        handleComputerFileActionTouch(x, y)
        return
    elseif launcherMode == "filerename" then
        handleFileRenameTouch(x, y)
        return
    end

    local L = layout()
    local visible = getVisibleCount(L)

    -- File rows
    if x >= L.listX1 and x <= L.listX2
       and y >= L.listY1 and y <= L.listY2 then

        local row = y - L.listY1
        local index = scrollOffset + row + 1

        if files[index] then
            selectedIndex = index
            keepSelectionVisible()

            statusMessage = basename(files[index])
            statusColor = C.text
        end

        return
    end

    -- Scroll up
    if inRect(x, y, L.upX1, L.upY1, L.upX2, L.upY2) then
        if scrollOffset > 0 then
            scrollOffset = math.max(0, scrollOffset - 1)
        end
        return
    end

    -- Scroll down
    if inRect(x, y, L.downX1, L.downY1, L.downX2, L.downY2) then
        local maxOffset = math.max(0, #files - visible)

        if scrollOffset < maxOffset then
            scrollOffset = math.min(maxOffset, scrollOffset + 1)
        end
        return
    end

    -- Rescan
    if inRect(
        x, y,
        L.rescanX1, L.rescanY1,
        L.rescanX2, L.rescanY2
    ) then
        rescan()
        return
    end

    -- Crash Logs
    if inRect(
        x, y,
        L.crashX1, L.crashY1,
        L.crashX2, L.crashY2
    ) then
        launcherMode = "crashlogs"
        crashSelectedFile = nil
        crashLines = {}
        crashScrollOffset = 0
        scanCrashLogs()
        return
    end

    -- Settings
    if inRect(
        x, y,
        L.settingsX1, L.settingsY1,
        L.settingsX2, L.settingsY2
    ) then
        launcherMode = "settings"
        parseRsguicData()
        statusMessage = "Settings"
        statusColor = C.dim
        return
    end

    -- Manage Disk
    if inRect(
        x, y,
        L.diskX1, L.diskY1,
        L.diskX2, L.diskY2
    ) then
        launcherMode = "diskmanage"
        diskScrollOffset = 0
        diskSelectedFile = nil
        statusMessage = "Disk Manager"
        statusColor = C.dim
        return
    end

    -- Run
    if inRect(
        x, y,
        L.runX1, L.runY1,
        L.runX2, L.runY2
    ) then
        runSelected()
        return
    end
end

-- =========================================================
-- STARTUP
-- =========================================================

loadLauncherSettings()
parseRsguicData()
syncConnectedRelaysToDataFile()
refreshMonitorRecords()

-- If the settings file refers to a valid connected monitor,
-- move to it now. The top-of-file preset normally already did this,
-- but this also handles older settings files safely.
if selectedLauncherMonitor
   and selectedLauncherMonitor ~= monitorPeripheralName
   and peripheral.isPresent(selectedLauncherMonitor)
   and peripheral.getType(selectedLauncherMonitor) == "monitor" then

    switchLauncherMonitor(selectedLauncherMonitor)
end

rescan()
scanCrashLogs()

local killOK, killInfo = setupKillInput()
if not killOK then
    statusMessage = killInfo
    statusColor = C.danger
elseif USE_REDSTONE_RELAYS then
    statusMessage = killInfo
    statusColor = C.dim
end

draw()

-- =========================================================
-- MAIN LOOP
-- =========================================================

while true do
    local event, p1, p2, p3 = os.pullEvent()

    if event == "monitor_touch" then
        handleTouch(p2, p3)
        draw()

    elseif event == "monitor_resize" then
        width, height = monitor.getSize()
        keepSelectionVisible()
        draw()

    elseif event == "peripheral" or event == "peripheral_detach" then
        -- If monitor dimensions/peripheral layout changes,
        -- refresh the UI safely.
        width, height = monitor.getSize()
        draw()
    end
end
