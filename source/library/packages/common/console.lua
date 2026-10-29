-- @ama-section: Role console | Application supervision, registry health and local tools.
-- Shared Amaryllis shell, status/logs view, installer supervisor, and role health.
local Console = {}

local APP_PATH = "/avionics/main.lua"
local DIAGNOSTICS_PATH = "/avionics/diagnostics.lua"
local SETTINGS_PATH = "/avionics/data/settings.json"
local PROTOCOL = "amaryllis.v1"
local INSTALL_PROTOCOL = "amaryllis.install.v1"
local safeTokenPattern = "^[%w_%.%-:]+$"
local ensureDiagnosticsCapture
local reportError
local observeInstallerStatus

local function safeText(value, limit)
    local text = tostring(value or "--"):gsub("[%c]", " ")
    limit = limit or 160
    if #text > limit then text = text:sub(1, math.max(0, limit - 3)) .. "..." end
    return text
end

local function isInteger(value)
    return type(value) == "number" and value == value and value ~= math.huge
        and value ~= -math.huge and value == math.floor(value)
end

local function validToken(value)
    return type(value) == "string" and #value > 0 and #value <= 128
        and value:match(safeTokenPattern) ~= nil
end

local function validLabel(value)
    return type(value) == "string" and #value > 0 and #value <= 64
        and value:match("^[%w%._%-]+$") ~= nil
end

local function clockLabel(seconds)
    seconds = tonumber(seconds) or 0
    if seconds ~= seconds or seconds == math.huge or seconds == -math.huge then seconds = 0 end
    seconds = math.floor(seconds) % 86400
    return string.format("%02d:%02d:%02d", math.floor(seconds / 3600),
        math.floor(seconds / 60) % 60, seconds % 60)
end

-- @ama-section: Role console | Application supervision, registry health and local tools.
-- @ama-summary: Format the current clock value for status and log rows.
local function currentTimeLabel(at)
    if os and type(os.date) == "function" then
        local ok, label = pcall(os.date, "%H:%M:%S")
        if ok and type(label) == "string" and label:match("^%d%d:%d%d:%d%d$") then return label end
    end
    if os and type(os.epoch) == "function" then
        local ok, milliseconds = pcall(os.epoch, "local")
        if ok and type(milliseconds) == "number" and milliseconds == milliseconds then
            return clockLabel(milliseconds / 1000)
        end
    end
    if at == nil and os and type(os.clock) == "function" then
        local ok, seconds = pcall(os.clock)
        if ok then at = seconds end
    end
    return clockLabel(at)
end

-- @ama-summary: Read and decode the selected JSON record.
local function readJson(path)
    if not fs or not textutils or type(textutils.unserializeJSON) ~= "function" then
        return nil, "filesystem or JSON support is unavailable"
    end
    local ok, handle = pcall(fs.open, path, "r")
    if not ok or not handle then return nil, "could not open " .. path end
    local readOK, raw = pcall(handle.readAll)
    pcall(handle.close)
    if not readOK or type(raw) ~= "string" or #raw > 1048576 then return nil, "could not read " .. path end
    local decodeOK, value = pcall(textutils.unserializeJSON, raw)
    if not decodeOK or type(value) ~= "table" then return nil, "invalid JSON in " .. path end
    return value
end

-- @ama-summary: Validate and apply a registry announcement from the installed core.
function Console.acceptRegistry(sender, message, protocol, role, localID, trustedCoreID)
    trustedCoreID = trustedCoreID or Console.trustedCoreID()
    if not isInteger(trustedCoreID) or sender ~= trustedCoreID or protocol ~= PROTOCOL or type(message) ~= "table"
        or message.v ~= 1 or message.kind ~= "fleet_registry" or message.coreID ~= trustedCoreID
        or not validToken(message.session) or type(message.computers) ~= "table"
        or type(role) ~= "string" or not isInteger(localID) then return false end

    local previous = os.__amaryllisFleetRegistry
    local retired = os.__amaryllisRetiredCoreSessions or {}
    if type(retired) ~= "table" or retired[message.session] then return false end
    -- @ama-summary: Retire cached state associated with the previous core identity.
    local function clearPreviousIdentity()
        if type(previous) ~= "table" or previous.coreID ~= trustedCoreID then return end
        if validToken(previous.session) and previous.session ~= message.session then
            retired[previous.session] = true
            os.__amaryllisRetiredCoreSessions = retired
        end
        os.__amaryllisFleetRegistry = nil
        os.__amaryllisIdentity = nil
        pcall(os.queueEvent, "amaryllis_registry_changed", message.session)
    end

    local ids, labels = {}, {}
    for otherRole, other in pairs(message.computers) do
        if type(otherRole) ~= "string" or type(other) ~= "table" then return false end
        if other.id ~= nil then
            if not isInteger(other.id) or other.id < 0 or ids[other.id] then return false end
            ids[other.id] = otherRole
        end
        if other.label ~= nil then
            if not validLabel(other.label) or labels[other.label] then return false end
            labels[other.label] = otherRole
        end
    end

    local core = message.computers.core
    if type(core) ~= "table" or core.id ~= trustedCoreID or not validLabel(core.label) then return false end
    local resolvedRole = role
    if role == "auto" then
        resolvedRole = nil
        for candidateRole, candidate in pairs(message.computers) do
            if candidateRole ~= "core" and type(candidate) == "table" and candidate.id == localID then
                if resolvedRole ~= nil then return false end
                resolvedRole = candidateRole
            end
        end
    end
    if type(resolvedRole) ~= "string" or resolvedRole == "core" then
        if role == "auto" then clearPreviousIdentity() end
        return false
    end
    local entry = message.computers[resolvedRole]
    if type(entry) ~= "table" or entry.id ~= localID or not validLabel(entry.label) then
        clearPreviousIdentity()
        return false
    end
    if type(previous) == "table" and validToken(previous.session) and previous.session ~= message.session then
        retired[previous.session] = true
        os.__amaryllisRetiredCoreSessions = retired
    end
    local computers = {}
    for otherRole, other in pairs(message.computers) do
        computers[otherRole] = { id = other.id, label = other.label }
    end
    os.__amaryllisFleetRegistry = { coreID = trustedCoreID, session = message.session,
        computers = computers, receivedAt = os.clock() }
    os.__amaryllisIdentity = { role = resolvedRole, computerID = localID, label = entry.label,
        coreID = trustedCoreID }
    if type(previous) == "table" and (previous.session ~= message.session
        or type(previous.computers) ~= "table" or type(previous.computers[resolvedRole]) ~= "table"
        or previous.computers[resolvedRole].id ~= entry.id or previous.computers[resolvedRole].label ~= entry.label) then
        pcall(os.queueEvent, "amaryllis_registry_changed", message.session)
    end
    return true
end

-- @ama-summary: Resolve the installed trusted core computer ID.
function Console.trustedCoreID()
    local localID = os and type(os.getComputerID) == "function" and os.getComputerID() or nil
    local fleetFile = readJson("/fleet.json")
    local coreEntry = type(fleetFile) == "table" and type(fleetFile.computers) == "table"
        and fleetFile.computers.core or nil
    if isInteger(localID) and type(coreEntry) == "table" and coreEntry.id == localID
        and validLabel(coreEntry.label) then return localID end
    local bootstrap = readJson("/config.json")
    if type(bootstrap) == "table" and isInteger(bootstrap.core_id) and bootstrap.core_id >= 0 then return bootstrap.core_id end
    local app = readJson("/avionics/config.json")
    if type(app) == "table" then
        local receipt = type(app.install) == "table" and app.install or nil
        local coreID = receipt and receipt.coreID or app.core_id or app.coreId
        if isInteger(coreID) and coreID >= 0 then return coreID end
    end
    local registry = os and os.__amaryllisFleetRegistry
    if type(registry) == "table" and isInteger(registry.coreID) and validToken(registry.session) then return registry.coreID end
    local installer = readJson("/installer/config.json")
    if type(installer) == "table" and isInteger(installer.core_id) and installer.core_id >= 0 then return installer.core_id end
    return nil
end

