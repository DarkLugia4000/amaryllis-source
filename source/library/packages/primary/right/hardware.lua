-- @ama-section: Primary hardware | Bearing/gearshift discovery and readback verification.
-- Read-only discovery and the sole transmission writer for thrust controllers.
-- This adapter uses only APIs checked in the installed Create Propulsion jar
-- and the existing Amaryllis propulsion reference. It never infers RPM or force
-- from a transmission shift-level readback.
local Hardware = {}

local TRANSMISSION_TYPE = "redstone_transmission"
local BEARING_TYPE = "propeller_bearing"
local BRIDGE_TYPE = "redstone_link_bridge"
local MAX_SHIFT_LEVEL = 256 -- installed 1.1.5 source: ratio = shift_level / 256
local RAW_VALUE_LIMIT = 1000000000000 -- wire-format bound only; no measurement units are inferred

local function finite(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end

local function integer(value)
    return finite(value) and value % 1 == 0
end

-- @ama-section: Endpoint context | Configuration, discovery and command identity.
-- @ama-summary: Return discovered names in deterministic order.
local function sortedNames(api)
    local ok, names = pcall(api.getNames)
    if not ok or type(names) ~= "table" then
        return nil, "could not list peripherals: " .. tostring(names)
    end
    table.sort(names)
    return names
end

-- @ama-summary: Check the reported peripheral type against the requested interface.
local function hasType(api, name, expected)
    if type(api.hasType) == "function" then
        local ok, result = pcall(api.hasType, name, expected)
        if ok and result == true then return true end
    end
    if type(api.getType) == "function" then
        local values = { pcall(api.getType, name) }
        if values[1] then
            for index = 2, #values do
                if values[index] == expected then return true end
            end
        end
    end
    return false
end

local function wrap(api, name)
    local ok, object = pcall(api.wrap, name)
    if not ok or type(object) ~= "table" then return nil end
    return object
end

local function invoke(object, method, ...)
    local fn = object and object[method]
    if type(fn) ~= "function" then return false, "missing " .. method end
    local result = { pcall(fn, ...) }
    if not result[1] then return false, tostring(result[2]) end
    return true, result[2]
end

local function readOptional(object, method, valid)
    if type(object and object[method]) ~= "function" then return nil, false end
    local ok, value = invoke(object, method)
    if not ok or not valid(value) then return nil, false end
    return value, true
end

local function validVector(value)
    if type(value) ~= "table" then return false end
    local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
    return finite(x) and finite(y) and finite(z) and math.abs(x) <= RAW_VALUE_LIMIT and
        math.abs(y) <= RAW_VALUE_LIMIT and math.abs(z) <= RAW_VALUE_LIMIT
end

function Hardware.isFinite(value)
    return finite(value)
end

function Hardware.isInteger(value)
    return integer(value)
end

-- @ama-summary: Discover and bind the configured role hardware.
function Hardware.discover(api)
    api = api or peripheral
    if type(api) ~= "table" or type(api.getNames) ~= "function" or type(api.wrap) ~= "function" then
        return nil, "ComputerCraft peripheral API is unavailable"
    end
    local names, reason = sortedNames(api)
    if not names then return nil, reason end
    local found = { all = {}, transmissions = {}, bearings = {}, bridges = {} }
    for _, name in ipairs(names) do
        local object = wrap(api, name)
        if object then
            local entry = { name = name, object = object }
            found.all[#found.all + 1] = entry
            if hasType(api, name, TRANSMISSION_TYPE) then
                found.transmissions[#found.transmissions + 1] = entry
            end
            if hasType(api, name, BEARING_TYPE) then
                found.bearings[#found.bearings + 1] = entry
            end
            if hasType(api, name, BRIDGE_TYPE) then
                found.bridges[#found.bridges + 1] = entry
            end
        end
    end
    return found
end

-- @ama-summary: Build the deterministic configured hardware identity used by binding checks.
function Hardware.inventoryFingerprint(role, bindings)
    local rows = { tostring(role or "") }
    local names = {}
    for drive, binding in pairs(bindings or {}) do names[#names + 1] = drive end
    table.sort(names)
    for _, drive in ipairs(names) do
        local binding = bindings[drive] or {}
        rows[#rows + 1] = drive .. "=" .. tostring(binding.peripheral or "")
    end
    return table.concat(rows, "|")
end

-- Sensor role reads only known PropellerBearing getters. Each raw field keeps
-- its getter name and validity flag, so an undocumented unit is never invented.
-- @ama-section: Readbacks | Timestamped physical observations and status.
-- @ama-summary: Read and validate one configured propulsion bearing observation.
function Hardware.readBearing(entry)
    local object = entry and entry.object
    if not object then return nil, "bearing is unavailable" end
    local reading = { name = tostring(entry.name or "unknown"):gsub("[%c]", " "):sub(1, 128), validity = {} }
    local fields = {
        { getter = "getSpeed", field = "speedRaw", valid = function(v) return finite(v) and math.abs(v) <= RAW_VALUE_LIMIT end },
        { getter = "getThrust", field = "thrustRaw", valid = function(v) return finite(v) and math.abs(v) <= RAW_VALUE_LIMIT end },
        { getter = "getThrustVector", field = "thrustVector", valid = validVector },
        { getter = "getThrustHandedness", field = "thrustHandedness", valid = function(v)
            return v == "left_handed" or v == "right_handed"
        end },
        { getter = "isAssembled", field = "assembled", valid = function(v) return type(v) == "boolean" end },
    }
    for _, definition in ipairs(fields) do
        local value, valid = readOptional(object, definition.getter, definition.valid)
        reading.validity[definition.field] = valid
        if valid then reading[definition.field] = value end
    end
    return reading
end

-- @ama-summary: Read the configured propulsion bearing observations.
function Hardware.readBearings(found)
    local readings = {}
    local allThrustAndAxisValid = #((found and found.bearings) or {}) > 0
    local anyUseful = false
    for _, entry in ipairs((found and found.bearings) or {}) do
        if #readings >= 32 then break end -- stay inside the core's bounded packet schema
        local reading = Hardware.readBearing(entry)
        readings[#readings + 1] = reading
        if not reading.validity.thrustRaw or not reading.validity.thrustVector then
            allThrustAndAxisValid = false
        end
        if reading.validity.speedRaw or reading.validity.thrustRaw or reading.validity.thrustVector then
            anyUseful = true
        end
    end
    return readings, allThrustAndAxisValid, anyUseful
end

-- @ama-section: Endpoint context | Configuration, discovery and command identity.
-- @ama-summary: Resolve the configured controller-to-drive hardware bindings.
function Hardware.controllerBindings(config, found)
    local bindings, reasons = {}, {}
    local source = config and config.bindings or {}
    local byName = {}
    for _, entry in ipairs((found and found.transmissions) or {}) do
        byName[entry.name] = entry
    end
    for drive, definition in pairs((config and config.drives) or {}) do
        local binding = source[drive] or {}
        local name = binding.peripheral
        if type(name) ~= "string" or name == "" then
            reasons[#reasons + 1] = "UNBOUND_TRANSMISSION:" .. drive
        elseif not byName[name] then
            reasons[#reasons + 1] = "TRANSMISSION_MISSING_OR_WRONG_TYPE:" .. drive
        else
            local object = byName[name].object
            for _, method in ipairs({ "getTransmissionMode", "setTransmissionMode", "getShiftLevel", "setShiftLevel" }) do
                if type(object[method]) ~= "function" then
                    reasons[#reasons + 1] = "TRANSMISSION_METHOD_MISSING:" .. drive .. ":" .. method
                end
            end
            bindings[drive] = { name = name, object = object, definition = definition, binding = binding }
        end
    end
    local used = {}
    for drive, binding in pairs(bindings) do
        if used[binding.name] then reasons[#reasons + 1] = "TRANSMISSION_BOUND_TWICE:" .. drive
        else used[binding.name] = drive end
    end
    return bindings, reasons
end

-- @ama-section: Readbacks | Timestamped physical observations and status.
-- @ama-summary: Read the selected gearshift's current drive level.
function Hardware.readShift(binding, allowed)
    if not binding or not binding.object then return nil, "transmission is not bound" end
    local modeOk, mode = invoke(binding.object, "getTransmissionMode")
    if not modeOk then return nil, "getTransmissionMode failed: " .. tostring(mode) end
    if type(allowed) == "function" and not allowed() then return nil, "command authority expired after reading mode" end
    local levelOk, level = invoke(binding.object, "getShiftLevel")
    if not levelOk then return nil, "getShiftLevel failed: " .. tostring(level) end
    if type(allowed) == "function" and not allowed() then return nil, "command authority expired after reading shift" end
    mode = type(mode) == "string" and mode:lower() or mode
    if mode == "incremental" then
        if not integer(level) or level < 0 or level > MAX_SHIFT_LEVEL then
            return nil, "incremental shift readback is outside 0..256"
        end
    elseif mode == "direct" then
        -- Direct mode reports a 0..15 value. Preserve it as raw readback and
        -- leave controller command readiness false until mode is verified.
        if not integer(level) or level < 0 or level > 15 then
            return nil, "direct shift readback is outside 0..15"
        end
    else
        return nil, "transmission mode readback is invalid"
    end
    return level, nil, mode
end

-- @ama-summary: Read and validate the configured controller drive levels.
function Hardware.readReadbacks(bindings)
    local result = {}
    for drive, binding in pairs(bindings or {}) do
        local level, reason, mode = Hardware.readShift(binding)
        result[drive] = { shiftLevel = level, mode = mode, valid = level ~= nil, reason = reason }
    end
    return result
end

-- Calling setters is deliberately isolated here. The caller must first pass
-- config, session, sole-writer, slew, and opposition checks in main.lua.
-- @ama-section: Output operations | Verified targets applied under current authority.
-- @ama-summary: Calling setters is deliberately isolated here. The caller must first pass config, session, sole-writer, slew, and opposition checks in main.lua.
function Hardware.writeShift(binding, level, allowed)
    if type(allowed) == "function" and not allowed() then return false, "command authority expired" end
    if not integer(level) or level < 0 or level > MAX_SHIFT_LEVEL then
        return false, "shift level must be an integer from 0 through 256"
    end
    local object = binding and binding.object
    if not object then return false, "transmission is not bound" end
    local modeOk, mode = invoke(object, "getTransmissionMode")
    if not modeOk then return false, "getTransmissionMode failed: " .. tostring(mode) end
    if type(allowed) == "function" and not allowed() then return false, "command authority expired after reading mode" end
    mode = type(mode) == "string" and mode:lower() or mode
    if mode ~= "incremental" then return false, "transmission mode must already be incremental" end
    local setOk, setError = invoke(object, "setShiftLevel", level)
    if not setOk then return false, "setShiftLevel failed: " .. tostring(setError) end
    if type(allowed) == "function" and not allowed() then return false, "command authority expired after setting shift level" end
    return true
end

-- Safe zero is allowed after a command lease expires so the controller can
-- ramp down. It still verifies the live mode and shift range on every call.
-- @ama-summary: Safe zero is allowed after a command lease expires so the controller can ramp down. It still verifies the live mode and shift range on every call.
function Hardware.writeSafeZero(binding, allowed)
    local object = binding and binding.object
    if not object then return false, "transmission is not bound" end
    if type(allowed) == "function" and not allowed() then return false, "writer job was superseded" end
    local modeOk, mode = invoke(object, "getTransmissionMode")
    if not modeOk then return false, "getTransmissionMode failed: " .. tostring(mode) end
    if type(allowed) == "function" and not allowed() then return false, "writer job was superseded after reading mode" end
    mode = type(mode) == "string" and mode:lower() or mode
    local levelOk, level = invoke(object, "getShiftLevel")
    if not levelOk then return false, "getShiftLevel failed: " .. tostring(level) end
    if type(allowed) == "function" and not allowed() then return false, "writer job was superseded after reading shift" end
    if mode == "direct" then
        if not integer(level) or level < 0 or level > 15 then return false, "direct shift readback is outside 0..15" end
    elseif mode == "incremental" then
        if not integer(level) or level < 0 or level > MAX_SHIFT_LEVEL then return false, "incremental shift readback is outside 0..256" end
    else
        return false, "transmission mode readback is invalid"
    end
    local zeroOk, zeroError = invoke(object, "setShiftLevel", 0)
    if not zeroOk then return false, "safe zero command failed: " .. tostring(zeroError) end
    if type(allowed) == "function" and not allowed() then return false, "writer job was superseded after safe zero" end
    return true
end

-- One-shot startup commissioning is deliberately separate from the runtime
-- writer. It first validates every transmission, then zeroes every drive and
-- reads all zeros back before changing any mode. The caller runs this before
-- starting network/writer loops, so no command task can race these setters.
-- @ama-summary: Verify configured drive zero and bounded incremental commissioning readbacks.
function Hardware.commissionZeroAndIncremental(bindings, drives, allowed, wait)
    local function stillAllowed()
        return type(allowed) ~= "function" or allowed() == true
    end
    if type(bindings) ~= "table" or type(drives) ~= "table" or #drives == 0 then
        return false, "commissioning has no configured drives"
    end
    local before = {}
    for _, drive in ipairs(drives) do
        if not stillAllowed() then return false, "commissioning authority expired during preflight" end
        local binding = bindings[drive]
        if not binding or not binding.object then return false, "commissioning drive is unbound: " .. tostring(drive) end
        for _, method in ipairs({ "getTransmissionMode", "setTransmissionMode", "getShiftLevel", "setShiftLevel" }) do
            if type(binding.object[method]) ~= "function" then
                return false, "commissioning method missing for " .. tostring(drive) .. ": " .. method
            end
        end
        local level, reason, mode = Hardware.readShift(binding, stillAllowed)
        if level == nil then return false, "commissioning preflight failed for " .. tostring(drive) .. ": " .. tostring(reason) end
        before[drive] = { level = level, mode = mode }
    end

    -- Establish a complete zero baseline before any mode setter is called.
    for _, drive in ipairs(drives) do
        if not stillAllowed() then return false, "commissioning authority expired before zero write" end
        local ok, reason = invoke(bindings[drive].object, "setShiftLevel", 0)
        if not ok then return false, "zero write failed for " .. tostring(drive) .. ": " .. tostring(reason) end
        if not stillAllowed() then return false, "commissioning authority expired after zero write" end
    end
    -- @ama-summary: Verify each configured output against the requested target and current authority.
    local function verifyAll(predicate, description)
        local lastReason
        for attempt = 1, 10 do
            local allVerified = true
            for _, drive in ipairs(drives) do
                if not stillAllowed() then return false, "commissioning authority expired during " .. description end
                local level, reason, mode = Hardware.readShift(bindings[drive], stillAllowed)
                if level == nil or not predicate(level, mode) then
                    allVerified = false
                    lastReason = tostring(reason or ("expected " .. description .. ", got mode=" ..
                        tostring(mode) .. " level=" .. tostring(level) .. " on " .. tostring(drive)))
                end
            end
            if allVerified then return true end
            if attempt < 10 and type(wait) == "function" then
                if not stillAllowed() then return false, "commissioning authority expired before " .. description .. " retry" end
                local ok, reason = pcall(wait, 0.1)
                if not ok then return false, "commissioning wait failed: " .. tostring(reason) end
            end
        end
        return false, description .. " readback timed out: " .. tostring(lastReason)
    end
    local zeroVerified, zeroReason = verifyAll(function(level) return level == 0 end, "zero")
    if not zeroVerified then
        return false, zeroReason
    end

    -- Only after every output reads zero may a direct-mode transmission move
    -- into incremental mode. Already-incremental devices are left untouched.
    for _, drive in ipairs(drives) do
        if before[drive].mode ~= "incremental" then
            if not stillAllowed() then return false, "commissioning authority expired before mode write" end
            local ok, reason = invoke(bindings[drive].object, "setTransmissionMode", "incremental")
            if not ok then return false, "incremental mode write failed for " .. tostring(drive) .. ": " .. tostring(reason) end
            if not stillAllowed() then return false, "commissioning authority expired after mode write" end
        end
    end
    local finalVerified, finalReason = verifyAll(function(level, mode)
        return mode == "incremental" and level == 0
    end, "incremental zero")
    if not finalVerified then
        return false, finalReason
    end
    return true
end

function Hardware.expectedShift(normalized, zeroLevel, fullLevel)
    if not finite(normalized) or normalized < 0 or normalized > 1 then return nil end
    if not integer(zeroLevel) or not integer(fullLevel) or zeroLevel < 0 or fullLevel > MAX_SHIFT_LEVEL or
        fullLevel < zeroLevel then return nil end
    return math.floor(zeroLevel + (fullLevel - zeroLevel) * normalized + 0.5)
end

Hardware.constants = {
    transmissionType = TRANSMISSION_TYPE,
    bearingType = BEARING_TYPE,
    bridgeType = BRIDGE_TYPE,
    maxShiftLevel = MAX_SHIFT_LEVEL,
}

return Hardware
