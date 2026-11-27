-- Section: Heading display | Cached compass/altitude instruments and status reception.
-- Information heading labels v1
-- Wireless status receiver for one Amaryllis heading display.
-- Computer ID and display role come from local config.json; this computer
-- never sends commands and never writes to vessel hardware.
package.path = "/avionics/?.lua;/avionics/?/init.lua;" .. package.path

-- Section: Heading display | Cached compass/altitude instruments and status reception.
-- Summary: Read and validate the current role configuration.
local function loadConfig()
    local handle = fs.open("/avionics/config.json", "r")
    if not handle then error("Missing /avionics/config.json", 0) end
    local raw = handle.readAll()
    handle.close()
    local decode = textutils and textutils.unserializeJSON
    if type(decode) ~= "function" then error("JSON decoder is unavailable", 0) end
    local ok, value = pcall(decode, raw)
    if not ok or type(value) ~= "table" then
        error("Could not decode /avionics/config.json: " .. tostring(value), 0)
    end
    return value
end

local config = loadConfig()
local programEnv = _ENV
if type(programEnv) ~= "table" and type(getfenv) == "function" then
    local envOK, currentEnv = pcall(getfenv, 1)
    if envOK then programEnv = currentEnv end
end
local loadOK, consoleChunk, loadIssue = pcall(loadfile, "/avionics/common/console.lua", nil, programEnv)
if not loadOK or type(consoleChunk) ~= "function" then
    error("Could not load shared console: " .. tostring(loadOK and loadIssue or consoleChunk), 0)
end
local consoleOK, Console = pcall(consoleChunk)
if not consoleOK or type(Console) ~= "table" then
    error("Could not start shared console: " .. tostring(Console), 0)
end
local install = config.install
if config.schemaVersion ~= 1 then error("Unsupported heading config schema", 0) end
if type(config.computerId) ~= "number" or os.getComputerID() ~= config.computerId then
    error("This program/config is for computer " .. tostring(config.computerId) ..
        "; current computer is " .. tostring(os.getComputerID()), 0)
end
local allowedRoles = { ["heading-left"] = true, ["heading-right"] = true, ["heading-main"] = true }
local function validID(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value)
        and value < math.huge
end
if not allowedRoles[config.role] or not validID(config.coreId) then
    error("Heading config must use a registered heading role and valid core ID", 0)
end

if type(install) ~= "table" or install.packageId ~= "amaryllis.heading." .. tostring(config.display == "center" and "main" or config.display)
    or install.role ~= config.role or install.computerID ~= os.getComputerID() or not validID(install.coreID)
    or install.coreID ~= config.coreId or type(install.version) ~= "number" or install.version < 2
    or install.version ~= math.floor(install.version) then
    error("Heading install receipt is invalid", 0)
