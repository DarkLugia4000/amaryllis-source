-- Section: Navigator presentation | Character frames, warning selection and pilot input.
-- Navigator information pages v1
-- A.E.V. Amaryllis display renderer.
-- Render cached vessel snapshots and return locally selected operator actions.
local UI = {}
local Info

UI.TEXT_SCALE = 0.5
UI.MIN_MAIN_WIDTH = 57
UI.MIN_MAIN_HEIGHT = 24
UI.PAGES = { "FLIGHT", "NAV", "SHIP", "SETTINGS" }
UI.KILL_REVIEW_SECONDS = 10

local colorValues = {
    white = 1, gray = 128, lightGray = 256, cyan = 512,
    yellow = 16, green = 8192, red = 16384, black = 32768,
}
local colorDigits = {
    [1] = "0", [2] = "1", [4] = "2", [8] = "3",
    [16] = "4", [32] = "5", [64] = "6", [128] = "7",
    [256] = "8", [512] = "9", [1024] = "a", [2048] = "b",
    [4096] = "c", [8192] = "d", [16384] = "e", [32768] = "f",
}

-- A compact 3x5 font makes the primary speed value visually dominant while
-- keeping the monitor at the agreed, readable 0.5 text scale. Each row is a
-- three-bit mask; lit cells are painted with background color, not glyphs.
local largeGlyphs = {
    ["0"] = { 7, 5, 5, 5, 7 },
    ["1"] = { 2, 6, 2, 2, 7 },
    ["2"] = { 7, 1, 7, 4, 7 },
    ["3"] = { 7, 1, 3, 1, 7 },
    ["4"] = { 5, 5, 7, 1, 1 },
    ["5"] = { 7, 4, 7, 1, 7 },
    ["6"] = { 7, 4, 7, 5, 7 },
    ["7"] = { 7, 1, 1, 2, 2 },
    ["8"] = { 7, 5, 7, 5, 7 },
    ["9"] = { 7, 5, 7, 1, 7 },
    ["+"] = { 0, 2, 7, 2, 0 },
    ["-"] = { 0, 0, 7, 0, 0 },
    ["."] = { 0, 0, 0, 0, 2 },
    ["e"] = { 0, 6, 7, 4, 3 },
}