-- @ama-summary: Identify whether this console belongs to the registered core role.
function Console.isCore()
    local localID = os and type(os.getComputerID) == "function" and os.getComputerID() or nil
    local fleetFile = readJson("/fleet.json")
    local coreEntry = type(fleetFile) == "table" and type(fleetFile.computers) == "table"
        and fleetFile.computers.core or nil
    if isInteger(localID) and type(coreEntry) == "table" and coreEntry.id == localID then return true end
    local bootstrap = readJson("/config.json")
    return type(bootstrap) == "table" and bootstrap.target_role == "core"
        and isInteger(bootstrap.core_id) and bootstrap.core_id == localID
end
local function installedConfig()
    local config = readJson("/avionics/config.json")
    if type(config) ~= "table" or type(config.install) ~= "table" then return nil end
    return config
end

-- @ama-summary: Format the current role's highest-priority reported issue.
local function faultSummary(runtime, capture)
    if type(runtime) == "table" then
        if type(runtime.faultSummary) == "string" and runtime.faultSummary ~= "" then
            return safeText(runtime.faultSummary, 160)
        end
        local faults = runtime.faults or (type(runtime.snapshot) == "table" and runtime.snapshot.faults)
        if type(faults) == "table" and #faults > 0 then
            local parts = {}
            for index = 1, math.min(4, #faults) do parts[#parts + 1] = safeText(faults[index], 40) end
            return safeText(table.concat(parts, "; "), 160)
        end
    end
    if type(capture) == "table" and type(capture.lastFault) == "string" then
        return safeText(capture.lastFault, 160)
    end
    return ""
end

-- @ama-summary: Build the current program, hardware and issue status for this role.
function Console.roleStatus(install, capture, runtime, sequence)
    if type(install) ~= "table" or type(capture) ~= "table" then return nil end
    local localID = os.getComputerID()
    local role = install.role
    local registry = os.__amaryllisFleetRegistry
    local entry = type(registry) == "table" and type(registry.computers) == "table"
        and registry.computers[role] or nil
    if type(entry) ~= "table" or entry.id ~= localID or entry.label ~= install.label
        or registry.coreID ~= install.coreID or not validToken(registry.session) then return nil end
    local running = capture.running == true and type(runtime) == "table" and runtime.running == true
    local hardwareAvailable = type(runtime) == "table" and runtime.hardwareAvailable == true
    return {
        v = 1,
        kind = "role_status",
        role = role,
        packageId = install.packageId,
        version = install.version,
        boot = capture.boot,
        coreID = install.coreID,
        coreSession = registry.session,
        seq = sequence,
        running = running,
        hardwareAvailable = hardwareAvailable,
        faultSummary = faultSummary(runtime, capture),
    }
end

local function requestRegistry(coreID, boot)
    if not rednet or type(rednet.send) ~= "function" then return false end
    return pcall(rednet.send, coreID, {
        v = 1, kind = "registry_request", coreID = coreID, session = boot,
    }, PROTOCOL)
end

-- @ama-summary: Format the selected console page from cached runtime state.
function Console.rows(page, capture, runtime, installer, now)
    local rows = {}
    local function row(label, value) rows[#rows + 1] = label .. ": " .. safeText(value, 180) end
    if page == "LOGS" then
        local entries = type(capture) == "table" and capture.console or {}
        for index = math.max(1, #entries - 79), #entries do
            local entry = entries[index]
            local timestamp = type(entry.timestamp) == "string"
                and entry.timestamp:match("^%d%d:%d%d:%d%d$") and entry.timestamp
                or currentTimeLabel(entry.at)
            rows[#rows + 1] = "[" .. timestamp .. "] " .. safeText(entry.text, 512)
        end
        if #rows == 0 then rows[1] = "No log messages yet." end
        return rows
    end
    local installed = installedConfig()
    local install = installed and installed.install or nil
    row("Computer", os.getComputerID() .. " " .. safeText(os.getComputerLabel()))
    row("Role", install and install.role or (Console.isCore() and "core" or "not installed"))
    row("Package", install and (tostring(install.packageId) .. " v" .. tostring(install.version)) or "--")
    row("Role code", capture and capture.running and "running" or "stopped / waiting")
    row("Hardware", runtime and runtime.hardwareAvailable == true and "available" or "unavailable")
    if runtime and runtime.publishedAt then row("Data age s", math.max(0, now - runtime.publishedAt)) end
    row("Role fault", faultSummary(runtime, capture))
    if type(installer) == "table" then
        row("Installer", installer.state or installer.applicationState or "--")
        row("Installer detail", installer.detail or installer.lastError or installer.applicationFault or "")
    end
    return rows
end

-- @ama-summary: Wrap bounded log records into the available terminal width.
local function wrapLogRows(rows, width)
    width = math.max(1, math.floor(tonumber(width) or 1))
    local wrapped = {}
    for _, row in ipairs(rows) do
        local remaining = safeText(row, 544)
        while #remaining > width do
            local boundary = remaining:sub(1, width):match("^.*()%s+")
            local take = boundary and boundary > 1 and boundary - 1 or width
            wrapped[#wrapped + 1] = remaining:sub(1, take)
            remaining = remaining:sub(take + 1):gsub("^%s+", "")
        end
        wrapped[#wrapped + 1] = remaining
    end
    return wrapped
end

-- @ama-summary: Refresh the role console using its cached runtime status.
function Console.status(initialPage)
    if multishell and multishell.setTitle and multishell.getCurrent then
        pcall(multishell.setTitle, multishell.getCurrent(), "status/logs")
    end
    local page, scroll = initialPage == "LOGS" and "LOGS" or "STATUS", 0
    local previousFrame, previousWidth, previousHeight
    local maxScroll = 0
    -- @ama-summary: Render the current view into its configured terminal or monitor.
    local function draw(force)
        local width, height = term.getSize()
        width, height = math.max(1, tonumber(width) or 1), math.max(1, tonumber(height) or 1)
        if previousWidth ~= width or previousHeight ~= height then force = true end
        local capture = os.__amaryllisDiagnostics
        local runtime = os.__amaryllisRuntime
        local installer = readJson(Console.isCore()
            and "/installer/install_status.json" or "/installer/status.json")
        local rows = Console.rows(page, capture, runtime, installer, os.clock())
        if page == "LOGS" then rows = wrapLogRows(rows, width) end
        local body = math.max(0, height - 4)
        maxScroll = math.max(0, #rows - body)
        scroll = math.min(scroll, maxScroll)
        local frame = {}
        for y = 1, height do frame[y] = { text = "", color = colors.white } end
        local function put(y, value, color)
            if y < 1 or y > height then return end
            frame[y] = { text = safeText(value, width):sub(1, width), color = color or colors.white }
        end
        put(1, "AMARYLLIS #" .. tostring(os.getComputerID()) .. " " .. safeText(os.getComputerLabel()), colors.cyan)
        if height >= 2 then
            put(2, page == "STATUS" and "[1 status]  2 logs" or "1 status  [2 logs]", colors.cyan)
        end
        for index = 1, body do put(index + 2, rows[index + scroll] or "") end
        if height >= 3 then put(height, "1/2 switch  up/down scroll", colors.gray) end

        local oldX, oldY
        local savedText, savedBackground, savedBlink
        if type(term.getCursorPos) == "function" then
            local ok, x, y = pcall(term.getCursorPos)
            if ok then oldX, oldY = x, y end
        end
        if type(term.getTextColor) == "function" then
            local ok, value = pcall(term.getTextColor)
            if ok then savedText = value end
        end
        if type(term.getBackgroundColor) == "function" then
            local ok, value = pcall(term.getBackgroundColor)
            if ok then savedBackground = value end
        end
        if type(term.getCursorBlink) == "function" then
            local ok, value = pcall(term.getCursorBlink)
            if ok then savedBlink = value end
        end
        if type(term.setCursorBlink) == "function" then pcall(term.setCursorBlink, false) end
        for y = 1, height do
            local row, previous = frame[y], previousFrame and previousFrame[y] or nil
            if force or not previous or previous.text ~= row.text or previous.color ~= row.color then
                local text = row.text .. string.rep(" ", math.max(0, width - #row.text))
                term.setCursorPos(1, y)
                term.setBackgroundColor(colors.black)
                term.setTextColor(row.color)
                term.write(text)
            end
        end
        if savedText ~= nil then pcall(term.setTextColor, savedText) end
        if savedBackground ~= nil then pcall(term.setBackgroundColor, savedBackground) end
        if oldX ~= nil and oldY ~= nil then pcall(term.setCursorPos, oldX, oldY) end
        if savedBlink ~= nil and type(term.setCursorBlink) == "function" then
            pcall(term.setCursorBlink, savedBlink)
        end
        previousFrame, previousWidth, previousHeight = frame, width, height
    end
    local timer = os.startTimer(0.25)
    draw(true)
    while true do
        local event, value = os.pullEventRaw()
        if event == "terminate" then return end
        if event == "timer" and value == timer then
            timer = os.startTimer(0.25)
            draw(false)
        elseif event == "term_resize" then
            draw(true)
        elseif event == "char" and (value == "1" or value == "2") then
            local nextPage = value == "1" and "STATUS" or "LOGS"
            if nextPage ~= page or scroll ~= 0 then
                page, scroll = nextPage, 0
                draw(true)
            end
        elseif event == "key" and value == keys.up and scroll > 0 then
            scroll = scroll - 1
            draw(true)
        elseif event == "key" and value == keys.down and scroll < maxScroll then
            scroll = scroll + 1
            draw(true)
        end
    end
end

local function readInstallConfig()
    local id = os.getComputerID()
    if Console.isCore() then return { target_role = "core", core_id = Console.trustedCoreID() } end
    return readJson("/config.json")
end

-- @ama-summary: Load a role program with the current CraftOS environment and arguments.
local function loadProgram(path)
    local programEnv = _ENV
    if type(programEnv) ~= "table" and type(getfenv) == "function" then
        local envOK, currentEnv = pcall(getfenv, 1)
        if envOK then programEnv = currentEnv end
    end
    local loadOK, chunk, issue = pcall(loadfile, path, nil, programEnv)
    if not loadOK then return nil, chunk end
    if type(chunk) ~= "function" then return nil, issue end
    return chunk
end

-- @ama-summary: Start the installed package receiver or core package-service task.
local function runInstaller()
    local path = Console.isCore() and "/installer/server.lua" or "/installer.lua"
    local chunk, issue = loadProgram(path)
    if type(chunk) ~= "function" then
        reportError("Amaryllis installer could not load: " .. safeText(issue), "installer-load:" .. safeText(issue))
        return
    end
    local loaded, installer = pcall(chunk)
    if not loaded or type(installer) ~= "table" or type(installer.run) ~= "function" then
        reportError("Amaryllis installer could not start: " .. safeText(installer), "installer-start:" .. safeText(installer))
        return
    end
    local config, issue = readInstallConfig()
    if type(config) ~= "table" then
        reportError("Amaryllis bootstrap config is unavailable: " .. safeText(issue), "installer-config:" .. safeText(issue))
        return
    end
    -- @ama-summary: Run a component with logged completion and paced restart.
    local function supervise()
        while true do
            local ok, result, detail = pcall(installer.run, config)
            if not ok then
                reportError("Amaryllis installer fault: " .. safeText(result), "installer-run:" .. safeText(result))
            elseif result == false then
                reportError("Amaryllis installer stopped: " .. safeText(detail), "installer-stop:" .. safeText(detail))
            end
            os.sleep(2)
        end
    end
    local function monitorStatus()
        while true do
            observeInstallerStatus(os.__amaryllisDiagnostics)
            os.sleep(2)
        end
    end
    parallel.waitForAny(supervise, monitorStatus)
end

local function diagnosticsFileExists()
    if type(fs) ~= "table" or type(fs.exists) ~= "function" then return false end
    local ok, exists = pcall(fs.exists, DIAGNOSTICS_PATH)
    return ok and exists == true
end

-- @ama-summary: Start the installed diagnostic client with the current role identity.
local function runDiagnostics()
    if not diagnosticsFileExists() then
        print("Amaryllis diagnostic client is not installed on this computer.")
        return false
    end
    local chunk, issue = loadProgram(DIAGNOSTICS_PATH)
    if type(chunk) ~= "function" then
        reportError("Amaryllis diagnostic client could not load: " .. safeText(issue), "diagnostics-load:" .. safeText(issue))
        return false
    end
    local ok, result = pcall(chunk)
    if not ok then
        reportError("Amaryllis diagnostic client stopped: " .. safeText(result), "diagnostics-run:" .. safeText(result))
        return false, result
    end
    return true, result
end

-- @ama-summary: Append bounded terminal output to the role's console history.
local function recordConsole(capture, message, key)
    if type(capture) ~= "table" then return false end
    if type(capture.console) ~= "table" then capture.console = {} end
    local text = safeText(message, 512)
    local entryKey = type(key) == "string" and key ~= "" and safeText(key, 256) or text
    for index, entry in ipairs(capture.console) do
        if type(entry) == "table" and entry.key == entryKey then
            entry.at = os.clock()
            entry.timestamp = currentTimeLabel(entry.at)
            entry.text = text
            table.remove(capture.console, index)
            capture.console[#capture.console + 1] = entry
            return true
        end
    end
    capture.console[#capture.console + 1] = {
        at = os.clock(), timestamp = currentTimeLabel(), text = text, key = entryKey,
    }
    if #capture.console > 80 then table.remove(capture.console, 1) end
    return true
end

-- @ama-summary: Wrap terminal output methods to record the role's emitted text.
local function captureOutput(capture)
    local originalPrint, originalPrintError = print, printError
    local previousLogger = os.__amaryllisLog
    local capturedPrinters = os.__amaryllisCapturedPrinters
    if type(capturedPrinters) ~= "table" then
        capturedPrinters = {}
        os.__amaryllisCapturedPrinters = capturedPrinters
    end
    local function activeCapture()
        local current = os.__amaryllisDiagnostics
        if type(current) == "table" then return current end
        return capture
    end
    -- @ama-summary: Append a bounded record to the current event collection.
    local function record(...)
        local pieces = {}
        for index = 1, select("#", ...) do
            local ok, value = pcall(tostring, select(index, ...))
            pieces[#pieces + 1] = ok and value or "<unprintable>"
        end
        recordConsole(activeCapture(), table.concat(pieces, " "))
    end
    -- @ama-summary: Append a bounded component exception to console history.
    local function recordError(...)
        local pieces = {}
        for index = 1, select("#", ...) do
            local ok, value = pcall(tostring, select(index, ...))
            pieces[#pieces + 1] = ok and value or "<unprintable>"
        end
        local message = table.concat(pieces, " "):sub(1, 512)
        recordConsole(activeCapture(), message, message)
    end
    local function log(message, key)
        return recordConsole(activeCapture(), message, key)
    end
    local wrappedPrint, wrappedPrintError
    if not capturedPrinters[originalPrint] then
        wrappedPrint = function(...) record(...); return originalPrint(...) end
        capturedPrinters[wrappedPrint] = true
        print = wrappedPrint
    end
    if not capturedPrinters[originalPrintError] then
        wrappedPrintError = function(...) recordError(...); return originalPrintError(...) end
        capturedPrinters[wrappedPrintError] = true
        printError = wrappedPrintError
    end
    os.__amaryllisLog = log
    return function()
        if wrappedPrint and print == wrappedPrint then
            print = originalPrint
            capturedPrinters[wrappedPrint] = nil
        end
        if wrappedPrintError and printError == wrappedPrintError then
            printError = originalPrintError
            capturedPrinters[wrappedPrintError] = nil
        end
        if os.__amaryllisLog == log then os.__amaryllisLog = previousLogger end
    end, log
end

ensureDiagnosticsCapture = function()
    local capture = type(os.__amaryllisDiagnostics) == "table" and os.__amaryllisDiagnostics or {}
    if type(capture.console) ~= "table" then capture.console = {} end
    os.__amaryllisDiagnostics = capture
    captureOutput(capture)
    return capture
end

-- @ama-summary: Publish a component error to the current console issue scope.
reportError = function(message, key)
    local logger = os and os.__amaryllisLog
    if type(logger) == "function" then
        local ok, recorded = pcall(logger, message, key)
        if ok and recorded == true then return true end
    end
    pcall(printError, message)
    return false
end

-- @ama-summary: Read cached installer progress and report its state transitions.
observeInstallerStatus = function(capture)
    if type(capture) ~= "table" then return end
    local path = Console.isCore() and "/installer/install_status.json" or "/installer/status.json"
    local status = readJson(path)
    local state = type(status) == "table" and tostring(status.state or status.applicationState or "") or ""
    local failedState = state == "fault" or state == "failed" or state == "transfer_failed"
        or state == "configuration_error" or state == "recovery_required"
        or (type(status) == "table" and status.recoveryRequired == true)
    local fault
    if failedState then
        local detail = status.lastError or status.detail or status.applicationFault
        if type(detail) ~= "string" or detail == "" then detail = state end
        local reason = state .. ": " .. safeText(detail, 160)
        fault = { key = "installer-status:" .. state .. ":" .. safeText(detail, 160),
            text = "FAULT [installer] " .. reason, reason = reason }
    end
    local previous = capture.installerFault
    if previous and (not fault or previous.key ~= fault.key) then
        reportError("RECOVERED [installer] " .. previous.reason, "installer-recovery")
    end
    if fault and (not previous or previous.key ~= fault.key) then reportError(fault.text, fault.key) end
    capture.installerFault = fault
end
local function isNeutralRuntimeReason(reason)
    -- A new core session is a normal handoff state, not an operation failure.
    return type(reason) == "string" and reason:upper():gsub("[%s_%-]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        == "NEW CORE SESSION"
end

-- @ama-summary: Collect active faults from the current runtime components.
local function collectRuntimeFaults(runtime)
    local found = {}
    local function add(source, reason)
        if type(reason) ~= "string" and type(reason) ~= "number" then return end
        reason = safeText(reason, 384):gsub("^%s+", ""):gsub("%s+$", "")
        if reason == "" or reason == "--" or isNeutralRuntimeReason(reason) then return end
        local key = "runtime-fault:" .. source .. ":" .. reason
        found[key] = { source = source, reason = reason }
    end
    -- @ama-summary: Append the supplied cached status fields to the current diagnostic view.
    local function addValues(source, values)
        if type(values) == "string" or type(values) == "number" then
            add(source, values)
        elseif type(values) == "table" then
            if #values > 0 then
                for _, value in ipairs(values) do add(source, value) end
            else
                add(source, values.reason or values.error)
            end
        end
    end
    -- @ama-summary: Add a bounded status/log record to the current collection.
    local function addRecord(source, record)
        if type(record) ~= "table" then return end
        local before = 0
        for _ in pairs(found) do before = before + 1 end
        add(source, record.error)
        add(source, record.abortReason)
        add(source, record.lastApplyFault)
        add(source, record.lastCommandFault)
        add(source, record.bindingError)
        addValues(source, record.configErrors)
        addValues(source, record.faults)
        add(source, record.snapshot and record.snapshot.error)
        add(source, record.snapshot and record.snapshot.lastApplyFault)
        add(source, record.snapshot and record.snapshot.lastCommandFault)
        add(source, record.snapshot and record.snapshot.bindingError)
        addValues(source, record.snapshot and record.snapshot.configErrors)
        addValues(source, record.snapshot and record.snapshot.faults)
        if before == (function() local count = 0; for _ in pairs(found) do count = count + 1 end; return count end)() then
            add(source, record.faultSummary)
        end
    end

    if type(runtime) ~= "table" then return found end
    if type(runtime.components) == "table" then
        local names = {}
        for name in pairs(runtime.components) do names[#names + 1] = tostring(name) end
        table.sort(names)
        for _, name in ipairs(names) do addRecord(name, runtime.components[name]) end
    end
    addRecord("role", runtime)
    if next(found) == nil then
        addValues("role", runtime.faults)
        local snapshot = type(runtime.snapshot) == "table" and runtime.snapshot or nil
        if snapshot then
            add("role", snapshot.error)
            addValues("role", snapshot.faults)
        end
        add("role", runtime.faultSummary)
    end
    return found
end

-- @ama-summary: Record changed runtime issues and clear recovered issue scopes.
local function observeRuntimeFaults(runtime, capture, logger)
    local current = collectRuntimeFaults(runtime)
    local previous = type(capture.runtimeFaults) == "table" and capture.runtimeFaults or {}
    local keys = {}
    for key in pairs(current) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local fault = current[key]
        if not previous[key] then
            local message = "FAULT [" .. fault.source .. "] " .. fault.reason
            if type(logger) == "function" then logger(message, key)
            else recordConsole(capture, message, key) end
        end
    end
    local previousKeys = {}
    for key in pairs(previous) do previousKeys[#previousKeys + 1] = key end
    table.sort(previousKeys)
    for _, key in ipairs(previousKeys) do
        if not current[key] then
            local fault = previous[key]
            local message = "RECOVERED [" .. fault.source .. "] " .. fault.reason
            local recoveryKey = "runtime-recovery:" .. fault.source
            if type(logger) == "function" then logger(message, recoveryKey)
            else recordConsole(capture, message, recoveryKey) end
        end
    end
    capture.runtimeFaults = current
end

Console._test = {
    captureOutput = captureOutput,
    ensureDiagnosticsCapture = ensureDiagnosticsCapture,
    observeInstallerStatus = observeInstallerStatus,
    observeRuntimeFaults = observeRuntimeFaults,
}

-- @ama-summary: Verify the committed installation receipt for this role and computer.
local function receiptReady(config)
    if Console.isCore() then return fs.exists(APP_PATH), nil end
    local install = type(config) == "table" and config.install or nil
    if not fs.exists(APP_PATH) or type(install) ~= "table" then return false, "waiting for installed role package" end
    local target = readJson("/config.json")
    local role = type(target) == "table" and (target.target_role or target.role) or nil
    if role == "auto" or role == nil then role = type(install) == "table" and install.role or nil end
    local localID = os.getComputerID()
    if install.protocol ~= INSTALL_PROTOCOL or install.coreID ~= Console.trustedCoreID()
        or install.role ~= role or install.computerID ~= localID
        or type(install.packageId) ~= "string" or not isInteger(install.version) or install.version < 2
        or not validLabel(install.label) or type(install.manifestChecksum) ~= "string"
        or type(install.installID) ~= "string" or not validToken(install.clientSession)
        or not validToken(install.serverSession) or not validToken(install.coreSession)
        or fs.exists("/installer/commit.json") or fs.exists("/installer/commit.json.bak")
        or fs.exists("/installer/commit.json.tmp") then
        return false, "installed package receipt is invalid or recovery is pending"
    end
    -- A committed local package can discover and sample its own peripherals
    -- before core is online. Live registry/session checks remain at the radio
    -- command and role-status boundaries, not at local program startup.
    local status = readJson("/installer/status.json")
    if type(status) ~= "table" or status.hasInstalled ~= true or status.recoveryRequired == true
        or status.state == "committing" or status.state == "recovery_required"
        or status.installedRole ~= install.role
        or status.installedPackageId ~= install.packageId or status.installedVersion ~= install.version
        or status.installedManifestChecksum ~= install.manifestChecksum
        or status.installedLabel ~= install.label or status.installedComputerID ~= localID then
        return false, "installed package receipt is not committed"
    end
    if status.installedCoreID ~= install.coreID or status.installedRole ~= install.role
        or tostring(status.installedInstallID) ~= tostring(install.installID)
        or status.installedClientSession ~= install.clientSession
        or status.installedServerSession ~= install.serverSession
        or status.installedCoreSession ~= install.coreSession then
        return false, "installed package identity does not match its receipt"
    end
    os.__amaryllisIdentity = { role = install.role, computerID = localID, label = install.label,
        coreID = install.coreID, packageId = install.packageId, version = install.version }
    return true, install
end

Console._test.receiptReady = receiptReady

-- @ama-summary: Open the configured modems for role registry and status traffic.
local function openNetwork()
    if not peripheral or not rednet or type(peripheral.getNames) ~= "function" then return false end
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return false end
    local opened = false
    for _, name in ipairs(names) do
        local typeOK, kind = pcall(peripheral.getType, name)
        if typeOK and kind=="modem" then
            local wrapped,modem=pcall(peripheral.wrap,name)
            local checked,wireless=false,nil
            if wrapped and type(modem)=="table" and type(modem.isWireless)=="function" then checked,wireless=pcall(modem.isWireless) end
            if checked and wireless==true then
                local ok,result=pcall(rednet.open,name);if ok and result~=false then opened=true end
            elseif checked and wireless==false then pcall(rednet.close,name) end
        end
    end
    return opened
end
Console._test.openNetwork=openNetwork

-- @ama-summary: Start the installed role program after identity and receipt verification.
local function roleRuntime()
    if multishell and multishell.setTitle and multishell.getCurrent then
        pcall(multishell.setTitle, multishell.getCurrent(), Console.isCore() and "core monitor" or "runtime")
    end
    local capture = ensureDiagnosticsCapture()
    capture.running = false
    capture.startedAt = capture.startedAt or os.clock()
    capture.boot = tostring(os.getComputerID()) .. "-" .. string.format("%.0f", os.epoch and os.epoch("utc") or os.clock() * 1000)
    local restorePrint, logRuntime = captureOutput(capture)
    local target = readJson("/config.json")
    local role = type(target) == "table" and target.target_role or nil
    local coreID = Console.trustedCoreID()
    local sequence = 0

    -- @ama-summary: Receive and publish the role's current fleet registry and health reports.
    local function registryPump()
        openNetwork()
        local lastRequest = -math.huge
        while true do
            local now = os.clock()
            if now - lastRequest >= 3 then
                requestRegistry(coreID, capture.boot)
                lastRequest = now
            end
            local sender, message, protocol = rednet.receive(PROTOCOL, 1)
            if not Console.isCore() and sender == coreID and type(message) == "table"
                and message.kind == "fleet_registry" then
                Console.acceptRegistry(sender, message, protocol, role, os.getComputerID(), coreID)
                local installed = readJson("/avionics/config.json")
                if type(installed) == "table" and type(installed.install) == "table"
                    and not receiptReady(installed) then return "identity changed" end
            end
        end
    end
    -- @ama-summary: Wait for the configured installation and identity prerequisites.
    local function waitReady()
        while true do
            local config = readJson("/avionics/config.json")
            local ready, details = receiptReady(config)
            if ready then capture.waitReason=nil;return config end
            capture.waitReason = details
            os.sleep(0.5)
        end
    end

    local config
    if Console.isCore() then
        config = readJson("/avionics/config.json") or {}
    else
        local readyConfig
        parallel.waitForAny(function() readyConfig = waitReady() end, registryPump)
        config = readyConfig or readJson("/avionics/config.json") or {}
    end

    if not Console.isCore() and type(config.install) == "table" then
        local labelOK, labelResult = pcall(os.setComputerLabel, config.install.label)
        if not labelOK or labelResult == false then
            reportError("Could not apply registry label", "runtime-label:" .. tostring(config.install.label))
        end
    end

    local function currentReceiptKey(value)
        local install = type(value) == "table" and value.install or nil
        if type(install) ~= "table" then return nil end
        return table.concat({ tostring(install.role), tostring(install.packageId), tostring(install.version),
            tostring(install.manifestChecksum), tostring(install.label), tostring(install.computerID) }, "|")
    end

    while true do
        local ready, install = receiptReady(config)
        if not Console.isCore() and not ready then
            local readyConfig
            parallel.waitForAny(function() readyConfig = waitReady() end, registryPump)
            config = readyConfig or readJson("/avionics/config.json") or {}
        else
            local appRunning, reason = false, nil
            local installKey = currentReceiptKey(config)
            -- @ama-summary: Run the role's supervised application task.
            local function appTask()
                capture.running = true
                appRunning = true
                local callOK, result = pcall(shell.run, APP_PATH)
                appRunning = false
                capture.running = false
                local runtime = os.__amaryllisRuntime
                observeRuntimeFaults(runtime, capture, logRuntime)
                if type(runtime) == "table" then runtime.running = false end
                if not callOK then
                    capture.lastFault = safeText(result)
                    reportError("Role program failed: " .. safeText(result), "role-program:" .. safeText(result))
                elseif result == false then
                    capture.lastFault = "role program returned an error"
                    reportError(capture.lastFault, "role-program:" .. capture.lastFault)
                else capture.lastFault = "role program stopped"; print("Role program stopped.") end
                if not Console.isCore() then
                    sequence = sequence + 1
                    local status = Console.roleStatus(install, capture, os.__amaryllisRuntime, sequence)
                    if status then status.running = false; pcall(rednet.send, install.coreID, status, PROTOCOL) end
                end
                reason = "app stopped"
            end
            -- @ama-summary: Publish cached role health and refresh its terminal status.
            local function statusTask()
                local nextStatusAt = 0
                while true do
                    observeRuntimeFaults(os.__amaryllisRuntime, capture, logRuntime)
                    local now = os.clock()
                    if appRunning and not Console.isCore() and now >= nextStatusAt then
                        sequence = sequence + 1
                        local status = Console.roleStatus(install, capture, os.__amaryllisRuntime, sequence)
                        if status then pcall(rednet.send, install.coreID, status, PROTOCOL) end
                        nextStatusAt = now + 2
                    end
                    os.sleep(0.5)
                end
            end
            -- @ama-summary: Handle the current role's program reload request.
            local function reloadTask()
                while true do
                    local event, first = os.pullEventRaw()
                    if event == "amaryllis_install_committed" then
                        local fresh = readJson("/avionics/config.json")
                        local currentReady = Console.isCore() and fs.exists(APP_PATH) or receiptReady(fresh)
                        if currentReady and currentReceiptKey(fresh) ~= installKey then reason = "package updated"; return end
                    elseif event == "amaryllis_registry_changed" then
                        local fresh = readJson("/avionics/config.json")
                        if not Console.isCore() and not receiptReady(fresh) then reason = "registry assignment changed"; return end
                    elseif event == "terminate" then
                        -- Keep the role supervisor alive if the visible shell tab receives terminate.
                        -- The app task lives in a different tab, so consuming this event keeps it running.
                    end
                end
            end
            local tasks = { appTask, statusTask, reloadTask }
            if not Console.isCore() then tasks[#tasks + 1] = registryPump end
            parallel.waitForAny(table.unpack(tasks))
            if reason == "package updated" or reason == "registry assignment changed" then
                config = readJson("/avionics/config.json") or {}
            else
                if not Console.isCore() then openNetwork() end
                os.sleep(1)
                config = readJson("/avionics/config.json") or {}
            end
        end
    end
    restorePrint()
end
local function openTab(arguments, title)
    local ok, tab = pcall(shell.openTab, "/startup.lua", table.unpack(arguments))
    if not ok or type(tab) ~= "number" then return nil, safeText(tab) end
    if multishell and multishell.setTitle then pcall(multishell.setTitle, tab, title) end
    return tab
end

-- @ama-summary: Find an existing diagnostic task in the terminal host.
local function diagnosticsTabExists()
    if type(multishell) ~= "table" or type(multishell.getCount) ~= "function"
        or type(multishell.getTitle) ~= "function" then return false end
    local ok, count = pcall(multishell.getCount)
    if not ok or type(count) ~= "number" then return false end
    for tab = 1, count do
        local titleOK, title = pcall(multishell.getTitle, tab)
        if titleOK and type(title) == "string" and title:lower() == "diagnostics" then return true end
    end
    return false
end

-- @ama-summary: Start or focus the role's diagnostic task.
local function openDiagnosticsTab()
    if not diagnosticsFileExists() then return false end
    if type(os) == "table" and os.__amaryllisDiagnosticTabLaunched == true then return true end
    if diagnosticsTabExists() then
        if type(os) == "table" then os.__amaryllisDiagnosticTabLaunched = true end
        return true
    end
    local tab, issue = openTab({ "diagnostics" }, "diagnostics")
    if tab then
        if type(os) == "table" then os.__amaryllisDiagnosticTabLaunched = true end
        return true
    end
    reportError("Could not open diagnostics tab: " .. safeText(issue), "diagnostics-tab:" .. safeText(issue))
    return false
end

-- @ama-summary: Build the available diagnostic pages for the current role.
function Console.pages(role)
    if type(role)=="string" and role:match("^thrust%-") then return {"OVERVIEW","PROPULSION","HARDWARE","LOGS","INSTALLER","UTILITIES"} end
    if role=="core" then return {"OVERVIEW","FLEET","LIFT","PROPULSION","NAVIGATION","LOGS","INSTALLER","UTILITIES"} end
    if role=="navigator" then return {"OVERVIEW","BRIDGE","FLEET","LOGS","INSTALLER","UTILITIES"} end
    if type(role)=="string" and (role:match("^heading") or role:match("^primary")) then
        return {"OVERVIEW","HARDWARE","LOGS","INSTALLER","UTILITIES"}
    end
    return {"OVERVIEW","LIFT","PROPULSION","HARDWARE","LOGS","INSTALLER","UTILITIES"}
end

-- @ama-summary: Format the rows for a selected role diagnostic page.
function Console.pageRows(page,role,capture,runtime,installer,now)
    runtime=type(runtime)=="table" and runtime or {}
    local snapshot=type(runtime.snapshot)=="table" and runtime.snapshot or {}
    local components=type(runtime.components)=="table" and runtime.components or {}
    local rows={}
    local function row(label,value) rows[#rows+1]=label..": "..safeText(value==nil and "--" or value,180) end
    -- @ama-summary: Format the selected computer's cached status and issue details.
    local function details(value,prefix,depth)
        if type(value)~="table" then row(prefix,value);return end
        local statusFields={ready=true,armed=true,localReady=true,statusReady=true,commandReady=true,
            statusCommandReady=true,startReady=true,systemsStartReady=true,systemsProbeReady=true}
        local hasState=value.liftControlState~=nil or value.thrustControlState~=nil
        local names={};for key in pairs(value) do
            if not (hasState and statusFields[key]) then names[#names+1]=key end
        end
        table.sort(names,function(a,b) return tostring(a)<tostring(b) end)
        for _,key in ipairs(names) do
            local item=value[key];local label=key=="thrustControlState" and "THRUST" or (key=="liftControlState" and "LIFT" or tostring(key))
            local name=prefix=="" and label or prefix.." / "..label
            if type(item)=="table" then
                if depth<3 then details(item,name,depth+1) end
            elseif type(item)~="function" and type(item)~="userdata" then row(name,item) end
        end
    end
    if page=="LOGS" then return Console.rows("LOGS",capture,runtime,installer,now) end
    if page=="OVERVIEW" then
        row("Computer",os.getComputerID().." "..safeText(os.getComputerLabel()))
        row("Role",role);row("Program",capture and capture.running and "RUNNING" or "WAITING")
        row("Hardware",runtime.hardwareAvailable and "AVAILABLE" or "UNAVAILABLE")
        if role=="core" then
            for _,name in ipairs({"vessel","fallback","assembler","cockpit","assembly"}) do
                local sample=(runtime.sampling or {})[name] or {}
                row(name.." reader",sample.phase or "NOT STARTED")
                if sample.lastError then row(name.." read error",sample.lastError) end
            end
        end
        if runtime.publishedAt then row("Sample age",string.format("%.1fs",math.max(0,now-runtime.publishedAt))) end
        local systems=snapshot.systemsStartup or {};local vessel=snapshot.vessel or {}
        if role=="core" or role=="navigator" then
            row("Flight",systems.phase);row("Altitude",vessel.altitude);row("Selected Y",(snapshot.targets or {}).altitude)
            row("Propulsion",(snapshot.thrust or {}).reason or (snapshot.thrust or {}).available)
            row("Autopilot",(snapshot.autopilot or {}).state);row("Anchor",(snapshot.anchorControl or {}).state)
        else
            for _,name in ipairs({"lift","thrust"}) do
                local component=components[name]
                if type(component)=="table" then
                    row(name.." running",component.running);row(name.." hardware",component.hardwareAvailable)
                    local state=component.snapshot or {}
                    row(name.." issue",component.faultSummary or state.reason or
                        (component.faults and component.faults[1]) or "NONE")
                    if name=="lift" then
                        row("THRUST",state.thrustControlState or "FAULT");row("LIFT",state.liftControlState or "FAULT");row("Core session",state.session)
                    else row("THRUST",component.controlState or state.thrustControlState or "FAULT");row("Last command",state.lastReceivedSeq) end
                end
            end
        end
        row("Current issue",faultSummary(runtime,capture))
        if capture and capture.waitReason then row("Waiting",capture.waitReason) end
    elseif page=="UTILITIES" then
        rows={"[S] Open shell", "[L] Open Lua", "[D] Diagnostic client"}
        if role=="core" then rows[#rows+1]="[F] Fleet setup / detailed core view" end
        if role=="core" then rows[#rows+1]="[R] Install / pair remote" end
        if role=="core" then rows[#rows+1]="[O] Remote flight access" end
        if role:match("^chamber_") then rows[#rows+1]="[H] Edit chamber hardware JSON" end
        rows[#rows+1]="";rows[#rows+1]="Utilities open in separate tabs."
        rows[#rows+1]="Control and installer workers stay running."
    elseif page=="INSTALLER" then details(installer or {},"Installer",0)
    elseif page=="FLEET" then
        local registry=os.__amaryllisFleetRegistry or {}
        details(snapshot.computers or snapshot.roleHealth or registry.computers or {},"",0)
    elseif page=="LIFT" then
        details(role=="core" and {systems=snapshot.systemsStartup,control=snapshot.altitudeControl,chambers=snapshot.nodes} or
            (components.lift and components.lift.snapshot) or components.lift or runtime,"Lift",0)
    elseif page=="PROPULSION" then details(snapshot.thrust or
        (components.thrust and components.thrust.snapshot) or components.thrust or {},"Propulsion",0)
    elseif page=="NAVIGATION" then details({autopilot=snapshot.autopilot,anchor=snapshot.anchorControl},"",0)
    elseif page=="BRIDGE" then
        row("Core data fresh",snapshot.dataFresh);row("Monitor available",runtime.hardwareAvailable)
        row("Current page",snapshot.page);details(snapshot.cockpitControl or {},"Controls",0)
    else details(components,"Hardware",0) end
    if #rows==0 then rows[1]="Waiting for current telemetry." end
    return rows
end

-- @ama-summary: Render fleet program, hardware and issue status from cached reports.
function Console.dashboard()
    local config=installedConfig() or {}
    local role=Console.isCore() and "core" or (config.install or {}).role or config.role or "unassigned"
    local pages=Console.pages(role);local index=1;local offsets={};local anchors={}
    local page,scroll,maxScroll=pages[1],0,0
    local previous={};local links={};local issueRow
    local function choose(nextIndex)
        offsets[page]=scroll;index=(nextIndex-1)%#pages+1;page=pages[index];scroll=offsets[page] or 0;previous={}
    end
    -- @ama-summary: Render the current view into its configured terminal or monitor.
    local function draw(preserveAnchor)
        local width,height=term.getSize();local now=os.clock()
        local capture=os.__amaryllisDiagnostics or {};local runtime=os.__amaryllisRuntime or {}
        local installer=readJson(Console.isCore() and "/installer/install_status.json" or "/installer/status.json")
        local raw=Console.pageRows(page,role,capture,runtime,installer,now)
        local rows=wrapLogRows(raw,width)
        -- Keep the first visible log entry fixed when old entries roll out.
        if preserveAnchor and page=="LOGS" and scroll>0 and anchors[page] then
            for at,text in ipairs(rows) do if text==anchors[page] then scroll=at-1;break end end
        end
        local body=math.max(0,height-5);maxScroll=math.max(0,#rows-body);scroll=math.min(scroll,maxScroll)
        anchors[page]=rows[scroll+1]
        local frame={};for y=1,height do frame[y]={"",colors.white} end
        local function put(y,text,tone) if y>=1 and y<=height then frame[y]={safeText(text,width):sub(1,width),tone or colors.white} end end
        put(1,"AMARYLLIS / "..role.." #"..os.getComputerID(),colors.cyan)
        put(2,"[<] "..page.." "..index.."/"..#pages.." [>]",colors.cyan)
        local issue=faultSummary(runtime,capture);issueRow=issue and issue~="" and issue~="none" and issue~="--"
        put(3,"ISSUE: "..safeText(issue),issueRow and colors.yellow or colors.gray)
        for at=1,body do put(at+3,rows[scroll+at] or "") end
        links={};local nav=""
        for i,name in ipairs(pages) do
            local label=tostring(i)..":"..name:sub(1,3).." "
            if #nav+#label<=width then links[#links+1]={first=#nav+1,last=#nav+#label,index=i};nav=nav..label end
        end
        put(height-1,nav,colors.cyan);put(height,"1-"..#pages.." pages | arrows | up/down scroll",colors.gray)
        term.setCursorBlink(false)
        for y=1,height do
            local text,tone=frame[y][1],frame[y][2]
            if not previous[y] or previous[y][1]~=text or previous[y][2]~=tone then
                term.setCursorPos(1,y);term.setBackgroundColor(colors.black);term.setTextColor(tone)
                term.write(text..string.rep(" ",math.max(0,width-#text)))
            end
        end
        previous=frame
    end
    local timer
    -- @ama-summary: Run the selected local console utility.
    local function utility(key)
        local mode=({s="shell",l="lua",d="diagnostics",f="fleet",h="hardware",r="remote-install",o="remote-ops"})[key]
        if not mode or ((mode=="fleet" or mode=="remote-install" or mode=="remote-ops") and role~="core") or (mode=="hardware" and not role:match("^chamber_")) then return end
        if type(shell.openTab)~="function" then
            reportError("Separate tabs require CraftOS multishell", "utility-tabs-unavailable")
            return
        end
        local tab,issue=openTab({mode},mode)
        if tab and multishell and multishell.setFocus then multishell.setFocus(tab)
        elseif not tab then reportError("Could not open utility tab: "..safeText(issue),"utility-tab") end
        previous={};timer=os.startTimer(.25)
    end
    timer=os.startTimer(.25);draw()
    while true do
        local event,a,b,c=os.pullEventRaw()
        local refresh=event=="timer" and a==timer
        if event=="timer" and a==timer then timer=os.startTimer(.25)
        elseif event=="char" then
            local number=tonumber(a)
            if number and pages[number] then choose(number)
            elseif page=="UTILITIES" then pcall(utility,a);previous={} end
        elseif event=="key" then
            if a==keys.left then choose(index-1) elseif a==keys.right then choose(index+1)
            elseif a==keys.up then scroll=math.max(0,scroll-1)
            elseif a==keys.down then scroll=math.min(maxScroll,scroll+1)
            elseif a==keys.pageUp then scroll=math.max(0,scroll-5)
            elseif a==keys.pageDown then scroll=math.min(maxScroll,scroll+5) end
        elseif event=="mouse_scroll" then scroll=math.max(0,math.min(maxScroll,scroll+a))
        elseif event=="mouse_click" then
            local width,height=term.getSize()
            if c==2 then if b<=3 then choose(index-1) else choose(index+1) end
            elseif c==height-1 then for _,link in ipairs(links) do if b>=link.first and b<=link.last then choose(link.index);break end end
            elseif page=="UTILITIES" and c>=4 and c<height-1 then
                local key=previous[c] and previous[c][1]:match("^%[([A-Z])%]")
                if key then pcall(utility,key:lower());previous={} end
            elseif c==3 and issueRow then
                for i,name in ipairs(pages) do if name=="LOGS" then choose(i);break end end
            end
        elseif event=="term_resize" then previous={} end
        -- Ctrl+T returns from utilities but never closes the dashboard.
        if refresh or event=="char" or event=="key" or
            event=="mouse_scroll" or event=="mouse_click" or event=="term_resize" or event=="terminate" then draw(refresh) end
    end
end

-- BEGIN POCKET ADMIN RECEIVER
-- Embedded in the common console so package updates keep remote management available.
-- @ama-summary: BEGIN POCKET ADMIN RECEIVER Embedded in the common console so package updates keep remote management available.
function Console.remoteManager()
    local protocol = "amaryllis.admin.v1"
    local cfg = readJson("/amaryllis-admin.json")
    if type(cfg) ~= "table" or type(cfg.token) ~= "string" or #cfg.token < 32
        or not isInteger(cfg.adminID) then
        while true do os.pullEventRaw("amaryllis_admin_disabled") end
    end
    local boot = tostring(os.getComputerID()) .. ":" .. tostring(os.epoch("utc")) .. ":" .. tostring(math.random(1,2147483647))
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name,"modem") then
            local ok,modem=pcall(peripheral.wrap,name)
            local checked,wireless=false,nil
            if ok and type(modem)=="table" and type(modem.isWireless)=="function" then checked,wireless=pcall(modem.isWireless) end
            if checked and wireless==true then pcall(rednet.open,name)
            elseif checked and wireless==false then pcall(rednet.close,name) end
        end
    end
    local seen, order = {}, {}
    local function raw(path)
        if not fs.exists(path) or fs.isDir(path) then return nil end
        if fs.getSize(path) > 48000 then error("File exceeds the 48 KB remote editor limit") end
        local h = assert(fs.open(path,"r")); local s = h.readAll(); h.close(); return s
    end
    local function checksum(s)
        if s == nil then return "missing" end
        local a,b=1,0
        for i=1,#s do a=(a+s:byte(i))%65521;b=(b+a)%65521 end
        return string.format("%08x",b*65536+a)
    end
    -- @ama-summary: Validate whether the current identity has permission for the selected operation.
    local function allowed(path)
        if type(path)~="string" or #path>180 or path:find("..",1,true) or path:find("//",1,true)
            or path:find("[^%w_/%-.]") then return false end
        if path=="/config.json" or path=="/fleet.json" then return true end
        -- Receipts, transaction journals, and credentials are never editable remotely.
        if path:match("^/avionics/data/[%w_-]+%.json$") then return true end
        if path=="/avionics/config.json" then return true end
        if path:match("^/avionics/[%w_/-]+%.lua$") then return true end
        if Console.isCore() and path:match("^/packages/[%w_/-]+%.lua$") then return true end
        if Console.isCore() and path:match("^/packages/[%w_/-]+%.json$") then return true end
        return false
    end
    -- @ama-summary: Build the selected cached runtime status view.
    local function status()
        local installer=readJson(Console.isCore() and "/installer/install_status.json" or "/installer/status.json") or {}
        local runtime=os.__amaryllisRuntime or {}
        local capture=os.__amaryllisDiagnostics or {}
        local config=installedConfig() or {}
        local role=Console.isCore() and "core" or (config.install or {}).role or config.role or "unassigned"
        local pages={}
        for _,page in ipairs(Console.pages(role)) do
            if page~="UTILITIES" then
                local rows=Console.pageRows(page,role,capture,runtime,installer,os.clock())
                pages[page]={}
                for i=math.max(1,#rows-39),#rows do pages[page][#pages[page]+1]=tostring(rows[i]):sub(1,140) end
            end
        end
        return {id=os.getComputerID(),label=os.getComputerLabel(),role=role,installer=installer,pages=pages}
    end
    -- @ama-summary: List the permitted installed files for the current role.
    local function files()
        local result={}
        local function scan(path,depth)
            if #result>=250 or depth>6 or not fs.exists(path) then return end
            if fs.isDir(path) then
                for _,name in ipairs(fs.list(path)) do scan("/"..fs.combine(path,name):gsub("^/",""),depth+1) end
            elseif allowed(path) then result[#result+1]=path end
        end
        scan("/config.json",0);scan("/fleet.json",0);scan("/avionics",0)
        if Console.isCore() then scan("/packages",0) end
        table.sort(result);return result
    end
    -- @ama-summary: Validate the selected operation and dispatch its registered handler.
    local function execute(p)
        if p.action=="status" then return status() end
        if p.action=="files" then return files() end
        if p.action=="read" then
            assert(allowed(p.path),"This path is not remotely editable")
            local s=raw(p.path);return {text=s or "",checksum=checksum(s),exists=s~=nil}
        end
        if p.action=="write" then
            assert(allowed(p.path),"This path is not remotely editable")
            assert(type(p.text)=="string" and #p.text<=48000,"Invalid file size")
            assert(checksum(raw(p.path))==p.checksum,"File changed since download; reload it before saving")
            if p.path:match("%.json$") then
                assert(type(textutils.unserializeJSON(p.text))=="table","Invalid JSON: expected an object or array")
            else
                local chunk,issue=load(p.text,"@"..p.path,"t",_ENV);assert(chunk,issue)
            end
            local tmp=p.path..".admin-tmp";local bak=p.path..".admin-backup"
            fs.makeDir(fs.getDir(p.path))
            local h=assert(fs.open(tmp,"w"));h.write(p.text);h.close()
            if fs.exists(p.path) then
                if fs.exists(bak) then fs.delete(bak) end
                fs.copy(p.path,bak);fs.delete(p.path)
            end
            local ok,issue=pcall(fs.move,tmp,p.path)
            if not ok then
                if fs.exists(bak) and not fs.exists(p.path) then fs.copy(bak,p.path) end
                error(issue)
            end
            return {message="Saved. Reboot to reload runtime configuration.",checksum=checksum(p.text)}
        end
        if p.action=="reinstall" then
            assert(not Console.isCore(),"Core is the package server; edit its sources instead")
            fs.makeDir("/installer");local h=assert(fs.open("/installer/reinstall","w"));h.write("pocket request");h.close()
            return {message="Reinstall requested; watch Installer for commit."}
        end
        if p.action=="reboot" then return {message="Reboot accepted"} end
        error("Unsupported management action")
    end
    while true do
        local _,sender,p,wire=os.pullEventRaw("rednet_message")
        if sender==cfg.adminID and wire==protocol and type(p)=="table" and p.v==1
            and p.token==cfg.token and type(p.requestID)=="string" and #p.requestID<=100
            and type(p.sentAt)=="number" and math.abs(os.epoch("utc")-p.sentAt)<15000 then
            if p.action=="hello" then
                rednet.send(sender,{v=1,requestID=p.requestID,boot=boot,ok=true,id=os.getComputerID()},protocol)
            elseif p.boot==boot then
                local prior=seen[p.requestID]
                if prior then rednet.send(sender,prior,protocol)
                else
                    local ok,data=pcall(execute,p)
                    local reply={v=1,requestID=p.requestID,boot=boot,ok=ok,data=ok and data or nil,error=not ok and tostring(data) or nil}
                    seen[p.requestID]=reply;order[#order+1]=p.requestID
                    if #order>64 then seen[table.remove(order,1)]=nil end
                    rednet.send(sender,reply,protocol)
                    if ok and p.action=="reboot" then os.sleep(.2);os.reboot() end
                end
            end
        end
    end
end

-- END POCKET ADMIN RECEIVER

-- @ama-summary: END POCKET ADMIN RECEIVER
function Console.remoteService()
    if not Console.isCore() then error("Remote provisioning service is core-only",0) end
    require("avionics.remote_install").serve(function(page)
        local runtime=os.__amaryllisRuntime or {}
        local capture=os.__amaryllisDiagnostics or {}
        local rows=Console.pageRows(page,"core",capture,runtime,{},os.clock())
        local result={}
        for i=1,math.min(40,#rows) do result[i]=safeText(rows[i],140) end
        return {lines=result}
    end,function(sender,pair,packet)
        local bridge=os.__amaryllisRemoteAP
        if not bridge then error("Load updated core runtime for remote AP",0) end
        return bridge.request(sender,pair,packet)
    end)
end

-- @ama-summary: Display a bounded text collection with page navigation.
function Console.runPaged(runtimeTask,installerTask,consoleTask)
    local parent=term.current();local width,height=parent.getSize()
    os.__amaryllisPagedConsole=true
    local tasks={}
    -- @ama-summary: Append one bounded entry to the current view or record collection.
    local function add(name,fn,visible)
        local screen=window.create(parent,1,1,width,height,visible)
        tasks[#tasks+1]={name=name,screen=screen,visible=visible,thread=coroutine.create(function()
            while true do
                local ok,issue=pcall(fn)
                if not ok then reportError(name..": "..safeText(issue),"console-worker:"..name) end
                os.sleep(1)
            end
        end)}
    end
    add("runtime",runtimeTask or roleRuntime,false)
    add("installer",installerTask or runInstaller,false)
    add("console",consoleTask or Console.dashboard,true)
    if Console.isCore() then add("remote-status",Console.remoteService,false) end
    local adminConfig=readJson("/amaryllis-admin.json")
    if type(adminConfig)=="table" and type(adminConfig.token)=="string" and #adminConfig.token>=32 and isInteger(adminConfig.adminID) then
        add("remote-admin",Console.remoteManager,false)
    end
    local function resume(task,event)
        local saved=term.redirect(task.screen)
        local ok,filter=coroutine.resume(task.thread,table.unpack(event or {}))
        term.redirect(saved)
        if not ok then error("Console worker "..task.name..": "..tostring(filter),0) end
        task.filter=filter
    end
    for _,task in ipairs(tasks) do resume(task) end
    while true do
        local event={os.pullEventRaw()};local kind=event[1]
        if kind=="term_resize" then
            width,height=parent.getSize()
            for _,task in ipairs(tasks) do task.screen.reposition(1,1,width,height) end
        end
        local input=kind=="char" or kind=="key" or kind=="key_up" or kind=="paste" or
            kind=="mouse_click" or kind=="mouse_up" or kind=="mouse_drag" or kind=="mouse_scroll" or kind=="terminate"
        for _,task in ipairs(tasks) do
            if (task.visible or not input) and (not task.filter or task.filter==kind or kind=="terminate") then resume(task,event) end
        end
    end
end

-- @ama-summary: Start the role console, registry service and supervised application tasks.
function Console.start(arguments)
    arguments = arguments or {}
    ensureDiagnosticsCapture()
    if multishell and multishell.getCount and multishell.getTitle and multishell.setTitle then
        for tab = 1, multishell.getCount() do
            local title = multishell.getTitle(tab)
            if type(title) == "string" then pcall(multishell.setTitle, tab, title:lower()) end
        end
    end
    local mode = arguments[1]
    if mode == "remote-ops" then
        if not Console.isCore() then print("Remote flight access is available on core only.");return end
        require("avionics.remote_install").opsMenu();return
    end
    if mode == "remote-install" then
        if not Console.isCore() then print("Remote installation is available on core only.");return end
        -- Starts only the request-driven status service, never another flight runtime.
        if type(shell.openTab)=="function" then
            local tabs=os.__amaryllisCoreWorkerTabs or {};os.__amaryllisCoreWorkerTabs=tabs
            local existing=tabs["remote-status"]
            if not existing or not multishell or not multishell.getTitle or not multishell.getTitle(existing) then
                local tab,issue=openTab({"remote-status"},"remote status")
                if not tab then error("Remote status service could not start: "..tostring(issue),0) end
                tabs["remote-status"]=tab
            end
        end
        require("avionics.remote_install").run();return
    end
    if mode == "remote-status" then Console.remoteService();return end
    if mode == "shell" then
        if type(shell) == "table" and type(shell.run) == "function" then
            shell.run("/rom/programs/shell.lua")
        else
            reportError("CraftOS shell runner is unavailable", "shell-runner-unavailable")
        end
        return
    end
    if mode == "diagnostics" then runDiagnostics(); return end
    if mode == "hardware" then
        local path="/avionics/data/chamber-hardware.json"
        if fs.exists(path) then shell.run("/rom/programs/edit.lua",path)
        else print("Chamber hardware JSON is created when the updated chamber runtime starts.") end
        return
    end
    if mode == "lua" then shell.run("/rom/programs/lua.lua"); return end
    if mode == "fleet" then shell.run(APP_PATH,"monitor"); return end
    if mode == "logs" then Console.status("LOGS"); return end
    if mode == "status" then
        if Console.isCore() then roleRuntime() else Console.status(); end
        return
    end
    if mode == "role" then roleRuntime(); return end
    if mode == "installer" then runInstaller(); return end
    if mode == "remote-admin" then Console.remoteManager(); return end
    if type(shell)=="table" and type(shell.openTab)=="function" then
        openTab({"shell"},"shell")
        openDiagnosticsTab()
    end
    local roleConfig=readJson("/avionics/config.json") or {}
    if (Console.isCore() or type(roleConfig.relayChildRole)=="string") and type(multishell)=="table" and type(shell.openTab)=="function" then
        -- Let CraftOS own event queues for core workers. The visible dashboard
        -- must not relay timer/peripheral completion events to flight tasks.
        os.__amaryllisPagedConsole=true
        local launched=os.__amaryllisCoreWorkerTabs or {}
        os.__amaryllisCoreWorkerTabs=launched
        local function startWorker(mode,title)
            local previous=launched[mode]
            if previous and multishell.getTitle and multishell.getTitle(previous) then return true end
            local tab,issue=openTab({mode},title)
            if not tab then reportError("Could not start "..title..": "..safeText(issue),"core-tab:"..mode);return false end
            launched[mode]=tab;return true
        end
        local ready=startWorker("role",Console.isCore() and "core runtime" or "chamber runtime")
        ready=startWorker("installer","installer") and ready
        if Console.isCore() then ready=startWorker("remote-status","remote status") and ready end
        local adminConfig=readJson("/amaryllis-admin.json")
        if type(adminConfig)=="table" and type(adminConfig.token)=="string" and #adminConfig.token>=32 then
            ready=startWorker("remote-admin","remote manager") and ready
        end
        if not ready then error("Core background workers did not start; see logs",0) end
        Console.dashboard();return
    end
    Console.runPaged()
end

return Console