end
-- A missing core registry is transient. Render stale data while the event
-- loop waits for a valid binding; live data and commands remain registry-gated.
local protocol = config.protocol or "amaryllis.v1"
local timeout = config.statusTimeoutSeconds or 2.0
local pollInterval = config.refreshIntervalSeconds or 0.25
local latestState, receivedAt, activeSession, latestSequence
local retiredSessions = {}
local retiredSessionOrder = {}
local registryIdentity
-- Summary: Reconcile the current role identity with a trusted registry announcement.
local function syncRegistry()
    local registry=os.__amaryllisFleetRegistry
    local entry=type(registry)=="table" and registry.coreID==config.coreId and
        type(registry.computers)=="table" and registry.computers[config.role] or nil
    local key
    if type(entry)=="table" and entry.id==os.getComputerID() and entry.label==install.label and
        os.getComputerLabel()==install.label and type(registry.session)=="string" then
        key=table.concat({registry.session,config.role,tostring(entry.id),entry.label},"|")
    end
    if key~=registryIdentity then
        if activeSession then
            retiredSessions[activeSession]=true;retiredSessionOrder[#retiredSessionOrder+1]=activeSession
            if #retiredSessionOrder>32 then retiredSessions[table.remove(retiredSessionOrder,1)]=nil end
        end
        latestState,receivedAt,activeSession,latestSequence=nil,nil,nil,nil
    end
    registryIdentity=key
end
local renderer, monitorName
local lastMonitorError, lastDrawError, lastConsoleIssue

local roleForDisplay = { center = "heading-main", right = "heading-right", left = "heading-left" }
if roleForDisplay[config.display] ~= config.role then
    error("Display role does not match its package role", 0)
end
if config.computerLabel ~= install.label or install.label ~= os.getComputerLabel() then
    error("Configured computer label does not match the active registry receipt", 0)
end
if config.protocol ~= "amaryllis.v1" then error("Unsupported status protocol", 0) end
local function finite(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end
if not finite(timeout) or timeout <= 0 or timeout > 60 or
    not finite(pollInterval) or pollInterval < 0.1 or pollInterval > 5 then
    error("Invalid status timeout or refresh interval in config.json", 0)
end
local textScale = config.textScale or 0.5
if not finite(textScale) or textScale < 0.5 or textScale > 5 or (textScale * 2) % 1 ~= 0 then
    error("Monitor textScale must be a half-step from 0.5 through 5", 0)
end
local currentLabel = os.getComputerLabel and os.getComputerLabel()
if config.computerLabel and currentLabel ~= config.computerLabel then
    error("Computer label does not match config.json", 0)
end

local function safeRestartToken(value)
    return type(value)=="string" and #value>0 and #value<=128 and
        value:match("^[%w_%.%-:]+$")~=nil
end
-- Summary: Validate a requested reboot against the configured core, session and local boot.
local function validateRestart(sender,message,receivedProtocol,coreId,session,nodeBoot,targetLabel)
    if sender~=coreId or receivedProtocol~="amaryllis.v1" or type(message)~="table" or
        message.v~=1 or message.kind~="system_restart" then return false end
    if not safeRestartToken(message.session) or message.session~=session then return false end
    if not safeRestartToken(message.nodeBoot) or message.nodeBoot~=nodeBoot then return false end
    if type(message.targetLabel)~="string" or message.targetLabel~=targetLabel then return false end
    if not safeRestartToken(message.bootToken) or not safeRestartToken(message.requestId) then return false end
    return true
end
-- Summary: Acknowledge and execute the validated role restart request.
local function handleRestart(sender,message,receivedProtocol,context,sendAck,reboot)
    context=context or {seen={},order={}}
    context.seen=context.seen or {};context.order=context.order or {}
    if not validateRestart(sender,message,receivedProtocol,context.coreId,context.session,
        context.nodeBoot,context.targetLabel) or context.seen[message.requestId] then return false end
    local ack={v=1,kind="system_restart_ack",session=message.session,
        nodeBoot=message.nodeBoot,bootToken=message.bootToken,requestId=message.requestId,
        targetLabel=message.targetLabel,accepted=true,detail="RESTARTING"}
    local ok,result=pcall(sendAck,context.coreId,ack,"amaryllis.v1")
    if not ok or result~=true then return false end
    if type(context.getSession)=="function" then
        local sessionOk,currentSession=pcall(context.getSession)
        if not sessionOk or currentSession~=message.session then return false end
    end
    context.seen[message.requestId]=true
    context.order[#context.order+1]=message.requestId
    if #context.order>32 then context.seen[table.remove(context.order,1)]=nil end
    reboot()
    return true
end

-- The small local renderer keeps each heading computer self-contained. It
-- draws local monitor instruments and never imports or executes core code.
local colorValues = {
    white = 1, red = 16384, gray = 128, cyan = 512, yellow = 16, green = 32, black = 32768,
}
local colorDigits = {
    [1] = "0", [16] = "4", [32] = "5", [128] = "7", [512] = "9", [16384] = "e", [32768] = "f",
}
local function color(name)
    return type(colors) == "table" and colors[name] or colorValues[name]
end
-- Section: Text cells | Printable ASCII plus the delta and degree glyphs, one monitor cell each
-- Monitors render UTF-8 through the installed unicode mod. DELTA and DEGREE are
-- the two multi-byte glyphs this display writes; every other non-ASCII
-- character becomes "?".
local GLYPH = { DELTA = "\206\148", DEGREE = "\194\176" }
GLYPH.allowed = { [GLYPH.DELTA] = true, [GLYPH.DEGREE] = true }
-- Summary: Split text into monitor cells: printable ASCII and allowed glyphs as themselves, any other character as "?".
function GLYPH.cells(value)
    local text, cells, i = tostring(value or ""), {}, 1
    while i <= #text do
        local glyph = string.sub(text, i, i + 1)
        if GLYPH.allowed[glyph] then
            cells[#cells + 1] = glyph
            i = i + 2
        else
            local character = string.sub(text, i, i)
            cells[#cells + 1] = string.match(character, "^[\032-\126]$") and character or "?"
            local byte = string.byte(character)
            -- A multi-byte character outside the allowed set becomes one "?".
            i = i + 1
            if byte >= 194 and byte <= 244 then
                while i <= #text and string.byte(text, i) >= 128 and string.byte(text, i) <= 191 do i = i + 1 end
            end
        end
    end
    return cells
end
-- Summary: Replace characters outside printable ASCII and the allowed glyphs with "?".
local function safeText(value)
    return table.concat(GLYPH.cells(value))
end
-- Summary: Return the number of monitor cells the text occupies.
function GLYPH.width(text)
    return #GLYPH.cells(text)
end
local function finiteDisplay(value)
    return finite(value) and math.abs(value) <= 1000000000
end
local function shown(value, decimals, signed)
    if not finiteDisplay(value) then return "--" end
    if signed then return string.format("%+." .. decimals .. "f", value) end
    return string.format("%." .. decimals .. "f", value)
end
local function angle(value)
    if not finiteDisplay(value) then return nil end
    return value % 360
end
local function sensorValid(vessel, field)
    if not finiteDisplay(vessel[field]) then return false end
    if type(vessel.validFields) == "table" and vessel.validFields[field] == false then return false end
    if vessel[field .. "Valid"] == false then return false end
    return true
end
local function targetValid(targets, field)
    if not finiteDisplay(targets[field]) then return false end
    if type(targets.validFields) == "table" and targets.validFields[field] == false then return false end
    if targets[field .. "Valid"] == false then return false end
    return true
end
local function shownSensor(vessel, field, decimals, signed, stale)
    if stale or not sensorValid(vessel, field) then return "--" end
    return shown(vessel[field], decimals, signed)
end
-- Summary: Allocate a character-cell display surface with foreground and background colours.
local function makeSurface(width, height)
    local surface = { width = width, height = height, rows = {} }
    for y = 1, height do
        local row = { chars = {}, fg = {}, bg = {} }
        for x = 1, width do
            row.chars[x], row.fg[x], row.bg[x] = " ", color("white"), color("black")
        end
        surface.rows[y] = row
    end
    return surface
end
-- Summary: Write bounded text cells with the selected foreground colour.
local function put(surface, x, y, text, tone)
    if y < 1 or y > surface.height or x > surface.width then return end
    local cells = GLYPH.cells(text)
    local fg = color(tone or "white")
    for i = 1, #cells do
        local at = x + i - 1
        if at >= 1 and at <= surface.width then
            surface.rows[y].chars[at], surface.rows[y].fg[at] = cells[i], fg
        end
    end
end
local function center(surface, y, text, tone)
    local used = math.min(GLYPH.width(text), surface.width)
    put(surface, math.floor((surface.width - used) / 2) + 1, y, text, tone)
end
local function centerColumn(surface, x, width, y, text, tone)
    local cells = GLYPH.cells(text)
    local used = math.min(#cells, width)
    put(surface, x + math.floor((width - used) / 2), y, table.concat(cells, "", 1, used), tone)
end
-- Summary: Wrap message words to the available character width.
local function wrapWords(text, width)
    local lines, line = {}, ""
    for word in string.gmatch(text, "%S+") do
        while #word > width do
            if line ~= "" then lines[#lines + 1], line = line, "" end
            lines[#lines + 1] = string.sub(word, 1, width)
            word = string.sub(word, width + 1)
        end
        if line == "" then
            line = word
        elseif #line + 1 + #word <= width then
            line = line .. " " .. word
        else
            lines[#lines + 1], line = line, word
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end
-- Summary: Build a bounded error display surface for the current monitor.
local function errorSurface(width, height)
    local surface = makeSurface(width, height)
    if width < 1 or height < 1 then return surface end
    local lines = wrapWords("ERROR. View Console", width)
    local firstY = math.max(1, math.floor((height - #lines) / 2) + 1)
    for index, line in ipairs(lines) do
        local y = firstY + index - 1
        if y <= height then center(surface, y, line, "red") end
    end
    return surface
end
-- Assembly screen. Core's snapshot carries `assembly`; anything except
-- ASSEMBLED replaces the readings with a dedicated, wrapped message so the
-- crew sees why heading/altitude data is withheld. Detail also goes to the
-- terminal through the normal issue path.
local ASSEMBLY_TITLES = {
    DISASSEMBLED = "VESSEL DISASSEMBLED", ASSEMBLING = "VESSEL ASSEMBLING", UNKNOWN = "ASSEMBLY UNKNOWN",
}
local function assemblyProblem(snapshot)
    local assembly = type(snapshot.assembly) == "table" and snapshot.assembly or nil
    if not assembly or assembly.state == "ASSEMBLED" then return nil end
    return assembly
end
-- Summary: Render the current vessel assembly status and its blocked-operation context.
local function assemblySurface(width, height, assembly)
    local surface = makeSurface(width, height)
    local tone = assembly.state == "ASSEMBLING" and "yellow" or "red"
    local lines = wrapWords(ASSEMBLY_TITLES[assembly.state] or "ASSEMBLY UNKNOWN", width)
    local detail = {}
    if assembly.reason then detail = wrapWords(assembly.reason, width) end
    local footer = wrapWords("Flight control blocked", width)
    local function rowCount() return #lines + (#detail > 0 and #detail + 1 or 0) + (#footer > 0 and #footer + 1 or 0) end
    -- Small monitors keep the title first; detail stays on the terminal.
    if rowCount() > height then footer = {} end
    if rowCount() > height then detail = {} end
    local rows = rowCount()
    local y = math.max(1, math.floor((height - rows) / 2) + 1)
    for _, line in ipairs(lines) do if y <= height then center(surface, y, line, tone) end; y = y + 1 end
    if #detail > 0 then
        y = y + 1
        for _, line in ipairs(detail) do if y <= height then center(surface, y, line, "white") end; y = y + 1 end
    end
    if #footer > 0 then y = y + 1 end
    for _, line in ipairs(footer) do if y <= height then center(surface, y, line, "gray") end; y = y + 1 end
    return surface
end
-- Summary: Render cached fleet startup progress and the current role prerequisite.
local function fleetBootSurface(width,height,fleet)
    local surface=makeSurface(width,height)
    local failed=fleet.phase=="FAILED" or fleet.phase=="CANCELLED"
    local complete=fleet.phase=="COMPLETE"
    local tone=failed and "red" or (complete and "green" or "yellow")
    local title=failed and "STARTUP CHECK FAILED" or (complete and "STARTUP CHECK COMPLETE" or "STARTUP CHECK")
    local phase=type(fleet.phase)=="string" and string.sub(safeText(fleet.phase),1,64) or "WAITING"
    local progress="FLEET "..phase
    if finite(fleet.completed) and finite(fleet.total) then
        progress=progress.." "..tostring(math.floor(fleet.completed)).."/"..tostring(math.floor(fleet.total))
    end
    local lines={wrapWords(title,width),wrapWords(progress,width)}
    if type(fleet.current)=="string" and fleet.current~="" then lines[#lines+1]=wrapWords(string.sub(safeText(fleet.current),1,96),width) end
    if type(fleet.reason)=="string" and fleet.reason~="" then lines[#lines+1]=wrapWords(string.sub(safeText(fleet.reason),1,128),width) end
    local count=0;for _,group in ipairs(lines) do count=count+#group end
    local y=math.max(1,math.floor((height-count)/2)+1)
    for index,group in ipairs(lines) do
        for _,line in ipairs(group) do
            if y<=height then center(surface,y,line,index==1 and tone or (index==#lines and failed and "red" or "white")) end
            y=y+1
        end
    end
    return surface
end
local function nonemptyReason(vessel)
    if type(vessel.reason) ~= "string" then return nil end
    local reason = string.sub(safeText(vessel.reason), 1, 2048)
    return string.find(reason, "%S") and reason or nil
end
-- Summary: Resolve the current display availability, assembly or role-status issue.
local function displayIssue(snapshot, display, width, height)
    if width < 18 or height < 5 then
        return string.format("monitor is too small (%dx%d); minimum is 18x5", width, height)
    end
    local vessel = type(snapshot.vessel) == "table" and snapshot.vessel or {}
    local reason = nonemptyReason(vessel)
    local stale = snapshot.displayStale == true or snapshot.stale == true or snapshot.dataFresh == false
    if stale then
        local detail = "CORE UNREACHABLE"
        if reason then detail = detail .. "; vessel reason: " .. reason end
        return detail
    end
    local assembly = assemblyProblem(snapshot)
    if assembly then
        return string.lower(ASSEMBLY_TITLES[assembly.state] or "assembly unknown") ..
            (assembly.reason and (": " .. assembly.reason) or ""), assembly
    end
    local fleet=type(snapshot.fleetBoot)=="table" and snapshot.fleetBoot or nil
    local assembled=type(snapshot.assembly)=="table" and snapshot.assembly.state=="ASSEMBLED"
    if assembled and fleet and fleet.ready==false then
        local phase=type(fleet.phase)=="string" and safeText(fleet.phase) or "WAITING"
        local detail="startup check: "..string.sub(phase,1,48)
        if finite(fleet.completed) and finite(fleet.total) then
            detail=detail.." "..tostring(math.floor(fleet.completed)).."/"..tostring(math.floor(fleet.total))
        end
        if type(fleet.current)=="string" and fleet.current~="" then detail=detail.." ("..string.sub(safeText(fleet.current),1,64)..")" end
        if type(fleet.reason)=="string" and fleet.reason~="" then detail=detail..": "..string.sub(safeText(fleet.reason),1,128) end
        return detail,nil,fleet
    end

    local issues = {}
    if reason then issues[#issues + 1] = "vessel reason: " .. reason end
    if not sensorValid(vessel, "heading") then
        issues[#issues + 1] = "required vessel heading is missing or invalid"
    end
    if display == "center" then
        if not sensorValid(vessel, "altitude") then
            issues[#issues + 1] = "required center altitude is missing or invalid"
        end
        if not sensorValid(vessel, "verticalSpeed") then
            issues[#issues + 1] = "required center vertical speed is missing or invalid"
        end
    end
    if (vessel.valid == false or snapshot.vesselValid == false or snapshot.valid == false) and
        not reason then
        issues[#issues + 1] = "vessel telemetry is marked invalid"
    end
    if #issues == 0 then return nil end
    return table.concat(issues, "; ")
end
local function shortestDelta(from, to)
    return (to - from + 540) % 360 - 180
end
-- Summary: Format the compass labels and markers for the observed heading.
local function compass(surface, current)
    local width = surface.width
    local mid = math.floor((width + 1) / 2)
    local perColumn = 120 / math.max(1, width - 1)
    local leftSpan, rightSpan = (mid - 1) * perColumn, (width - mid) * perColumn
    for x = 1, width do
        local value = (current + (x - mid) * perColumn) % 360
        local mark = math.floor(value / 10 + 0.5) * 10 % 360
        local difference = (mark - value + 540) % 360 - 180
        local major = math.abs(difference) <= perColumn / 2 and mark % 30 == 0
        surface.rows[3].chars[x] = major and "|" or "."
        surface.rows[3].fg[x] = color(major and "cyan" or "gray")
    end
    surface.rows[3].chars[mid], surface.rows[3].fg[mid] = "v", color("cyan")
    for bearing = 0, 330, 30 do
        local delta = (bearing - current + 540) % 360 - 180
        if delta >= -leftSpan and delta <= rightSpan then
            local x = mid + math.floor(delta / perColumn + 0.5)
            local text = bearing == 0 and "N" or (bearing == 90 and "E" or
                (bearing == 180 and "S" or (bearing == 270 and "W" or string.format("%03d", bearing))))
            local start = math.max(1, math.min(width - #text + 1, x - math.floor(#text / 2)))
            put(surface, start, 4, text, bearing % 90 == 0 and "cyan" or "gray")
        end
    end
end
local function centerLayout(surface)
    local altitudeWidth = math.min(14, math.max(6, math.floor(surface.width / 4)))
    local headingWidth = surface.width - altitudeWidth - 1
    return headingWidth, headingWidth + 2, altitudeWidth
end
-- Summary: Render the horizontal heading tape and selected-heading marker.
local function drawHeadingTape(surface, headingWidth, current, selected, compact, targetY)
    local mid = math.floor((headingWidth + 1) / 2)
    local perColumn = 120 / math.max(1, headingWidth - 1)
    local leftSpan, rightSpan = (mid - 1) * perColumn, (headingWidth - mid) * perColumn
    if current then
        for x = 1, headingWidth do
            local bearing = (current + (x - mid) * perColumn) % 360
            local rounded = math.floor(bearing / 10 + 0.5) * 10 % 360
            surface.rows[3].chars[x] = math.abs(shortestDelta(bearing, rounded)) <= perColumn / 2 and
                rounded % 30 == 0 and "|" or "."
            surface.rows[3].fg[x] = color("gray")
        end
        surface.rows[3].chars[mid], surface.rows[3].fg[mid] = "v", color("cyan")
        if not compact then
            local occupied = {}
            for bearing = 0, 330, 30 do
                local delta = shortestDelta(current, bearing)
                if delta >= -leftSpan and delta <= rightSpan then
                    local label = bearing == 0 and "N" or (bearing == 90 and "E" or
                        (bearing == 180 and "S" or (bearing == 270 and "W" or string.format("%03d", bearing))))
                    local x = mid + math.floor(delta / perColumn + 0.5)
                    local first = math.max(1, math.min(headingWidth - #label + 1, x - math.floor(#label / 2)))
                    local free = true
                    for at = first, first + #label - 1 do
                        if occupied[at] then free = false end
                    end
                    if free then
                        put(surface, first, 4, label, "gray")
                        for at = first, first + #label - 1 do occupied[at] = true end
                    end
                end
            end
        end
    else
        center({ width = headingWidth, height = surface.height, rows = surface.rows }, 3, "NO HEADING DATA", "gray")
    end
    if selected then
        local delta = current and shortestDelta(current, selected) or nil
        local marker, x
        if delta and delta < -leftSpan then
            marker, x = "<", 1
        elseif delta and delta > rightSpan then
            marker, x = ">", headingWidth
        elseif delta then
            marker = "^"
            x = mid + math.floor(delta / perColumn + 0.5)
        end
        if marker then put(surface, x, targetY, marker, "yellow") end
    end
end
-- Core's altitude ceiling from the snapshot, or nil when core has not sent one.
local function altitudeCeiling(snapshot)
    local control=type(snapshot.altitudeControl)=="table" and snapshot.altitudeControl or {}
    return type(control.ceiling)=="number" and control.ceiling or nil
end
-- Summary: Render the altitude scale and selected-altitude marker; levels above the altitude ceiling stay blank.
local function drawAltitudeTape(surface, altitudeX, altitudeWidth, top, bottom,
    actual, selected, compact, targetTone, ceiling)
    if top > bottom then return end
    local actualY = math.floor((top + bottom) / 2)
    local roundedActual = actual and math.floor(actual / 10 + 0.5) * 10 or nil
    for y = top, bottom do
        local level = roundedActual and roundedActual + (actualY - y) * 10 or nil
        local tickX = altitudeX + 1
        -- Levels at or above Y 290 are drawn red: above about Y 300 the air
        -- pressure falls ~5% per block and altitude hold gets twitchy.
        local high = level and level >= 290
        local aboveCeiling = level and ceiling and level > ceiling
        surface.rows[y].chars[tickX] = y == actualY and "|" or (aboveCeiling and " " or ".")
        surface.rows[y].fg[tickX] = color(high and "red" or "gray")
        if not compact and actual and altitudeWidth >= 11 and not aboveCeiling then
            local text = string.format("%.0f", level)
            text = string.sub(text, 1, altitudeWidth - 5)
            put(surface, altitudeX + 3, y, text, high and "red" or "gray")
        end
    end
    if actual then
        put(surface, altitudeX, actualY, ">", "cyan")
    end
    if selected and actual then
        local offset = math.floor((selected - actual) / 10 + 0.5)
        local targetY = actualY - offset
        local marker = "<"
        if targetY < top then targetY, marker = top, "^" end
        if targetY > bottom then targetY, marker = bottom, "v" end
        if compact and top == bottom and selected ~= actual then
            marker = selected > actual and "^" or "v"
        end
        put(surface, altitudeX + altitudeWidth - 1, targetY, marker, targetTone or "yellow")
    end
end
-- Summary: Resolve the altitude-control indicator from current systems/control state.
local function altitudeHoldIndicatorRaw(snapshot, stale)
    if stale then return nil end
    local systems=type(snapshot.systemsStartup)=="table" and snapshot.systemsStartup or nil
    local phase=systems and type(systems.phase)=="string" and string.upper(systems.phase) or ""
    if systems and systems.displayPhase=="READY" then return "READY","cyan" end
    if phase=="ABORTED" then return "ABORTED","red" end
    if phase=="READY" or phase=="HOLDING" then return "READY","cyan" end
    if phase=="MAIN_LIFT" then return "ACQUIRING","cyan" end
    if systems and systems.active==true then return "STARTING","cyan" end
    local control=type(snapshot.altitudeControl)=="table" and snapshot.altitudeControl or nil
    if phase=="STOPPED" or phase=="BLOCKED" or phase=="IDLE" or
        (control and control.enabled==false) then return "ALT OFFLINE","gray" end
    return nil
end
-- Low air pressure warning on the hold label (ABORTED still wins). From
-- about Y 280 the air pressure falls several times faster per block, and
-- near Y 310 she runs out of lift with every chamber full of steam.
--   Y 285+: LOW PRESS (yellow), steady until she leaves the area (drops back
--           below Y 284; the block of hysteresis stops boundary flicker).
--   Y 305+: alternates LOW PRESS and DESCEND (both red), a second each.
local lowPressureActive=false
-- Summary: Format the current altitude-control indicator and its display colour.
local function altitudeHoldIndicator(snapshot, stale)
    local label,tone=altitudeHoldIndicatorRaw(snapshot,stale)
    if stale or label=="ABORTED" then return label,tone end
    local vessel=type(snapshot.vessel)=="table" and snapshot.vessel or {}
    if not sensorValid(vessel,"altitude") then return label,tone end
    if vessel.altitude>=285 then lowPressureActive=true elseif vessel.altitude<284 then lowPressureActive=false end
    if not lowPressureActive then return label,tone end
    if vessel.altitude>=305 then return math.floor(os.clock())%2==1 and "DESCEND" or "LOW PRESS","red" end
    return "LOW PRESS","yellow"
end
-- Summary: Render the center heading/altitude display from the cached snapshot.
local function drawCenter(snapshot, width, height)
    local surface = makeSurface(width, height)
    local vessel = type(snapshot.vessel) == "table" and snapshot.vessel or {}
    local targets = type(snapshot.targets) == "table" and snapshot.targets or {}
    local stale = snapshot.displayStale == true or snapshot.stale == true or snapshot.dataFresh == false
    local heading = not stale and sensorValid(vessel, "heading") and angle(vessel.heading) or nil
    local altitude = not stale and sensorValid(vessel, "altitude") and vessel.altitude or nil
    local headingTarget = not stale and targetValid(targets, "heading") and angle(targets.heading) or nil
    local altitudeTarget = not stale and targetValid(targets, "altitude") and targets.altitude or nil
    local anchored = not stale and snapshot.anchor == "ANCHORED"
    local holdLabel,holdTone=altitudeHoldIndicator(snapshot,stale)
    local targetInactive=holdLabel=="ABORTED" or holdLabel=="ALT OFFLINE"
    local altitudeTargetTone=altitudeTarget and (targetInactive and "gray" or "yellow") or "gray"
    local headingWidth, altitudeX, altitudeWidth = centerLayout(surface)
    local compact = height < 8
    local targetY = compact and height or 5

    put(surface, 1, 1, anchored and "AMARYLLIS / CENTER / ANCHORED" or "AMARYLLIS / CENTER",
        anchored and "yellow" or "white")
    if stale then put(surface, 1, 1, "CORE UNREACHABLE", "yellow") end
    local actualHeadingText = heading and string.format("%05.1f", heading) or "--.-"
    local selectedHeadingText = headingTarget and string.format("%05.1f", headingTarget) or "--.-"
    put(surface, math.floor((headingWidth - #actualHeadingText) / 2) + 1, 2,
        actualHeadingText, heading and "white" or "gray")
    local actualAltitudeText = shown(altitude, 1, false)
    centerColumn(surface, altitudeX, altitudeWidth, 2,
        actualAltitudeText, altitude and "white" or "gray")

    drawHeadingTape(surface, headingWidth, heading, headingTarget, compact, targetY)
    local tapeTop, tapeBottom = 3, height - 2
    drawAltitudeTape(surface, altitudeX, altitudeWidth, tapeTop, tapeBottom,
        altitude, altitudeTarget, compact, altitudeTargetTone, altitudeCeiling(snapshot))

    local selectedRow = compact and 4 or 6
    put(surface, math.floor((headingWidth - #selectedHeadingText) / 2) + 1, selectedRow,
        selectedHeadingText, headingTarget and "yellow" or "gray")
    local selectedAltitudeText = shown(altitudeTarget, 1, false)
    local altitudeRow = compact and 4 or height - 1
    centerColumn(surface, altitudeX, altitudeWidth, altitudeRow,
        selectedAltitudeText, altitudeTargetTone)
    if holdLabel then
        if altitudeWidth<8 then
            local compactLabels={ABORTED="ABORT",["ALT OFFLINE"]="OFF",["LOW PRESS"]="LOW P",DESCEND="DESC",READY="READY",ACQUIRING="ACQ",STARTING="START"}
            holdLabel=compactLabels[holdLabel] or holdLabel
        end
        centerColumn(surface,altitudeX,altitudeWidth,1,holdLabel,holdTone)
    end
    if height >= 8 then
        local vertical = shownSensor(vessel, "verticalSpeed", 2, true, stale)
        put(surface, 1, height, "V/S " .. vertical, "white")
    end
    local reason = type(vessel.reason) == "string" and vessel.reason or nil
    if not stale and reason and height >= 9 then
        put(surface, 1, height - 1,
            "DATA " .. string.sub(safeText(reason), 1, math.max(0, headingWidth - 5)), "red")
    end
    return surface
end
local turnIndicatorPhase,turnIndicatorAt=0,nil
-- Summary: Render the wide heading display and its status labels.
local function drawHorizontalHeading(snapshot,width,height)
    local fullSurface=makeSurface(width,height)
    local altitudeX,altitudeWidth
    if width>=30 then
        local headingWidth
        headingWidth,altitudeX,altitudeWidth=centerLayout(fullSurface)
        width=headingWidth
    end
    -- Both instruments share the output rows, but heading layout is confined
    -- to its own column so speed and AP markers cannot overwrite altitude.
    local surface={width=width,height=height,rows=fullSurface.rows}
    local ap=type(snapshot.autopilot)=="table" and snapshot.autopilot.active and snapshot.autopilot or nil
    local recovering=ap and (ap.state=="RECOVERING" or
        (type(ap.state)=="string" and ap.state:match("^RETRYING %(%d+%)$")~=nil))
    local vessel=snapshot.vessel or {};local targets=snapshot.targets or {}
    local lateral=type(snapshot.lateralControl)=="table" and snapshot.lateralControl or {}
    local showLateral=not ap and snapshot.displayStale~=true and lateral.mode=="SEL" and lateral.active==true
    local selected=ap or (snapshot.effectiveModes or snapshot.modes or {}).heading=="SEL"
    local current=not recovering and sensorValid(vessel,"heading") and angle(vessel.heading) or nil
    local target=selected and angle(ap and ap.requestedHeading or targets.heading) or nil
    local title=ap and ("AP - "..safeText(ap.state or "ACTIVE")) or (selected and "SEL HDG" or "")
    put(surface,1,1,string.sub(title,1,width),recovering and "yellow" or "cyan")
    local name=ap and safeText(ap.destinationName or "DESTINATION") or "AMARYLLIS"
    local available=width-#title-2
    -- Keep the name clear of the centred turn arrow (three cells).
    local arrowEnd=math.floor((width-3)/2)+3
    available=math.min(available,width-arrowEnd-1)
    if available>=4 then
        -- A name longer than the space keeps its start and ends in "..".
        if #name>available then name=string.sub(name,1,available-2)..".." end
        put(surface,width-#name+1,1,name,"cyan")
    end
    local headingText=current and shown(current,1,false) or "HDG --"
    center(surface,2,headingText,"white")
    local rowTwoRightUsed=false
    if ap and target and width>=38 then put(surface,1,2,"ROUTE "..shown(target,1,false),"yellow") end
    -- SEL heading shows the error to the selected heading on the right of row 2.
    if not ap and selected and current and target and width>=38 then
        local readout="HDG "..GLYPH.DELTA.." "..shown(shortestDelta(current,target),1,true)..GLYPH.DEGREE
        put(surface,width-GLYPH.width(readout)+1,2,readout,"white")
        rowTwoRightUsed=true
    end
    drawHeadingTape(surface,width,current,not recovering and target or nil,height<7,height>=7 and 5 or 4)
    -- Actual speed on the right; the requested speed (current AP speed request or the
    -- SEL throttle target) on the left as REQ.
    local speed="SPD "..shownSensor(vessel,"forwardSpeed",1,false,false).." b/s"
    local requested
    if ap then requested=ap.requestedSpeed
    elseif (snapshot.effectiveModes or snapshot.modes or {}).throttle=="SEL" and targetValid(targets,"speed") then requested=targets.speed end
    local req=requested~=nil and ("REQ "..shown(requested,1,false).." b/s") or nil
    local left=""
    if ap then
        local deviation=not recovering and ap.crossTrack or nil
        local side=finiteDisplay(deviation) and (deviation>0 and " R" or (deviation<0 and " L" or "")) or ""
        local dev="DEV "..shown(finiteDisplay(deviation) and math.abs(deviation) or nil,1,false).." b"..side
        local distance=not recovering and ap.distance or nil
        left="DIST "..shown(distance,finiteDisplay(distance) and distance>=100 and 0 or 1,false).." b"
        if height>=7 then
            local row=6;local mid=math.floor((width+1)/2);local low=3;local high=width-2
            for x=low,high do put(surface,x,row,"-","gray") end
            put(surface,mid,row,"|","cyan")
            put(surface,1,row,"L","gray");put(surface,width,row,"R","gray")
            if finiteDisplay(deviation) then
                local x=mid+math.floor(math.max(-10,math.min(10,deviation))*(high-low)/20+.5)
                x=math.max(low,math.min(high,x))
                put(surface,x,row,math.abs(deviation)>10 and (deviation>0 and ">" or "<") or "*","white")
            end
            if height>=8 then center(surface,7,dev,"white")
            else put(surface,1,2,string.sub(dev,1,math.max(0,math.floor(width/2)-7)),"white") end
        else left=dev end
        if recovering and height>=9 then center(surface,8,"WAITING FOR TELEMETRY","yellow") end
    elseif selected and current and target then
        left=""
        if height>=7 then center(surface,6,shown(target,1,false),"yellow")
        elseif height>=6 then center(surface,5,shown(target,1,false),"yellow") end
    end
    -- Animated turn indicator, top row centre (SEL heading and AP): one
    -- arrow stepping across three cells in the turn direction. It steps
    -- faster the faster the heading loop is commanding her to yaw: 0.6 s per
    -- step for a gentle turn, down to 0.25 s (the display refresh) at 10 deg/s.
    local turnError=selected and current and target and not recovering and shortestDelta(current,target) or nil
    if turnError and math.abs(turnError)>=.5 then
        local headingControl=type(snapshot.headingControl)=="table" and snapshot.headingControl or {}
        local rate=finiteDisplay(headingControl.targetYawRate) and math.abs(headingControl.targetYawRate) or 0
        local period=math.max(0.25,0.6-0.035*math.min(rate,10))
        local now=os.clock()
        local dt=turnIndicatorAt and math.max(0,math.min(1,now-turnIndicatorAt)) or 0
        turnIndicatorAt=now
        turnIndicatorPhase=(turnIndicatorPhase+dt/period)%3
        local frame=math.floor(turnIndicatorPhase)
        center(surface,1,turnError>0 and (string.rep(" ",frame)..">"..string.rep(" ",2-frame)) or
            (string.rep(" ",2-frame).."<"..string.rep(" ",frame)),"yellow")
    else turnIndicatorAt=nil end
    if showLateral then
        local remaining=finiteDisplay(lateral.remaining) and lateral.remaining or nil
        local requested=finiteDisplay(lateral.offset) and lateral.offset or nil
        local phase=safeText(lateral.state or "MOVING")
        local text="STRAFE "..shown(requested,1,true).."b "..shown(remaining and math.abs(remaining),1,false).."b TO GO"
        if height>=8 then
            local row=6;local mid=math.floor((width+1)/2);local low,high=3,width-2
            for x=1,width do put(surface,x,row," ","white") end
            for x=low,high do put(surface,x,row,"-","gray") end
            put(surface,1,row,"L","gray");put(surface,width,row,"R","gray")
            put(surface,mid,row,"|","cyan")
            if remaining then
                local span=math.max(1,math.abs(requested or 0));local relative=-remaining/span
                local x=mid+math.floor(math.max(-1,math.min(1,relative))*(high-low)/2+.5)
                x=math.max(low,math.min(high,x))
                put(surface,x,row,math.abs(relative)>1 and (relative>0 and ">" or "<") or "*","yellow")
            end
            center(surface,7,text,"cyan")
            if height>=10 then center(surface,8,phase,phase=="TURNING" and "yellow" or "white")
            else left=phase end
        else
            for x=1,width do put(surface,x,height-1," ","white") end
            center(surface,height-1,"STRAFE "..shown(remaining,1,true).."b","cyan");left=""
        end
    end
    local leftWidth=math.max(0,width-#speed-2)
    -- An engaged anchor (braking or anchored) owns the bottom left until it is released.
    local anchorOn=snapshot.displayStale~=true and (snapshot.anchor=="BRAKING" or snapshot.anchor=="ANCHORED")
    if anchorOn then
        put(surface,1,height,string.sub("ANCHORED",1,leftWidth),"yellow")
    elseif req then
        -- REQ owns the bottom left. Whatever was there (DIST, TURNING, the
        -- strafe phase) moves to the free right side of row 2 when it fits,
        -- shares the bottom row when both fit, and is otherwise left out.
        if left~="" then
            local headingEnd=math.floor((width-#headingText)/2)+#headingText
            local free=rowTwoRightUsed and 0 or (width-headingEnd-1)
            local moved=left
            if #moved<=free then put(surface,width-#moved+1,2,moved,"cyan");left=req
            elseif #req+2+#left<=leftWidth then left=req.."  "..left
            else left=req end
        else left=req end
    end
    if not anchorOn then put(surface,1,height,string.sub(left,1,leftWidth),"cyan") end
    put(surface,math.max(1,width-#speed+1),height,speed,"white")
    if altitudeX then
        local actual=sensorValid(vessel,"altitude") and vessel.altitude or nil
        local selectedAltitude=targetValid(targets,"altitude") and targets.altitude or nil
        local holdLabel,holdTone=altitudeHoldIndicator(snapshot,false)
        local targetTone=(holdLabel=="ABORTED" or holdLabel=="ALT OFFLINE") and "gray" or "yellow"
        centerColumn(fullSurface,altitudeX,altitudeWidth,1,holdLabel or "ALTITUDE",holdTone or "cyan")
        centerColumn(fullSurface,altitudeX,altitudeWidth,2,shown(actual,1,false),"white")
        drawAltitudeTape(fullSurface,altitudeX,altitudeWidth,3,height-2,
            actual,selectedAltitude,height<8,targetTone,altitudeCeiling(snapshot))
        centerColumn(fullSurface,altitudeX,altitudeWidth,height-1,shown(selectedAltitude,1,false),targetTone)
        centerColumn(fullSurface,altitudeX,altitudeWidth,height,
            "V/S "..shownSensor(vessel,"verticalSpeed",2,true,false),"white")
    end
    return fullSurface
end
-- Summary: Build the current bounded display frame from cached status.
local function frame(snapshot, display, width, height)
    local issue, assembly, fleet = displayIssue(snapshot, display, width, height)
    if assembly then return assemblySurface(width, height, assembly), issue end
    if fleet then return fleetBootSurface(width,height,fleet),issue end
    if issue then return errorSurface(width, height), issue end
    if (type(snapshot.autopilot)=="table" and snapshot.autopilot.active==true) or
        (type(snapshot.lateralControl)=="table" and snapshot.lateralControl.mode=="SEL" and snapshot.lateralControl.active==true) then
        return drawHorizontalHeading(snapshot,width,height),nil
    end
    if display~="center" or (width>=30 and height<=11) then return drawHorizontalHeading(snapshot,width,height),nil end
    if display == "center" then return drawCenter(snapshot, width, height), nil end
    local surface = makeSurface(width, height)
    local vessel = type(snapshot.vessel) == "table" and snapshot.vessel or {}
    local targets = type(snapshot.targets) == "table" and snapshot.targets or {}
    local stale = snapshot.displayStale == true
    local current = not stale and sensorValid(vessel, "heading") and angle(vessel.heading) or nil
    local selected = not stale and angle(targets.heading) or nil
    local anchor = not stale and snapshot.anchor == "ANCHORED"
    local title = display == "center" and "AMARYLLIS / CENTER" or "AMARYLLIS / HEADING"
    if anchor then title = title .. " / ANCHORED" end
    put(surface, 1, 1, title, anchor and "yellow" or "white")
    if stale then put(surface, 1, 1, "CORE UNREACHABLE", "yellow") end
    center(surface, 2, current and ("HDG " .. string.format("%05.1f", current)) or "HDG --.-",
        current and "white" or "gray")
    if height >= 5 then
        if current then compass(surface, current) else center(surface, 3, "NO HEADING DATA", "gray") end
    end
    if height >= 5 then
        center(surface, 5, selected and ("TGT " .. string.format("%05.1f", selected)) or
            "TGT --.-", selected and "yellow" or "gray")
    end
    local reason = type(vessel.reason) == "string" and vessel.reason or nil
    if not stale and reason and height >= 7 then
        center(surface, height, "DATA " .. string.sub(safeText(reason), 1, math.max(0, width - 5)), "red")
    end
    return surface, nil
end
-- Summary: Build and flush the selected cached display view.
local function render(monitor, snapshot, display)
    local okSize, width, height = pcall(monitor.getSize)
    if not okSize or not finite(width) or not finite(height) or width < 1 or height < 1 then
        error("monitor getSize() failed: " .. tostring(width))
    end
    width, height = math.floor(width), math.floor(height)
    return frame(snapshot, display, width, height)
end
-- Summary: Write one character row through the monitor's plain-text methods.
local function drawPlainRow(monitor, row, y)
    local setForeground = monitor.setTextColor or monitor.setTextColour
    local setBackground = monitor.setBackgroundColor or monitor.setBackgroundColour
    local first = 1
    while first <= #row.chars do
        local foreground, background = row.fg[first], row.bg[first]
        local last = first
        while last < #row.chars and row.fg[last + 1] == foreground and
            row.bg[last + 1] == background do
            last = last + 1
        end
        if type(setForeground) == "function" then setForeground(foreground) end
        if type(setBackground) == "function" then setBackground(background) end
        monitor.setCursorPos(first, y)
        local text = {}
        for x = first, last do text[#text + 1] = row.chars[x] end
        monitor.write(table.concat(text))
        first = last + 1
    end
end
-- Section: Pixel graphics | Optional CC: Graphics backend for the cached instruments.
-- Each glyph occupies a 4 by 6 logical pixel cell. Lowercase uses the same
-- shapes as uppercase; delta and degree retain their instrument meanings.
local PIXEL_FONT = {
    A="010101111101101", B="110101110101110", C="011100100100011",
    D="110101101101110", E="111100110100111", F="111100110100100",
    G="011100101101011", H="101101111101101", I="111010010010111",
    J="001001001101010", K="101101110101101", L="100100100100111",
    M="101111111101101", N="101111111111101", O="010101101101010",
    P="110101110100100", Q="010101101111011", R="110101110101101",
    S="011100010001110", T="111010010010010", U="101101101101111",
    V="101101101101010", W="101101111111101", X="101101010101101",
    Y="101101010010010", Z="111001010100111",
    ["0"]="111101101101111", ["1"]="010110010010111",
    ["2"]="110001010100111", ["3"]="110001010001110",
    ["4"]="101101111001001", ["5"]="111100110001110",
    ["6"]="011100111101111", ["7"]="111001010010010",
    ["8"]="111101111101111", ["9"]="111101111001110",
    [" "]="000000000000000", ["."]="000000000000010",
    [","]="000000000010100", [":"]="000010000010000",
    [";"]="000010000010100", ["-"]="000000111000000",
    ["+"]="000010111010000", ["/"]="001001010100100",
    ["\\"]="100100010001001", ["|"]="010010010010010",
    ["<"]="001010100010001", [">"]="100010001010100",
    ["="]="000111000111000", ["_"]="000000000000111",
    ["["]="110100100100110", ["]"]="011001001001011",
    ["("]="010100100100010", [")"]="010001001001010",
    ["!"]="010010010000010", ["?"]="110001010000010",
    ["%"]="101001010100101", ["'"]="010010000000000",
    ["\""]="101101000000000", ["*"]="000101010101000",
    ["#"]="101111101111101", ["^"]="010101000000000",
    ["~"]="000011110000000", ["@"]="111101111100111",
    ["&"]="010101010101011", ["$"]="011110011110010",
    ["`"]="100010000000000", ["{"]="011010110010011",
    ["}"]="110010011010110",
    ["\206\148"]="010010101101111", ["\194\176"]="010101010000000",
}

-- Section: Native instruments | Pixel coordinates independent of the text grid.
local Pixel = {}
-- Seven-row instrument type keeps open counters and distinct digit shapes.
-- Slash-separated rows are unpacked once; status-frame rasterization retains
-- its original cell font for compatibility with small monitors.
Pixel.font = {
    A="01110/10001/10001/11111/10001/10001/10001",
    B="11110/10001/10001/11110/10001/10001/11110",
    C="01111/10000/10000/10000/10000/10000/01111",
    D="11110/10001/10001/10001/10001/10001/11110",
    E="11111/10000/10000/11110/10000/10000/11111",
    F="11111/10000/10000/11110/10000/10000/10000",
    G="01111/10000/10000/10111/10001/10001/01111",
    H="10001/10001/10001/11111/10001/10001/10001",
    I="01110/00100/00100/00100/00100/00100/01110",
    J="00111/00010/00010/00010/10010/10010/01100",
    K="10001/10010/10100/11000/10100/10010/10001",
    L="10000/10000/10000/10000/10000/10000/11111",
    M="10001/11011/10101/10101/10001/10001/10001",
    N="10001/11001/11001/10101/10011/10011/10001",
    O="01110/10001/10001/10001/10001/10001/01110",
    P="11110/10001/10001/11110/10000/10000/10000",
    Q="01110/10001/10001/10001/10101/10010/01101",
    R="11110/10001/10001/11110/10100/10010/10001",
    S="01111/10000/10000/01110/00001/00001/11110",
    T="11111/00100/00100/00100/00100/00100/00100",
    U="10001/10001/10001/10001/10001/10001/01110",
    V="10001/10001/10001/10001/10001/01010/00100",
    W="10001/10001/10001/10101/10101/10101/01010",
    X="10001/10001/01010/00100/01010/10001/10001",
    Y="10001/10001/01010/00100/00100/00100/00100",
    Z="11111/00001/00010/00100/01000/10000/11111",
    ["0"]="01110/10001/10011/10101/11001/10001/01110",
    ["1"]="00100/01100/00100/00100/00100/00100/01110",
    ["2"]="01110/10001/00001/00010/00100/01000/11111",
    ["3"]="11110/00001/00001/01110/00001/00001/11110",
    ["4"]="00010/00110/01010/10010/11111/00010/00010",
    ["5"]="11111/10000/10000/11110/00001/00001/11110",
    ["6"]="01110/10000/10000/11110/10001/10001/01110",
    ["7"]="11111/00001/00010/00100/01000/01000/01000",
    ["8"]="01110/10001/10001/01110/10001/10001/01110",
    ["9"]="01110/10001/10001/01111/00001/00001/01110",
    [" "]="00000/00000/00000/00000/00000/00000/00000",
    ["."]="00000/00000/00000/00000/00000/00110/00110",
    ["-"]="00000/00000/00000/11111/00000/00000/00000",
    ["+"]="00000/00100/00100/11111/00100/00100/00000",
    ["/"]="00001/00010/00010/00100/01000/01000/10000",
    ["?"]="01110/10001/00001/00010/00100/00000/00100",
    [":"]="00000/00110/00110/00000/00110/00110/00000",
    ["("]="00010/00100/01000/01000/01000/00100/00010",
    [")"]="01000/00100/00010/00010/00010/00100/01000",
}
for glyph, rows in pairs(Pixel.font) do Pixel.font[glyph] = rows:gsub("/", "") end

-- Summary: Allocate a black byte framebuffer. Drawing helpers clip to its
-- bounds; rows are converted to strings only after the whole frame is built.
function Pixel.new(width, height)
    local image = { width = width, height = height, rows = {} }
    for y = 1, height do
        local row = {}
        for x = 1, width do row[x] = string.char(15) end
        image.rows[y] = row
    end
    return image
end

-- Summary: Fill an integer pixel rectangle, clipped to the framebuffer.
-- Write the supplied palette-index byte into each covered framebuffer cell.
function Pixel.rect(image, x, y, width, height, index)
    local left, top = math.max(0, math.floor(x)), math.max(0, math.floor(y))
    local right = math.min(image.width - 1, math.floor(x + width - 1))
    local bottom = math.min(image.height - 1, math.floor(y + height - 1))
    local byte = string.char(index)
    for py = top, bottom do
        for px = left, right do image.rows[py + 1][px + 1] = byte end
    end
end

-- Summary: Draw bitmap text with integer enlargement and optional alignment.
-- Limit the glyph count to the supplied pixel width before touching the frame.
function Pixel.text(image, x, y, value, index, scale, align, available)
    local cells = GLYPH.cells(safeText(value))
    local limit = math.floor((available or image.width) / (6 * scale))
    while #cells > limit do table.remove(cells) end
    local width = math.max(0, #cells * 6 * scale - scale)
    if align == "center" then x = x - width / 2 end
    if align == "right" then x = x - width end
    x, y = math.floor(x), math.floor(y)
    for i, cell in ipairs(cells) do
        local glyph = Pixel.font[string.upper(cell)] or Pixel.font["?"]
        for gy = 0, 6 do
            for gx = 0, 4 do
                if glyph:sub(gy * 5 + gx + 1, gy * 5 + gx + 1) == "1" then
                    Pixel.rect(image, x + (i - 1) * 6 * scale + gx * scale,
                        y + gy * scale, scale, scale, index)
                end
            end
        end
    end
end

-- Summary: Draw a filled instrument triangle at an integer pixel position.
-- Direction identifies its tip; index supplies a mode-1 palette slot.
function Pixel.triangle(image, x, y, size, direction, index)
    x, y = math.floor(x), math.floor(y)
    for n = 0, size - 1 do
        if direction == "up" or direction == "down" then
            local py = direction == "up" and y + n or y - n
            Pixel.rect(image, x - n, py, 2 * n + 1, 1, index)
        else
            local px = direction == "left" and x + n or x - n
            Pixel.rect(image, px, y - n, 1, 2 * n + 1, index)
        end
    end
end

-- Summary: Draw an integer line between two pixel coordinates.
-- Step along the longer axis and clip each point through the rectangle helper.
function Pixel.stroke(image, x1, y1, x2, y2, index)
    local steps = math.max(1, math.ceil(math.max(math.abs(x2 - x1), math.abs(y2 - y1))))
    for step = 0, steps do
        local fraction = step / steps
        local x = math.floor(x1 + (x2 - x1) * fraction + 0.5)
        local y = math.floor(y1 + (y2 - y1) * fraction + 0.5)
        Pixel.rect(image, x, y, 1, 1, index)
    end
end

-- Summary: Draw measured forward-speed magnitude on a 0..40 b/s dial.
-- The scale is presentation range, with actual signed speed retained below.
-- An amber rim mark shows requested magnitude; unavailable data hides its needle.
function Pixel.speedometer(image, left, right, height, small, actual, requested, selector, unit, targetIndex)
    targetIndex = targetIndex or 4
    local centreX = math.floor((left + right) / 2)
    local centreY = math.floor(height * 0.49)
    local radius = math.floor(math.min((right - left - 12 * small) / 2, height * 0.26))
    -- Map zero at lower-left clockwise across the upper arc to 40 at lower-right.
    local function radians(speed)
        return (135 + math.max(0, math.min(40, math.abs(speed))) * 270 / 40) * math.pi / 180
    end
    for speed = 0, 40, 0.25 do
        local angle = radians(speed)
        Pixel.rect(image, centreX + math.cos(angle) * radius,
            centreY + math.sin(angle) * radius, 1, 1, 7)
    end
    for speed = 0, 40, 2 do
        local angle = radians(speed)
        local major = speed % 10 == 0
        local inner = radius - (major and 4 or 2) * small
        Pixel.stroke(image, centreX + math.cos(angle) * inner, centreY + math.sin(angle) * inner,
            centreX + math.cos(angle) * radius, centreY + math.sin(angle) * radius, major and 0 or 7)
        if major then
            local labelRadius = radius - 10 * small
            Pixel.text(image, centreX + math.cos(angle) * labelRadius,
                centreY + math.sin(angle) * labelRadius - 3 * small,
                tostring(speed), 7, small, "center")
        end
    end
    if finiteDisplay(requested) then
        local angle = radians(requested)
        Pixel.stroke(image, centreX + math.cos(angle) * (radius + small),
            centreY + math.sin(angle) * (radius + small),
            centreX + math.cos(angle) * (radius + 4 * small),
            centreY + math.sin(angle) * (radius + 4 * small), targetIndex)
    end
    if finiteDisplay(actual) then
        local angle = radians(actual)
        Pixel.stroke(image, centreX, centreY, centreX + math.cos(angle) * (radius - 6 * small),
            centreY + math.sin(angle) * (radius - 6 * small), 0)
        Pixel.rect(image, centreX - small, centreY - small, 3 * small, 3 * small, 0)
    end
    Pixel.text(image, centreX, height - 29 * small, shown(actual, 1, false), 0, small, "center")
    local decimals = unit == "RPM" and 0 or (unit == "b/s2" and 2 or 1)
    Pixel.text(image, centreX, height - 20 * small, shown(selector, decimals, unit == "b/s2"), targetIndex, small, "center")
    Pixel.text(image, centreX, height - 7 * small, unit or "b/s", 7, small, "center")
end

-- Summary: Paint a six-petal, 48-pixel emblem using the existing purple,
-- magenta, pink and yellow palette slots, preserving the shared monitor palette.
function Pixel.flower(image, x, y, scale)
    for petal = 0, 5 do
        local angle = -math.pi / 2 + petal * math.pi / 3
        local cosine, sine = math.cos(angle), math.sin(angle)
        for py = 2, 45 do
            for px = 2, 45 do
                local dx, dy = px - 23.5, py - 23.5
                local radial = dx * cosine + dy * sine
                local across = -dx * sine + dy * cosine
                local fraction = math.max(0, math.min(1, (radial + 1) / 23))
                local halfWidth = 6.8 * math.sin(math.pi * fraction) ^ 0.8
                if radial >= 0 and radial <= 21 and math.abs(across) <= halfWidth then
                    local index = 10
                    if halfWidth - math.abs(across) >= 1.1 then
                        if math.abs(across) < 1.15 and radial < 17 then index = 6
                        elseif across < 0 then index = 2 end
                    end
                    Pixel.rect(image, x + px * scale, y + py * scale, scale, scale, index)
                end
            end
        end
    end
    Pixel.rect(image, x + 21 * scale, y + 21 * scale, 6 * scale, 6 * scale, 6)
    Pixel.rect(image, x + 22 * scale, y + 22 * scale, 4 * scale, 4 * scale, 0)
    Pixel.rect(image, x + 23 * scale, y + 23 * scale, 2 * scale, 2 * scale, 4)
end

-- Summary: Draw a shared +/-10 block lateral scale and an exact-value footer.
-- Negative displacement is left, positive is right. Off-scale arrows preserve
-- direction; unavailable displacement retains the scale with an empty marker.
function Pixel.deviation(image, left, right, middle, height, small, displacement, index, detail)
    local scaleY = height - 16 * small
    local scaleLeft, scaleRight = left + 10 * small, right - 10 * small
    Pixel.rect(image, scaleLeft, scaleY, scaleRight - scaleLeft + 1, 1, 7)
    for tick = -2, 2 do
        local x = middle + tick * (scaleRight - scaleLeft) / 4
        Pixel.rect(image, x, scaleY - 2 * small, 1, 5 * small, tick == 0 and 9 or 7)
    end
    Pixel.text(image, left, scaleY - 3 * small, "L", 7, small)
    Pixel.text(image, right, scaleY - 3 * small, "R", 7, small, "right")
    if finiteDisplay(displacement) then
        local x = middle + math.max(-10, math.min(10, displacement)) * (scaleRight - scaleLeft) / 20
        Pixel.triangle(image, x, scaleY - 3 * small, 2 * small,
            math.abs(displacement) <= 10 and "down" or (displacement < 0 and "left" or "right"), index)
    end
    Pixel.text(image, middle, height - 7 * small, detail, index, small, "center", right - left)
end

-- Summary: Build the approved tapes or disassembled emblem from a validated
-- snapshot. Return nil for smaller monitors and blocked/error states so their
-- existing wrapped messages remain available through the raster backend.
function Pixel.frame(snapshot, display, columns, lines, width, height)
    if width < 240 or height < 80 then return nil end
    local issue, assembly = displayIssue(snapshot, display, columns, lines)
    if issue and not (assembly and assembly.state == "DISASSEMBLED") then return nil end
    local image = Pixel.new(width, height)
    local small = math.max(1, math.floor(math.min(width / 340, height / 100)))
    local margin = 5 * small
    if assembly then
        local scale = math.max(1, math.floor((height - 28 * small) / 48))
        local total = 48 * scale + 24 * small
        local top = math.floor((height - total) / 2)
        Pixel.flower(image, math.floor((width - 48 * scale) / 2), top, scale)
        Pixel.text(image, width / 2, top + 48 * scale + 5 * small,
            "VESSEL DISASSEMBLED", 0, small, "center")
        Pixel.text(image, width / 2, top + 48 * scale + 16 * small,
            "A.E.V. AMARYLLIS", 7, small, "center")
        return image
    end
    local vessel, targets = snapshot.vessel or {}, snapshot.targets or {}
    local modes = snapshot.effectiveModes or snapshot.modes or {}
    local ap = type(snapshot.autopilot) == "table" and snapshot.autopilot.active and snapshot.autopilot or nil
    local commandIndex = ap and 10 or 4
    local recovering = ap and (ap.state == "RECOVERING" or
        (type(ap.state) == "string" and ap.state:match("^RETRYING %(%d+%)$") ~= nil))
    local heading = not recovering and sensorValid(vessel, "heading") and angle(vessel.heading) or nil
    local target = not recovering and (ap or modes.heading == "SEL") and
        angle(ap and ap.requestedHeading or targets.heading) or nil
    local speedColumn = width >= 300
    local propulsion = type(snapshot.propulsion) == "table" and snapshot.propulsion or {}
    local throttleMode = propulsion.mode or modes.throttle
    local throttleTitle = throttleMode == "DIRECT" and "DIR RPM" or
        (throttleMode == "SEL" and "SEL SPD" or "MAN THR")
    local split = math.floor(width * (speedColumn and 0.60 or 0.72))
    local speedLeft = speedColumn and math.floor(width * 0.80) or width
    local left, right = margin, split - 10 * small
    local middle = math.floor((left + right) / 2)
    local title = ap and ("AP - " .. safeText(ap.state or "ACTIVE")) or
        (modes.heading == "SEL" and "SEL HDG" or "")
    Pixel.text(image, margin, 2 * small, title, recovering and 4 or 9, small, nil, split - 2 * margin)
    Pixel.rect(image, margin, 11 * small, width - 2 * margin, 1, 7)
    Pixel.rect(image, split, 15 * small, 1, height - 28 * small, 7)
    if speedColumn then
        Pixel.rect(image, speedLeft, 15 * small, 1, height - 28 * small, 7)
        Pixel.text(image, (speedLeft + width) / 2, 2 * small, throttleTitle, 9, small, "center")
    end
    local big = math.max(small, math.floor(math.min(height / 44, (right - left) / 48)))
    -- Instrument values share the smaller integer font step to preserve
    -- space around the heading markers and within the altitude column.
    local headingScale = math.max(small, big - 1)
    local baseline = math.floor(height * 0.40)
    local curveDepth = math.max(1, math.floor(height * 0.18))
    -- Lower the tape ends into a pronounced compass arc. Tick, label and target
    -- positions share this curve so they keep their bearing relationship.
    local function tapeY(x)
        local relative = (x - middle) / math.max(1, (right - left) / 2)
        return math.floor(baseline + curveDepth * relative * relative + 0.5)
    end
    local above = math.max(15 * small, math.floor(height * 0.20) - 3 * small)
    Pixel.text(image, middle, above, heading and string.format("%05.1f", heading) or "--.-", 0, headingScale, "center")
    Pixel.triangle(image, middle, baseline - 5 * small, 2 * small, "down", 0)
    for x = left, right do Pixel.rect(image, x, tapeY(x), 1, 1, 7) end
    if heading then
        local perDegree = (right - left) / 120
        for bearing = math.ceil((heading - 60) / 5) * 5, heading + 60, 5 do
            local x = math.floor(middle + (bearing - heading) * perDegree + 0.5)
            if x >= left and x <= right then
                local major = bearing % 30 == 0
                local y = tapeY(x)
                Pixel.rect(image, x, y - (major and 5 or 3) * small,
                    1, (major and 5 or 3) * small, 7)
                if major and x > left + 10 * small and x < right - 10 * small then
                    Pixel.text(image, x, y + 5 * small,
                        string.format("%03d", bearing % 360), 7, small, "center")
                end
            end
        end
        if target then
            local difference = shortestDelta(heading, target)
            local x = math.max(left, math.min(right, middle + difference * perDegree))
            -- Keep the edge selector and its value above the detail/footer
            -- region even where the curved tape reaches its lowest point.
            local markerY = math.min(tapeY(x) + 15 * small,
                height - 24 * small - 7 * headingScale)
            Pixel.triangle(image, x, markerY, 2 * small,
                math.abs(difference) <= 60 and "up" or (difference < 0 and "left" or "right"), commandIndex)
            local halfLabel = 15 * headingScale
            local valueX = math.max(left + halfLabel, math.min(right - halfLabel, x))
            Pixel.text(image, valueX, markerY + 5 * small, string.format("%05.1f", target), commandIndex, headingScale, "center")
        end
    end
    local detailY = height - 20 * small
    if recovering then
        Pixel.text(image, middle, detailY, "WAITING FOR TELEMETRY", 4, small, "center", right - left)
    elseif ap then
        local deviation = finiteDisplay(ap.crossTrack) and ap.crossTrack or nil
        local side = deviation and (deviation < 0 and " L" or (deviation > 0 and " R" or "")) or ""
        local detail = "DEV " .. shown(deviation and math.abs(deviation), 1, false) .. side ..
            "  DIST " .. shown(ap.distance, 0, false) .. " b"
        Pixel.deviation(image, left, right, middle, height, small, deviation, 0, detail)
    else
        local lateral = type(snapshot.lateralControl) == "table" and snapshot.lateralControl or {}
        if lateral.mode == "SEL" and lateral.active then
            local remaining = finiteDisplay(lateral.remaining) and lateral.remaining or nil
            local side = remaining and (remaining < 0 and " L" or (remaining > 0 and " R" or "")) or ""
            local detail = "STRAFE " .. shown(remaining and math.abs(remaining), 1, false) .. "b" .. side ..
                " " .. safeText(lateral.state or "MOVING")
            Pixel.deviation(image, left, right, middle, height, small, remaining, 4, detail)
        end
    end
    local actual = sensorValid(vessel, "altitude") and vessel.altitude or nil
    local altitudeTarget = targetValid(targets, "altitude") and targets.altitude or nil
    local hold, holdTone = altitudeHoldIndicator(snapshot, false)
    local targetIndex = ap and commandIndex or ((hold == "ABORTED" or hold == "ALT OFFLINE") and 7 or 4)
    local axis = split + 21 * small
    local altitudeRight = speedLeft - margin
    local altitudeMiddle = math.floor((split + speedLeft) / 2)
    Pixel.text(image, altitudeMiddle, 2 * small, hold or "ALTITUDE",
        tonumber(colorDigits[color(holdTone or "gray")] or "7", 16), small, "center", width - split - margin)
    -- Fixed readouts mirror the original instrument: measured altitude above
    -- the tape and the entered target below it; only the tape marker moves.
    Pixel.text(image, altitudeMiddle, 15 * small, shown(actual, 1, false), 0, headingScale, "center")
    local top, bottom = math.floor(height * 0.34), height - 26 * small
    local midY = math.floor((top + bottom) / 2)
    local perBlock = (bottom - top) / 40
    Pixel.rect(image, axis, top, 1, bottom - top + 1, 7)
    if actual then
        local ceiling = altitudeCeiling(snapshot)
        for level = math.ceil((actual - 20) / 5) * 5, actual + 20, 5 do
            local y = math.floor(midY - (level - actual) * perBlock + 0.5)
            if y >= top and y <= bottom and (not ceiling or level <= ceiling) then
                local index = level >= 290 and 14 or 7
                Pixel.rect(image, axis, y, 3 * small, 1, index)
                if level % 10 == 0 then Pixel.text(image, axis - 3 * small, y - 3 * small,
                    tostring(level), index, small, "right", 18 * small) end
            end
        end
        if altitudeTarget then
            local rawY = midY - (altitudeTarget - actual) * perBlock
            local y = math.max(top, math.min(bottom, rawY))
            Pixel.triangle(image, axis, y, 3 * small,
                rawY < top and "up" or (rawY > bottom and "down" or "right"), targetIndex)
        end
    end
    Pixel.triangle(image, axis + 6 * small, midY, 3 * small, "left", 0)
    Pixel.text(image, altitudeMiddle, height - 20 * small, shown(altitudeTarget, 1, false),
        targetIndex, headingScale, "center", width - split - margin)
    local footerY = height - 7 * small
    Pixel.rect(image, margin, height - 11 * small, width - 2 * margin, 1, 7)
    local requested = ap and ap.requestedSpeed or (modes.throttle == "SEL" and targets.speed or nil)
    if speedColumn then
        local actualSpeed = sensorValid(vessel, "forwardSpeed") and vessel.forwardSpeed or nil
        local selector, unit = propulsion.manualAcceleration, "b/s2"
        if throttleMode == "DIRECT" then selector, unit = propulsion.directRpm, "RPM"
        elseif throttleMode == "SEL" then selector, unit = requested, "b/s" end
        Pixel.speedometer(image, speedLeft, width, height, small, actualSpeed,
            throttleMode == "SEL" and requested or nil, selector, unit, commandIndex)
    end
    local anchored = snapshot.anchor == "BRAKING" or snapshot.anchor == "ANCHORED"
    if anchored then Pixel.text(image, margin, footerY, "ANCHORED", 4, small) end
    if not speedColumn then
        Pixel.text(image, split - margin, footerY, "SPD " .. shownSensor(vessel, "forwardSpeed", 1, false, false) .. " b/s",
            0, small, "right")
    end
    Pixel.text(image, altitudeRight, footerY, "V/S " .. shownSensor(vessel, "verticalSpeed", 2, true, false),
        0, small, "right", width - split - margin)
    if speedColumn then
        -- Move the completed speed column ahead of the heading and altitude
        -- columns. Each instrument keeps its own geometry and readout spacing.
        local speedWidth = width - speedLeft
        for y, row in ipairs(image.rows) do
            local reordered = {}
            for x = speedLeft + 1, width do reordered[#reordered + 1] = row[x] end
            for x = 1, speedLeft do reordered[#reordered + 1] = row[x] end
            image.rows[y] = reordered
        end
        -- The speed column's former left divider is now the outer edge;
        -- place its divider between speed and heading at the new boundary.
        Pixel.rect(image, 0, 15 * small, 1, height - 28 * small, 15)
        Pixel.rect(image, speedWidth, 15 * small, 1, height - 28 * small, 7)
        Pixel.rect(image, 0, 11 * small, width, 1, 7)
        Pixel.rect(image, 0, height - 11 * small, width, 1, 7)
    end
    if ap then
        -- AP owns the complete header while active; clear the individual mode
        -- labels after column placement and retain the continuous divider.
        Pixel.rect(image, 0, 0, width, 11 * small, 15)
        Pixel.text(image, width / 2, 2 * small, "AP - " .. safeText(ap.state or "ACTIVE"),
            commandIndex, small, "center", width - 2 * margin)
    end
    -- Open only the heading section's lower divider for route deviation.
    -- The speed and altitude footer bars remain in place.
    local headingStart = speedColumn and (width - speedLeft) or 0
    Pixel.rect(image, headingStart + 1, height - 11 * small, split - 1, 1, 15)
    return image
end

-- Summary: Seal a completed framebuffer into mode-1 byte rows for batching.
function Pixel.seal(image)
    local rows = {}
    for y, row in ipairs(image.rows) do rows[y] = table.concat(row) end
    return rows
end

-- Summary: Restore text mode after graphics failure or termination. Clear the
-- pixel cache so the next successful draw repaints the complete display.
local function leaveGraphics(displayObject)
    local monitor = displayObject.monitor
    if type(monitor.setFrozen) == "function" then pcall(monitor.setFrozen, false) end
    if type(monitor.setGraphicsMode) == "function" then
        local ok, reason = pcall(monitor.setGraphicsMode, 0)
        if not ok then return false, reason end
    end
    displayObject.pixelRows = nil
    displayObject.previous = nil
    return true
end

-- Summary: Build native instruments or rasterize a wrapped status frame into
-- byte rows, using queried pixel dimensions and zero-based graphics offsets.
-- Cache only completed frames; failed writes are retried through text mode.
local function drawGraphics(displayObject, surface, snapshot)
    local monitor = displayObject.monitor
    local width, height = monitor.getSize(1)
    if not finite(width) or not finite(height) or width < surface.width * 4 or
        height < surface.height * 6 or width > 8192 or height > 8192 or
        width * height > 2000000 then
        error("unsupported graphics dimensions")
    end
    width, height = math.floor(width), math.floor(height)
    local cellWidth = math.floor(width / surface.width)
    local cellHeight = math.floor(height / surface.height)
    local scale = math.max(1, math.floor(math.min(cellWidth / 4, cellHeight / 6)))
    local left = math.floor((cellWidth - 3 * scale) / 2)
    local top = math.floor((cellHeight - 5 * scale) / 2)
    local native = Pixel.frame(snapshot, displayObject.display, surface.width, surface.height, width, height)
    local rows = native and Pixel.seal(native) or {}
    if not native then
        for y = 1, surface.height do
            local row = surface.rows[y]
            for py = 0, cellHeight - 1 do
                local parts = {}
                local gy = math.floor((py - top) / scale)
                for x = 1, surface.width do
                    local glyph = PIXEL_FONT[string.upper(row.chars[x])] or PIXEL_FONT["?"]
                    local fg = tonumber(colorDigits[row.fg[x]] or "0", 16)
                    local bg = tonumber(colorDigits[row.bg[x]] or "f", 16)
                    local pixels = {}
                    for px = 0, cellWidth - 1 do
                        local gx = math.floor((px - left) / scale)
                        local lit = gx >= 0 and gx < 3 and gy >= 0 and gy < 5 and
                            glyph:sub(gy * 3 + gx + 1, gy * 3 + gx + 1) == "1"
                        pixels[#pixels + 1] = string.char(lit and fg or bg)
                    end
                    parts[#parts + 1] = table.concat(pixels)
                end
                parts[#parts + 1] = string.rep(string.char(15), width - surface.width * cellWidth)
                rows[#rows + 1] = table.concat(parts)
            end
        end
        while #rows < height do rows[#rows + 1] = string.rep(string.char(15), width) end
    end
    if not displayObject.pixelRows then monitor.setGraphicsMode(1) end
    if type(monitor.setFrozen) == "function" then monitor.setFrozen(true) end
    local old = displayObject.pixelRows
    local first = 1
    while first <= height do
        if old and old[first] == rows[first] then
            first = first + 1
        else
            local last = first
            while last < height and (not old or old[last + 1] ~= rows[last + 1]) do
                last = last + 1
            end
            local changed = {}
            for y = first, last do changed[#changed + 1] = rows[y] end
            monitor.drawPixels(0, first - 1, changed)
            first = last + 1
        end
    end
    if type(monitor.setFrozen) == "function" then monitor.setFrozen(false) end
    displayObject.pixelRows = rows
end

-- Summary: Write the prepared frame using graphics when supported. A graphics
-- failure disables that backend until reattachment and repaints in text mode.
local function drawToMonitor(displayObject, snapshot)
    local surface, issue = render(displayObject.monitor, snapshot, displayObject.display)
    local monitor = displayObject.monitor
    if config.graphicsMode ~= "text" and not displayObject.graphicsFailed and
        type(monitor.setGraphicsMode) == "function" and type(monitor.drawPixels) == "function" then
        local ok, reason = pcall(drawGraphics, displayObject, surface, snapshot)
        if ok then return issue end
        displayObject.graphicsFailed = tostring(reason)
        local restored, restoreReason = leaveGraphics(displayObject)
        if not restored then error("cannot restore text mode: " .. tostring(restoreReason)) end
        print("Amaryllis heading graphics unavailable; using text: " .. tostring(reason))
    end
    local resized = not displayObject.previous or
        displayObject.previous.width ~= surface.width or displayObject.previous.height ~= surface.height
    if resized then
        if type(displayObject.monitor.setBackgroundColor) == "function" then
            displayObject.monitor.setBackgroundColor(color("black"))
        end
        if type(displayObject.monitor.clear) == "function" then displayObject.monitor.clear() end
    end
    for y = 1, surface.height do
        local row = surface.rows[y]
        local old = displayObject.previous and displayObject.previous.rows[y]
        local text = table.concat(row.chars)
        local foreground, background = {}, {}
        for x = 1, surface.width do
            foreground[x] = colorDigits[row.fg[x]] or "0"
            background[x] = colorDigits[row.bg[x]] or "f"
        end
        local fg, bg = table.concat(foreground), table.concat(background)
        local key = text .. fg .. bg
        if resized or not old or old.key ~= key then
            -- blit needs one byte per cell; rows holding a multi-byte glyph are written per colour run.
            if type(displayObject.monitor.blit) == "function" and #text == surface.width then
                displayObject.monitor.setCursorPos(1, y)
                displayObject.monitor.blit(text, fg, bg)
            else
                drawPlainRow(displayObject.monitor, row, y)
            end
        end
        row.text, row.key = text, key
    end
    displayObject.previous = surface
    return issue
end

-- Summary: Render the current display error using the available monitor methods.
local function bestEffortErrorFrame(displayObject)
    leaveGraphics(displayObject)
    local monitor = displayObject.monitor
    local okSize, width, height = pcall(monitor.getSize)
    if not okSize or not finite(width) or not finite(height) or width < 1 or height < 1 then
        return false
    end
    width, height = math.floor(width), math.floor(height)
    local surface = errorSurface(width, height)
    if type(monitor.setBackgroundColor) == "function" then
        pcall(monitor.setBackgroundColor, color("black"))
    end
    if type(monitor.clear) == "function" then pcall(monitor.clear) end
    local wrote = false
    for y = 1, height do
        local row = surface.rows[y]
        local text = table.concat(row.chars)
        local foreground, background = {}, {}
        for x = 1, width do
            foreground[x] = colorDigits[row.fg[x]] or "0"
            background[x] = colorDigits[row.bg[x]] or "f"
        end
        local fg, bg = table.concat(foreground), table.concat(background)
        local positioned = pcall(monitor.setCursorPos, 1, y)
        if positioned and type(monitor.blit) == "function" then
            local ok = pcall(monitor.blit, text, fg, bg)
            wrote = wrote or ok
        elseif positioned and type(monitor.write) == "function" then
            if type(monitor.setTextColor) == "function" then pcall(monitor.setTextColor, color("red")) end
            if type(monitor.setBackgroundColor) == "function" then
                pcall(monitor.setBackgroundColor, color("black"))
            end
            local ok = pcall(monitor.write, text)
            wrote = wrote or ok
        end
    end
    displayObject.previous = nil
    return wrote
end

local function say(message)
    local detail = string.sub(safeText(message), 1, 2048)
    if detail ~= lastConsoleIssue then
        print("Amaryllis heading display: " .. detail)
        lastConsoleIssue = detail
    end
end

-- Summary: Check the reported peripheral type against the requested interface.
local function hasType(name, wanted)
    if peripheral.hasType then
        local ok, result = pcall(peripheral.hasType, name, wanted)
        if ok then return result == true end
    end
    if peripheral.getType then
        local ok, result = pcall(peripheral.getType, name)
        if not ok then return false end
        if type(result) == "table" then
            for _, item in ipairs(result) do
                if item == wanted then return true end
            end
            return false
        end
        return result == wanted
    end
    return false
end

local function sortedPeripheralNames()
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return nil, tostring(names) end
    table.sort(names)
    return names
end

-- Summary: Select the configured monitor from the attached peripheral inventory.
local function findMonitor()
    local names, reason = sortedPeripheralNames()
    if not names then return nil, "cannot list attached peripherals: " .. reason end
    local found = {}
    if type(config.monitorName) == "string" and config.monitorName ~= "" then
        if not hasType(config.monitorName, "monitor") then
            return nil, "configured monitor is not attached: " .. config.monitorName
        end
        found[1] = config.monitorName
    else
        for _, name in ipairs(names) do
            if hasType(name, "monitor") then found[#found + 1] = name end
        end
    end
    if #found == 0 then return nil, "no monitor is attached" end
    if #found > 1 then
        return nil, "multiple monitors are attached; set monitorName in config.json"
    end
    local ok, object = pcall(peripheral.wrap, found[1])
    if not ok or type(object) ~= "table" then
        return nil, "could not wrap monitor " .. found[1] .. ": " .. tostring(object)
    end
    return found[1], object
end

-- Summary: Bind the selected monitor and apply the configured text scale.
local function attachMonitor()
    local name, object = findMonitor()
    if not name then
        renderer, monitorName = nil, nil
        if lastMonitorError ~= object then
            say(tostring(object))
            lastMonitorError = object
        end
        return false
    end
    if type(object.setTextScale) ~= "function" or type(object.getSize) ~= "function" or
        type(object.setCursorPos) ~= "function" or
        (type(object.blit) ~= "function" and type(object.write) ~= "function") then
        local reason = "monitor lacks required getSize/setTextScale/setCursorPos/blit-or-write methods"
        renderer, monitorName = nil, nil
        if lastMonitorError ~= reason then
            say(reason)
            lastMonitorError = reason
        end
        pcall(bestEffortErrorFrame, { monitor = object, previous = nil })
        return false
    end
    local scaleOk, scaleError = pcall(object.setTextScale, textScale)
    if not scaleOk then
        local reason = "could not set monitor text scale: " .. tostring(scaleError)
        renderer, monitorName = nil, nil
        if lastMonitorError ~= reason then say(reason) lastMonitorError = reason end
        pcall(bestEffortErrorFrame, { monitor = object, previous = nil })
        return false
    end
    renderer = { monitor = object, display = config.display, previous = nil }
    -- A previous program may have left the physical monitor in graphics mode.
    -- Reset before either backend draws, including an explicit text override.
    local restored, restoreReason = leaveGraphics(renderer)
    if not restored then
        renderer, monitorName = nil, nil
        lastMonitorError = "could not restore monitor text mode: " .. tostring(restoreReason)
        say(lastMonitorError)
        return false
    end
    monitorName, lastMonitorError = name, nil
    return true
end

-- Summary: Find and open wireless modems for fleet status reception.
local function openWirelessModems()
    local names, listError = sortedPeripheralNames()
    if not names then
        say("cannot list peripherals while opening wireless modem: " .. tostring(listError))
        return false
    end
    local foundModem, opened, lastError = false, false, nil
    for _, name in ipairs(names) do
        if hasType(name, "modem") then
            foundModem = true
            local wrapOk, modem = pcall(peripheral.wrap, name)
            if not wrapOk or type(modem) ~= "table" then
                lastError = "could not wrap modem " .. name .. ": " .. tostring(modem)
            elseif type(modem.isWireless) ~= "function" then
                lastError = "modem " .. name .. " does not provide isWireless()"
            else
                local wirelessOk, wireless = pcall(modem.isWireless)
                if not wirelessOk then
                    lastError = "could not query modem " .. name .. " wireless status: " .. tostring(wireless)
                elseif wireless then
                    local openOk, alreadyOpen = pcall(rednet.isOpen, name)
                    if openOk and alreadyOpen then
                        opened = true
                    else
                        local callOk, openError = pcall(rednet.open, name)
                        if callOk then opened = true end
                        if not callOk then lastError = "could not open modem " .. name .. ": " .. tostring(openError) end
                    end
                end
            end
        end
    end
    if not opened then
        say(lastError or (foundModem and "no wireless modem could be opened" or
            "no wireless modem is attached; core telemetry cannot be received"))
    end
    return opened
end

local function finiteInteger(value, minimum)
    return type(value) == "number" and value == value and value ~= math.huge and
        value ~= -math.huge and value >= minimum and value % 1 == 0
end

local function cleanNumber(value)
    if finiteDisplay(value) then return value end
    return nil
end

-- Summary: Validate and bound the received vessel/display snapshot.
local function sanitizeSnapshot(state)
    local result = { vessel = {}, targets = {} }
    local propulsion=type(state.propulsion)=="table" and state.propulsion or {}
    result.propulsion={manualAcceleration=cleanNumber(propulsion.manualAcceleration),
        directRpm=cleanNumber(propulsion.directRpm)}
    if propulsion.mode=="MANUAL" or propulsion.mode=="SEL" or propulsion.mode=="DIRECT" then
        result.propulsion.mode=propulsion.mode
    end
    local thrust=type(state.thrust)=="table" and state.thrust or {}
    if type(thrust.headingControl)=="table" then
        result.headingControl={targetYawRate=cleanNumber(thrust.headingControl.targetYawRate)}
    end
    if type(state.autopilot)=="table" then
        local ap=state.autopilot
        result.autopilot={active=ap.active==true}
        for _,key in ipairs({"distance","crossTrack","cruiseSpeed","requestedSpeed","requestedHeading"}) do
            result.autopilot[key]=cleanNumber(ap[key])
        end
        for _,key in ipairs({"state","reason"}) do
            if type(ap[key])=="string" then result.autopilot[key]=string.sub(safeText(ap[key]),1,160) end
        end
        local route=type(ap.route)=="table" and ap.route or {}
        local entry=type(route.entries)=="table" and route.entries[route.index or 1] or nil
        if type(entry)=="table" and type(entry.name)=="string" then
            result.autopilot.destinationName=string.sub(safeText(entry.name),1,40)
        end
    end
    if type(state.lateralControl)=="table" then
        local lateral=state.lateralControl
        result.lateralControl={active=lateral.active==true,mode=lateral.mode=="SEL" and "SEL" or "MANUAL"}
        for _,key in ipairs({"offset","remaining","sidewaysSpeed"}) do result.lateralControl[key]=cleanNumber(lateral[key]) end
        if type(lateral.state)=="string" then result.lateralControl.state=string.sub(safeText(lateral.state),1,24) end
    end
    local vessel = type(state.vessel) == "table" and state.vessel or {}
    local targets = type(state.targets) == "table" and state.targets or {}
    local sensorFields = {
        "altitude", "heading", "pitch", "roll", "verticalSpeed", "forwardSpeed", "mass",
    }
    for _, field in ipairs(sensorFields) do
        result.vessel[field] = cleanNumber(vessel[field])
    end
    if type(vessel.valid) == "boolean" then result.vessel.valid = vessel.valid end
    if type(vessel.reason) == "string" then
        result.vessel.reason = string.sub(safeText(vessel.reason), 1, 2048)
    end
    -- Keep core provenance and sample age for Status/Logs without consulting
    -- local sensors. Display receipt age and measurement age are distinct.
    result.vessel.sampleAgeSeconds=cleanNumber(vessel.sampleAgeSeconds)
    for _,field in ipairs({"altitudeSource","headingSource","altitudeUnit"}) do
        if type(vessel[field])=="string" then result.vessel[field]=string.sub(safeText(vessel[field]),1,128) end
    end
    if type(vessel.validFields) == "table" then
        result.vessel.validFields = {}
        for _, field in ipairs(sensorFields) do
            if type(vessel.validFields[field]) == "boolean" then
                result.vessel.validFields[field] = vessel.validFields[field]
            end
        end
    end
    for _, field in ipairs(sensorFields) do
        if type(vessel[field .. "Valid"]) == "boolean" then
            result.vessel[field .. "Valid"] = vessel[field .. "Valid"]
        end
    end
    for _, field in ipairs({ "altitude", "heading", "speed" }) do
        result.targets[field] = cleanNumber(targets[field])
    end
    local systems=type(state.systemsStartup)=="table" and state.systemsStartup or nil
    if systems then
        result.systemsStartup={}
        local labels={["OPENING STEAM VENTS"]=true,["STATIC INFLATION"]=true,["CAPTURING PITCH ZERO"]=true,["ACQUIRING SEL ALT"]=true,READY=true}
        if labels[systems.displayPhase] then result.systemsStartup.displayPhase=systems.displayPhase end
        if type(systems.active)=="boolean" then result.systemsStartup.active=systems.active end
        local phases={ABORTED=true,HOLDING=true,MAIN_LIFT=true,PROBING=true,
            VERIFYING=true,VENT_IGNITION=true,STOPPED=true,STOPPING=true,BLOCKED=true,
            READY=true,IDLE=true}
        if type(systems.phase)=="string" then
            local phase=string.upper(safeText(systems.phase))
            if phases[phase] then result.systemsStartup.phase=phase end
        end
        if type(systems.abortReason)=="string" then
            result.systemsStartup.abortReason=string.sub(safeText(systems.abortReason),1,160)
        end
    end
    local altitudeControl=type(state.altitudeControl)=="table" and state.altitudeControl or nil
    if altitudeControl and type(altitudeControl.enabled)=="boolean" then
        result.altitudeControl={enabled=altitudeControl.enabled}
    end
    if altitudeControl and type(altitudeControl.ceiling)=="number" and
        altitudeControl.ceiling==altitudeControl.ceiling and math.abs(altitudeControl.ceiling)<=4096 then
        result.altitudeControl=result.altitudeControl or {}
        result.altitudeControl.ceiling=altitudeControl.ceiling
    end
    if type(state.assembly) == "table" then
        local states = { ASSEMBLED = true, ASSEMBLING = true, DISASSEMBLED = true, UNKNOWN = true }
        local assembly = state.assembly
        result.assembly = { state = states[assembly.state] and assembly.state or "UNKNOWN" }
        if type(assembly.reason) == "string" then
            result.assembly.reason = string.sub(safeText(assembly.reason), 1, 160)
        end
    end
    if type(state.fleetBoot)=="table" and type(state.fleetBoot.ready)=="boolean" then
        local fleet=state.fleetBoot
        result.fleetBoot={ready=fleet.ready}
        local phases={WAITING_ASSEMBLY=true,DISCOVERING=true,ZEROING_PROPULSION=true,
            RESTARTING=true,VERIFYING=true,COMPLETE=true,FAILED=true,CANCELLED=true}
        if type(fleet.phase)=="string" and phases[fleet.phase] then result.fleetBoot.phase=fleet.phase end
        if type(fleet.current)=="string" then result.fleetBoot.current=string.sub(safeText(fleet.current),1,96) end
        if finiteInteger(fleet.completed,0) and fleet.completed<=10000 then result.fleetBoot.completed=fleet.completed end
        if finiteInteger(fleet.total,0) and fleet.total<=10000 then result.fleetBoot.total=fleet.total end
        if type(fleet.reason)=="string" then result.fleetBoot.reason=string.sub(safeText(fleet.reason),1,160) end
    end
    if type(state.modes) == "table" then
        result.modes = {}
        for _, field in ipairs({ "heading", "throttle", "altitude" }) do
            local mode = state.modes[field]
            if type(mode) == "string" and #mode <= 16 and mode:match("^[%w _%-]+$") then
                result.modes[field] = mode
            end
        end
    end
    if type(state.effectiveModes)=="table" then
        result.effectiveModes={}
        for _,field in ipairs({"heading","throttle","altitude"}) do
            local mode=state.effectiveModes[field]
            if type(mode)=="string" and #mode<=16 and mode:match("^[%w _%-]+$") then
                result.effectiveModes[field]=mode
            end
        end
    end
    if type(state.anchor) == "string" and
        (state.anchor == "OFF" or state.anchor == "BRAKING" or state.anchor == "ANCHORED") then
        result.anchor = state.anchor
    else
        result.anchor = "UNAVAILABLE"
    end
    result.authorityReady = state.authorityReady == true
    return result
end

-- Summary: Validate and cache a fresh status packet from the configured core.
local function acceptStatus(sender, message)
    if sender ~= config.coreId or type(message) ~= "table" or
        message.v ~= 1 or message.kind ~= "display_status" or
        type(message.state) ~= "table" then
        return false
    end
    local registry=os.__amaryllisFleetRegistry
    if not registryIdentity or type(registry)~="table" or message.session~=registry.session then return false end
    if type(message.session) ~= "string" or #message.session == 0 or #message.session > 128 or
        not message.session:match("^[%w_%.%-:]+$") or
        not finiteInteger(message.seq, 1) or message.seq > 2147483647 then
        return false
    end
    if message.session == activeSession then
        if message.seq <= latestSequence then return false end
    elseif retiredSessions[message.session] then
        return false
    else
        if activeSession then
            retiredSessions[activeSession] = true
            retiredSessionOrder[#retiredSessionOrder + 1] = activeSession
            if #retiredSessionOrder > 32 then
                retiredSessions[table.remove(retiredSessionOrder, 1)] = nil
            end
        end
        activeSession, latestSequence = message.session, 0
    end
    latestSequence = message.seq
    latestState = sanitizeSnapshot(message.state)
    receivedAt = os.clock()
    return true
end

-- Summary: Resolve the current status snapshot and its stale-display treatment.
local function displaySnapshot(now, forceStale)
    if type(latestState) ~= "table" then
        return { displayStale = true, dataFresh = false, anchor = "UNAVAILABLE" }, false
    end
    local age = receivedAt and finite(now) and now - receivedAt or math.huge
    local fresh = not forceStale and age >= 0 and age <= timeout
    local snapshot = {}
    for key, value in pairs(latestState) do snapshot[key] = value end
    -- Measure snapshot age in seconds from this display computer's receipt time.
    snapshot.displayStale = not fresh
    snapshot.dataFresh = fresh
    snapshot.stale = not fresh
    return snapshot, fresh
end

-- Summary: Render the current view into its configured terminal or monitor.
local function draw(forceStale)
    local snapshot = displaySnapshot(os.clock(), forceStale)
    -- Publish even without an attached monitor so diagnostics can inspect
    -- receiver freshness. Receipt age/validity still belongs to this receiver.
    os.__amaryllisRuntime = { publishedAt = os.clock(), snapshot = snapshot, running = true, hardwareAvailable = renderer ~= nil, faultSummary = lastDrawError or lastMonitorError }
    if not renderer then return end
    local ok, issue = pcall(drawToMonitor, renderer, snapshot)
    if not ok then
        local detail = "monitor draw failed: " .. tostring(issue)
        if detail ~= lastDrawError then say(detail) end
        lastDrawError = detail
        pcall(bestEffortErrorFrame, renderer)
        return
    end
    lastDrawError = nil
    if issue then
        say(issue)
    else
        lastConsoleIssue = nil
    end
end

-- Summary: Initialize the role and run its configured display/network service.
local function run()
    syncRegistry()
    attachMonitor()
    openWirelessModems()
    draw()

    local timer = os.startTimer(pollInterval)
    local wasFresh = false
    local heartbeatSeq,nextHeartbeat=0,0
    local heartbeatBoot=tostring(config.computerId).."-"..
        string.format("%.0f",os.epoch and os.epoch("utc") or os.clock()*1000)
    local restartContext={coreId=config.coreId,targetLabel=currentLabel,nodeBoot=heartbeatBoot,
        getSession=function()
            local _,fresh=displaySnapshot(os.clock())
            if fresh then return activeSession end
            return nil
        end,seen={},order={}}
    while true do
        local event, first, second, third = os.pullEventRaw()
        if event == "rednet_message" then
            local sender, message, receivedProtocol = first, second, third
            restartContext.session=restartContext.getSession()
            if sender==config.coreId and receivedProtocol=="amaryllis.v1" and type(message)=="table" and message.kind=="fleet_registry" then
                Console.acceptRegistry(sender,message,receivedProtocol,config.role,os.getComputerID(),config.coreId)
                syncRegistry()
            elseif handleRestart(sender,message,receivedProtocol,restartContext,rednet.send,os.reboot) then
                -- The acknowledgement is sent before the accepted request reboots.
            elseif receivedProtocol == protocol and acceptStatus(sender, message) then
                draw()
                wasFresh = true
            end
        elseif event == "timer" and first == timer then
            timer = os.startTimer(pollInterval)
            local _, fresh = displaySnapshot(os.clock())
            -- Publish local receipt freshness on every refresh, including a
            -- stable connection or persistent outage, for the status console.
            draw()
            wasFresh = fresh
            -- This is a role-health report, not an actuator command or proof of
            -- sensor validity. Core uses its own receipt time for expiry.
            if activeSession and os.clock()>=nextHeartbeat then
                heartbeatSeq=math.min(heartbeatSeq+1,2147483647)
                pcall(rednet.send,config.coreId,{v=1,kind="subsystem_status",session=activeSession,
                    boot=heartbeatBoot,seq=heartbeatSeq,label=config.computerLabel,role="heading",
                    coreDataFresh=fresh,monitorAttached=renderer~=nil},protocol)
                nextHeartbeat=os.clock()+1
            end
        elseif event == "peripheral" then
            openWirelessModems()
            if not renderer then attachMonitor() end
            draw()
        elseif event == "peripheral_detach" then
            if first == monitorName then
                renderer, monitorName = nil, nil
            end
            openWirelessModems()
            if not renderer then attachMonitor() end
            draw()
        elseif event == "monitor_resize" then
            if first == monitorName then draw() end
        elseif event == "terminate" then
            if renderer then
                renderer.graphicsFailed = "terminated"
                leaveGraphics(renderer)
            end
            draw(true)
            return
        end
    end
end

-- The host-side suite loads this file in an isolated fake CC environment.
-- This test hook remains inert on the computer unless a test sets the flag.
if rawget(_G, "__AMARYLLIS_TEST") == true then
    return {
        acceptStatus = acceptStatus,
        displaySnapshot = displaySnapshot,
        draw = draw,
        frame = frame,
        sanitizeSnapshot = sanitizeSnapshot,
        validateRestart = validateRestart,
        handleRestart = handleRestart,
        run = run,
    }
end

local ok, reason = xpcall(run, function(errorValue) return tostring(errorValue) end)
if not ok then
    local detail = "receiver loop failed: " .. tostring(reason)
    say(detail)
    if renderer then pcall(bestEffortErrorFrame, renderer) end
    error("Amaryllis heading display stopped: " .. tostring(reason), 0)
end