local function finite(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end

-- Section: Display data | Field validity, formatting and status selection.
-- Summary: Whether a message reports an expired or lost command or control lease, which is a recoverable warning.
local function leaseText(value)
    return type(value) == "string" and string.find(string.upper(value), "LEASE", 1, true) ~= nil
end

-- Summary: The pilot-facing wording for a lease problem: the core paused briefly and is retrying by itself.
local function stallText(snapshot)
    local recovery = type(snapshot) == "table" and type(snapshot.systemsStartup) == "table" and snapshot.systemsStartup.recovery or {}
    local attempts = type(recovery) == "table" and tonumber(recovery.attempts) or 0
    if attempts >= 1 then return "CORE STALL; RESOLVING (RETRY " .. math.floor(attempts) .. ")" end
    return "CORE STALL; RESOLVING"
end

-- Summary: Bound display text to the available character count.
local function clampText(value, limit)
    local text = tostring(value or "")
    -- Keep text to the basic terminal character set so byte positions match
    -- monitor columns on every ComputerCraft font and Lua build.
    text = string.gsub(text, "[^\032-\126]", "?")
    if #text > limit then
        text = string.sub(text, 1, math.max(0, limit - 3)) .. "..."
    end
    return text
end

local function numberText(value, decimals, signed)
    if not finite(value) then return "--" end
    if signed then
        return string.format("%+." .. tostring(decimals) .. "f", value)
    end
    return string.format("%." .. tostring(decimals) .. "f", value)
end

local function integerText(value)
    if not finite(value) then return "--" end
    return tostring(math.floor(value + 0.5))
end

local function normalizeHeading(value)
    if not finite(value) then return nil end
    return value % 360
end

local function angleText(value)
    local heading = normalizeHeading(value)
    if heading == nil then return "--.-" end
    return string.format("%05.1f", heading)
end

local function getColor(name)
    if type(colors) == "table" and colors[name] then return colors[name] end
    return colorValues[name] or colorValues.white
end

-- Section: Operator navigation | Local selection, editing and returned actions.
-- Summary: Allocate the main renderer's character, foreground and background cells.
local function newSurface(width, height)
    local surface = { width = width, height = height, rows = {} }
    local white, black = getColor("white"), getColor("black")
    for y = 1, height do
        local row = { chars = {}, fg = {}, bg = {} }
        for x = 1, width do
            row.chars[x], row.fg[x], row.bg[x] = " ", white, black
        end
        surface.rows[y] = row
    end
    return surface
end

-- Section: Display data | Field validity, formatting and status selection.
-- Summary: Write bounded text cells with the selected foreground colour.
local function put(surface, x, y, text, tone)
    if y < 1 or y > surface.height or x > surface.width then return end
    text = clampText(text, surface.width)
    local foreground = getColor(tone or "white")
    for index = 1, #text do
        local targetX = x + index - 1
        if targetX >= 1 and targetX <= surface.width then
            local char = string.sub(text, index, index)
            if char ~= "\n" and char ~= "\r" then
                surface.rows[y].chars[targetX] = char
                surface.rows[y].fg[targetX] = foreground
            end
        end
    end
end

-- Paint rectangular UI elements by changing each cell's background. The
-- character stays blank, so buttons and the speed digits are real filled
-- shapes instead of text characters that merely imitate them.
-- Summary: Fill the bounded surface rectangle with the selected cell colours.
local function fillRect(surface, x, y, width, height, backgroundTone, foregroundTone)
    local background = getColor(backgroundTone or "black")
    local foreground = getColor(foregroundTone or "white")
    local left, top = math.max(1, x), math.max(1, y)
    local right = math.min(surface.width, x + width - 1)
    local bottom = math.min(surface.height, y + height - 1)
    for rowY = top, bottom do
        local row = surface.rows[rowY]
        for columnX = left, right do
            row.chars[columnX] = " "
            row.fg[columnX] = foreground
            row.bg[columnX] = background
        end
    end
end

-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Render the label using its selected, enabled, disabled or danger style.
local function drawButton(surface, x, y, width, label, state)
    local background, foreground
    if state == "selected" then
        background, foreground = "cyan", "black"
    elseif state == "enabled" then
        background, foreground = "white", "black"
    elseif state == "danger" then
        background, foreground = "red", "white"
    else
        background, foreground = "gray", "lightGray"
    end
    fillRect(surface, x, y, width, 1, background, foreground)
    label = clampText(label, width)
    local labelX = x + math.floor((width - #label) / 2)
    put(surface, labelX, y, label, foreground)
end

local function drawLargePixel(surface, x, y, tone)
    if x < 1 or x > surface.width or y < 1 or y > surface.height then return end
    local row = surface.rows[y]
    row.chars[x] = " "
    row.fg[x] = getColor("black")
    row.bg[x] = getColor(tone)
end

local function centered(surface, y, text, tone)
    text = clampText(text, surface.width)
    local x = math.floor((surface.width - #text) / 2) + 1
    put(surface, x, y, text, tone)
end

-- Section: Display data | Field validity, formatting and status selection.
-- Summary: Convert the surface cells into terminal text and blit rows.
local function finishSurface(surface)
    for y = 1, surface.height do
        local row = surface.rows[y]
        local fg, bg = {}, {}
        row.text = table.concat(row.chars)
        for x = 1, surface.width do
            fg[x] = colorDigits[row.fg[x]] or "0"
            bg[x] = colorDigits[row.bg[x]] or "f"
        end
        row.foreground, row.background = table.concat(fg), table.concat(bg)
        row.key = row.text .. row.foreground .. row.background
    end
    return surface
end

-- Summary: Read and validate the monitor's current character dimensions.
local function monitorSize(monitor)
    if type(monitor) ~= "table" or type(monitor.getSize) ~= "function" then
        return nil, nil, "monitor does not provide getSize()"
    end
    local ok, width, height = pcall(monitor.getSize)
    if not ok then return nil, nil, "could not read monitor size: " .. tostring(width) end
    if not finite(width) or not finite(height) or width < 1 or height < 1 then
        return nil, nil, "monitor returned an invalid size"
    end
    return math.floor(width), math.floor(height)
end

-- Summary: Clear the monitor and reset its drawing state.
local function clearMonitor(monitor)
    if type(monitor.setBackgroundColor) == "function" then
        monitor.setBackgroundColor(getColor("black"))
    elseif type(monitor.setBackgroundColour) == "function" then
        monitor.setBackgroundColour(getColor("black"))
    end
    if type(monitor.setTextColor) == "function" then
        monitor.setTextColor(getColor("white"))
    elseif type(monitor.setTextColour) == "function" then
        monitor.setTextColour(getColor("white"))
    end
    if type(monitor.clear) == "function" then monitor.clear() end
end

-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Write one character row through the monitor's plain-text methods.
local function drawPlainRow(monitor, row, y)
    if type(monitor.setCursorPos) ~= "function" or type(monitor.write) ~= "function" then
        error("monitor lacks setCursorPos() or write()")
    end
    local setTextColor = monitor.setTextColor or monitor.setTextColour
    local setBackgroundColor = monitor.setBackgroundColor or monitor.setBackgroundColour
    local first = 1
    while first <= #row.text do
        local foreground = row.fg[first]
        local background = row.bg[first]
        local last = first
        while last < #row.text and row.fg[last + 1] == foreground and
            row.bg[last + 1] == background do
            last = last + 1
        end
        if type(setTextColor) == "function" then setTextColor(foreground) end
        if type(setBackgroundColor) == "function" then setBackgroundColor(background) end
        monitor.setCursorPos(first, y)
        monitor.write(string.sub(row.text, first, last))
        first = last + 1
    end
end

-- Summary: Flush changed character rows to the configured display.
local function drawSurface(renderer, surface)
    local monitor = renderer.monitor
    local resized = not renderer.previous or renderer.previous.width ~= surface.width or
        renderer.previous.height ~= surface.height
    if resized then clearMonitor(monitor) end
    for y = 1, surface.height do
        local row = surface.rows[y]
        local old = renderer.previous and renderer.previous.rows[y]
        if resized or not old or old.key ~= row.key then
            if type(monitor.blit) == "function" then
                monitor.setCursorPos(1, y)
                monitor.blit(row.text, row.foreground, row.background)
            else
                drawPlainRow(monitor, row, y)
            end
        end
    end
    renderer.previous = surface
end

local function isLive(snapshot)
    return snapshot.displayStale ~= true and snapshot.stale ~= true and
        snapshot.dataFresh ~= false
end

-- Unavailable core snapshots share the auxiliary network-state label. Up to
-- STALE_NOTICE_SECONDS they read WAITING FOR CORE; after that CORE UNREACHABLE
-- with the age of the newest snapshot (recorded by UI:draw in displayAge).
local STALE_NOTICE_SECONDS = 10
local displayAge = nil
local function staleLabel()
    if finite(displayAge) and displayAge > STALE_NOTICE_SECONDS then
        return string.format("CORE UNREACHABLE %.0f S", displayAge), "yellow"
    end
    return "WAITING FOR CORE", "yellow"
end

local function getTargets(snapshot)
    return type(snapshot.targets) == "table" and snapshot.targets or {}
end

local function modeText(modes, field)
    modes = type(modes) == "table" and modes or {}
    local value = modes[field]
    if type(value) ~= "string" or value == "" then return "UNAVAILABLE" end
    return clampText(string.upper(value), 12)
end

local function nodeStatus(node)
    if type(node) ~= "table" then return nil end
    return type(node.status) == "table" and node.status or node
end

local function providerMap(node)
    local status = nodeStatus(node)
    if not status then return nil end
    if type(status.providers) == "table" then return status.providers end
    if type(node.providers) == "table" then return node.providers end
    return nil
end

-- Section: Display data | Field validity, formatting and status selection.
local function controlState(node,key)
    if type(node)~="table" or node.online==false then return "FAULT" end
    local v=node[key] or (type(node.status)=="table" and node.status[key])
    if v=="CMD" or v=="RDY" or v=="FAULT" then return v end
    return "FAULT"
end
local function controlTone(state) return state=="FAULT" and "red" or (state=="CMD" and "yellow" or "green") end
-- Summary: Format a chamber's link, control, lift, gas and target observations.
local function nodeSummary(name, node)
    if type(node) ~= "table" then return name .. " UNKNOWN" end
    local online = node.online == true and "ON" or (node.online == false and "OFF" or "LINK--")
    local ready = "THRUST "..controlState(node,"thrustControlState")
    local armed = "LIFT "..controlState(node,"liftControlState")
    local status = nodeStatus(node) or {}
    local balloon = type(status.balloon) == "table" and status.balloon or
        (type(node.balloon) == "table" and node.balloon or {})
    local lift = balloon.liftValid == true and finite(balloon.lift) and
        integerText(balloon.lift) or "--"
    local providers = providerMap(node)
    local gas, ceiling, providerTotal = 0, 0, 0
    local allGasValid, allCeilingsValid = providers ~= nil, providers ~= nil
    for _, provider in pairs(providers or {}) do
        providerTotal = providerTotal + 1
        if type(provider) ~= "table" then
            allGasValid, allCeilingsValid = false, false
        else
            if provider.gasOutputValid == true and finite(provider.gasOutput) then
                gas = gas + provider.gasOutput
            else
                allGasValid = false
            end
            if provider.targetValid == true and finite(provider.targetAmount) then
                ceiling = ceiling + provider.targetAmount
            else
                allCeilingsValid = false
            end
        end
    end
    local rate = allGasValid and providerTotal > 0 and numberText(gas, 2, false) or "--"
    local target = allCeilingsValid and providerTotal > 0 and integerText(ceiling) or "--"
    -- Lift force is the single configured representative balloon reading.
    -- Per-provider ceilings and gas readings may be summed within this node;
    -- balloon lift is a single representative and is never summed.
    return name .. " " .. online .. " " .. ready .. " " .. armed ..
        "   L=" .. lift .. "   G=" .. rate .. "   T=" .. target
end

-- Summary: Choose the chamber status colour from link/readiness and reported faults.
local function nodeTone(node)
    if type(node) ~= "table" then return "gray" end
    local status = nodeStatus(node) or {}
    local faults = node.faults or status.faults
    if node.online == false or node.ready == false or
        (type(faults) == "table" and next(faults) ~= nil) then
        return "red"
    end
    if node.online == true and node.ready == true then return "green" end
    return "gray"
end

-- Summary: Resolve the chamber gas, target and lift values for its tile.
local function nodeTileMeasurements(node)
    local status = nodeStatus(node) or {}
    local balloon = type(status.balloon) == "table" and status.balloon or
        (type(node) == "table" and type(node.balloon) == "table" and node.balloon or {})
    local lift = balloon.liftValid == true and finite(balloon.lift) and
        integerText(balloon.lift) or "--"
    local providers = providerMap(node)
    local gas, ceiling, total = 0, 0, 0
    local allGasValid, allCeilingsValid = providers ~= nil, providers ~= nil
    for _, provider in pairs(providers or {}) do
        total = total + 1
        if type(provider) ~= "table" then
            allGasValid, allCeilingsValid = false, false
        else
            if provider.gasOutputValid == true and finite(provider.gasOutput) then
                gas = gas + provider.gasOutput
            else
                allGasValid = false
            end
            if provider.targetValid == true and finite(provider.targetAmount) then
                ceiling = ceiling + provider.targetAmount
            else
                allCeilingsValid = false
            end
        end
    end
    local rate = allGasValid and total > 0 and numberText(gas, 2, false) or "--"
    local target = allCeilingsValid and total > 0 and integerText(ceiling) or "--"
    return lift, rate, target
end

-- Summary: Report the lowest measured bulk-vent boiler efficiency of a chamber as a whole percent.
-- The percent is rounded down, so 100% appears only when the start requirement of 100% is met.
-- The reading is "--" until the chamber reports a valid efficiency (after its probe burner starts).
local function nodeBoilerText(node)
    local lowest
    for _, provider in pairs(providerMap(node) or {}) do
        if type(provider) == "table" and provider.controlRole == "bulk" and
            provider.boilerEfficiencyValid == true and finite(provider.boilerEfficiency) and
            (not lowest or provider.boilerEfficiency < lowest) then
            lowest = provider.boilerEfficiency
        end
    end
    if not lowest then return "BOILER --" end
    return string.format("BOILER %d%%", math.floor(lowest * 100))
end

local function putColumn(surface, x, y, width, text, tone)
    if width < 1 then return end
    put(surface, x, y, clampText(text, width), tone)
end

local function putControlStatus(surface,x,y,width,label,state,suffix)
    putColumn(surface,x,y,width,label..state..(suffix or ""),"white")
    local remaining=width-#label
    if remaining>0 then put(surface,x+#label,y,state:sub(1,remaining),controlTone(state)) end
end

local function centeredColumn(surface, x, width, y, text, tone)
    text = clampText(text, width)
    local left = x + math.floor((width - #text) / 2)
    put(surface, left, y, text, tone)
end

-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Render the four chamber control states and measured outputs.
local function drawQuadrantTiles(surface, nodes, rightX, rightWidth)
    centeredColumn(surface, rightX, rightWidth, 7, "CHAMBERS", "gray")
    local gap = rightWidth >= 27 and 1 or 0
    local tileWidth = math.floor((rightWidth - gap) / 2)
    local tiles = {
        { name = "FL", x = rightX, width = tileWidth, y = 8 },
        { name = "FR", x = rightX + tileWidth + gap, width = rightWidth - tileWidth - gap, y = 8 },
        { name = "BL", x = rightX, width = tileWidth, y = 15 },
        { name = "BR", x = rightX + tileWidth + gap, width = rightWidth - tileWidth - gap, y = 15 },
    }
    for _, tile in ipairs(tiles) do
        local node = nodes[tile.name]
        local link
        if type(node) ~= "table" then
            link = "LINK --"
        elseif node.online == true then
            link = "ONLINE"
        elseif node.online == false then
            link = "OFFLINE"
        else
            link = "LINK --"
        end
        local lift, rate, target = nodeTileMeasurements(node)
        local ready, armed
        if type(node) == "table" then
            ready, armed = node.ready, node.armed
        end
        putColumn(surface, tile.x, tile.y, tile.width, tile.name .. " " .. link, nodeTone(node))
        putControlStatus(surface,tile.x,tile.y+1,tile.width,"THRUST ",controlState(node,"thrustControlState"))
        putControlStatus(surface,tile.x,tile.y+2,tile.width,"LIFT ",controlState(node,"liftControlState"))
        putColumn(surface, tile.x, tile.y + 3, tile.width, "GAS " .. rate, "white")
        putColumn(surface, tile.x, tile.y + 4, tile.width, "TARGET " .. target, "white")
        putColumn(surface, tile.x, tile.y + 5, tile.width, "LIFT " .. lift, "white")
    end
end

-- Section: Display data | Field validity, formatting and status selection.
-- Summary: Validate a vessel field's availability within the current display snapshot.
local function sensorAvailable(snapshot, vessel, field, live)
    if not live or not finite(vessel[field]) then return false end
    local validFields = type(vessel.validFields) == "table" and vessel.validFields or
        (type(snapshot.validFields) == "table" and snapshot.validFields or nil)
    if validFields and validFields[field] == false then return false end
    if vessel[field .. "Valid"] == false then return false end
    return true
end

-- Summary: Resolve the current vessel-data availability reason.
local function vesselReason(snapshot, vessel)
    if vessel.valid ~= false and snapshot.vesselValid ~= false and snapshot.valid ~= false then
        return nil
    end
    local reason = type(vessel.reason) == "string" and vessel.reason or snapshot.reason
    if type(reason) ~= "string" or reason == "" then return "SENSOR DATA UNAVAILABLE" end
    return clampText(reason, 40)
end

-- Summary: Filter successive speed observations into an increasing/decreasing trend marker.
local function speedTrend(renderer, vessel, live, now)
    if not sensorAvailable(renderer.snapshot or {}, vessel, "forwardSpeed", live) then
        renderer.lastAbsSpeed, renderer.lastSpeedAt = nil, nil
        renderer.filteredTrend = nil
        return "?", "gray"
    end
    local magnitude = math.abs(vessel.forwardSpeed)
    local trend
    if renderer.lastAbsSpeed and renderer.lastSpeedAt then
        local elapsed = now - renderer.lastSpeedAt
        if elapsed > 0.05 and elapsed <= 10 then
            local instantaneous = (magnitude - renderer.lastAbsSpeed) / elapsed
            local alpha = renderer.config.trendFilterAlpha or 0.30
            if alpha < 0.05 then alpha = 0.05 elseif alpha > 1 then alpha = 1 end
            renderer.filteredTrend = renderer.filteredTrend and
                (renderer.filteredTrend * (1 - alpha) + instantaneous * alpha) or instantaneous
        else
            renderer.filteredTrend = nil
        end
    else
        renderer.filteredTrend = nil
    end
    renderer.lastAbsSpeed, renderer.lastSpeedAt = magnitude, now
    local deadband = renderer.config.trendDeadband or 0.025
    if not finite(renderer.filteredTrend) then return "-", "gray" end
    if renderer.filteredTrend > deadband then return "^", "green" end
    if renderer.filteredTrend < -deadband then return "v", "yellow" end
    return "-", "gray"
end

-- Shared geometry keeps drawn selectors and hit regions exactly aligned.
-- Summary: Shared geometry keeps drawn selectors and hit regions exactly aligned.
local function modeRegions(width,field)
    local left=field=="heading" and 1 or math.floor(width/3)+1
    local right=field=="heading" and math.floor(width/3) or math.floor(width*2/3)
    local modes=field=="heading" and {"MANUAL","SEL"} or {"MANUAL","SEL","DIRECT"}
    local result={}
    for i,mode in ipairs(modes) do
        result[i]={x1=left+math.floor((i-1)*(right-left+1)/#modes),
            x2=left+math.floor(i*(right-left+1)/#modes)-1,mode=mode,
            label=field=="throttle" and mode=="MANUAL" and "MAN" or mode}
    end
    return result
end
-- ===================== ASSEMBLY GATE DISPLAY =====================
-- Core reports `assembly` in every snapshot. Anything but ASSEMBLED means
-- core has cancelled lift/propulsion/cockpit authority. FLIGHT, NAV and SHIP
-- replace their body with this panel inside the fixed body area (rows 5-21);
-- SETTINGS stays usable for lift-computer maintenance, and every page shows
-- the state in the header slot. Only fresh core data can show the panel;
-- stale data keeps the existing STALE handling.
UI.ASSEMBLY_TITLES = {
    DISASSEMBLED = "VESSEL NOT ASSEMBLED", ASSEMBLING = "VESSEL ASSEMBLING", UNKNOWN = "ASSEMBLY UNKNOWN",
}
local wrapErrorText -- defined with the page rendering helpers below
local function assemblyProblem(snapshot, live)
    local assembly = type(snapshot.assembly) == "table" and snapshot.assembly or nil
    if not live or not assembly or assembly.state == "ASSEMBLED" then return nil end
    return assembly
end
local function vesselDefinitelyDisassembled(snapshot, live)
    local assembly = type(snapshot.assembly) == "table" and snapshot.assembly or nil
    return live and assembly ~= nil and assembly.state == "DISASSEMBLED"
end
local function fleetBootBlocked(snapshot)
    return type(snapshot.fleetBoot)=="table" and snapshot.fleetBoot.ready==false
end
local function systemsStopAvailable(snapshot)
    local systems=type(snapshot.systemsStartup)=="table" and snapshot.systemsStartup or {}
    return systems.active==true or systems.phase=="ABORTED"
end
-- Summary: Format the retained systems-abort reason for the Flight warning area.
local function altitudeAbortMessage(snapshot, live)
    if not live then return nil end
    local systems=type(snapshot.systemsStartup)=="table" and snapshot.systemsStartup or nil
    if not systems or type(systems.phase)~="string" or string.upper(systems.phase)~="ABORTED" then
        return nil
    end
    local reason=type(systems.abortReason)=="string" and systems.abortReason~="" and systems.abortReason or
        (type(systems.reason)=="string" and systems.reason~="" and systems.reason or nil)
    return clampText(reason and ("ALTITUDE ABORTED: "..reason) or "ALTITUDE HOLD ABORTED", 55)
end
local function requestWaiting(request)
    return request.status=="PENDING" or request.status=="QUEUED"
end
local function requestNotice(request)
    request=request or {}
    if request.status=="QUEUED" then return "COMMAND QUEUED; WAITING FOR CORE ("..tostring(request.queuedCount or 1)..")" end
    if request.status=="PENDING" then return "WAITING FOR CORE"..((request.attempts or 0)>1 and "; RETRYING" or "") end
    if request.status=="UNKNOWN" then return "COMMAND NOT CONFIRMED; CHECK CORE" end
    if request.status=="CANCELLED" then return "COMMAND CANCELLED: "..tostring(request.reason or "") end
end
-- Summary: Resolve kill/disarm progress text, availability and message-specific colour.
local function emergencyLift(snapshot, live)
    local lift=type(snapshot.emergencyLift)=="table" and snapshot.emergencyLift or {}
    local request=type(snapshot.bridgeRequest)=="table" and snapshot.bridgeRequest or {}
    local phase=string.upper(tostring(lift.phase or ""))
    local latched=live and (lift.latched==true or lift.complete==true or phase=="KILL CONFIRMED")
    local disarming=live and (lift.disarming==true or
        (request.actionType=="disarm_lift_kill" and requestWaiting(request)))
    if disarming then return {disarm=true,pending=true,label="DISARMING",
        message="DISARMING KILL; SYSTEMS STOPPED",tone="yellow"} end
    if live and phase=="KILL INCOMPLETE" then return {disarm=latched,failed=true,label=latched and "DISARM KILL" or "KILL LIFT",
        message="KILL LIFT INCOMPLETE "..tostring(lift.reason or ""),tone="yellow"} end
    if live and (lift.pending==true or phase=="KILLING" or phase=="RECHECKING AFTER REBOOT") then
        return {disarm=latched,pending=true,label="KILL LIFT",message="KILL LIFT PENDING",tone="yellow"}
    end
    if latched then return {disarm=true,label="DISARM KILL",
        message="KILL LIFT ARMED; DISARM BEFORE START",tone="red"} end
    if request.actionType=="emergency_kill_lift" then
        if requestWaiting(request) then return {pending=true,label="KILL LIFT",message="KILL LIFT PENDING",tone="yellow"} end
        if request.status=="ACCEPTED" then return {accepted=true,label="KILL LIFT",message="KILL REQUEST ACCEPTED",tone="yellow"} end
        if request.status=="REJECTED" then return {failed=true,label="KILL LIFT",
            message="KILL LIFT FAILED "..tostring(request.reason or ""),tone="red"} end
        if request.status=="UNKNOWN" or request.status=="CANCELLED" then return {failed=true,label="KILL LIFT",
            message="KILL NOT CONFIRMED; CHECK CORE",tone="yellow"} end
    end
    return {label="KILL LIFT"}
end
-- Summary: Resolve the cached balanced-capacity model exposed by systems control.
local function balancedLift(snapshot)
    local lift=type(snapshot.balancedLift)=="table" and snapshot.balancedLift or nil
    if not lift then
        local systems=type(snapshot.systemsStartup)=="table" and snapshot.systemsStartup or {}
        lift=type(systems.balancedLift)=="table" and systems.balancedLift or nil
    end
    return lift
end
-- Summary: Format the active chamber capacity or provider-floor limit.
local function balancedLiftWarning(snapshot,live)
    if not live then return nil end
    local lift=balancedLift(snapshot)
    local phase=lift and type(lift.phase)=="string" and string.upper(lift.phase) or ""
    if phase=="LIMITED" then
        local quadrant=type(lift.limitingQuadrant)=="string" and string.upper(lift.limitingQuadrant) or ""
        if quadrant~="FL" and quadrant~="FR" and quadrant~="BL" and quadrant~="BR" then quadrant="" end
        local limit=quadrant~="" and (quadrant.." LIFT LIMIT") or "LIFT LIMIT"
        return clampText("TARGET UNREACHABLE: "..limit,55)
    end
    if phase=="INFEASIBLE" then return "TARGET UNREACHABLE: PROVIDER FLOOR LIMIT" end
    return nil
end
local function fleetBootProblem(snapshot,live)
    local assembly=type(snapshot.assembly)=="table" and snapshot.assembly or nil
    if not live or not assembly or assembly.state~="ASSEMBLED" or not fleetBootBlocked(snapshot) then return nil end
    return snapshot.fleetBoot
end
local function fleetMaintenanceAllowed(snapshot)
    local assembly=type(snapshot.assembly)=="table" and snapshot.assembly or nil
    if assembly and assembly.state=="DISASSEMBLED" then return true end
    local phase=type(snapshot.fleetBoot)=="table" and snapshot.fleetBoot.phase or nil
    return phase=="WAITING_ASSEMBLY" or phase=="FAILED" or phase=="CANCELLED"
end
-- Summary: Evaluate the selected action against the current fleet startup gate.
local function fleetActionAllowed(snapshot,action)
    if not fleetBootBlocked(snapshot) or type(action)~="table" or type(action.type)~="string" then return true end
    local kind=action.type
    if kind=="debug_mode" or kind=="settings_view" or kind=="display_setting" or kind=="settings_next" or
        kind=="setting_update" or kind=="settings_edit" or kind=="settings_key" then return true end
    if kind:match("^maintenance_") then
        return kind=="maintenance_cancel" or fleetMaintenanceAllowed(snapshot)
    end
    if kind=="systems_stop" or kind=="tuning_stop" or kind=="altitude_disengage" or
        kind:match("_cancel$") or kind=="systems_stop_confirm" then return true end
    if kind=="recover_systems" or kind=="start_systems" or kind=="restart_systems" or kind=="tuning_review" or kind=="tuning_confirm" or
        kind=="altitude_engage" then return false end
    return true
end
-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Render assembly status and the operator instruction.
local function drawAssemblyPanel(surface, snapshot, assembly)
    local width = surface.width
    fillRect(surface, 1, 5, width, 17, "black", "white")
    local tone = assembly.state == "ASSEMBLING" and "yellow" or "red"
    centered(surface, 6, "ERROR: " .. (UI.ASSEMBLY_TITLES[assembly.state] or "ASSEMBLY UNKNOWN"), tone)
    -- The cause starts on row 9; the instruction and the gas-levels line follow on rows 13 and 14.
    local groups = assembly.state == "DISASSEMBLED" and {
        { 9, "Core module reports physics assembler is not engaged.", "white", 2 },
        { 13, "Please assemble the vessel to enable controls.", "yellow", 1 },
        { 14, "Previous gas levels will be carried over.", "lightGray", 1 },
    } or { { 9, clampText(assembly.reason or "No detail reported", 300), "white", 2 } }
    for _, group in ipairs(groups) do
        for n, line in ipairs(wrapErrorText(group[2], width - 4)) do
            if n <= group[4] then centered(surface, group[1] + n - 1, line, group[3]) end
        end
    end
end
-- Summary: Render the fleet operation phase, current role and progress.
local function drawFleetBootPanel(surface,fleet)
    local width=surface.width
    local failed=fleet.phase=="FAILED" or fleet.phase=="CANCELLED"
    local complete=fleet.phase=="COMPLETE"
    local tone=failed and "red" or (complete and "green" or "yellow")
    fillRect(surface,1,5,width,17,"black","white")
    local title=failed and "FLEET REBOOT FAILED" or (complete and "FLEET REBOOT COMPLETE" or "FLEET REBOOT IN PROGRESS")
    centered(surface,6,title,tone)
    local phase=type(fleet.phase)=="string" and clampText(fleet.phase,48) or "WAITING"
    local progress="PHASE "..phase
    if finite(fleet.completed) and finite(fleet.total) then
        progress=progress.."  "..tostring(math.floor(fleet.completed)).."/"..tostring(math.floor(fleet.total))
    end
    centered(surface,9,progress,failed and "red" or "white")
    if type(fleet.current)=="string" and fleet.current~="" then
        centered(surface,11,"CURRENT "..clampText(fleet.current,math.max(0,width-10)),"white")
    end
    if type(fleet.reason)=="string" and fleet.reason~="" then
        local lines=wrapErrorText(clampText(fleet.reason,240),math.max(1,width-4))
        for index,line in ipairs(lines) do if index<=3 then centered(surface,13+index,line,failed and "red" or "white") end end
    end
    centered(surface,18,"Flight controls remain disabled.","lightGray")
    centered(surface,20,"Settings and stop controls remain available.","gray")
end

-- Section: Display data | Field validity, formatting and status selection.
-- Summary: Render the common heading, mode selectors and Systems control.
local function addHeader(surface, snapshot, page, live)
    local width = surface.width
    local title = "A.E.V. AMARYLLIS"
    if width >= 48 then title = title .. "  " .. page end
    put(surface, 1, 1, title, "white")
    local controlsReady = snapshot.authorityReady == true or
        ((snapshot.autopilot or {}).active==true or (snapshot.autopilot or {}).available==true)
    local ap = controlsReady and clampText(snapshot.ap or "UNAVAILABLE", 12) or "UNAVAILABLE"
    local headerState = "AP " .. ap .. (live and " LIVE" or " STALE")
    local headerTone = live and controlsReady and "white" or (live and "gray" or "red")
    -- The assembly state takes over the same header slot on every page.
    local assembly = assemblyProblem(snapshot, live)
    local fleet = fleetBootProblem(snapshot,live)
    if assembly then
        headerState = UI.ASSEMBLY_TITLES[assembly.state] or "ASSEMBLY UNKNOWN"
        headerTone = assembly.state == "ASSEMBLING" and "yellow" or "red"
    elseif fleet then
        local failed=fleet.phase=="FAILED" or fleet.phase=="CANCELLED"
        local progress="FLEET "..clampText(fleet.phase or "STARTUP",20)
        if finite(fleet.completed) and finite(fleet.total) then
            progress=progress.." "..tostring(math.floor(fleet.completed)).."/"..tostring(math.floor(fleet.total))
        end
        headerState=clampText(progress,width)
        headerTone=failed and "red" or (fleet.phase=="COMPLETE" and "green" or "yellow")
    end
    put(surface, math.max(1, width - #headerState + 1), 1, headerState, headerTone)

    -- These three status groups occupy the same rows on every main-display
    -- page. Only a known active mode is cyan; unavailable mode controls stay
    -- gray and have no touch action during the display and lift milestones.
    local firstRight = math.floor(width / 3)
    local secondRight = math.floor(width * 2 / 3)
    local groups = {
        { x1 = 1, x2 = firstRight, label = "HEADING MODE", field = "heading" },
        { x1 = firstRight + 1, x2 = secondRight, label = "THROTTLE MODE", field = "throttle" },
        { x1 = secondRight + 1, x2 = width, label = "SYSTEMS" },
    }
    for _, group in ipairs(groups) do
        local groupWidth = group.x2 - group.x1 + 1
        local label = group.label
        local labelX = group.x1 + math.max(0, math.floor((groupWidth - #label) / 2))
        put(surface, labelX, 2, label, "lightGray")
        if group.field then
            local cockpitReady=live and not fleetBootBlocked(snapshot) and (snapshot.cockpitControl or {}).available==true
            local mode=(controlsReady or cockpitReady) and live and not fleetBootBlocked(snapshot) and modeText(snapshot.modes,group.field) or nil
            for _,region in ipairs(modeRegions(width,group.field)) do
                drawButton(surface,region.x1,3,region.x2-region.x1+1,region.label,
                    mode==region.mode and "selected" or (cockpitReady and "enabled" or "disabled"))
            end
        else
            local label,style="Options [v]","enabled"
            drawButton(surface, group.x1, 3, groupWidth, label, style)
        end
    end

    -- Systems actions live in Options; keep the strafe control here.
    local sideWidth = math.floor((width - 3) / 3)
    if page=="FLIGHT" then
        local lateral=snapshot.lateralControl or {};local modes=snapshot.modes or {}
        local lateralMode=modes.lateral or lateral.mode or "MANUAL"
        local allowed=live and lateral.locked~=true and (snapshot.cockpitControl or {}).available==true and
            not (snapshot.autopilot or {}).active and not (snapshot.anchorControl or {}).active
        local phase=({MOVING="MOVE",BRAKING="BRAKE",TURNING="TURN",IDLE="IDLE"})[lateral.state]
        local label="STRAFE "..(lateralMode=="SEL" and "SEL" or "MAN")
        if phase then label=label.." "..phase end
        drawButton(surface,sideWidth+2,4,sideWidth,label,allowed and (lateralMode=="SEL" and "selected" or "enabled") or "disabled")
        local detail=lateralMode=="SEL" and (numberText(lateral.offset,1,true).."b "..
            numberText(finite(lateral.remaining) and math.abs(lateral.remaining),1,false).."b TO GO") or
            (lateral.locked and "SYSTEMS STOPPED" or (lateral.state=="BRAKING" and "STRAFE BRAKING" or "PULL TO STRAFE"))
        putColumn(surface,sideWidth*2+3,4,width-sideWidth*2-2,detail,"cyan")
    end
end

-- Summary: Calculate the current page-tab touch rectangles.
local function tabRegions(width, height)
    local count = #UI.PAGES
    local regions = {}
    local top = math.max(1, height - 2)
    for i = 1, count do
        -- Adjacent buttons cover the full three-row footer, with matching
        -- touch regions. The caption sits on the middle row.
        local left = math.floor((i - 1) * width / count) + 1
        local right = math.floor(i * width / count)
        regions[i] = { x1 = left, x2 = right, y1 = top, y2 = height, page = UI.PAGES[i] }
    end
    return regions
end

-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Render the page tabs and return their current touch regions.
local function drawTabs(surface, selected)
    local regions = tabRegions(surface.width, surface.height)
    for _, region in ipairs(regions) do
        local label = " " .. region.page .. " "
        local start = math.floor((region.x1 + region.x2 - #label + 1) / 2)
        local labelY = math.floor((region.y1 + region.y2) / 2)
        local active = region.page == selected
        fillRect(surface, region.x1, region.y1, region.x2 - region.x1 + 1,
            region.y2 - region.y1 + 1,
            active and "cyan" or "gray", active and "black" or "white")
        put(surface, start, labelY, label, active and "black" or "white")
    end
    return regions
end

local function liveField(snapshot, vessel, field, live, decimals, signed)
    -- A missing heading must not erase a separately valid altitude reading.
    if not sensorAvailable(snapshot, vessel, field, live) then return "--" end
    return numberText(vessel[field], decimals, signed)
end

local thrustControllerLabels = { "thrust-lb", "thrust-rb", "thrust-ls", "thrust-rs" }
local thrustControllerUserLabels = {
    ["thrust-lb"] = "FL PROPULSION", ["thrust-rb"] = "FR PROPULSION",
    ["thrust-ls"] = "BL PROPULSION", ["thrust-rs"] = "BR PROPULSION",
}
-- Only the two primary sensor computers publish thrust telemetry. Lateral
-- transmissions are read by their owning controller, not separate computers.
local thrustDataLabels = { "primary-left", "primary-right" }
local lateralRoles = {
    FL = { controller = "thrust-lb", port = "lateral-lb-p", starboard = "lateral-lb-s" },
    FR = { controller = "thrust-rb", port = "lateral-rb-p", starboard = "lateral-rb-s" },
    BL = { controller = "thrust-ls", port = "lateral-ls-p", starboard = "lateral-ls-s" },
    BR = { controller = "thrust-rs", port = "lateral-rs-p", starboard = "lateral-rs-s" },
}

local function thrustSnapshot(snapshot)
    return type(snapshot.thrust) == "table" and snapshot.thrust or {}
end

local function roleIsFresh(role, live)
    return live and type(role) == "table" and role.online == true and
        role.available == true and role.statusFresh == true
end

-- Section: Display data | Field validity, formatting and status selection.
-- Summary: Extract a bounded issue message from the endpoint's cached fault data.
local function roleFaultText(role)
    if type(role) ~= "table" then return nil end
    local fault = role.fault
    if type(fault) == "string" and fault ~= "" then return clampText(fault, 48) end
    if type(fault) == "table" then
        if type(fault.message) == "string" and fault.message ~= "" then
            return clampText(fault.message, 48)
        end
        if type(fault.reason) == "string" and fault.reason ~= "" then
            return clampText(fault.reason, 48)
        end
        if fault.active == true then return "FAULT" end
    elseif fault == true then
        return "FAULT"
    end
    return nil
end

-- Summary: Classify endpoint discovery, link, freshness and control readiness.
local function roleDisplayStatus(role, live, controller)
    if not live then return "STALE" end
    if type(role) ~= "table" then return "MISSING" end
    if role.discovered == false then return "MISSING" end
    if role.online == false then return "OFFLINE" end
    if roleFaultText(role) then return "FAULT" end
    if role.statusFresh ~= true then return "STALE" end
    if role.available ~= true then return "UNAVAILABLE" end
    if controller then
        return role.thrustControlState or (role.ready==true and "RDY" or "FAULT")
    end
    return "LIVE"
end

-- Summary: Count the ready/live endpoints in the selected role group.
local function roleCounts(map, labels, live, controller)
    if not live or type(map) ~= "table" then return nil, #labels end
    local ready = 0
    for _, label in ipairs(labels) do
        local status = roleDisplayStatus(map[label], live, controller)
        if (controller and (status == "RDY" or status == "CMD")) or (not controller and status == "LIVE") then
            ready = ready + 1
        end
    end
    return ready, #labels
end

-- Summary: Resolve the first reported fault or availability issue in a role group.
local function roleIssue(map, labels, live, controller)
    if not live then return (staleLabel("THRUST STATUS")) end
    if type(map) ~= "table" then return controller and "THRUST CONTROL UNAVAILABLE" or "PROP DATA UNAVAILABLE" end
    for _, label in ipairs(labels) do
        local role = map[label]
        local userLabel = controller and thrustControllerUserLabels[label] or label
        local fault = roleFaultText(role)
        if fault then return userLabel .. " FAULT " .. fault end
    end
    for _, label in ipairs(labels) do
        local status = roleDisplayStatus(map[label], live, controller)
        if not ((controller and (status=="RDY" or status=="CMD")) or (not controller and status=="LIVE")) then
            local role = map[label]
            local reason = type(role) == "table" and role.reason or nil
            local userLabel = controller and thrustControllerUserLabels[label] or label
            if type(reason) == "string" and reason ~= "" then
                return userLabel .. " " .. clampText(reason, 40)
            end
            return userLabel .. " " .. status
        end
    end
    return nil
end

local function readbackPercent(role, live)
    if not roleIsFresh(role, live) or role.readbackFresh ~= true or
        role.appliedTransmissionLevelValid ~= true or not finite(role.appliedTransmissionLevel) then return nil end
    if role.appliedTransmissionLevel < 0 or role.appliedTransmissionLevel > 256 then return nil end
    return math.floor(role.appliedTransmissionLevel * 100 / 256 + 0.5)
end

-- Summary: Format the measured left/right primary drive output.
local function appliedThrottleReadback(snapshot, live)
    local thrust = thrustSnapshot(snapshot)
    local roles = type(thrust.roles) == "table" and thrust.roles or nil
    local left = roles and readbackPercent(roles["thrust-ls"], live) or nil
    local right = roles and readbackPercent(roles["thrust-rs"], live) or nil
    if left == nil and right == nil then
        return live and "UNAVAIL" or "STALE", "yellow"
    end
    local leftText = left == nil and "--" or tostring(left)
    local rightText = right == nil and "--" or tostring(right)
    local tone = left ~= nil and right ~= nil and "white" or "yellow"
    return "L/R " .. leftText .. "/" .. rightText .. "%", tone
end

local function propulsionMode(snapshot, thrust)
    local mode = type(thrust.mode) == "string" and thrust.mode or
        (type(snapshot.effectiveModes) == "table" and snapshot.effectiveModes.throttle or
            (type(snapshot.modes) == "table" and snapshot.modes.throttle or nil))
    return type(mode) == "string" and string.upper(mode) or "UNAVAILABLE"
end

local speedControlStatuses = {
    HOLDING = true, ACCELERATING = true, COASTING = true, BRAKING = true,
    OVERSPEED_COAST = true, UNAVAILABLE = true, DISABLED = true,
    ACTIVE = true, SATURATED = true,
}

local function speedControlSnapshot(snapshot, thrust)
    thrust = type(thrust) == "table" and thrust or thrustSnapshot(snapshot)
    return type(thrust.speedControl) == "table" and thrust.speedControl or nil
end

local function manualAccelerationSnapshot(snapshot, thrust)
    thrust = type(thrust) == "table" and thrust or thrustSnapshot(snapshot)
    return type(thrust.manualAcceleration) == "table" and thrust.manualAcceleration or nil
end

local function headingControlSnapshot(snapshot, thrust)
    thrust = type(thrust) == "table" and thrust or thrustSnapshot(snapshot)
    return type(thrust.headingControl) == "table" and thrust.headingControl or nil
end

-- Summary: Resolve controller operating mode, then effective authority and pilot selections.
local function controlMode(snapshot, control, field)
    local mode = type(control) == "table" and control.mode or nil
    if type(mode) ~= "string" then
        local modes=type(snapshot.effectiveModes)=="table" and snapshot.effectiveModes or snapshot.modes
        mode = type(modes) == "table" and modes[field] or nil
    end
    return type(mode) == "string" and string.upper(mode) or nil
end

-- Summary: Check the selected feedback controller's reported availability.
local function controlUnavailable(control, selectedMode)
    if type(control) ~= "table" then return true end
    if control.available ~= true then return true end
    local state = type(control.state) == "string" and string.upper(control.state) or nil
    if state == "UNAVAILABLE" then return true end
    local controlModeValue = type(control.mode) == "string" and string.upper(control.mode) or nil
    return selectedMode ~= nil and controlModeValue ~= nil and controlModeValue ~= selectedMode
end

local function controlReason(control, fallback)
    if type(control) == "table" and type(control.reason) == "string" and control.reason ~= "" then
        return control.reason
    end
    return type(fallback) == "string" and fallback ~= "" and fallback or nil
end

local function uncommissionedReason(reason)
    return type(reason) == "string" and
        string.find(string.upper(reason), "UNCOMMISSIONED", 1, true) ~= nil
end

-- Summary: Format measured acceleration feedback and its availability reason.
local function manualAccelerationDetail(snapshot, live, thrust)
    if not live then return staleLabel("MAN ACCEL") end
    local selectedMode = controlMode(snapshot, nil, "throttle")
    local control = manualAccelerationSnapshot(snapshot, thrust)
    if not control then
        local reason = controlReason(nil, thrust.reason)
        if uncommissionedReason(reason) then return "MANUAL UNCOMMISSIONED", "yellow" end
        return "MAN ACCEL UNAVAILABLE", "yellow"
    end
    if controlUnavailable(control, selectedMode) then
        local reason = controlReason(control, thrust.reason)
        if uncommissionedReason(reason) then return "MANUAL UNCOMMISSIONED", "yellow" end
        return "MAN ACCEL UNAVAILABLE", "yellow"
    end
    local vessel = type(snapshot.vessel) == "table" and snapshot.vessel or {}
    if not sensorAvailable(snapshot, vessel, "forwardSpeed", live) then
        return "MAN ACCEL SENSOR UNAVAILABLE", "yellow"
    end
    local states = {
        COASTING = "COAST", ACCELERATING = "ACCEL", HOLDING = "HOLD",
        SATURATED = "SAT", DISABLED = "OFF", COASTLIMIT = "COAST LIM",
    }
    local state = type(control.state) == "string" and string.upper(control.state) or "ACTIVE"
    state = states[state] or clampText(state, 8)
    local measured = finite(control.measuredAcceleration) and
        numberText(control.measuredAcceleration, 2, true) or "--"
    return "MAN " .. state .. " M" .. measured .. " b/s^2", "white"
end

-- Summary: Format current heading/yaw feedback and its availability reason.
local function headingFeedbackDetail(snapshot, live, thrust)
    if not live then return staleLabel("HDG STATUS") end
    local selectedMode = controlMode(snapshot, nil, "heading")
    if selectedMode ~= "MANUAL" and selectedMode ~= "SEL" then return nil, "gray" end
    local control = headingControlSnapshot(snapshot, thrust)
    if not control then return "HDG STATUS UNAVAILABLE", "yellow" end
    if controlUnavailable(control, selectedMode) then
        local reason = controlReason(control)
        if uncommissionedReason(reason) then return "HDG UNCOMMISSIONED", "yellow" end
        return "HDG UNAVAILABLE", "yellow"
    end
    local vessel = type(snapshot.vessel) == "table" and snapshot.vessel or {}
    if not sensorAvailable(snapshot, vessel, "heading", live) then
        return "HDG SENSOR UNAVAILABLE", "yellow"
    end
    local measured = finite(control.measuredYawRate) and
        numberText(control.measuredYawRate, 1, true) or "--"
    if selectedMode == "MANUAL" then
        local demand = finite(control.yawDemand) and math.abs(control.yawDemand) <= 1 and
            numberText(control.yawDemand * 100, 0, true) .. "%" or "--%"
        return "HDG MAN IN" .. demand .. " R" .. measured .. "d/s", "white"
    end
    local states = {
        HOLDING = "HOLD", TURNING = "TURN", SATURATED = "SAT",
        COASTING = "COAST", DISABLED = "OFF",
    }
    local state = type(control.state) == "string" and string.upper(control.state) or "ACTIVE"
    state = states[state] or clampText(state, 8)
    local targetRate = finite(control.targetYawRate) and
        numberText(control.targetYawRate, 1, true) or "--"
    return "HDG " .. state .. " T" .. targetRate .. " R" .. measured .. "d/s", "white"
end

-- Summary: Resolve the supported selected-speed feedback state for display.
local function speedControlStatus(speedControl)
    if type(speedControl) ~= "table" then return nil end
    local status = type(speedControl.controlStatus) == "string" and
        string.upper(speedControl.controlStatus) or nil
    if not speedControlStatuses[status] then
        status = type(speedControl.state) == "string" and
            string.upper(speedControl.state) or nil
    end
    if not speedControlStatuses[status] then return nil end
    if status == "OVERSPEED_COAST" then return "OVERSPEED COAST" end
    return status
end

-- Summary: Resolve the current selected-speed target from feedback or pilot selection.
local function speedTarget(snapshot, thrust, live)
    if not live then return nil end
    local speedControl = speedControlSnapshot(snapshot, thrust)
    local target = speedControl and speedControl.targetSpeed
    if not finite(target) then
        local request = type(thrust.request) == "table" and thrust.request or {}
        target = request.speedTarget
    end
    if not finite(target) then
        target = type(snapshot.targets) == "table" and snapshot.targets.speed or nil
    end
    return finite(target) and target or nil
end

local function propulsionInputPercent(snapshot, live)
    local cockpit = type(snapshot.cockpitControl) == "table" and snapshot.cockpitControl or {}
    if live and finite(cockpit.propulsionRequestPercent) then
        return numberText(cockpit.propulsionRequestPercent, 0, true) .. "%"
    end
    return nil
end

-- Summary: Format the requested acceleration, selected speed or direct drive value.
local function propulsionRequestText(snapshot, live)
    local thrust = thrustSnapshot(snapshot)
    if not live then return staleLabel("THRUST REQUEST") end
    local mode = propulsionMode(snapshot, thrust)
    local request = type(thrust.request) == "table" and thrust.request or {}
    -- While AP is engaged, the mode and request are AP's own (SEL, or DIRECT at idle in ACQ and CAPTURE).
    local apActive = (snapshot.autopilot or {}).active == true
    if mode == "MAN" or mode == "MANUAL" then
        if finite(request.manualAcceleration) then
            return "REQ ACC " .. numberText(request.manualAcceleration, 2, true) .. " b/s^2", "white"
        end
        local input = propulsionInputPercent(snapshot, live)
        return input and ("MAN INPUT " .. input) or "REQ ACC UNAVAILABLE", input and "yellow" or "gray"
    elseif mode == "SEL" then
        local target = speedTarget(snapshot, thrust, live)
        if finite(target) then
            return (apActive and "AP TARGET " or "SEL TARGET ") .. numberText(target, 2, true) .. " b/s", "white"
        end
        return apActive and "AP TARGET UNAVAILABLE" or "SEL TARGET UNAVAILABLE", "gray"
    elseif mode == "DIRECT" then
        local settingsRoot = type(snapshot.settings) == "table" and snapshot.settings or {}
        local settings = type(settingsRoot.thrust) == "table" and settingsRoot.thrust or {}
        local rpmVerified = settings.directRpmVerified == true or
            settings.directRpmCalibrationAvailable == true
        if rpmVerified and finite(request.directRpm) then
            return (apActive and "AP RPM " or "REQ RPM ") .. numberText(request.directRpm, 0, true), "white"
        end
        if finite(request.directDriveRequest) and
            request.directDriveRequest >= 0 and request.directDriveRequest <= 1 then
            return "DIRECT DRIVE REQUEST " .. numberText(request.directDriveRequest * 100, 0, false) .. "%", "white"
        end
        local input = propulsionInputPercent(snapshot, live)
        return input and ("DIRECT INPUT " .. input) or "DIRECT RPM UNAVAILABLE", input and "yellow" or "gray"
    end
    return "THRUST REQUEST UNAVAILABLE", "gray"
end

-- Summary: Format propulsion-mode feedback, calibration and thrust-limit information.
local function propulsionModeDetail(snapshot, live)
    if not live then return "PROP SETTINGS UNAVAILABLE", "red" end
    local thrust = thrustSnapshot(snapshot)
    local rootSettings = type(snapshot.settings) == "table" and snapshot.settings or {}
    local settings = type(rootSettings.thrust) == "table" and rootSettings.thrust or {}
    local mode = propulsionMode(snapshot, thrust)
    if mode == "MAN" or mode == "MANUAL" then
        return manualAccelerationDetail(snapshot, live, thrust)
    elseif mode == "SEL" then
        local speedControl = speedControlSnapshot(snapshot, thrust)
        local reason = speedControl and speedControl.reason or thrust.reason
        if not speedControl or speedControl.available ~= true or
            speedControlStatus(speedControl) == "UNAVAILABLE" then
            if uncommissionedReason(reason) then return "SEL UNCOMMISSIONED", "yellow" end
            return "SEL UNAVAILABLE", "yellow"
        end
        if speedControl.controlStatus=="MAX_THRUST" or speedControl.controlStatus=="CONFIG_THRUST" then
            return speedControl.controlStatus=="MAX_THRUST" and "UNABLE TO REACH TARGET: MAX THRUST" or
                "UNABLE TO REACH TARGET: CONFIG THRUST", "yellow"
        end
        local status = speedControlStatus(speedControl)
        if status then return "SEL " .. status, "white" end
        return "SEL STATUS UNAVAILABLE", "yellow"
    elseif mode == "DIRECT" then
        local rpmVerified = settings.directRpmVerified == true or
            settings.directRpmCalibrationAvailable == true
        return rpmVerified and "DIRECT RPM SCALE VERIFIED" or "RPM SCALE UNVERIFIED",
            rpmVerified and "gray" or "yellow"
    end
    return "PROP MODE UNAVAILABLE", "gray"
end

-- Summary: Resolve the current propulsion, endpoint or cockpit-feedback issue.
local function rawThrustIssue(snapshot, live)
    if not live then return (staleLabel("THRUST STATUS")) end
    -- Identity conflict bridge warning v1
    local conflict=snapshot.identityConflict or {}
    if conflict.active then return conflict.text end
    local thrust = thrustSnapshot(snapshot)
    local faults = type(snapshot.faults) == "table" and snapshot.faults or {}
    if #faults > 0 then return "FAULT " .. clampText(faults[1], 48) end
    local issue = roleIssue(thrust.roles, thrustControllerLabels, live, true)
    if issue then return issue end
    issue = roleIssue(thrust.units, thrustDataLabels, live, false)
    if issue then return issue end
    local mode = propulsionMode(snapshot, thrust)
    if mode == "SEL" then
        local speedControl = speedControlSnapshot(snapshot, thrust)
        if speedControl and speedControl.available==true and
            (speedControl.controlStatus=="MAX_THRUST" or speedControl.controlStatus=="CONFIG_THRUST") then
            return speedControl.controlStatus=="MAX_THRUST" and "UNABLE TO REACH TARGET: MAX THRUST" or
                "UNABLE TO REACH TARGET: CONFIG THRUST"
        end
        if not speedControl or speedControl.available ~= true or
            speedControlStatus(speedControl) == "UNAVAILABLE" then
            return clampText(controlReason(speedControl, thrust.reason) or
                "SEL SPEED CONTROL UNAVAILABLE", 52)
        end
    elseif mode == "MAN" or mode == "MANUAL" then
        local manualControl = manualAccelerationSnapshot(snapshot, thrust)
        if not manualControl or controlUnavailable(manualControl, "MANUAL") then
            return clampText(controlReason(manualControl, thrust.reason) or
                "MANUAL ACCELERATION CONTROL UNAVAILABLE", 52)
        end
        local vessel = type(snapshot.vessel) == "table" and snapshot.vessel or {}
        if not sensorAvailable(snapshot, vessel, "forwardSpeed", live) then
            return "FORWARD SPEED DATA UNAVAILABLE"
        end
    end
    local headingMode = controlMode(snapshot, nil, "heading")
    if headingMode == "MANUAL" or headingMode == "SEL" then
        local headingControl = headingControlSnapshot(snapshot, thrust)
        if not headingControl or controlUnavailable(headingControl, headingMode) then
            return clampText(controlReason(headingControl) or "HEADING CONTROL UNAVAILABLE", 52)
        end
        local vessel = type(snapshot.vessel) == "table" and snapshot.vessel or {}
        if not sensorAvailable(snapshot, vessel, "heading", live) then
            return "HEADING DATA UNAVAILABLE"
        end
    end
    if mode == "DIRECT" and thrust.available == false then
        if type(thrust.reason) == "string" and thrust.reason ~= "" then
            return clampText(thrust.reason, 52)
        end
        return "THRUST UNAVAILABLE"
    end
    return nil
end

-- Summary: First propulsion issue, with every lease problem shown as one yellow core stall notice.
local function firstThrustIssue(snapshot, live)
    local issue = rawThrustIssue(snapshot, live)
    if leaseText(issue) then return stallText(snapshot) end
    return issue
end

-- Summary: Read a validated raw value from the cached propulsion endpoint.
local function readbackRaw(endpoint, key)
    if type(endpoint) ~= "table" then return nil end
    local readings = type(endpoint.readings) == "table" and endpoint.readings or endpoint
    local validity = type(endpoint.validity) == "table" and endpoint.validity or
        (type(readings.validity) == "table" and readings.validity or {})
    local value = readings[key]
    local readingName = type(readings.name) == "string" and readings.name or nil
    local fieldValid = validity[key] == true
    if value == nil and type(endpoint.readings) == "table" then
        for _, sample in ipairs(endpoint.readings) do
            if type(sample) == "table" and type(sample.validity) == "table" and
                sample.validity[key] == true and sample[key] ~= nil then
                value, readingName, fieldValid = sample[key], sample.name, true
                break
            end
        end
    end
    if not fieldValid then return nil end
    readingName = type(readingName) == "string" and readingName or
        (type(endpoint.name) == "string" and endpoint.name or
        (type(endpoint.label) == "string" and endpoint.label or endpoint.role))
    if finite(value) then return numberText(value, 1, true), readingName end
    if type(value) == "table" and key == "thrustVector" then
        if finite(value.x) and finite(value.y) and finite(value.z) then
            return numberText(value.x, 1, true) .. "/" .. numberText(value.y, 1, true) .. "/" ..
                numberText(value.z, 1, true), readingName
        end
    end
    if type(value) == "boolean" and key == "assembled" then return value and "YES" or "NO", readingName end
    return nil
end

-- Summary: Format the endpoint's raw speed, thrust, vector or assembly observation.
local function dataReadout(endpoint, live, compact)
    local status = roleDisplayStatus(endpoint, live, false)
    if status ~= "LIVE" then return status end
    local function display(tag, key)
        local value = readbackRaw(endpoint, key)
        if not value then return nil end
        local raw = compact and "" or " RAW"
        return tag .. raw .. " " .. value
    end
    local speed = display("SPD", "speedRaw")
    if speed then return speed end
    local thrust = display("THR", "thrustRaw")
    if thrust then return thrust end
    local vector = display("VEC", "thrustVector")
    if vector then return vector end
    local assembled = display("ASM", "assembled")
    if assembled then return assembled end
    return "LIVE"
end

-- Summary: Format a controller drive's requested demand and measured level.
local function controllerDriveReadback(controller, drive, live)
    local current = live and type(controller) == "table" and controller.online == true
        and controller.statusFresh == true
    local requested = current and type(controller.requested) == "table" and controller.requested[drive] or nil
    local requestText = finite(requested) and requested >= 0 and requested <= 1
        and (tostring(math.floor(requested * 100 + 0.5)) .. "%") or "--"
    local level
    if current and controller.readbackFresh == true and type(controller.readbacks) == "table" then
        local readback = controller.readbacks[drive]
        if type(readback) == "table" and readback.valid == true and finite(readback.shiftLevel)
            and readback.shiftLevel >= 0 and readback.shiftLevel <= 256
            and readback.shiftLevel == math.floor(readback.shiftLevel) then
            level = tostring(readback.shiftLevel) .. "/256"
        end
    end
    return "LVL " .. (level or "--") .. " REQ " .. requestText
end

-- Summary: Map detailed endpoint status into the compact tile label.
local function shortRoleStatus(role, live, controller)
    local status = roleDisplayStatus(role, live, controller)
    if controller and status~="CMD" and status~="RDY" then return "FAULT" end
    if status == "RDY" or status == "CMD" or status == "FAULT" then return status end
    if status == "LIVE" then return "OK" end
    if status == "MISSING" and controller then return "UNAVAIL" end
    if status == "NOT READY" then return "NOT RDY" end
    if status == "OFFLINE" then return "OFFLINE" end
    if status == "UNAVAILABLE" then return "UNAVAIL" end
    if status == "READY --" then return "READY?" end
    return status
end

-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Render speed, vessel motion, propulsion feedback and chamber control tiles.
local function drawFlight(surface, snapshot, live, renderer, now)
    local vessel = type(snapshot.vessel) == "table" and snapshot.vessel or {}
    local nodes = type(snapshot.nodes) == "table" and snapshot.nodes or {}
    local width = surface.width
    local leftWidth = math.floor(width / 2)
    local rightX = leftWidth + 2
    local rightWidth = width - rightX + 1
    renderer.snapshot = snapshot
    local trend, trendTone = speedTrend(renderer, vessel, live, now)
    local speed = liveField(snapshot, vessel, "forwardSpeed", live, 2, true)
    local speedValid = sensorAvailable(snapshot, vessel, "forwardSpeed", live)
    local altitude = liveField(snapshot, vessel, "altitude", live, 1, false)
    local targets = getTargets(snapshot)
    local altitudeTarget = finite(targets.altitude) and numberText(targets.altitude, 1, false) or "--"
    local vertical = liveField(snapshot, vessel, "verticalSpeed", live, 2, true)
    local heading = liveField(snapshot, vessel, "heading", live, 1, false)
    local headingTargetValue = targets.heading
    local headingControl = headingControlSnapshot(snapshot)
    if not finite(headingTargetValue) and live and headingControl and
        finite(headingControl.targetHeading) then
        headingTargetValue = headingControl.targetHeading
    end
    local headingTarget = finite(headingTargetValue) and angleText(headingTargetValue) or "--"
    local pitch = liveField(snapshot, vessel, "pitch", live, 1, true)
    local roll = liveField(snapshot, vessel, "roll", live, 1, true)

    local largeNumber = speed
    local maxGlyphCount = math.floor((leftWidth + 1) / 4)
    if #largeNumber > maxGlyphCount and speedValid then
        largeNumber = string.format("%+.1e", vessel.forwardSpeed)
    end
    if #largeNumber <= maxGlyphCount then
        local glyphWidth = #largeNumber * 4 - 1
        local startX = math.floor((leftWidth - glyphWidth) / 2) + 1
        for index = 1, #largeNumber do
            local glyph = largeGlyphs[string.sub(largeNumber, index, index)]
            if glyph then
                for glyphY = 1, 5 do
                    for glyphX = 1, 3 do
                        local mask = glyph[glyphY]
                        local isLit = math.floor(mask / (2 ^ (3 - glyphX))) % 2 == 1
                        if isLit then
                            local tone = speedValid and vessel.forwardSpeed < 0 and
                                "yellow" or "white"
                            drawLargePixel(surface, startX + (index - 1) * 4 + glyphX - 1,
                                5 + glyphY, tone)
                        end
                    end
                end
            end
        end
    else
        putColumn(surface, 1, 8, leftWidth, largeNumber,
            speedValid and vessel.forwardSpeed < 0 and "yellow" or "white")
    end
    put(surface, 1, 5, "SPEED", "gray")
    local trendLabel = trend == "^" and "^ SPEEDING UP" or
        (trend == "v" and "v SLOWING DOWN" or (trend == "?" and "TREND --" or "- STEADY"))
    local speedLimitControl=speedControlSnapshot(snapshot,thrustSnapshot(snapshot))
    if live and speedLimitControl and (speedLimitControl.controlStatus=="MAX_THRUST" or speedLimitControl.controlStatus=="CONFIG_THRUST") then
        trendLabel,trendTone=speedLimitControl.controlStatus=="MAX_THRUST" and "MAX THRUST" or "CONFIG THRUST","yellow"
    end
    putColumn(surface, math.max(1, leftWidth - #trendLabel + 1), 5,
        math.min(#trendLabel, leftWidth), trendLabel, trendTone)
    centeredColumn(surface, 1, leftWidth, 11, "b/s", "gray")
    local requestText, requestTone = propulsionRequestText(snapshot, live)
    putColumn(surface, 1, 17, leftWidth, requestText, requestTone)
    put(surface, 1, 12, "MAIN ENG. POWER", "gray")
    local appliedText, appliedTone = appliedThrottleReadback(snapshot, live)
    putColumn(surface, 18, 12, leftWidth - 17, appliedText, appliedTone)
    putColumn(surface, 1, 13, leftWidth,
        "ALTITUDE Y " .. altitude .. " TGT " .. altitudeTarget, "white")
    putColumn(surface, 1, 14, leftWidth, "V/S " .. vertical .. " b/s", "white")
    putColumn(surface, 1, 15, leftWidth,
        "HDG " .. heading .. " deg TGT " .. headingTarget .. " deg", "white")

    putColumn(surface, rightX, 5, rightWidth,
        "PITCH " .. pitch .. "  ROLL " .. roll, "white")
    centeredColumn(surface, rightX, rightWidth, 6, "^ BOW ^", "cyan")

    local thrust = thrustSnapshot(snapshot)
    local vesselIssue = vesselReason(snapshot, vessel)
    if vesselIssue then
        putColumn(surface, 1, 16, leftWidth, "SENSOR " .. vesselIssue, "red")
    else
        local headingDetail, headingTone = headingFeedbackDetail(snapshot, live, thrust)
        if headingDetail then putColumn(surface, 1, 16, leftWidth, headingDetail, headingTone) end
    end
    local controllerReady, controllerTotal = roleCounts(thrust.roles, thrustControllerLabels, live, true)
    local dataReady, dataTotal = roleCounts(thrust.units, thrustDataLabels, live, false)
    local thrustState=controllerReady==controllerTotal and controllerReady~=nil and "RDY" or "FAULT"
    if thrustState=="RDY" then
        for _,role in pairs((thrustSnapshot(snapshot).roles or {})) do if role.thrustControlState=="CMD" then thrustState="CMD" end end
    end
    putControlStatus(surface,1,18,leftWidth,"THRUST ",thrustState,
        " "..(controllerReady == nil and "--" or tostring(controllerReady)).."/"..controllerTotal)
    putColumn(surface, 1, 19, leftWidth,
        "PROP DATA " .. (dataReady == nil and "--" or tostring(dataReady)) .. "/" .. dataTotal .. " FRESH",
        dataReady == dataTotal and dataReady ~= nil and "green" or "yellow")

    local lateral=snapshot.lateralControl or {}
    if live and lateral.mode=="SEL" and lateral.active==true and
        not (snapshot.autopilot or {}).active and not (snapshot.anchorControl or {}).active and
        controllerReady==controllerTotal and dataReady==dataTotal then
        fillRect(surface,1,18,leftWidth,2,"black","white")
        local mid=math.floor((leftWidth+1)/2);local low,high=2,leftWidth-1
        for x=low,high do put(surface,x,18,"-","gray") end
        put(surface,1,18,"L","gray");put(surface,leftWidth,18,"R","gray");put(surface,mid,18,"|","cyan")
        if finite(lateral.remaining) then
            local ratio=-lateral.remaining/math.max(1,math.abs(lateral.offset or 0))
            local x=mid+math.floor(math.max(-1,math.min(1,ratio))*(high-low)/2+.5)
            put(surface,math.max(low,math.min(high,x)),18,"*","yellow")
        end
        centeredColumn(surface,1,leftWidth,19,"STRAFE "..numberText(lateral.offset,1,true).."b "..
            numberText(finite(lateral.remaining) and math.abs(lateral.remaining),1,false).."b TO GO","cyan")
    end
    local modeDetail, modeTone = propulsionModeDetail(snapshot, live)
    local systems = snapshot.systemsStartup or {}
    if systems.active then
        local phaseText=systems.displayPhase or (systems.phase=="MAIN_LIFT" and "BUILD" or tostring(systems.phase or "STARTING"))
        local detail=systems.displayPhase and phaseText or ("SYSTEMS "..phaseText)
        -- Show which bound is holding the climb back and the chamber ACK wait.
        if type(systems.speedLimiter) == "string" and systems.phase == "MAIN_LIFT" then
            detail = detail .. " " .. systems.speedLimiter
        end
        if type(systems.ackWaitSeconds) == "number" and systems.ackWaitSeconds == systems.ackWaitSeconds and
            systems.ackWaitSeconds > 0 then
            detail = detail .. string.format(" ACK %.1fS", systems.ackWaitSeconds)
        end
        modeDetail, modeTone = detail, "yellow"
    elseif systems.reason and (not live or not thrust.available) then
        modeDetail, modeTone = systems.reason, "yellow"
    end
    local selectedControl=speedControlSnapshot(snapshot,thrust)
    if live and systems.phase=="READY" and selectedControl and (selectedControl.controlStatus=="MAX_THRUST" or selectedControl.controlStatus=="CONFIG_THRUST") then
        modeDetail,modeTone=selectedControl.controlStatus=="MAX_THRUST" and "UNABLE TO REACH TARGET: MAX THRUST" or
            "UNABLE TO REACH TARGET: CONFIG THRUST","yellow"
    end
    if (snapshot.tuning or {}).active then
        modeDetail, modeTone = "PID TEST " .. tostring(snapshot.tuning.mode) .. " " .. tostring(snapshot.tuning.phase), "yellow"
    end
    local lift=balancedLift(snapshot)
    local liftPhase=lift and type(lift.phase)=="string" and string.upper(lift.phase) or ""
    if type(systems.phase)=="string" and string.upper(systems.phase)=="ABORTED" then
        modeDetail, modeTone = "SYSTEMS ABORTED", "red"
    elseif live and liftPhase=="LIMITED" then
        local active=systems.active or (snapshot.altitudeControl or {}).enabled or (snapshot.tuning or {}).active
        modeDetail, modeTone = active and "SYSTEMS LIMITED" or "LIFT LIMITED", "yellow"
    end
    putColumn(surface, 1, 20, leftWidth, modeDetail, modeTone)

    local issue = firstThrustIssue(snapshot, live)
    if not issue and type(snapshot.cockpitControl) == "table" then
        local cockpit = snapshot.cockpitControl
        if not live then issue = (staleLabel("COCKPIT"))
        elseif type(cockpit.reason) == "string" and cockpit.reason ~= "" then issue = cockpit.reason
        elseif cockpit.thrustNotNeutral == true then issue = "THRUST NOT NEUTRAL" end
    end
    local issueTone = not issue and "green" or
        ((string.find(issue, "FAULT", 1, true) and not leaseText(issue)) and "red" or "yellow")
    surface.flightMessage={text=issue and (issue:find("UNABLE TO REACH TARGET:",1,true)==1 and issue or ("PROP STATUS "..issue)) or "PROP STATUS AVAILABLE",tone=issueTone}
    drawQuadrantTiles(surface, nodes, rightX, rightWidth)
end

-- Summary: Render destination editing, active route guidance or digital-anchor status.
local function drawNavigation(surface, snapshot, live, renderer)
    renderer.navRegions={}
    local view=renderer.navView or "ANCHOR"
    local function button(x,y,w,label,action,enabled,selected)
        drawButton(surface,x,y,w,label,selected and "selected" or (live and enabled~=false and "enabled" or "disabled"))
        renderer.navRegions[#renderer.navRegions+1]={x1=x,x2=x+w-1,y=y,action=action,enabled=enabled~=false}
    end
    button(2,5,26,"ANCHOR",{type="nav_view",view="ANCHOR"},true,view=="ANCHOR")
    button(29,5,27,"AUTOPILOT",{type="nav_view",view="AUTOPILOT"},true,view~="ANCHOR")
    local ap=snapshot.autopilot or {};local draft=ap.destination or {}
    if renderer.navEditor then
        local e=renderer.navEditor
        centered(surface,6,"EDIT "..string.upper(e.label),"cyan")
        putColumn(surface,2,8,surface.width-2,e.buffer,"yellow")
        local rows
        if e.key=="name" or e.type=="destination_rename" then
            rows={{"A","B","C","D","E","F","G"},{"H","I","J","K","L","M","N"},
                {"O","P","Q","R","S","T","U"},{"V","W","X","Y","Z","SPACE","DEL"}}
            for i,row in ipairs(rows) do for j,key in ipairs(row) do button(2+(j-1)*8,9+i*2,7,key,{type="nav_key",key=key}) end end
            button(2,9,26,"CLEAR",{type="nav_key",key="CLEAR"})
        else
            rows={{"7","8","9","-"},{"4","5","6","."},{"1","2","3","DEL"},{"0","CLEAR"}}
            for i,row in ipairs(rows) do for j,key in ipairs(row) do button(2+(j-1)*14,9+i*2,12,key,{type="nav_key",key=key}) end end
        end
        button(2,19,26,"CANCEL",{type="nav_key",key="CANCEL"})
        button(29,19,27,"SAVE",{type="nav_key",key="SAVE"})
        if renderer.actionNotice then putColumn(surface,2,20,surface.width-2,renderer.actionNotice,"yellow") end
        return
    end
    if view=="LIBRARY" then
        local library=ap.library or {};local entries=library.entries or {};local offset=renderer.libraryOffset or 0
        centered(surface,6,"SAVED DESTINATIONS","cyan")
        for i=1,4 do
            local index=offset+i;local entry=entries[index]
            if entry then
                button(2,6+i*2,32,entry.name,{type="destination_highlight",index=index},true,renderer.destinationIndex==index)
                putColumn(surface,35,6+i*2,21,numberText(entry.x,0,false)..","..numberText(entry.z,0,false),"white")
            end
        end
        button(2,16,26,"PREVIOUS",{type="library_previous"},offset>0)
        button(29,16,27,"NEXT",{type="library_next"},offset+4<#entries)
        local selected=entries[renderer.destinationIndex or 0]
        button(2,18,16,"USE",{type="destination_select",index=renderer.destinationIndex},selected~=nil and not ap.active)
        button(20,18,17,"RENAME",{type="destination_rename_edit",index=renderer.destinationIndex,name=selected and selected.name},selected~=nil and library.writable)
        button(39,18,17,"DELETE",{type="destination_delete",index=renderer.destinationIndex},selected~=nil and library.writable)
        button(2,20,54,"BACK",{type="nav_view",view="AUTOPILOT"})
        if not library.available or #entries==0 then centered(surface,8,library.reason or "NO SAVED DESTINATIONS","gray") end
        return
    elseif view=="AUTOPILOT" then
        if ap.active then
            local vessel=snapshot.vessel or {}
            local stage=ap.state=="ACQ" and "ACQUIRING HEADING" or
                (ap.state=="CAPTURE" and "CAPTURING ROUTE" or tostring(ap.state or "ACQ"))
            local route=ap.route or {}
            local entry=(route.entries or {})[route.index or 1] or {}
            centered(surface,6,"AUTOPILOT / "..stage,"cyan")
            centered(surface,7,"HDG BIAS "..numberText(ap.headingBias or 0,1,true).." DEG","gray")
            centered(surface,8,clampText(entry.name or draft.label or "--",surface.width-4),"white")
            putColumn(surface,2,10,26,"HDG "..angleText(vessel.heading),"white")
            putColumn(surface,29,10,27,"TARGET "..angleText(ap.requestedHeading),"cyan")
            putColumn(surface,2,12,26,"SPEED "..numberText(live and vessel.forwardSpeed,1,false).." b/s","white")
            if not ap.primaryIdle then
                putColumn(surface,29,12,27,"TARGET "..numberText(ap.requestedSpeed,1,false).." b/s","cyan")
            end
            putColumn(surface,2,14,54,"DEVIATION "..numberText(ap.crossTrack,1,true).." blocks","white")
            putColumn(surface,2,16,54,"DISTANCE "..numberText(ap.distance,1,false).." blocks","white")
            button(2,18,54,"DISENGAGE AUTOPILOT",{type="ap_disengage"},true)
            if ap.reason then putColumn(surface,2,20,surface.width-2,ap.reason,"yellow")
            elseif ap.state=="DECEL" then centered(surface,20,"Slowing for the destination","gray") end
            return
        end
        centered(surface,6,"PLAN ROUTE","cyan")
        button(2,8,54,"DESTINATION "..tostring(draft.label or "--"),{type="ap_field",key="name",label="destination name",value=draft.name or ""},not ap.active)
        button(2,10,26,"X "..numberText(draft.x,1,false),{type="ap_field",key="x",label="destination X",value=draft.x or 0},not ap.active)
        button(29,10,27,"Z "..numberText(draft.z,1,false),{type="ap_field",key="z",label="destination Z",value=draft.z or 0},not ap.active)
        button(2,12,26,"SPEED "..numberText(draft.cruiseSpeed,1,false).." b/s",{type="ap_field",key="cruiseSpeed",label="cruise speed",value=draft.cruiseSpeed or 3},not ap.active)
        button(29,12,27,"ALTITUDE "..numberText(draft.altitude,1,false),{type="ap_field",key="altitude",label="flight altitude",value=draft.altitude or 160},not ap.active)
        button(2,14,26,"SET CURRENT POSITION",{type="ap_current"},not ap.active)
        button(29,14,27,"SAVED DESTINATIONS",{type="nav_view",view="LIBRARY"})
        button(2,16,54,"SAVE DESTINATION TO DISK",{type="destination_save"},(ap.library or {}).writable and draft.x~=nil and draft.z~=nil)
        button(2,18,54,ap.active and "DISENGAGE" or "ENGAGE",{type=ap.active and "ap_disengage" or "ap_engage"},ap.active or ap.available)
        if ap.active then centered(surface,20,"DISTANCE "..numberText(ap.distance,1,false).."  SPEED "..numberText(ap.requestedSpeed,1,false),"white")
        else putColumn(surface,2,20,surface.width-2,ap.engageReason or "Enter coordinates, cruise speed and altitude","gray") end
        return
    end
    local anchor=snapshot.anchorControl or {}
    drawButton(surface,2,20,surface.width-2,anchor.active and "RELEASE ANCHOR" or "HOLD CURRENT POSITION",
        live and (anchor.active and "selected" or (anchor.available and "enabled")) or "disabled")
    if anchor.active then
        centered(surface,6,"DIGITAL ANCHOR", "cyan")
        centered(surface,8,"STATE "..tostring(anchor.state or "UNAVAILABLE"),anchor.reason and "red" or "white")
        local point=anchor.point or {}
        centered(surface,10,"HOLD X "..numberText(point.x,1,false).."  Z "..numberText(point.z,1,false),"white")
        centered(surface,12,"DISTANCE "..numberText(live and anchor.distance,2,false).." BLOCKS","white")
        centered(surface,14,"HORIZONTAL SPEED "..numberText(live and anchor.horizontalSpeed,2,false).." b/s","white")
        centered(surface,16,"Holding the captured world position","gray")
        if anchor.reason then putColumn(surface,2,18,surface.width-2,anchor.reason,"red")
        else centered(surface,18,"Release anchor to resume manual propulsion","gray") end
        return
    end
    local vessel=type(snapshot.vessel)=="table" and snapshot.vessel or {}
    local position=live and vessel.position or {}
    position=type(position)=="table" and position or {}
    centered(surface,6,"DIGITAL ANCHOR","cyan")
    centered(surface,8,"POSITION HOLD OFF","white")
    centered(surface,10,"X "..numberText(position.x,1,false).."   Z "..numberText(position.z,1,false),"white")
    centered(surface,12,"SPEED "..numberText(live and vessel.forwardSpeed,1,false).." b/s","white")
    centered(surface,15,"Holds the vessel in the specified coordinate.","gray")
    if not live then centered(surface,18,"WAITING FOR FRESH DATA","yellow")
    elseif not anchor.available then centered(surface,18,anchor.engageReason or "ANCHOR UNAVAILABLE","yellow") end
end

-- Summary: Render the highest-priority cached ship fault.
local function drawShipFaults(surface, snapshot, live)
    local faults = type(snapshot.faults) == "table" and snapshot.faults or {}
    local faultText, faultTone = "CLEAR", "green"
    local conflict=snapshot.identityConflict or {}
    if live and conflict.active then
        faultText,faultTone=clampText(conflict.text,surface.width-4),"red"
    elseif #faults > 0 then
        -- Boiler checks are yellow; other reported faults stay red.
        faultText = clampText(faults[1], surface.width - 4)
        faultTone = tostring(faults[1]):find("CHECK BOILER",1,true) and "yellow" or "red"
    elseif not live then
        faultText, faultTone = staleLabel("FAULT STATUS")
    else
        local issue = firstThrustIssue(snapshot, live)
        if issue and string.find(issue, "FAULT", 1, true) then
            faultText, faultTone = clampText(issue, surface.width - 4), leaseText(issue) and "yellow" or "red"
        end
    end
    putColumn(surface, 2, surface.height - 3, surface.width - 2, "FAULTS " .. faultText, faultTone)
end

-- Summary: Render vessel lift and per-chamber envelope/provider observations.
local function drawShipLift(surface, snapshot, live)
    local vessel = type(snapshot.vessel) == "table" and snapshot.vessel or {}
    local nodes = type(snapshot.nodes) == "table" and snapshot.nodes or {}
    centered(surface, 6, "LIFT STATUS", "cyan")
    put(surface, 2, 7, "MASS " .. liveField(snapshot, vessel, "mass", live, 1, false) ..
        " kg   ALTITUDE Y " .. liveField(snapshot, vessel, "altitude", live, 1, false), "white")
    local reason = vesselReason(snapshot, vessel)
    if reason then putColumn(surface, 2, 8, surface.width - 2, "SENSOR DATA: " .. reason, "red") end
    if not reason and type(vessel.altitudeSource) == "string" then
        putColumn(surface, 2, 8, surface.width - 2, "ALT: " .. vessel.altitudeSource,
            vessel.altitudeSource == "Sable world CoM" and "gray" or "yellow")
    end
    centered(surface, 9, "CHAMBER STATUS", "gray")
    local quadrants = { "FL", "FR", "BL", "BR" }
    local rightX = math.floor(surface.width / 2) + 2
    local tileWidth = math.floor(surface.width / 2) - 1
    -- Match the vessel's quadrant arrangement, with separate gas and target rows.
    for i = 1, #quadrants do
        local id = quadrants[i]
        local x = i % 2 == 1 and 2 or rightX
        local y = i <= 2 and 10 or 15
        local node = nodes[id]
        local link = type(node) == "table" and
            (node.online == true and "ONLINE" or (node.online == false and "OFFLINE" or "LINK --")) or "LINK --"
        local ready, armed
        if type(node) == "table" then ready, armed = node.ready, node.armed end
        local lift, rate, target = nodeTileMeasurements(node)
        local status = id .. " " .. link .. "  " .. nodeBoilerText(node)
        putColumn(surface, x, y, tileWidth, status, nodeTone(node))
        putControlStatus(surface,x,y+1,13,"THRUST ",controlState(node,"thrustControlState"))
        putControlStatus(surface,x+13,y+1,tileWidth-13,"LIFT ",controlState(node,"liftControlState"))
        putColumn(surface, x, y+2, tileWidth, "LIFT " .. lift, "white")
        putColumn(surface, x, y+3, tileWidth, "GAS " .. rate, "white")
        putColumn(surface, x, y+4, tileWidth, "TARGET " .. target, "white")
    end
    drawShipFaults(surface, snapshot, live)
end

-- Summary: Render configured propulsion endpoints and their readbacks.
local function drawShipPropulsion(surface, snapshot, live)
    local thrust = thrustSnapshot(snapshot)
    local controllers = type(thrust.roles) == "table" and thrust.roles or {}
    local units = type(thrust.units) == "table" and thrust.units or {}
    centered(surface, 6, "PROPULSION STATUS", "cyan")
    centered(surface, 8, "MAIN PROPS / RAW SHAFT SPEED", "gray")
    putColumn(surface, 2, 9, surface.width - 2,
        "LEFT  " .. dataReadout(units["primary-left"], live, true), "white")
    putColumn(surface, 2, 10, surface.width - 2,
        "RIGHT " .. dataReadout(units["primary-right"], live, true), "white")
    centered(surface, 11, "LATERALS / APPLIED LEVEL AND REQUEST", "gray")
    local quadrants = { "FL", "FR", "BL", "BR" }
    for i, id in ipairs(quadrants) do
        local mapping = lateralRoles[id]
        local controller = controllers[mapping.controller]
        local controllerStatus = shortRoleStatus(controller, live, true)
        local portData = controllerDriveReadback(controller, mapping.port, live)
        local starboardData = controllerDriveReadback(controller, mapping.starboard, live)
        putControlStatus(surface,2,10+i*2,surface.width-2,id.." THRUST ",controllerStatus)
        local line = "LVL PORT " .. portData:gsub("^LVL ", "") .. " STB " .. starboardData:gsub("^LVL ", "")
        putColumn(surface, 2, 11 + i * 2, surface.width - 2, line, "white")
    end
    drawShipFaults(surface, snapshot, live)
end

-- Section: Display data | Field validity, formatting and status selection.
-- Summary: Calculate the local Ship subsection touch rectangles.
local function shipTabRegions(width)
    local first = math.floor(width / 3)
    local second = math.floor(width * 2 / 3)
    return {
        { x1 = 1, x2 = first, y1 = 5, y2 = 5, view = "LIFT" },
        { x1 = first + 1, x2 = second, y1 = 5, y2 = 5, view = "PROP" },
        { x1 = second + 1, x2 = width, y1 = 5, y2 = 5, view = "TRIM" },
    }
end

-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Render the Ship subsection labels and selection.
local function drawShipTabs(surface, renderer)
    local regions = shipTabRegions(surface.width)
    renderer.shipTabRegions = regions
    local selected = renderer.shipView or "LIFT"
    for _, region in ipairs(regions) do
        local view = region.view
        drawButton(surface, region.x1, 5, region.x2 - region.x1 + 1,
            view, selected == view and "selected" or "enabled")
    end
end

-- Summary: Render manual fore/aft bias, measured attitude difference and trim status.
local function drawShipTrim(surface, snapshot, renderer, live)
    local trim = type(snapshot.trimControl) == "table" and snapshot.trimControl or {}
    local bias = trim.manualForeAftBias
    local minimum = finite(trim.manualTrimMinimum) and trim.manualTrimMinimum or -2
    local maximum = finite(trim.manualTrimMaximum) and trim.manualTrimMaximum or 2
    local available = live and trim.manualTrimAvailable == true and finite(bias)
    renderer.shipRegions = {}

    -- Summary: Render a bounded action label and record its touch region.
    local function button(x, y, width, label, action, enabled)
        local canPress = enabled == true and available and fleetActionAllowed(snapshot, action)
        drawButton(surface, x, y, width, label, canPress and "enabled" or "disabled")
        renderer.shipRegions[#renderer.shipRegions + 1] = {
            x1 = x, x2 = x + width - 1, y1 = y, y2 = y,
            action = action, enabled = canPress,
        }
    end

    centered(surface, 6, "MANUAL FORE/AFT TRIM", "cyan")
    centered(surface, 8, "BIAS " .. numberText(bias, 1, true) .. " BLOCKS", "white")
    centered(surface, 9, "POSITIVE = BOW UP   NEGATIVE = STERN UP", "gray")
    centered(surface, 10, "TARGET BOW - STERN HEIGHT " ..
        numberText(trim.manualTargetForeAftHeightDifferenceBlocks, 2, true) .. " BLOCKS", "white")

    local function adjustButton(x, y, width, label, delta)
        local candidate = finite(bias) and bias + delta or nil
        local inRange = candidate ~= nil and candidate >= minimum - 0.000001 and candidate <= maximum + 0.000001
        button(x, y, width, label, { type = "manual_trim_adjust", delta = delta }, inRange)
    end
    adjustButton(2, 11, 26, "STERN UP -0.1", -0.1)
    adjustButton(29, 11, 26, "BOW UP +0.1", 0.1)
    adjustButton(2, 13, 26, "STERN UP -0.5", -0.5)
    adjustButton(29, 13, 26, "BOW UP +0.5", 0.5)
    button(2, 15, 53, "RESET BIAS TO ZERO", { type = "manual_trim_reset" },
        finite(bias) and math.abs(bias) > 0.000001)

    local difference = trim.foreAftHeightDifferenceBlocks
    if not finite(difference) then difference = trim.foreAftHeightDifference end
    if not finite(difference) and type(snapshot.trimStatus) == "table" then
        difference = snapshot.trimStatus.foreAftHeightDifference
    end
    centered(surface, 17, "MEASURED BOW - STERN HEIGHT " .. numberText(difference, 2, true) .. " BLOCKS", "white")
    if trim.authorityLimited == true then
        centered(surface, 18, "ROLL/PITCH TRIM IS AT ITS LIMIT", "yellow")
    elseif trim.manualTrimAvailable ~= true then
        centered(surface, 18, clampText(trim.manualTrimReason or "MANUAL BIAS UNAVAILABLE", surface.width), "yellow")
    elseif trim.active == true then
        centered(surface, 18, "AUTO TRIM ACTIVE", "green")
    else
        centered(surface, 18, "BIAS SAVED FOR NEXT ALTITUDE HOLD", "green")
    end
    centered(surface, 19, "RANGE " .. numberText(minimum, 1, true) .. " TO " ..
        numberText(maximum, 1, true) .. " BLOCKS", "gray")
end

-- Summary: Render the selected Ship lift, propulsion or trim subsection.
local function drawShip(surface, snapshot, live, renderer)
    drawShipTabs(surface, renderer)
    renderer.shipRegions = {}
    if renderer.shipView == "TRIM" then
        drawShipTrim(surface, snapshot, renderer, live)
    elseif renderer.shipView == "PROP" then
        drawShipPropulsion(surface, snapshot, live)
    else
        drawShipLift(surface, snapshot, live)
    end
end

-- Settings reuse the existing body. Every painted button registers the same
-- rectangle for touch handling; subpages never extend the monitor footprint.
-- Summary: Render the selected settings page, editor or maintenance review.
local function drawSettings(surface,snapshot,renderer)
    renderer.settingsRegions={}
    -- Each settings page names its parent page for BACK and, where the group
    -- name reads poorly as a heading, its title. Pages absent from this table
    -- return to GENERAL and use "<GROUP> SETTINGS" as their title, so renaming
    -- a group changes its page and its BACK target together.
    local SETTINGS_PAGES={
        ["SEL HEADING"]={parent="TARGET",title="SEL HEADING SETTINGS"},
        ["SEL THROTTLE"]={parent="TARGET",title="SEL THROTTLE SETTINGS"},
        ["INPUT ALTITUDE"]={parent="TARGET",title="ALTITUDE SELECTOR SETTINGS"},
        ["STRAFE SETTINGS"]={parent="TARGET",title="STRAFE SETTINGS"},
        HARDWARE={parent="MAINTENANCE"},["LEVEL RESET"]={parent="SYSTEMS",title="RESET LEVELING"},
        ["NAV ANCHOR"]={parent="NAV"},["NAV AUTOPILOT"]={parent="NAV"},
        ["PROP SPEED PID"]={parent="PROP PID"},["PROP ACCEL PID"]={parent="PROP PID"},["PROP YAW PID"]={parent="PROP PID"},
        ["PROP PID"]={parent="PROPULSION"},["PROP LIMITS"]={parent="PROPULSION"},["PROPULSION STATUS"]={parent="PROPULSION"},
        ["ALT PID"]={parent="PID",title="ALTITUDE PID / LIMITS"},["VS PID"]={parent="PID"},LIMITS={parent="PID"},STARTUP={parent="PID"},TUNING={parent="PID"},
    } -- end SETTINGS_PAGES
    local live=isLive(snapshot)
    local function button(x,y,w,label,action,enabled)
        local available=enabled~=false and fleetActionAllowed(snapshot,action)
        drawButton(surface,x,y,w,label,available and ((action.type=="systems_stop" or action.type=="propulsion_disable") and "danger" or "enabled") or "disabled")
        renderer.settingsRegions[#renderer.settingsRegions+1]={x1=x,x2=x+w-1,y1=y,y2=y,action=action,enabled=available}
    end
    local function view(name) return {type="settings_view",view=name} end
    local function text(y,label,tone) put(surface,2,y,label,tone or "white") end
    local entries=(snapshot.settings or {}).entries or {}
    local maintenance=snapshot.maintenance or {}
    local sub=renderer.settingsView or "GENERAL"
    local review=maintenance.review
    local function edit(entry,y)
        local valid=finite(entry.value)
        button(2,y,4,"-",{type="setting_update",key=entry.key,value=valid and math.max(entry.min,entry.value-entry.step) or nil},live and valid)
        button(7,y,43,entry.label.."  "..(valid and string.format("%.4g",entry.value) or "--"),{type="settings_edit",entry=entry},live and valid)
        button(51,y,5,"+",{type="setting_update",key=entry.key,value=valid and math.min(entry.max,entry.value+entry.step) or nil},live and valid)
    end
    if renderer.editor then
        local e=renderer.editor
        centered(surface,6,"EDIT "..string.upper(e.entry.label),"cyan")
        text(8,"VALUE: "..e.buffer,"yellow")
        local keys={{"7","8","9","-"},{"4","5","6","."},{"1","2","3","DEL"},{"0","CLEAR"}}
        for row,list in ipairs(keys) do
            for col,label in ipairs(list) do button(2+(col-1)*14,9+row*2,12,label,{type="settings_key",key=label},live) end
        end
        button(2,19,26,"CANCEL",{type="settings_key",key="CANCEL"})
        button(29,19,27,"SAVE",{type="settings_key",key="SAVE"},live)
        text(20,"RANGE "..e.entry.min.." TO "..e.entry.max,"gray")
    elseif (snapshot.tuning or {}).review then
        local r=snapshot.tuning.review
        centered(surface,6,"CONFIRM BOUNDED PID TEST","yellow")
        text(8,r.mode=="VS" and "VERTICAL SPEED: +/-0.1 b/s" or "ALTITUDE: +/-1 BLOCK")
        text(10,r.direction==1 and "DIRECTION: UP" or "DIRECTION: DOWN")
        text(12,"30 seconds. Steam ceilings limited to +/-5%.")
        text(14,"Trim retained. Stop restores captured ceilings.")
        text(16,"Confirm sensor signs and clear flight space.","yellow")
        button(2,19,26,"CANCEL",{type="tuning_cancel"},live)
        button(29,19,27,"START TEST",{type="tuning_confirm",token=r.token},live)
    elseif review then
        centered(surface,6,"REVIEW LIFT RESTART: "..tostring(review.scope),"yellow")
        text(8,"CoM Y "..numberText(maintenance.altitude,2,false).."   LIMIT "..tostring(maintenance.threshold))
        text(10,"Restart may interrupt lift. Output retention")
        text(11,"during reboot has not been verified.")
        text(13,"ALL restarts one quadrant at a time.")
        text(15,maintenance.altitudeValid==true and (maintenance.locked and "ALTITUDE LOCK ACTIVE" or "BELOW ALTITUDE LOCK") or "FRESH CoM ALTITUDE REQUIRED", "yellow")
        if maintenance.locked and not review.override then
            button(2,17,54,"OVERRIDE LOCK FOR THIS RESTART",{type="maintenance_override",token=review.token},live and maintenance.altitudeValid==true)
        else
            text(17,review.override and "ONE-USE OVERRIDE READY" or "CONFIRMATION REQUIRED","yellow")
        end
        button(2,19,26,"CANCEL",{type="maintenance_cancel"},live)
        button(29,19,27,"CONFIRM RESTART",{type="maintenance_confirm",token=review.token},live and maintenance.altitudeValid==true and (not maintenance.locked or review.override))
    elseif sub=="GENERAL" then
        centered(surface,6,"FLIGHT SETTINGS 1/2","cyan")
        for _,entry in ipairs(entries) do if entry.key=="cockpit_timeout" then edit(entry,8) end end
        button(2,10,26,"COCKPIT INPUTS",view("TARGET"))
        button(29,10,27,"PID / LIMITS",view("PID"))
        button(2,12,26,"NAV / ANCHOR",view("NAV"))
        button(29,12,27,"DISPLAY",view("DISPLAY"))
        button(2,14,26,"PROPULSION",view("PROPULSION"))
        button(29,14,27,"LIFT MAINTENANCE",view("MAINTENANCE"))
        button(2,16,26,"CURRENT ISSUES",view("ISSUES"))
        button(29,16,27,"DEBUG MODE",view("DEBUG"))
        local recovery=snapshot.systemsRecovery or {}
        button(2,18,26,"RECOVER LIFT",{type="recover_systems"},live and recovery.available==true and not ((snapshot.emergencyLift or {}).latched))
        button(29,18,27,"NEXT PAGE >",view("SYSTEMS"))
        local systems=snapshot.systemsStartup or {}
        text(20,systems.phase=="ABORTED" and (recovery.reason or
            "Resume retained lift / selected altitude; no takeoff seed.") or
            "","gray")
    elseif sub=="TARGET" then
        centered(surface,6,"COCKPIT INPUTS","cyan")
        button(2,8,54,"SEL HEADING SETTINGS",view("SEL HEADING"))
        button(2,10,54,"SEL THROTTLE SETTINGS",view("SEL THROTTLE"))
        button(2,12,54,"ALTITUDE SELECTOR SETTINGS",view("INPUT ALTITUDE"))
        button(2,14,54,"STRAFE SETTINGS",view("STRAFE SETTINGS"))
    elseif sub=="DEBUG" then
        local debug=snapshot.debugMode or {}
        centered(surface,6,"DISK DEBUG RECORDING","cyan")
        text(8,"DEBUG MODE "..(debug.enabled and "ON" or "OFF").."  "..tostring(debug.state or "UNAVAILABLE"),debug.state=="ERROR" and "red" or (debug.enabled and "green" or "white"))
        button(2,10,54,debug.enabled and "STOP DEBUG RECORDING" or "START DEBUG RECORDING",
            {type="debug_mode",enabled=not debug.enabled},live and not debug.pending)
        text(12,"Use an empty disk in one of core's disk drives.","gray")
        text(15,debug.runID and ("RUN "..debug.runID) or "Each start creates a new recording.","white")
        local location=debug.reason or debug.path or "Logs are located under /amaryllis-logs/ directory on the disk."
        for index,line in ipairs(wrapErrorText(location,surface.width-2)) do
            if index>2 then break end
            text(15+index,line,debug.reason and "red" or "gray")
        end
        text(18,"SAVED "..tostring(debug.bytes or 0).." bytes  DROPPED "..tostring(debug.dropped or 0),"gray")
    elseif sub=="SYSTEMS" then
        centered(surface,6,"FLIGHT SETTINGS 2/2","cyan")
        local systems=snapshot.systemsStartup or {}
        button(2,8,54,"RESET LEVELING",view("LEVEL RESET"))
        local stopSystems=systemsStopAvailable(snapshot)
        button(2,16,26,stopSystems and "STOP SYSTEMS" or "START SYSTEMS",
            {type=stopSystems and "systems_stop" or "start_systems"},
            live and (stopSystems or (systems.available==true and not ((snapshot.emergencyLift or {}).latched))))
        button(29,16,27,"RESTART SYSTEMS",{type="restart_systems"},
            live and (snapshot.systemsRestart or {}).available==true)
    elseif sub=="LEVEL RESET" then
        centered(surface,6,"RESET LEVELING","cyan")
        local systems=snapshot.systemsStartup or {}
        local trim=type(snapshot.trimControl)=="table" and snapshot.trimControl or {}
        text(8,"Resets the learned roll/pitch split back to the values")
        text(9,"saved while she was last airborne and level. Sets them")
        text(10,"to zero if none is saved.")
        text(11,"Use after an outside force held her tilted.","gray")
        text(13,"LEARNED ROLL "..numberText(trim.coarseSteamTrimRoll,1,true).."  PITCH "..numberText(trim.coarseSteamTrimPitch,1,true))
        local ready=systems.phase=="READY"
        text(17,ready and "LEVEL RESET READY" or "AVAILABLE AFTER START SYSTEMS IS READY",ready and "white" or "yellow")
        button(29,19,27,"CONFIRM RESET",{type="level_reset"},live and ready)
    elseif sub=="MAINTENANCE" then
        centered(surface,6,"LIFT MAINTENANCE","cyan")
        text(8,"CoM Y "..numberText(maintenance.altitude,2,false).."   "..(maintenance.locked and "LOCKED" or "BELOW LIMIT"),"yellow")
        for _,entry in ipairs(entries) do if entry.key=="restart_y" then edit(entry,10) end end
        local systems=snapshot.systemsStartup or {}
        local stopSystems=systemsStopAvailable(snapshot)
        button(2,12,26,stopSystems and "STOP SYSTEMS" or "START SYSTEMS",{type=stopSystems and "systems_stop" or "start_systems"},live and (stopSystems or (systems.available==true and not ((snapshot.emergencyLift or {}).latched))))
        button(29,12,27,"HARDWARE RECHECK",view("HARDWARE"))
        text(14,"RESTART LIFT COMPUTERS (review required)")
        for i,q in ipairs({"FL","FR","BL","BR"}) do button(2+(i-1)*14,16,12,q,{type="maintenance_review",scope=q},live and not maintenance.job) end
        button(2,18,54,"RESTART ALL SEQUENTIALLY",{type="maintenance_review",scope="ALL"},live and not maintenance.job)
        text(20,stopSystems and (tostring(systems.phase).."  TARGET "..numberText(systems.target,1,false)) or (maintenance.status or systems.reason or "Recheck reads hardware without changing output."),"gray")
    elseif sub=="HARDWARE" then
        centered(surface,6,"HARDWARE RECHECK","cyan")
        text(9,"Read and verify chamber hardware.","white")
        text(11,"Existing gas targets are retained.","gray")
        button(2,14,54,"RECHECK ALL CHAMBERS",{type="maintenance_recheck",scope="ALL"},live and not maintenance.job)
        for i,q in ipairs({"FL","FR","BL","BR"}) do
            button(2+(i-1)*14,17,12,q,
                {type="maintenance_recheck",scope=q},live and not maintenance.job)
        end
        text(20,maintenance.status or "Recheck does not reboot the computers.","gray")
    elseif sub=="TUNING" then
        local t=snapshot.tuning or {};local result=t.result or {}
        centered(surface,6,"PID TUNING","cyan")
        if t.active then
            text(8,"TEST "..tostring(t.mode).."  "..tostring(t.phase),"yellow")
            text(10,"TARGET "..numberText(t.target,2,true).."  REMAINING "..numberText(t.remaining,1,false).."s")
            text(12,"VENT CHANGE "..numberText((t.effort or 0)*100,2,true).."%")
            text(14,"PEAK ERROR "..numberText(t.peakError,3,false).."  RMS "..numberText(t.rmsError,3,false))
            button(2,17,54,"STOP TEST / RESTORE BASELINE",{type="tuning_stop"},live)
        else
            text(8,"Tune vertical speed first, then altitude.","gray")
            button(2,10,26,"V/S +0.1",{type="tuning_review",mode="VS",direction=1},live and t.available)
            button(29,10,27,"V/S -0.1",{type="tuning_review",mode="VS",direction=-1},live and t.available)
            button(2,12,26,"ALTITUDE +1",{type="tuning_review",mode="ALT",direction=1},live and t.available)
            button(29,12,27,"ALTITUDE -1",{type="tuning_review",mode="ALT",direction=-1},live and t.available)
            text(14,t.available and "READY: STABLE HOVER" or (t.reason or "WAITING FOR CORE"),"yellow")
            text(16,result.status or "No completed test recorded.")
            text(17,"PEAK "..numberText(result.peakError,3,false).."  RMS "..numberText(result.rmsError,3,false))
            text(18,result.saveError or (result.status and (result.baselineRestored and "CAPTURED CEILINGS RESTORED" or "RESTORATION NOT CONFIRMED") or "Results saved on core; edit gains between tests."),"gray")
        end
    elseif sub=="PID" then
        centered(surface,6,"PID / CONTROL LIMITS","cyan")
        button(2,8,54,"ALTITUDE PID / LIMITS",view("ALT PID"))
        button(2,10,54,"VERTICAL SPEED PID",view("VS PID"))
        button(2,12,54,"ACTUATOR / HOVER / TRIM LIMITS",view("LIMITS"))
        button(2,14,54,"START SYSTEMS SPEED / SHAPING",view("STARTUP"))
        button(2,16,54,"BOUNDED TUNING TESTS",view("TUNING"))
    elseif sub=="NAV" then
        centered(surface,6,"NAV / ANCHOR SETTINGS","cyan")
        button(2,9,54,"DIGITAL ANCHOR",view("NAV ANCHOR"))
        button(2,12,54,"AUTOPILOT ROUTE CONTROL",view("NAV AUTOPILOT"))
        text(15,"Cruise speed and destination: NAV > AUTOPILOT.","gray")
        text(17,"Release anchor / disengage AP before tuning.","yellow")
    elseif sub=="PROPULSION" then
        centered(surface,6,"PROPULSION SETTINGS","cyan")
        local propulsion=(snapshot.settings or {}).thrust or {}
        button(2,7,54,propulsion.enabled and "DISABLE PROPULSION" or "ENABLE PROPULSION",
            {type=propulsion.enabled and "propulsion_disable" or "propulsion_enable"},
            live and (propulsion.enabled or propulsion.enableAvailable==true))
        for _,entry in ipairs(entries) do
            if entry.key=="primary_max_rpm" then edit(entry,9) end
            if entry.key=="lateral_max_rpm" then edit(entry,11) end
        end
        button(2,13,54,"ACCELERATION / STEERING LIMITS",view("PROP LIMITS"))
        button(2,15,54,"PROPULSION PID GAINS",view("PROP PID"))
        button(2,17,54,"PROPULSION STATUS / DETAILS",view("PROPULSION STATUS"))
        text(20,propulsion.enabled and "Strong turns: up to 5% primary assistance." or
            (propulsion.enableReason or "Propulsion enables once START SYSTEMS is READY."),"gray")
    elseif sub=="PROP PID" then
        centered(surface,6,"PROPULSION PID GAINS","cyan")
        button(2,9,54,"SELECTED SPEED PID",view("PROP SPEED PID"))
        button(2,12,54,"MANUAL ACCELERATION PID",view("PROP ACCEL PID"))
        button(2,15,54,"SELECTED HEADING / TURN RATE PID",view("PROP YAW PID"))
        text(18,"Gains are configured; flight tuning remains required.","yellow")
    elseif sub=="PROPULSION STATUS" then
        centered(surface,6,"PROPULSION STATUS / DETAILS","cyan")
        local rootSettings=type(snapshot.settings)=="table" and snapshot.settings or {}
        local propulsion=type(rootSettings.thrust)=="table" and rootSettings.thrust or {}
        local thrust=thrustSnapshot(snapshot)
        local speedControl=speedControlSnapshot(snapshot,thrust)
        local gains=speedControl and type(speedControl.gains)=="table" and speedControl.gains or {}
        if finite(gains.kp) and finite(gains.ki) and finite(gains.kd) then
            text(10,"SEL PID KP "..numberText(gains.kp,3,false)..
                " KI "..numberText(gains.ki,3,false).." KD "..numberText(gains.kd,3,false),
                gains.verified==true and "white" or "yellow")
        else
            text(10,"SEL PID GAINS UNAVAILABLE","yellow")
        end
        local gainSource=type(gains.source)=="string" and string.upper(gains.source) or
            (gains.verified==true and "CONFIGURED" or "UNSPECIFIED")
        local gainVerification=gains.verified==true and "VERIFIED" or "UNVERIFIED"
        local pidDetails="PID "..gainSource.." "..gainVerification
        if finite(gains.integralLimit) then
            pidDetails=pidDetails.." I-LIMIT "..numberText(gains.integralLimit,2,false)
        end
        if finite(gains.derivativeFilterSeconds) then
            pidDetails=pidDetails.." D-FILTER "..numberText(gains.derivativeFilterSeconds,2,false).."s"
        end
        text(13,pidDetails,gains.verified==true and "white" or "yellow")
        text(8,"MANUAL: SIGNED ACCELERATION (b/s^2)","white")
        if (propulsion.manualAccelerationConfigured==true or propulsion.manualAccelerationVerified==true) and
            finite(propulsion.manualMinimumAccelerationBps2) and
            finite(propulsion.manualMaximumAccelerationBps2) then
            text(9,"LIMIT "..numberText(propulsion.manualMinimumAccelerationBps2,2,true)..
                " TO "..numberText(propulsion.manualMaximumAccelerationBps2,2,true).." b/s^2")
        else
            text(9,"MANUAL ACCEL LIMIT UNSET","yellow")
        end
        text(11,"SEL: SIGNED SPEED TARGET RATE (b/s^2)","white")
        if propulsion.speedControlVerified==true and finite(propulsion.speedTargetRateBps2) then
            text(12,"RATE "..numberText(propulsion.speedTargetRateBps2,2,false).." b/s^2")
        else
            text(12,"SEL SPEED RATE UNSET","yellow")
        end
        text(14,"DIRECT: PROPELLER SHAFT RPM","white")
        text(15,propulsion.directRpmVerified==true and "RPM SCALE VERIFIED" or "RPM SCALE UNVERIFIED",
            propulsion.directRpmVerified==true and "white" or "yellow")
        if propulsion.enabled==true and propulsion.mappingVerified==true and propulsion.limitsVerified==true and
            propulsion.directDriveRequestUnit=="fraction_of_configured_drive_range" and
            finite(propulsion.directMaximumDriveRequest) and
            propulsion.directMaximumDriveRequest>=0 and propulsion.directMaximumDriveRequest<=1 then
            text(16,"MAX DRIVE REQUEST "..numberText(propulsion.directMaximumDriveRequest*100,0,false).."%")
        else
            text(16,"MAX DRIVE REQUEST UNVERIFIED","yellow")
        end
        text(17,propulsion.enabled==true and "CONTROL ENABLED" or
            (propulsion.enabled==false and "CONTROL DISABLED" or "CONTROL STATUS UNAVAILABLE"),
            propulsion.enabled==true and "white" or "yellow")
        text(18,(propulsion.mappingVerified==true and "MAPPING VERIFIED" or "MAPPING UNVERIFIED")..
            "  "..(propulsion.reverseVerified==true and "REVERSE VERIFIED" or "REVERSE UNAVAILABLE"),
            propulsion.mappingVerified==true and propulsion.reverseVerified==true and "white" or "yellow")
        local status=speedControlStatus(speedControl)
        if not live then
            text(20,staleLabel("SEL CONTROL"))
        elseif speedControl and speedControl.available==true then
            text(20,"SEL CONTROL "..(status or "AVAILABLE"),"white")
        elseif speedControl and type(speedControl.reason)=="string" and speedControl.reason~="" then
            text(20,"SEL CONTROL UNAVAILABLE: "..clampText(speedControl.reason,31),"yellow")
        else
            text(20,"SEL CONTROL "..(status or "UNAVAILABLE"),"yellow")
        end
    else
        centered(surface,6,(SETTINGS_PAGES[sub] or {}).title or (sub.." SETTINGS"),"cyan")
        local list={}
        if sub=="DISPLAY" then
            local prefs=snapshot.displaySettings or {}
            list={{key="speed_trend_filter_alpha",label="Speed trend filter",value=prefs.speed_trend_filter_alpha or .3,min=.05,max=1,step=.05,localSetting=true},
                {key="speed_trend_deadband",label="Speed trend deadband",value=prefs.speed_trend_deadband or .025,min=0,max=1,step=.005,localSetting=true}}
        else for _,entry in ipairs(entries) do if entry.group==sub then list[#list+1]=entry end end end
        local page=renderer.settingsOffset or 0
        if page>=#list then page=0;renderer.settingsOffset=0 end
        for i=1,9 do local entry=list[page+i];if entry then edit(entry,7+i) end end
        if #list>9 then
            local pages=math.ceil(#list/9)
            local current=math.floor(page/9)+1
            put(surface,2,18,string.format("PAGE %d/%d  %d-%d OF %d",current,pages,page+1,math.min(page+9,#list),#list),"cyan")
            button(29,18,27,current<pages and "NEXT PAGE" or "FIRST PAGE",{type="settings_next",count=#list})
        end
    end
    if not renderer.editor and not review and not (snapshot.tuning or {}).review and sub~="GENERAL" then
        button(2,19,26,"BACK",view((SETTINGS_PAGES[sub] or {}).parent or "GENERAL"))
    end
    local feedback=snapshot.bridgeRequest or {}
    local line=renderer.settingsNotice or requestNotice(feedback) or (feedback.status and (feedback.status.." "..tostring(feedback.reason or ""))) or maintenance.status
    local presetReason=(snapshot.controlPresets or {}).reason
    if type(presetReason)=="string" and presetReason:find("CONTROL PRESETS",1,true) then
        text(21,presetReason,"red")
    elseif line then text(21,line,feedback.status=="REJECTED" and "red" or "yellow") end
end

-- Summary: Compose the common header, selected page, modal reviews and warning area.
local function drawMain(renderer, snapshot, width, height, now)
    local surface = newSurface(width, height)
    local live = isLive(snapshot)
    local page = string.upper(tostring(snapshot.page or renderer.page or "FLIGHT"))
    if page ~= "NAV" and page ~= "SHIP" and page ~= "SETTINGS" then page = "FLIGHT" end
    renderer.page = page
    if page=="FLIGHT" and live and renderer.actionNotice=="WAITING FOR FRESH CORE STATUS" then
        renderer.actionNotice=nil
    end
    addHeader(surface, snapshot, page, live)
    local selected = page
    if page == "FLIGHT" then
        drawFlight(surface, snapshot, live, renderer, now)
    elseif page == "NAV" then
        drawNavigation(surface, snapshot, live, renderer)
    elseif page == "SHIP" then
        drawShip(surface, snapshot, live, renderer)
    else
        drawSettings(surface, snapshot, renderer)
    end
    -- The three-row footer keeps the full-width page tabs easy to touch.
    local assembly = assemblyProblem(snapshot, live)
    local fleet = fleetBootProblem(snapshot,live)
    local disassembled = vesselDefinitelyDisassembled(snapshot, live)
    if assembly and page ~= "SETTINGS" then drawAssemblyPanel(surface, snapshot, assembly)
    elseif fleet and page ~= "SETTINGS" then drawFleetBootPanel(surface,fleet) end
    local kill=page=="FLIGHT" and emergencyLift(snapshot,live) or nil
    local capacityWarning=not disassembled and (page=="FLIGHT" or page=="SHIP") and balancedLiftWarning(snapshot,live) or nil
    local altitudeAbort=page=="FLIGHT" and not assembly and not fleet and
        not disassembled and altitudeAbortMessage(snapshot,live) or nil
    -- At or above Y 290 air pressure falls ~5% per block (steep above Y 300)
    -- and altitude hold gets twitchy.
    local vesselNow=type(snapshot.vessel)=="table" and snapshot.vessel or {}
    local pressureWarning=not assembly and not fleet and not disassembled and
        sensorAvailable(snapshot,vesselNow,"altitude",live) and vesselNow.altitude>=290 and
        "ALTITUDE AIR PRESSURE WARNING" or nil
    local anchorInputs=false
    local anchor=snapshot.anchorControl or {}
    local inputs=snapshot.inputs or {}
    if live and anchor.active and inputs.valid==true and type(inputs.raw)=="table" then
        for _,key in ipairs({"prop_forward","prop_reverse","left_press","right_press","left_lift","right_lift"}) do
            local value=inputs.raw[key]
            if type(value)=="number" and value>0 then anchorInputs=true end
        end
    end
    if not live or not anchor.active then renderer.anchorInputNoticeUntil=nil
    elseif anchorInputs then renderer.anchorInputNoticeUntil=now+2 end
    local anchorNotice=live and anchor.active and renderer.anchorInputNoticeUntil and now<=renderer.anchorInputNoticeUntil
    if page~="FLIGHT" and anchorNotice and not assembly and not fleet and not disassembled and
        not (kill and kill.message) and not capacityWarning and not altitudeAbort then
        centered(surface,21,"ANCHOR ENGAGED - RELEASE ANCHOR TO USE CONTROLS","yellow")
    elseif page~="FLIGHT" and renderer.actionNotice and not disassembled and not (kill and kill.message) and not capacityWarning then
        put(surface,2,21,renderer.actionNotice,"yellow")
    elseif page == "SHIP" and renderer.shipView == "TRIM" and not disassembled and
        not (kill and kill.message) and not capacityWarning then
        local request = type(snapshot.bridgeRequest) == "table" and snapshot.bridgeRequest or {}
        if request.actionType == "manual_trim_adjust" or request.actionType == "manual_trim_reset" then
            if requestWaiting(request) then
                centered(surface, 21, "BIAS CHANGE QUEUED; WAITING FOR CORE", "yellow")
            elseif request.status == "ACCEPTED" then
                centered(surface, 21, "FORE/AFT BIAS SAVED", "green")
            elseif request.status == "REJECTED" then
                centered(surface, 21, clampText("NOT SAVED: " .. tostring(request.reason or "CORE REJECTED"), surface.width), "red")
            elseif request.status == "UNKNOWN" or request.status=="CANCELLED" then
                centered(surface, 21, "SAVE STATUS UNKNOWN; CHECK CORE", "yellow")
            end
        end
    end
    renderer.tabs = drawTabs(surface, selected)
    renderer.stopRegions={}
    local stopReview=snapshot.systemsStopReview
    if stopReview then
        fillRect(surface,1,6,width,15,"black","white")
        centered(surface,7,"WARNING: STOP SYSTEMS","red")
        centered(surface,10,"This action will stop all lift calculations.","white")
        centered(surface,12,"Steam vents will be reset, Amaryllis will descend.","white")
        centered(surface,14,"Confirm to stop and reset all four lift controllers.","white")
        local half=math.floor((width-6)/2)
        for _,button in ipairs({{x=3,label="CANCEL",kind="systems_stop_cancel"},
            {x=width-half-2,label="CONFIRM STOP",kind="systems_stop_confirm"}}) do
            fillRect(surface,button.x,16,half,3,"gray","white")
            drawButton(surface,button.x,17,half,button.label,live and "enabled" or "disabled")
            renderer.stopRegions[#renderer.stopRegions+1]={x1=button.x,x2=button.x+half-1,y1=16,y2=18,
                action={type=button.kind,token=stopReview.token}}
        end
    end
    renderer.killRegions={}
    local killReview=renderer.killReview
    if killReview and (now or 0)-killReview.at>UI.KILL_REVIEW_SECONDS then
        renderer.killReview=nil;killReview=nil
    end
    if killReview then
        local remaining=math.max(0,math.ceil(UI.KILL_REVIEW_SECONDS-((now or 0)-killReview.at)))
        fillRect(surface,1,6,width,15,"black","white")
        centered(surface,7,"CONFIRM EMERGENCY LIFT KILL","red")
        centered(surface,9,"All bulk steam vents switch OFF.","white")
        centered(surface,10,"Trim probes stay on; balloon data stays live.","white")
        centered(surface,12,"Main buoyancy is removed: the vessel will descend.","yellow")
        centered(surface,13,"Disarm the kill before START SYSTEMS.","yellow")
        centered(surface,15,"Closes in "..remaining.."s without action.","gray")
        local half=math.floor((width-6)/2)
        for _,button in ipairs({{x=3,label="CANCEL",confirm=false,style="enabled"},
            {x=width-half-2,label="KILL LIFT",confirm=true,style=live and "danger" or "disabled"}}) do
            fillRect(surface,button.x,16,half,3,button.confirm and "red" or "gray","white")
            drawButton(surface,button.x,17,half,button.label,button.style)
            renderer.killRegions[#renderer.killRegions+1]={x1=button.x,x2=button.x+half-1,y1=16,y2=18,
                confirm=button.confirm}
        end
    end
    if page=="FLIGHT" then
        -- One owner for the entire message row. Higher severity wins; ties
        -- retain the more specific fault before general status or notices.
        local chosen=nil
        local rank={green=1,yellow=2,red=3}
        local function offer(message,tone)
            if type(message)~="string" or message=="" then return end
            tone=tone or "yellow"
            if not chosen or (rank[tone] or 2)>(rank[chosen.tone] or 2) then
                chosen={text=message,tone=tone}
            end
        end
        if kill then offer(kill.message,"red") end
        if assembly then offer(assembly.reason or ("VESSEL "..tostring(assembly.state)),"red") end
        local conflict=snapshot.identityConflict or {}
        if live and conflict.active then offer(conflict.text,"red") end
        if fleet then offer(fleet.reason or "FLEET NOT READY","red") end
        offer(altitudeAbort,"red");offer(capacityWarning,"red");offer(pressureWarning,"red")
        local motion=snapshot.motionWarnings or {}
        if live and motion.active==true then offer(motion.text,motion.tone) end
        local status=surface.flightMessage
        if anchorNotice then offer("ANCHOR ENGAGED - RELEASE ANCHOR TO USE CONTROLS","yellow") end
        if status and status.tone~="green" then offer(status.text,status.tone) end
        offer(requestNotice(snapshot.bridgeRequest),"yellow")
        offer(renderer.actionNotice,"yellow")
        if status then offer(status.text,status.tone) end
        fillRect(surface,1,21,width,1,"black","white")
        if chosen then put(surface,2,21,clampText(chosen.text,width-2),chosen.tone) end
    elseif kill and kill.message then centered(surface,21,kill.message,kill.tone)
    elseif altitudeAbort then centered(surface,21,altitudeAbort,"red")
    elseif capacityWarning then centered(surface,21,capacityWarning,"red")
    elseif pressureWarning and page~="SETTINGS" then centered(surface,21,pressureWarning,"red")
    elseif page~="SETTINGS" and requestNotice(snapshot.bridgeRequest) and not assembly and not fleet and not renderer.killReview and not stopReview then
        centered(surface,21,clampText(requestNotice(snapshot.bridgeRequest),width),"yellow") end
    return finishSurface(surface)
end

-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Render the required monitor dimensions for the bridge display.
local function drawTooSmall(renderer, width, height)
    local surface = newSurface(width, height)
    centered(surface, 1, "DISPLAY TOO SMALL", "yellow")
    if height >= 2 then centered(surface, 2, "SIZE " .. width .. "x" .. height, "white") end
    if height >= 3 then
        centered(surface, 3, "NEED " .. UI.MIN_MAIN_WIDTH .. "x" .. UI.MIN_MAIN_HEIGHT, "gray")
    end
    return finishSurface(surface)
end

-- Section: Display data | Field validity, formatting and status selection.
-- Summary: Wrap an availability or error message into bounded display rows.
function wrapErrorText(text, width)
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

-- Systems menu: available commands, presentation and touch routing.
-- Pure display/input helpers. Core remains the authority for every command.
-- Summary: Build Systems menu actions and availability from the current core snapshot.
local function systemsMenuItems(snapshot)
    local live=isLive(snapshot)
    local systems=snapshot.systemsStartup or {}
    local restart=snapshot.systemsRestart or {}
    local lift=snapshot.emergencyLift or {}
    local kill=emergencyLift(snapshot,live)
    local assembled=not assemblyProblem(snapshot,live)
    local function item(label,action,available,reason,danger)
        if not live then available=false;reason="WAITING FOR FRESH CORE STATUS"
        elseif not fleetActionAllowed(snapshot,action) then available=false;reason="FLEET NOT READY" end
        return {label=label,action=action,enabled=available==true,reason=reason,danger=danger}
    end
    local startReason=lift.latched and "DISARM KILL BEFORE START" or
        (not assembled and "VESSEL ASSEMBLY NOT READY") or systems.reason or "START SYSTEMS UNAVAILABLE"
    local killAvailable=not kill.pending and not kill.accepted and not kill.complete
    return {
        item("Start Systems",{type="start_systems"},systems.available==true and not systems.active and
            not lift.latched and assembled,startReason),
        item("Stop Systems",{type="systems_stop"},systemsStopAvailable(snapshot),"SYSTEMS ARE NOT RUNNING"),
        item("Restart Systems",{type="restart_systems"},restart.available==true and not lift.latched and assembled,
            restart.reason or (lift.latched and "DISARM KILL BEFORE RESTART") or "SYSTEMS RESTART UNAVAILABLE"),
        item(kill.disarm and "Disarm Kill" or "Kill Lift",
            {type=kill.disarm and "disarm_lift_kill" or "emergency_kill_lift"},killAvailable,
            kill.message or "LIFT KILL IN PROGRESS",not kill.disarm)
    }
end

local function systemsMenuLayout(width)
    local menuWidth=28
    return {x=width-menuWidth+1,y=4,width=menuWidth,height=12}
end

-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Render the current Systems dropdown and its available actions.
local function drawSystemsMenu(surface,renderer,snapshot)
    if renderer.killReview or snapshot.systemsStopReview then renderer.systemsMenu=nil end
    renderer.systemsMenuRegions={}
    if not renderer.systemsMenu then return surface end
    local layout=systemsMenuLayout(surface.width)
    local headerX=math.floor(surface.width*2/3)+1
    drawButton(surface,headerX,3,surface.width-headerX+1,"Options [v]","selected")
    fillRect(surface,layout.x,layout.y,layout.width,layout.height,"gray","white")
    for index,entry in ipairs(systemsMenuItems(snapshot)) do
        local y=layout.y+1+(index-1)*2
        drawButton(surface,layout.x+1,y,layout.width-2,entry.label,
            entry.enabled and (entry.danger and "danger" or "enabled") or "disabled")
        renderer.systemsMenuRegions[index]={x1=layout.x+1,x2=layout.x+layout.width-2,
            y1=y,y2=y,action=entry.action,enabled=entry.enabled,reason=entry.reason}
    end
    if renderer.systemsMenuNotice then
        for index,line in ipairs(wrapErrorText(renderer.systemsMenuNotice,layout.width-2)) do
            if index>2 then break end
            put(surface,layout.x+1,layout.y+8+index,line,"white")
        end
    end
    return finishSurface(surface)
end

-- Section: Operator navigation | Local selection, editing and returned actions.
-- Summary: Resolve dropdown touches against the current snapshot's action availability.
local function touchSystemsMenu(renderer,x,y,snapshot,width)
    if renderer.killReview or snapshot.systemsStopReview then renderer.systemsMenu=nil;return false end
    local trigger=y==3 and x>math.floor(width*2/3)
    if not renderer.systemsMenu then
        if not trigger then return false end
        renderer.systemsMenu=true;renderer.systemsMenuNotice=nil
        return true
    end
    local layout=systemsMenuLayout(width)
    for index,entry in ipairs(systemsMenuItems(snapshot)) do
        local row=layout.y+1+(index-1)*2
        if y==row and x>=layout.x+1 and x<=layout.x+layout.width-2 then
            -- Recompute from this touch's raw snapshot, never cached draw state.
            if not entry.enabled then renderer.systemsMenuNotice=entry.reason;return true end
            renderer.systemsMenu=nil;renderer.systemsMenuNotice=nil;renderer.actionNotice=nil
            if entry.action.type=="emergency_kill_lift" then
                renderer.killReview={at=os.clock and os.clock() or 0}
                return true
            end
            return true,entry.action
        end
    end
    if trigger or x<layout.x or x>=layout.x+layout.width or y<layout.y or y>=layout.y+layout.height then
        renderer.systemsMenu=nil;renderer.systemsMenuNotice=nil
    end
    -- Gaps and outside touches are consumed; nothing underneath receives them.
    return true
end
-- End systems menu helpers.

-- Navigator current issues and warning navigation v1
Info={}
-- Collect active notices from the same cached snapshot used by navigation.
-- Section: Current issues | Active warnings, rotation and local issue navigation.
-- Summary: Collect active notices from the same cached snapshot used by navigation.
function Info.collect(renderer,snapshot)
    local live=isLive(snapshot);local items,seen={},{}
    local function add(id,message,tone,source,detail)
        -- Command and control lease problems are the core pausing; one notice covers all of them.
        if leaseText(message) or leaseText(detail) then
            id,message,tone,source,detail="core-stall",stallText(snapshot),"yellow","core",nil
        end
        if type(message)~="string" or message=="" or seen[id] then return end
        seen[id]=true
        items[#items+1]={id=id,text=message,tone=tone or "yellow",source=source,detail=detail}
    end
    local kill=emergencyLift(snapshot,live)
    add("kill",kill.message,kill.tone,"core")
    local assembly=assemblyProblem(snapshot,live)
    -- A disassembled vessel shows only this instruction (and a latched lift kill): the other
    -- warnings are its consequences, reported again by vessel data, propulsion and faults.
    -- The assembly check's own message is the issue's detail.
    if vesselDefinitelyDisassembled(snapshot,live) then
        add("assembly-lock","ASSEMBLE VESSEL TO ENABLE CONTROLS","red","state",
            assembly.message or assembly.reason or "VESSEL DISASSEMBLED")
        return items
    end
    if assembly then add("assembly-lock",assembly.message or assembly.reason or "VESSEL DISASSEMBLED","red","state") end
    local check=snapshot.assembly or {}
    if live then add("assembly-unverified",check.warning,"yellow","state",
        check.unverifiedSeconds and ("UNVERIFIED "..math.floor(check.unverifiedSeconds).."s")) end
    local fleet=fleetBootProblem(snapshot,live)
    if fleet then add("fleet",fleet.reason or "FLEET NOT READY","red","core") end
    local conflict=snapshot.identityConflict or {}
    if live and conflict.active then add("duplicate-id",conflict.text,"red","core",conflict.detail) end
    add("altitude-abort",altitudeAbortMessage(snapshot,live),"red","core")
    add("lift-capacity",balancedLiftWarning(snapshot,live),"red","core")
    local v=snapshot.vessel or {}
    if sensorAvailable(snapshot,v,"altitude",live) and v.altitude>=290 then
        add("air-pressure","ALTITUDE AIR PRESSURE WARNING","red","core")
    end
    local motion=snapshot.motionWarnings or {}
    if live and motion.active then add("motion",motion.text,motion.tone,"core") end
    local systems=snapshot.systemsStartup or {};local recovery=systems.recovery or {}
    if systems.phase=="SUSPENDED" and recovery.state then
        add("lift-recovery","LIFT "..recovery.state,"yellow","core",recovery.reason)
    end
    for _,key in ipairs({"autopilot","anchorControl"}) do
        local r=snapshot[key] or {};local state=tostring(r.state or "")
        if r.active and state:find("RETRYING",1,true) then
            add(key.."-recovery",(key=="autopilot" and "AP " or "ANCHOR ")..state,
                "yellow","core",r.reason)
        end
    end
    local issue=firstThrustIssue(snapshot,live)
    local duplicate=false
    for _,fault in ipairs(snapshot.faults or {}) do
        if issue==tostring(fault) or issue=="FAULT "..tostring(fault) then duplicate=true end
    end
    local endpointIssue=false
    if live then
        local thrust=thrustSnapshot(snapshot)
        for _,spec in ipairs({{thrust.roles,thrustControllerLabels,true},{thrust.units,thrustDataLabels,false}}) do
            if type(spec[1])=="table" then
                for _,label in ipairs(spec[2]) do
                    local role=spec[1][label]
                    local status=roleDisplayStatus(role,live,spec[3])
                    if status~="RDY" and status~="CMD" and status~="LIVE" then
                        endpointIssue=true
                        local detail=roleFaultText(role) or (type(role)=="table" and role.reason)
                        add("endpoint-"..label,label.." "..status,(status=="FAULT" and not leaseText(detail)) and "red" or "yellow",label,detail)
                    end
                end
            end
        end
    end
    if issue and not duplicate and not endpointIssue then
        add("propulsion",issue,(issue:find("FAULT",1,true) and not leaseText(issue)) and "red" or "yellow","core")
    end
    local cockpit=snapshot.cockpitControl or {}
    if live and cockpit.reason then add("cockpit",cockpit.reason,"yellow","core")
    elseif live and cockpit.thrustNotNeutral==true then
        add("neutral","THRUST NOT NEUTRAL","yellow","core")
    end
    add("command",requestNotice(snapshot.bridgeRequest),"yellow","bridge")
    local trimControl=type(snapshot.trimControl)=="table" and snapshot.trimControl or {}
    if live and type(trimControl.levelingWarning)=="string" then add("leveling",trimControl.levelingWarning,"yellow","core") end
    local anchor=snapshot.anchorControl or {}
    if anchor.active and renderer.anchorInputNoticeUntil and (os.clock()<=renderer.anchorInputNoticeUntil) then
        add("anchor-input","ANCHOR ENGAGED - RELEASE ANCHOR TO USE CONTROLS","yellow","core")
    end
    -- Lease faults and boiler checks (vent faults the probe does not confirm) are yellow.
    local function reportedTone(fault)
        if leaseText(fault) or tostring(fault):find("CHECK BOILER",1,true) then return "yellow" end
        return "red"
    end
    for n,fault in ipairs(snapshot.faults or {}) do
        add("reported-fault:"..tostring(fault),tostring(fault),reportedTone(fault),"core")
    end
    for _,q in ipairs({"FL","FR","BL","BR"}) do
        local node=(snapshot.nodes or {})[q] or {}
        local source="chamber-"..string.lower(q)
        for n,fault in ipairs(node.faults or (node.status or {}).faults or {}) do
            add(source.."-fault:"..tostring(fault),tostring(fault),reportedTone(fault),source)
        end
    end
    add("action",renderer.actionNotice,"yellow","bridge")
    return items
end
-- Choose the rotating warning while retaining a stable per-issue age.
-- Summary: Choose the rotating warning while retaining a stable per-issue age.
function Info.choose(renderer,items,now)
    local ages=renderer.issueAges or {};renderer.issueAges=ages
    local active,top,rank={},0,{red=3,yellow=2,green=1}
    for _,item in ipairs(items) do
        active[item.id]=true;ages[item.id]=ages[item.id] or now;item.since=ages[item.id]
        top=math.max(top,rank[item.tone] or 2)
    end
    for id in pairs(ages) do if not active[id] then ages[id]=nil end end
    local eligible={}
    for _,item in ipairs(items) do if (rank[item.tone] or 2)==top then eligible[#eligible+1]=item end end
    local current,index=renderer.warningID,nil
    for n,item in ipairs(eligible) do if item.id==current then index=n end end
    if not index then index=1;renderer.warningChangedAt=now
    elseif now-(renderer.warningChangedAt or now)>=3 then
        index=index%#eligible+1;renderer.warningChangedAt=now
    end
    local chosen=eligible[index]
    renderer.warningID=chosen and chosen.id or nil
    return chosen
end
-- Record the displayed touch target and draw plain warning text.
-- Summary: Record the displayed touch target and draw plain warning text.
function Info.warning(surface,renderer,snapshot,now)
    local items=Info.collect(renderer,renderer.informationSnapshot or snapshot)
    renderer.currentIssues=items
    local chosen=Info.choose(renderer,items,now)
    renderer.warningRegion=nil
    if chosen then
        fillRect(surface,1,21,surface.width,1,"black","white")
        local text=clampText(chosen.text,surface.width-2)
        put(surface,2,21,text,chosen.tone)
        renderer.warningRegion={x1=2,x2=1+#text,y=21,id=chosen.id}
    end
    return finishSurface(surface)
end
-- Open the shared issues page and retain its invoking view.
function Info.open(renderer,id)
    renderer.issuesParent={page=renderer.page,settingsView=renderer.settingsView,
        settingsOffset=renderer.settingsOffset,shipView=renderer.shipView,navView=renderer.navView}
    renderer.issuesOpen=true;renderer.issuesOffset=0;renderer.issueFocus=id
    for n,item in ipairs(renderer.currentIssues or {}) do if item.id==id then renderer.issuesOffset=math.floor((n-1)/4)*4 end end
end
-- Render active issues in four readable entries with cached status details.
-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Render the current view into its configured terminal or monitor.
function Info.draw(surface,renderer,snapshot,now)
    if not renderer.issuesOpen then return surface end
    renderer.systemsMenu=nil;renderer.warningRegion=nil
    fillRect(surface,1,5,surface.width,17,"black","white")
    centered(surface,5,"CURRENT ISSUES","cyan")
    local items=renderer.currentIssues or {}
    local offset=math.max(0,math.min(renderer.issuesOffset or 0,math.max(0,math.floor((#items-1)/4)*4)))
    renderer.issuesOffset=offset
    if #items==0 then centered(surface,10,"NO CURRENT ISSUES","green") end
    for n=1,4 do
        local item=items[offset+n]
        if item then
            local y=6+(n-1)*3
            put(surface,2,y,(item.id==renderer.issueFocus and "> " or "")..clampText(item.text,surface.width-4),item.tone)
            local lines=wrapErrorText(item.detail or "",surface.width-2)
            if lines[1] then put(surface,2,y+1,lines[1],"lightGray") end
            put(surface,2,y+2,tostring(item.source or "core").." | ACTIVE "..math.floor(math.max(0,now-(item.since or now))).."s","gray")
        end
    end
    drawButton(surface,2,5,15,"< BACK","enabled")
    drawButton(surface,19,19,16,"< PREVIOUS",offset>0 and "enabled" or "disabled")
    drawButton(surface,37,19,surface.width-38,"NEXT >",offset+4<#items and "enabled" or "disabled")
    centered(surface,20,tostring(#items).." ACTIVE | "..tostring(math.floor(offset/4)+1).."/"..tostring(math.max(1,math.ceil(#items/4))),"gray")
    return finishSurface(surface)
end
-- Handle issue navigation locally before underlying cockpit touch targets.
-- Section: Operator navigation | Local selection, editing and returned actions.
-- Summary: Handle issue navigation locally before underlying cockpit touch targets.
function Info.touch(renderer,x,y,snapshot,width)
    if renderer.killReview or snapshot.systemsStopReview then return false end
    if renderer.issuesOpen then
        if y==5 and x>=2 and x<=16 then
            local parent=renderer.issuesParent or {}
            renderer.issuesOpen=false
            for _,key in ipairs({"page","settingsView","settingsOffset","shipView","navView"}) do renderer[key]=parent[key] end
        elseif y==19 and x>=19 and x<=34 then renderer.issuesOffset=math.max(0,(renderer.issuesOffset or 0)-4)
        elseif y==19 and x>=37 then renderer.issuesOffset=(renderer.issuesOffset or 0)+4 end
        return true
    end
    local r=renderer.warningRegion
    if r and y==r.y and x>=r.x1 and x<=r.x2 then Info.open(renderer,r.id);return true end
    if renderer.page=="SETTINGS" and (renderer.settingsView or "GENERAL")=="GENERAL" and y==16 and x>=2 and x<=27 then
        Info.open(renderer);return true
    end
    return false
end

-- Summary: Construct renderer navigation, editor, cache and monitor state.
function UI.new(monitor, config)
    if type(monitor) ~= "table" then return nil, "UI.new requires a wrapped monitor peripheral" end
    config = type(config) == "table" and config or {}
    if type(monitor.getSize) ~= "function" or type(monitor.setCursorPos) ~= "function" then
        return nil, "monitor must provide getSize() and setCursorPos()"
    end
    if type(monitor.blit) ~= "function" and type(monitor.write) ~= "function" then
        return nil, "monitor must provide blit() or write()"
    end
    if type(monitor.setTextScale) == "function" then
        local ok, reason = pcall(monitor.setTextScale, config.textScale or UI.TEXT_SCALE)
        if not ok then return nil, "could not set monitor text scale: " .. tostring(reason) end
    end
    local renderer = {
        monitor = monitor,
        config = config,
        page = "FLIGHT",
        shipView = "LIFT",
        tabs = {},
        previous = nil,
        lastAbsSpeed = nil,
        lastSpeedAt = nil,
        filteredTrend = nil,
    }
    return setmetatable(renderer, { __index = UI })
end

-- Display-only retention. Raw snapshots and all command gates retain their
-- actual validity/age, and are still used by touch handlers and diagnostics.
-- Section: Display data | Field validity, formatting and status selection.
-- Summary: Display-only retention. Raw snapshots and all command gates retain their actual validity/age, and are still used by touch handlers and diagnostics.
local function retainedDisplay(renderer,snapshot)
 local function copy(t) local out={};for k,v in pairs(t or {}) do out[k]=v end;return out end
 if not isLive(snapshot) or vesselDefinitelyDisassembled(snapshot,true) then
  renderer.lastGoodVessel=nil;renderer.lastGoodSystems=nil;return snapshot
 end
 local shown=copy(snapshot)
 local vessel=snapshot.vessel or {}
 if vessel.valid==true then renderer.lastGoodVessel=copy(vessel)
 elseif renderer.lastGoodVessel and (vessel.uuid==nil or vessel.uuid==renderer.lastGoodVessel.uuid) then
  shown.vessel=copy(renderer.lastGoodVessel);shown.vessel.held=true
  shown.faults={}
  for _,fault in ipairs(snapshot.faults or {}) do
   if fault~="SABLE SENSOR SAMPLE STALE" and fault~="VESSEL DATA UNAVAILABLE" then shown.faults[#shown.faults+1]=fault end
  end
 end
 local systems=snapshot.systemsStartup or {};local recovery=systems.recovery or {}
 if systems.phase=="SUSPENDED" and recovery.background==true then
  shown.systemsStartup=copy(systems)
  shown.systemsStartup.phase=recovery.resumePhase or (renderer.lastGoodSystems or {}).phase or "READY"
  shown.systemsStartup.reason=nil;shown.systemsStartup.warning=nil
  shown.systemsStartup.ackWaitSeconds=nil
 elseif systems.phase~="ABORTED" then renderer.lastGoodSystems=copy(systems) end
 return shown
end

-- Section: Page rendering | Cached character-cell views and action regions.
-- Summary: Build and flush the current cached navigator display.
function UI:draw(snapshot)
    snapshot = type(snapshot) == "table" and snapshot or {}
    displayAge = snapshot.displayAgeSeconds
    local actionSnapshot=snapshot
    self.informationSnapshot=snapshot
    snapshot = retainedDisplay(self,snapshot)
    local width, height, sizeError = monitorSize(self.monitor)
    if not width then return false, sizeError end
    local surface
    if width < UI.MIN_MAIN_WIDTH or height < UI.MIN_MAIN_HEIGHT then
        surface = drawTooSmall(self, width, height)
        self.tabs = {};self.systemsMenu=nil
    else
        local now = os.clock and os.clock() or 0
        surface = drawMain(self, snapshot, width, height, now)
        surface = drawSystemsMenu(surface,self,actionSnapshot)
        if not self.killReview and not actionSnapshot.systemsStopReview and not self.systemsMenu then
            surface=Info.warning(surface,self,snapshot,now)
            surface=Info.draw(surface,self,snapshot,now)
        end
    end
    local ok, reason = pcall(drawSurface, self, surface)
    if not ok then
        self.previous = nil
        return false, "could not draw monitor: " .. tostring(reason)
    end
    return true
end

-- Page selection is local. Mode and altitude buttons send requests to core;
-- core must accept them before a snapshot changes. AP remains unavailable.
-- Section: Operator navigation | Local selection, editing and returned actions.
-- Summary: Page selection is local. Mode and altitude buttons send requests to core; core must accept them before a snapshot changes. AP remains unavailable.
function UI:touch(x, y, snapshot)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    snapshot = type(snapshot) == "table" and snapshot or {}
    local width, height = monitorSize(self.monitor)
    if not width or width < UI.MIN_MAIN_WIDTH or height < UI.MIN_MAIN_HEIGHT then return nil end
    if x<1 or x>width or y<1 or y>height or x%1~=0 or y%1~=0 then return nil end
    if Info.touch(self,x,y,snapshot,width) then return nil end
    if self.killReview then
        local now=os.clock and os.clock() or 0
        if now-self.killReview.at>UI.KILL_REVIEW_SECONDS then
            self.killReview=nil
        else
            -- While the dialog is open only its two buttons respond.
            for _,region in ipairs(self.killRegions or {}) do
                if x>=region.x1 and x<=region.x2 and y>=region.y1 and y<=region.y2 then
                    self.killReview=nil
                    if not region.confirm then self.actionNotice="LIFT KILL CANCELLED";return nil end
                    if not isLive(snapshot) then self.actionNotice="WAITING FOR FRESH CORE STATUS";return nil end
                    self.actionNotice=nil
                    return {type="emergency_kill_lift"}
                end
            end
            return nil
        end
    end
    local menuHandled,menuAction=touchSystemsMenu(self,x,y,snapshot,width)
    if menuHandled then return menuAction end
    local lateralWidth=math.floor((width-3)/3)
    if self.page=="FLIGHT" and y==4 and x>=lateralWidth+2 and x<=lateralWidth*2+1 then
        if not isLive(snapshot) or (snapshot.lateralControl or {}).locked==true or (snapshot.cockpitControl or {}).available~=true or
            (snapshot.autopilot or {}).active or (snapshot.anchorControl or {}).active then return nil end
        local mode=(snapshot.modes or {}).lateral or "MANUAL"
        return {type="cockpit_mode",axis="lateral",mode=mode=="SEL" and "MANUAL" or "SEL"}
    end
    if self.page=="NAV" and (self.navView or "ANCHOR")=="ANCHOR" and not self.navEditor and y==20 and x>=2 and x<=width-1 then
        if not isLive(snapshot) then self.actionNotice="WAITING FOR FRESH CORE STATUS";return nil end
        local anchor=snapshot.anchorControl or {}
        if anchor.active then
            self.actionNotice=nil;return {type="anchor_cancel"}
        end
        if not anchor.available then self.actionNotice=anchor.engageReason or "ANCHOR UNAVAILABLE";return nil end
        self.actionNotice=nil;return {type="anchor_engage"}
    end
    if snapshot.systemsStopReview then
        if not isLive(snapshot) then return nil end
        for _,region in ipairs(self.stopRegions or {}) do
            if x>=region.x1 and x<=region.x2 and y>=region.y1 and y<=region.y2 then return region.action end
        end
        return nil
    end
    -- A monitor can resize/rebind before its next draw. Never use footer
    -- regions cached at the old width to interpret a new touch coordinate.
    self.tabs = tabRegions(width, height)
    for _, region in ipairs(self.tabs) do
        if x >= region.x1 and x <= region.x2 and y >= region.y1 and y <= region.y2 then
            self.editor=nil;self.settingsNotice=nil;self.actionNotice=nil
            return { type = "page", page = region.page }
        end
    end
    if self.page=="NAV" then
        for _,r in ipairs(self.navRegions or {}) do
            if x>=r.x1 and x<=r.x2 and y==r.y then
                local a=r.action
                if a.type=="nav_view" then self.navView=a.view;self.navEditor=nil;self.actionNotice=nil;return nil end
                if not isLive(snapshot) then self.actionNotice="WAITING FOR FRESH CORE STATUS";return nil end
                if not r.enabled then self.actionNotice=(snapshot.autopilot or {}).engageReason or "NAVIGATION ACTION UNAVAILABLE";return nil end
                if a.type=="ap_field" then self.navEditor={type="ap_edit",key=a.key,label=a.label,buffer=tostring(a.value)};self.actionNotice=nil;return nil end
                if a.type=="nav_key" then return self:navEditorKey(a.key) end
                if a.type=="destination_highlight" then self.destinationIndex=a.index;return nil end
                if a.type=="library_previous" then self.libraryOffset=math.max(0,(self.libraryOffset or 0)-4);return nil end
                if a.type=="library_next" then self.libraryOffset=(self.libraryOffset or 0)+4;return nil end
                if a.type=="destination_rename_edit" then self.navEditor={type="destination_rename",index=a.index,label="saved destination name",buffer=a.name};return nil end
                if a.type=="destination_select" then self.navView="AUTOPILOT" end
                self.actionNotice=nil;return a
            end
        end
    end
    if self.page == "SHIP" then
        local live = isLive(snapshot)
        if assemblyProblem(snapshot, live) or fleetBootProblem(snapshot, live) then return nil end
        for _, region in ipairs(shipTabRegions(width)) do
            if x >= region.x1 and x <= region.x2 and y >= region.y1 and y <= region.y2 then
                self.shipView = region.view
                self.actionNotice = nil
                return nil
            end
        end
        if self.shipView == "TRIM" then
            if not live then
                self.actionNotice = "WAITING FOR FRESH CORE STATUS"
                return nil
            end
            for _, region in ipairs(self.shipRegions or {}) do
                if x >= region.x1 and x <= region.x2 and y >= region.y1 and y <= region.y2 then
                    if region.enabled and fleetActionAllowed(snapshot, region.action) then
                        self.actionNotice = nil
                        return region.action
                    end
                    local trim = type(snapshot.trimControl) == "table" and snapshot.trimControl or {}
                    self.actionNotice = trim.manualTrimReason or "MANUAL BIAS NOT AVAILABLE"
                    return nil
                end
            end
        end
    end
    if self.page=="SETTINGS" then
        for _,region in ipairs(self.settingsRegions or {}) do
            if x>=region.x1 and x<=region.x2 and y>=region.y1 and y<=region.y2 and region.enabled then
                local action=region.action
                if not fleetActionAllowed(snapshot,action) then return nil end
                if action.type=="settings_view" then self.settingsView=action.view;self.settingsOffset=0;self.settingsNotice=nil;return nil end
                if not isLive(snapshot) then return nil end
                if action.type=="settings_next" then
                    -- Step whole pages and wrap to the first page, never to a partial offset.
                    local nextOffset=(self.settingsOffset or 0)+9
                    if nextOffset>=action.count then nextOffset=0 end
                    self.settingsOffset=nextOffset;return nil
                end
                if action.type=="settings_edit" then self.editor={entry=action.entry,buffer=tostring(action.entry.value)};self.settingsNotice=nil;return nil end
                if action.type=="settings_key" then return self:editorKey(action.key) end
                if action.type=="setting_update" then
                    for _,entry in ipairs((snapshot.settings or {}).entries or {}) do if entry.key==action.key then return action end end
                    action.type="display_setting";return action
                end
                return action
            end
        end
    end
    if fleetBootBlocked(snapshot) then return nil end
    if y==3 and isLive(snapshot) and x<=math.floor(width*2/3) and (snapshot.cockpitControl or {}).available~=true then
        self.actionNotice=(snapshot.cockpitControl or {}).reason or "COCKPIT INPUTS UNAVAILABLE"
    end
    if y==3 and isLive(snapshot) and (snapshot.cockpitControl or {}).available==true then
        for _,axis in ipairs({"heading","throttle"}) do
            for _,region in ipairs(modeRegions(width,axis)) do
                if x>=region.x1 and x<=region.x2 then self.actionNotice=nil;return {type="cockpit_mode",axis=axis,mode=region.mode} end
            end
        end
    end

    return nil
end


-- Summary: Apply local settings-editor input and return a validated save action.
function UI:editorKey(key)
    local e=self.editor;if not e then return nil end
    if key=="CANCEL" then self.editor=nil;return nil end
    if key=="DEL" then e.buffer=e.buffer:sub(1,-2)
    elseif key=="CLEAR" then e.buffer=""
    elseif key=="SAVE" then
        local value=tonumber(e.buffer)
        if not finite(value) or value<e.entry.min or value>e.entry.max then self.settingsNotice="VALUE OUT OF RANGE";return nil end
        self.editor=nil;self.settingsNotice=nil
        return {type=e.entry.localSetting and "display_setting" or "setting_update",key=e.entry.key,value=value}
    elseif #e.buffer<20 and key:match("^[0-9%.%-]$") then e.buffer=e.buffer..key end
end
-- Summary: Apply local destination-editor input and return a validated navigation action.
function UI:navEditorKey(key)
    local e=self.navEditor;if not e then return nil end
    if key=="CANCEL" then self.navEditor=nil;return nil end
    if key=="CLEAR" then e.buffer=""
    elseif key=="DEL" then e.buffer=e.buffer:sub(1,-2)
    elseif key=="SAVE" then
        local name=e.key=="name" or e.type=="destination_rename"
        local value=name and e.buffer or tonumber(e.buffer)
        -- A blank destination name is accepted: core then names it by its coordinates. Saved-library names stay required.
        local blankAllowed=e.key=="name" and e.type~="destination_rename"
        if (name and ((not value:match("%S") and not blankAllowed) or #value>40)) or (not name and not finite(value)) then self.actionNotice="ENTER A VALID VALUE";return nil end
        self.navEditor=nil;self.actionNotice=nil
        if e.type=="destination_rename" then return {type=e.type,index=e.index,name=value} end
        return {type="ap_edit",key=e.key,value=value}
    elseif e.key=="name" or e.type=="destination_rename" then
        if key=="SPACE" then key=" " end
        if #key==1 and not key:find("[%c]") and #e.buffer<40 then e.buffer=e.buffer..key end
    elseif #e.buffer<20 and key:match("^[0-9%.%-]$") then e.buffer=e.buffer..key end
end
-- Summary: Route keyboard input to the active local editor or navigation context.
function UI:input(event,value)
    if self.systemsMenu then
        if event=="key" and keys and value==keys.escape then self.systemsMenu=nil;self.systemsMenuNotice=nil end
        return nil
    end
    if self.page=="NAV" and self.navEditor then
        if event=="char" then return self:navEditorKey(value) end
        if event=="key" and keys then
            if value==keys.backspace then return self:navEditorKey("DEL") end
            if value==keys.enter or value==keys.numPadEnter then return self:navEditorKey("SAVE") end
            if value==keys.escape then return self:navEditorKey("CANCEL") end
        end
        return nil
    end
    if self.page~="SETTINGS" or not self.editor then return nil end
    if event=="char" then return self:editorKey(value) end
    if event=="key" and keys then
        if value==keys.backspace then return self:editorKey("DEL") end
        if value==keys.enter or value==keys.numPadEnter then return self:editorKey("SAVE") end
        if value==keys.escape then return self:editorKey("CANCEL") end
    end
end

-- Export these pure helpers for the offline checks without making them part
-- of the normal display/runtime interface.
UI._test = {
    numberText = numberText,
    normalizeHeading = normalizeHeading,
    nodeSummary = nodeSummary,
    tabRegions = tabRegions,
}

return UI
