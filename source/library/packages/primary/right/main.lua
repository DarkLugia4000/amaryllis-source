-- @ama-section: Primary propulsion | Direction interlocks, drive commands and endpoint status.
-- Read-only primary-bearing telemetry endpoint.
package.path = "/avionics/?.lua;" .. package.path
local Hardware = require("hardware")
local Thrust = {}

Thrust.PROTOCOL = "amaryllis.v1"
Thrust.CONTROLLERS = { "thrust-lb", "thrust-rb", "thrust-ls", "thrust-rs" }
Thrust.SENSORS = { "primary-left", "primary-right" }
Thrust.ROLE_DRIVES = {
    ["thrust-lb"] = { "lateral-lb-p", "lateral-lb-s" },
    ["thrust-rb"] = { "lateral-rb-p", "lateral-rb-s" },
    ["thrust-ls"] = { "primary-left", "lateral-ls-p", "lateral-ls-s" },
    ["thrust-rs"] = { "primary-right", "lateral-rs-p", "lateral-rs-s" },
}
Thrust.ROLE_ALIASES = {
    ["lat-lb-p"] = "lateral-lb-p", ["lat-lb-s"] = "lateral-lb-s",
    ["lat-rb-p"] = "lateral-rb-p", ["lat-rb-s"] = "lateral-rb-s",
    ["lat-ls-p"] = "lateral-ls-p", ["lat-ls-s"] = "lateral-ls-s",
    ["lat-rs-p"] = "lateral-rs-p", ["lat-rs-s"] = "lateral-rs-s",
}

local function canonicalRole(role)
    return Thrust.ROLE_ALIASES[role] or role
end
Thrust.canonicalRole = canonicalRole

local MAX_SEQUENCE = 2147483647
local SESSION_TIMEOUT = 5
local SYSTEM_RESTART_MAX_AGE = 15
local SYSTEM_RESTART_MAX_REQUESTS = 64
local MAX_RETIRED_CORE_SESSIONS = 32
local SYSTEM_RESTART_EVENT = "amaryllis_thrust_restart"
local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
local function integer(v, lo, hi)
    return finite(v) and v % 1 == 0 and v >= lo and v <= hi
end
local function boundedText(v, max)
    return type(v) == "string" and #v > 0 and #v <= max and not v:find("[%c]")
end
local function coreSessionKey(coreId, session)
    return tostring(coreId) .. ":" .. tostring(#session) .. ":" .. session
end
-- Retain the last 32 core sessions, matching the display consumers, so a
-- delayed session packet cannot restore old command authority without growing forever.
-- @ama-section: Primary propulsion | Direction interlocks, drive commands and endpoint status.
-- @ama-summary: Record an obsolete core session in the bounded replay-rejection history.
local function retireCoreSession(state, coreId, session)
    if not integer(coreId, 0, 65535) or not boundedText(session, 128) then return end
    state.retiredCoreSessions = state.retiredCoreSessions or {}
    state.retiredCoreSessionOrder = state.retiredCoreSessionOrder or {}
    local key = coreSessionKey(coreId, session)
    if state.retiredCoreSessions[key] then return end
    state.retiredCoreSessions[key] = true
    local order = state.retiredCoreSessionOrder
    order[#order + 1] = key
    if #order > MAX_RETIRED_CORE_SESSIONS then
        state.retiredCoreSessions[table.remove(order, 1)] = nil
    end
end
local function safeSystemRestartId(value)
    return type(value) == "string" and #value > 0 and #value <= 128 and
        value:match("^[A-Za-z0-9._:%-]+$") ~= nil
end
local function wireText(value, max)
    return tostring(value or ""):gsub("[%c]", " "):sub(1, max or 160)
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function copyMap(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end
local function roleKind(role)
    role = canonicalRole(role)
    if Thrust.ROLE_DRIVES[role] then return "controller" end
    for _, name in ipairs(Thrust.SENSORS) do if name == role then return "sensor" end end
end
local function inList(list, wanted)
    for _, value in ipairs(list or {}) do if value == wanted then return true end end
    return false
end
local function zeroMap(drives)
    local result = {}
    for _, drive in ipairs(drives or {}) do result[drive] = 0 end
    return result
end
local function counterpart(drive)
    if type(drive) ~= "string" then return nil end
    if drive:match("%-p$") then return drive:sub(1, -2) .. "s" end
    if drive:match("%-s$") then return drive:sub(1, -2) .. "p" end
end

-- The logical target is a normalized transmission request, never measured
-- thrust. Reverse on the primary shaft is rejected until a verified adapter is
-- added; lateral pair exclusivity is checked before any command is accepted.
-- @ama-summary: Validate the requested drive target map against configured channels and limits.
function Thrust.validateTargets(role, drives, targets)
    if type(targets) ~= "table" then return nil, "TARGETS MUST BE A MAP" end
    local checked = zeroMap(drives)
    for drive, value in pairs(targets) do
        if not inList(drives, drive) or not finite(value) then return nil, "UNKNOWN OR NONFINITE DRIVE TARGET" end
        if drive:match("^primary%-") then
            if value < 0 then return nil, "PRIMARY REVERSE IS UNSUPPORTED" end
            if value > 1 then return nil, "PRIMARY TARGET OUT OF RANGE" end
        elseif drive:match("^lateral%-") then
            if value < 0 or value > 1 then return nil, "LATERAL TARGET OUT OF RANGE" end
        else
            return nil, "UNKNOWN DRIVE KIND"
        end
        checked[drive] = value
    end
    for _, drive in ipairs(drives) do
        local other = counterpart(drive)
        if other and checked[drive] > 0 and checked[other] and checked[other] > 0 then
            return nil, "OPPOSING LATERALS REQUESTED TOGETHER"
        end
    end
    return checked
end

function Thrust.ramp(current, target, ratePerSecond, dt)
    if not finite(current) or not finite(target) or not finite(ratePerSecond) or not finite(dt) or
        ratePerSecond <= 0 or dt < 0 then return nil end
    local step = ratePerSecond * math.min(dt, 1)
    if current < target then return math.min(target, current + step) end
    return math.max(target, current - step)
end

-- On a side switch, the requested side stays at zero until the opposing
-- transmission is read back at zero. Unknown readback never releases the gate.
-- @ama-summary: Apply the configured direction/neutral interlocks to requested drive targets.
function Thrust.interlockTargets(drives, targets, readbacks)
    local gated, waiting = copyMap(targets), {}
    for _, drive in ipairs(drives or {}) do
        local other = counterpart(drive)
        if other and gated[drive] and gated[drive] > 0 then
            local state = readbacks and readbacks[other]
            if not state or state.mode == nil or state.level ~= 0 then
                gated[drive] = 0
                waiting[#waiting + 1] = drive
            end
        end
    end
    return gated, waiting
end

-- @ama-summary: Construct the endpoint's boot, session, target and readback state.
local function makeState(config, role, boot)
    role = canonicalRole(role)
    local drives = roleKind(role) == "controller" and Thrust.ROLE_DRIVES[role] or {}
    return {
        config = config, role = role, endpointKind = roleKind(role), drives = drives,
        nodeBoot = boot, session = nil, coreId = nil, authorizedCoreId = config.coreId, lastSessionAt = nil,
        retiredCoreSessions = {}, retiredCoreSessionOrder = {},
        lastReceivedSeq = -1, lastAppliedSeq = -1, ackSeq = -1, ackAccepted = false,
        desiredTargets = zeroMap(drives), requestedTargets = zeroMap(drives),
        applied = {}, readbacks = {}, rawShifts = {}, leaseUntil = nil,
        writerToken = 0, hasCommand = false, stopping = false,
        pendingSystemRestart = nil, pendingSystemRestartAck = nil,
        systemRestartRequestIds = {}, systemRestartRequestCount = 0,
        systemRestartRetryAt = nil, systemRestarted = false,
        phase = "DISCOVERING", reason = nil, faults = {}, statusSeq = 0,
        readbackSampleAt = nil, commandReady = false,
        commissioningStatus = "NOT REQUESTED", commissioningReason = nil,
    }
end
Thrust.newState = makeState

-- @ama-summary: Revoke the current endpoint command context and record its reason.
local function invalidate(state, reason, receivedSeq, accepted)
    state.writerToken = state.writerToken + 1
    state.desiredTargets = zeroMap(state.drives)
    state.requestedTargets = zeroMap(state.drives)
    state.leaseUntil = nil
    state.pendingAppliedSeq = nil
    state.ackAccepted = accepted == true
    if receivedSeq ~= nil then state.ackSeq = receivedSeq end
    state.reason = reason
    state.phase = "RAMPING TO ZERO"
end

-- @ama-summary: Stage a correlated rejection for the current restart request.
local function queueSystemRestartError(state, message, reason)
    if not safeSystemRestartId(message.requestId) or not safeSystemRestartId(message.bootToken) then return false end
    state.pendingSystemRestartAck = {
        sender = state.coreId,
        session = state.session,
        requestId = message.requestId,
        targetLabel = safeSystemRestartId(message.targetLabel) and message.targetLabel or state.role,
        nodeBoot = safeSystemRestartId(message.nodeBoot) and message.nodeBoot or state.nodeBoot,
        currentNodeBoot = state.nodeBoot,
        bootToken = message.bootToken,
        accepted = false,
        zeroVerified = false,
        detail = wireText(reason, 160),
    }
    state.systemRestartRetryAt = nil
    return true
end

-- @ama-summary: Validate and queue a core-requested endpoint restart.
local function queueSystemRestart(state, sender, message, now)
    if not integer(sender, 0, 65535) or not state.coreId or sender ~= state.coreId or
        type(state.session) ~= "string" or message.session ~= state.session then
        return false
    end
    if not safeSystemRestartId(message.requestId) or not safeSystemRestartId(message.bootToken) then
        return false
    end
    if state.systemRestartRequestIds[message.requestId] then
        if state.pendingSystemRestart and state.pendingSystemRestart.requestId == message.requestId then
            return false
        end
        queueSystemRestartError(state, message, "RESTART_REQUEST_REPLAY")
        return false
    end
    if state.systemRestartRequestCount >= SYSTEM_RESTART_MAX_REQUESTS then
        queueSystemRestartError(state, message, "RESTART_REQUEST_LIMIT_REACHED")
        return false
    end
    state.systemRestartRequestIds[message.requestId] = true
    state.systemRestartRequestCount = state.systemRestartRequestCount + 1

    local reason
    if message.v ~= 1 then reason = "INVALID_RESTART_VERSION"
    elseif message.role ~= nil and message.role ~= state.role then reason = "RESTART_ROLE_MISMATCH"
    elseif not safeSystemRestartId(message.targetLabel) then reason = "INVALID_RESTART_TARGET"
    elseif message.targetLabel ~= state.role then reason = "RESTART_TARGET_MISMATCH"
    elseif message.nodeBoot ~= state.nodeBoot then reason = "RESTART_BOOT_MISMATCH"
    elseif not finite(state.lastSessionAt) or now < state.lastSessionAt or
        now - state.lastSessionAt > SYSTEM_RESTART_MAX_AGE then reason = "CORE_SESSION_STALE"
    elseif state.pendingSystemRestart then reason = "RESTART_ALREADY_PENDING"
    end
    if reason then
        queueSystemRestartError(state, message, reason)
        return false
    end

    -- Cancel an in-flight normal writer job after its current peripheral API
    -- call yields. The restart owner then gets sole writer access to bound
    -- transmissions and no new flight command can gain authority.
    invalidate(state, "FORCED SYSTEM RESTART PENDING", nil, false)
    state.phase = "SYSTEM RESTART PENDING"
    state.pendingSystemRestartAck = nil
    state.systemRestartRetryAt = nil
    state.pendingSystemRestart = {
        sender = sender, session = state.session, coreId = state.coreId,
        sessionGeneration = state.sessionGeneration, role = state.role,
        targetLabel = message.targetLabel, nodeBoot = message.nodeBoot,
        requestId = message.requestId, bootToken = message.bootToken,
        receivedAt = now, writerToken = state.writerToken,
    }
    return true
end

-- Pure protocol state transition used by the runtime and offline tests.
-- @ama-summary: Pure protocol state transition used by the runtime and offline tests.
function Thrust.processPacket(state, sender, message, protocol, now)
    if protocol ~= Thrust.PROTOCOL or type(message) ~= "table" or not finite(now) then return false end
    if message.kind == "system_restart" then return queueSystemRestart(state, sender, message, now) end
    if message.kind == "thrust_session" then
        if not integer(sender, 0, 65535) or sender ~= state.authorizedCoreId or message.v ~= 1 or message.role ~= state.role or
            message.nodeBoot ~= state.nodeBoot or not boundedText(message.session, 128) then return false end
        local newSessionKey = coreSessionKey(sender, message.session)
        if (state.session ~= message.session or state.coreId ~= sender) and
            state.retiredCoreSessions and state.retiredCoreSessions[newSessionKey] then return false end
        if state.coreId and state.coreId ~= sender then
            if not finite(state.lastSessionAt) or now - state.lastSessionAt <= SESSION_TIMEOUT then return false end
            invalidate(state, "CORE CONNECTION REPLACED", nil, false)
        end
        if state.session ~= message.session or state.coreId ~= sender then
            retireCoreSession(state, state.coreId, state.session)
        end
        if state.session ~= message.session or state.coreId ~= sender then
            invalidate(state, "NEW CORE SESSION", nil, false)
            state.lastReceivedSeq, state.lastAppliedSeq = -1, -1
            state.ackSeq, state.ackAccepted, state.pendingAppliedSeq = -1, false, nil
            state.pendingSystemRestart = nil
            state.pendingSystemRestartAck = nil
            state.systemRestartRetryAt = nil
        end
        state.coreId, state.session, state.lastSessionAt = sender, message.session, now
        state.phase = "SESSION ACTIVE"
        return true
    end
    if message.kind ~= "thrust_command" and message.kind ~= "thrust_stop" then return false end
    if state.pendingSystemRestart then return false end
    if state.endpointKind ~= "controller" or not integer(sender, 0, 65535) or sender ~= state.coreId or
        message.v ~= 1 or message.role ~= state.role or message.nodeBoot ~= state.nodeBoot or
        message.session ~= state.session or not finite(state.lastSessionAt) or now - state.lastSessionAt > SESSION_TIMEOUT or
        not integer(message.seq, 1, MAX_SEQUENCE) or message.seq <= state.lastReceivedSeq then return false end

    state.lastReceivedSeq = message.seq
    state.hasCommand = true
    if message.kind == "thrust_stop" then
        invalidate(state, type(message.reason) == "string" and message.reason or "CORE STOP", message.seq, true)
        state.pendingAppliedSeq = message.seq
        return true
    end

    local ttl = message.ttlSeconds
    if not finite(ttl) or ttl <= 0 or ttl > (state.config.maxCommandTtlSeconds or 1) or ttl > 3 then
        invalidate(state, "COMMAND TTL OUT OF RANGE", message.seq, false)
        return false
    end
    if state.config.enabled ~= true or state.config.bindingsVerified ~= true then
        invalidate(state, "WRITER DISABLED OR BINDINGS UNVERIFIED", message.seq, false)
        return false
    end
    local targets, reason = Thrust.validateTargets(state.role, state.drives, message.targets)
    if not targets then
        invalidate(state, reason, message.seq, false)
        return false
    end
    state.writerToken = state.writerToken + 1
    state.desiredTargets, state.requestedTargets = targets, copyMap(targets)
    state.leaseUntil, state.pendingAppliedSeq = now + ttl, message.seq
    state.ackSeq, state.ackAccepted = message.seq, true
    state.reason, state.phase = nil, "COMMAND ACCEPTED"
    return true
end

function Thrust.targetsAt(state, now)
    if state.leaseUntil and (not finite(now) or now > state.leaseUntil) then
        if state.leaseUntil ~= false then invalidate(state, "COMMAND LEASE EXPIRED; RAMPING TO ZERO", nil, false) end
        state.leaseUntil = false -- one-shot expiry marker; no repeated token bumps
    end
    return state.leaseUntil and copyMap(state.desiredTargets) or zeroMap(state.drives)
end

local function settingMatches(definition, demand, shift)
    local maximum = definition and definition.maxLevel
    if not integer(maximum, 1, 256) then return demand == 0 and shift == 0 end
    local expected = Hardware.expectedShift(demand, 0, maximum)
    return expected ~= nil and shift == expected
end

-- @ama-summary: Read and cache the configured endpoint drive levels.
function Thrust.updateReadbacks(state, readbacks, now)
    state.rawShifts = copyMap(readbacks)
    state.readbacks, state.applied = {}, {}
    for _, drive in ipairs(state.drives) do
        local raw = readbacks[drive]
        local def = state.config.drives and state.config.drives[drive] or {}
        if raw and raw.mode == "incremental" and integer(raw.level, 0, 256) then
            state.readbacks[drive] = { shiftLevel = raw.level, valid = true }
            local maxLevel = def.maxLevel
            if integer(maxLevel, 1, 256) then state.applied[drive] = clamp(raw.level / maxLevel, 0, 1) end
        else
            state.readbacks[drive] = { valid = false }
        end
    end
    local targets = Thrust.targetsAt(state, now)
    local pending = state.pendingAppliedSeq
    if pending then
        local allSettled = true
        for _, drive in ipairs(state.drives) do
            local raw = readbacks[drive]
            local definition = state.config.drives and state.config.drives[drive] or {}
            if not raw or raw.mode ~= "incremental" or not integer(raw.level, 0, 256) or
                not settingMatches(definition, targets[drive] or 0, raw.level) then
                allSettled = false
                break
            end
        end
        if allSettled then
            state.lastAppliedSeq = pending
            local active = false
            for _, value in pairs(targets) do if value > 0 then active = true end end
            state.phase = active and "APPLIED" or "ZERO READBACK CONFIRMED"
        end
    end
end

function Thrust.shouldWrite(state)
    return state.endpointKind == "controller" and state.writerEnabled == true and
        state.hasCommand == true and state.pendingSystemRestart == nil and state.systemRestarted ~= true
end

-- Age is for the last completed readback pass across every bound drive. A
-- status heartbeat cannot make cached hardware observations look fresh.
-- @ama-summary: Build the bounded endpoint drive-readback view.
function Thrust.readbackSnapshot(state, now, staleAfter)
    local age = finite(state.readbackSampleAt) and finite(now) and now >= state.readbackSampleAt and
        (now - state.readbackSampleAt) or nil
    local fresh = age ~= nil and finite(staleAfter) and staleAfter > 0 and age <= staleAfter
    local readbacks, applied = {}, {}
    if not fresh then
        -- Invalidate cached observations locally as well as on the wire. A
        -- later completed getter pass repopulates these maps.
        state.readbacks, state.applied = {}, {}
        for _, drive in ipairs(state.drives or {}) do state.readbacks[drive] = { valid = false } end
    end
    for _, drive in ipairs(state.drives or {}) do
        local readback = state.readbacks and state.readbacks[drive]
        if fresh and readback and readback.valid == true then
            readbacks[drive] = { shiftLevel = readback.shiftLevel, valid = true }
            if state.applied and finite(state.applied[drive]) then applied[drive] = state.applied[drive] end
        else
            readbacks[drive] = { valid = false }
        end
    end
    return age, fresh == true, readbacks, applied
end

-- @ama-summary: Validate the role's required configuration fields and operating bounds.
local function validateConfig(config, role, endpointKind)
    role = canonicalRole(role)
    local configRole = type(config) == "table" and canonicalRole(config.telemetryRole or config.role) or nil
    local roleMatches = type(config) == "table" and (configRole == role or
        (config.role == "auto" and endpointKind == "sensor" and roleKind(role) == "sensor"))
    if type(config) ~= "table" or config.version ~= 1 or config.protocol ~= "amaryllis.v1" or not roleMatches or
        config.endpointKind ~= endpointKind then return false, "ROLE OR CONFIG VERSION MISMATCH" end
    if endpointKind == "sensor" then return true end
    if type(config.enabled) ~= "boolean" or type(config.bindingsVerified) ~= "boolean" or
        type(config.drives) ~= "table" or type(config.bindings) ~= "table" then
        return false, "CONTROLLER CONFIGURATION IS INCOMPLETE"
    end
    if config.commissionZeroOnStartup ~= nil and type(config.commissionZeroOnStartup) ~= "boolean" then
        return false, "commissionZeroOnStartup MUST BE A BOOLEAN"
    end
    if config.commissionZeroOnStartup == true and
        (config.enabled ~= true or config.bindingsVerified ~= true or type(config.bindingFingerprint) ~= "string" or
            config.bindingFingerprint == "") then
        return false, "STARTUP COMMISSIONING REQUIRES AN ENABLED, VERIFIED BINDING"
    end
    local expected = Thrust.ROLE_DRIVES[role] or {}
    for key in pairs(config.drives) do if not inList(expected, key) then return false, "UNEXPECTED DRIVE: " .. tostring(key) end end
    for key in pairs(config.bindings) do if not inList(expected, key) then return false, "UNEXPECTED BINDING: " .. tostring(key) end end
    for _, drive in ipairs(expected) do
        local definition = config.drives[drive]
        local binding = config.bindings[drive]
        if type(definition) ~= "table" or type(binding) ~= "table" then return false, "DRIVE CONFIG MISSING: " .. drive end
        if not integer(definition.maxLevel, 0, 256) or (config.enabled and definition.maxLevel == 0) then
            return false, "INVALID VERIFIED LIMIT FOR " .. drive
        end
        if not finite(definition.rampPerSecond) or definition.rampPerSecond <= 0 or definition.rampPerSecond > 1 then
            return false, "INVALID RAMP LIMIT FOR " .. drive
        end
        if definition.commissionModeOnCommand ~= nil then
            return false, "MODE COMMISSIONING IS MANUAL; REMOVE commissionModeOnCommand"
        end
        if type(binding.peripheral) ~= "string" then return false, "PERIPHERAL NAME MISSING FOR " .. drive end
    end
    local ttl = config.maxCommandTtlSeconds
    if not finite(ttl) or ttl <= 0 or ttl > 3 then return false, "INVALID MAXIMUM COMMAND TTL" end
    local readbackStale = config.readbackStaleSeconds
    if not finite(readbackStale) or readbackStale <= 0 or readbackStale > 3 then
        return false, "INVALID READBACK FRESHNESS LIMIT"
    end
    return true
end
Thrust.validateConfig = validateConfig

-- @ama-summary: Discover and open role-network modems through rednet.
local function connectRednet()
    local opened = {}
    if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" or type(rednet) ~= "table" then
        return opened, "REDNET OR PERIPHERAL API UNAVAILABLE"
    end
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return opened, "COULD NOT ENUMERATE MODEMS" end
    table.sort(names)
    for _, name in ipairs(names) do
        local isModem = false
        if type(peripheral.hasType) == "function" then
            local good, yes = pcall(peripheral.hasType, name, "modem")
            isModem = good and yes == true
        end
        if not isModem and type(peripheral.getType) == "function" then
            local good, kind = pcall(peripheral.getType, name)
            isModem = good and (kind == "modem" or (type(kind) == "table" and inList(kind, "modem")))
        end
        if isModem then
            local good = pcall(rednet.open, name)
            if good then opened[#opened + 1] = name end
        end
    end
    if #opened == 0 then return opened, "NO MODEM PERIPHERAL FOUND" end
    return opened
end

local function sendBroadcast(packet)
    if not rednet or type(rednet.broadcast) ~= "function" then return false end
    local ok, result = pcall(rednet.broadcast, packet, Thrust.PROTOCOL)
    return ok and result ~= false
end
local function sendDirect(id, packet)
    if not rednet or type(rednet.send) ~= "function" then return false end
    local ok, result = pcall(rednet.send, id, packet, Thrust.PROTOCOL)
    return ok and result ~= false
end

-- @ama-summary: Load and validate the role's configuration file.
local function readConfig()
    if not fs or not fs.exists("/avionics/config.json") then return nil, "MISSING /avionics/config.json" end
    local handle, reason = fs.open("/avionics/config.json", "r")
    if not handle then return nil, "CONFIG OPEN FAILED: " .. tostring(reason) end
    local raw = handle.readAll(); handle.close()
    local ok, value = pcall(textutils.unserializeJSON, raw)
    if not ok or type(value) ~= "table" then return nil, "CONFIG JSON IS INVALID" end
    return value
end

local function bootToken()
    local id = type(os.getComputerID) == "function" and os.getComputerID() or 0
    local epoch = type(os.epoch) == "function" and os.epoch("utc") or math.floor(os.clock() * 1000)
    math.randomseed((epoch or 0) + id)
    return tostring(epoch or 0) .. "-" .. tostring(math.random(100000, 999999))
end

-- @ama-summary: Rediscover role hardware and update its binding identity and availability.
local function refreshBindings(config, role)
    local found, reason = Hardware.discover()
    if not found then return {}, false, reason, nil end
    local bindings, reasons = Hardware.controllerBindings(config, found)
    local currentFingerprint = Hardware.inventoryFingerprint(role, config.bindings)
    if config.bindingsVerified ~= true then reasons[#reasons + 1] = "BINDINGS_NOT_COMMISSIONED" end
    if type(config.bindingFingerprint) ~= "string" or config.bindingFingerprint ~= currentFingerprint then
        reasons[#reasons + 1] = "BINDING_FINGERPRINT_MISMATCH"
    end
    local ready = #reasons == 0
    return bindings, ready, table.concat(reasons, "; "), found
end

-- @ama-summary: Refresh the endpoint's configuration, hardware and drive readback status.
local function refreshStatus(state, config, configValid, bindingReady, bindingReason, networkReady)
    state.configValid = configValid == true
    state.bindingReady = bindingReady == true
    local commissioningReady = config.commissionZeroOnStartup ~= true or state.commissioningStatus == "READY"
    state.writerEnabled = state.endpointKind == "controller" and state.configValid and
        state.bindingReady and config.enabled == true and commissioningReady
    state.enabled = state.endpointKind == "sensor" or config.enabled == true
    state.ready = state.endpointKind == "sensor" and networkReady == true or state.writerEnabled and networkReady == true
    if not state.configValid then state.reason = state.configReason or "CONFIG INVALID"
    elseif state.endpointKind == "controller" and not state.bindingReady then state.reason = bindingReason or "BINDINGS NOT READY"
    elseif state.endpointKind == "controller" and config.commissionZeroOnStartup == true and not commissioningReady then
        state.reason = state.commissioningReason or "STARTUP ZERO/INCREMENTAL COMMISSIONING NOT COMPLETE"
    elseif state.endpointKind == "controller" and not state.writerEnabled then state.reason = "WRITER DISABLED IN CONFIG"
    elseif not networkReady then state.reason = "NETWORK UNAVAILABLE"
    elseif state.reason == "CONFIG INVALID" or state.reason == "BINDINGS NOT READY" or state.reason == "WRITER DISABLED IN CONFIG" or
        state.reason == "NETWORK UNAVAILABLE" or state.reason == "STARTUP ZERO/INCREMENTAL COMMISSIONING NOT COMPLETE" then state.reason = nil end
end

-- @ama-summary: Advance endpoint control authority and the current requested drive operation.
local function controllerTick(state, config, hardwareBindings, now, dt)
    if state.stopping or state.endpointKind ~= "controller" or state.pendingSystemRestart then return end
    state.phase = state.phase or "READY"
    local liveTargets = Thrust.targetsAt(state, now)
    local token = state.writerToken
    local function jobCurrent() return not state.stopping and state.writerToken == token end
    local rawReadbacks = {}
    local hardwareFault
    for _, drive in ipairs(state.drives) do
        local binding = hardwareBindings[drive]
        if binding then
            local level, reason, mode = Hardware.readShift(binding, jobCurrent)
            if level ~= nil then rawReadbacks[drive] = { level = level, mode = mode }
            else
                rawReadbacks[drive] = { reason = reason }
                hardwareFault = hardwareFault or reason
            end
        else
            rawReadbacks[drive] = { reason = "TRANSMISSION UNBOUND" }
        end
        if not jobCurrent() then return end
    end
    state.rawShifts = rawReadbacks
    local gatedTargets, waiting = Thrust.interlockTargets(state.drives, liveTargets, rawReadbacks)
    state.interlockWaiting = waiting

    for _, drive in ipairs(state.drives) do
        if not jobCurrent() then return end
        local binding = hardwareBindings[drive]
        local raw = rawReadbacks[drive]
        local definition = config.drives[drive]
        if binding and raw and raw.level ~= nil and Thrust.shouldWrite(state) then
            local wanted = gatedTargets[drive] or 0
            local activeCommand = state.leaseUntil and state.leaseUntil ~= false and now <= state.leaseUntil
            if wanted > 0 and raw.mode ~= "incremental" then
                hardwareFault = hardwareFault or "TRANSMISSION NOT IN INCREMENTAL MODE; MANUAL COMMISSIONING REQUIRED"
                state.phase = "MODE NOT READY"
                -- A mode changed while thrust was requested. Revoke the lease;
                -- the next sole-writer pass can command verified zero in the
                -- observed mode, then readiness remains false until repaired.
                if state.hasCommand then invalidate(state, "TRANSMISSION MODE CHANGED; RAMPING TO ZERO", nil, false) end
            elseif raw.mode == "incremental" and integer(raw.level, 0, 256) then
                local current = definition.maxLevel > 0 and clamp(raw.level / definition.maxLevel, 0, 1) or 0
                local nextValue = Thrust.ramp(current, wanted, definition.rampPerSecond, dt)
                local nextLevel = nextValue and Hardware.expectedShift(nextValue, 0, definition.maxLevel)
                if nextLevel ~= nil and nextLevel ~= raw.level then
                    local stillAuthorized = activeCommand and wanted > 0
                    local allowed = stillAuthorized and function()
                        return jobCurrent() and state.leaseUntil and state.leaseUntil ~= false and os.clock() <= state.leaseUntil
                    end or jobCurrent
                    local ok, reason
                    if not stillAuthorized and nextLevel == 0 then
                        ok, reason = Hardware.writeShift(binding, 0, allowed)
                    else
                        ok, reason = Hardware.writeShift(binding, nextLevel, allowed)
                    end
                    if not ok then hardwareFault = hardwareFault or reason end
                elseif nextLevel == nil then state.reason = "INVALID SHIFT LIMIT: " .. drive end
            elseif raw.mode == "direct" and raw.level > 0 and state.hasCommand and wanted == 0 then
                -- Direct-mode readback has different units. A zero command is
                -- safe in either mode; no direct-mode intermediate is inferred.
                local ok, reason = Hardware.writeSafeZero(binding, jobCurrent)
                if not ok then hardwareFault = hardwareFault or reason end
            elseif raw.reason and state.hasCommand and liveTargets[drive] == 0 then
                hardwareFault = hardwareFault or raw.reason
            end
        end
        if not jobCurrent() then return end
    end

    -- A separate fresh readback pass provides ACK only after the librarys
    -- scheduled transmission update becomes visible through getShiftLevel.
    local settled = {}
    local completeReadback = true
    for _, drive in ipairs(state.drives) do
        local binding = hardwareBindings[drive]
        if binding then
            local level, _, mode = Hardware.readShift(binding, jobCurrent)
            if level ~= nil then settled[drive] = { level = level, mode = mode } end
            if level == nil then completeReadback = false end
        else
            completeReadback = false
        end
        if not jobCurrent() then return end
    end
    Thrust.updateReadbacks(state, settled, os.clock())
    if completeReadback then state.readbackSampleAt = os.clock() end
    if #waiting > 0 then
        state.phase = "LATERAL INTERLOCK: WAITING FOR ZERO READBACK"
    elseif hardwareFault then
        state.reason = hardwareFault
    elseif state.leaseUntil and state.leaseUntil ~= false then
        state.reason = nil
        state.phase = "COMMAND ACTIVE"
    elseif state.reason and state.reason:find("TRANSMISSION MODE CHANGED", 1, true) then
        local allIncremental = true
        for _, drive in ipairs(state.drives) do
            if not settled[drive] or settled[drive].mode ~= "incremental" then allIncremental = false end
        end
        if allIncremental then state.reason = nil; state.phase = "READY" end
    elseif state.reason and state.reason:find("TRANSMISSION NOT IN", 1, true) then
        state.reason = nil
    end
end

-- @ama-summary: Build the bounded current-session endpoint status packet.
local function statusPacket(state, now)
    state.statusSeq = math.min(MAX_SEQUENCE, state.statusSeq + 1)
    if state.endpointKind == "sensor" then
        local readings, _, usefulData = Hardware.readBearings(state.inventory)
        local available = usefulData == true and state.configValid == true
        state.sensorAvailable = available
        state.sensorReason = not available and (state.configReason or "NO VALID SPEED, THRUST, OR VECTOR READBACK") or nil
        return {
            v = 1, kind = "thrust_status", session = state.session,
            role = state.role, endpointKind = "sensor", nodeBoot = state.nodeBoot,
            seq = state.statusSeq, available = available,
            reason = not available and state.sensorReason or nil,
            faults = {}, readings = readings,
        }
    end
    local reason = state.reason and wireText(state.reason, 160) or nil
    local age, fresh, readbacks, applied = Thrust.readbackSnapshot(state, now or os.clock(), state.config.readbackStaleSeconds)
    local allValid = fresh
    for _, drive in ipairs(state.drives) do
        if not readbacks[drive] or readbacks[drive].valid ~= true then allValid = false end
    end
    local ready = state.ready == true and allValid
    if not fresh then reason = reason or "TRANSMISSION READBACK STALE" end
    if fresh and not allValid then reason = reason or "TRANSMISSION MODE OR READBACK INVALID" end
    state.readbackAgeSeconds, state.readbackFresh = age, fresh
    state.statusReady = ready
    state.statusCommandReady = state.commandReady == true and ready
    return {
        v = 1, kind = "thrust_status", session = state.session,
        role = state.role, endpointKind = "controller", nodeBoot = state.nodeBoot,
        seq = state.statusSeq, ready = ready, enabled = state.enabled == true,
        configValid = state.configValid == true, bindingReady = state.bindingReady == true,
        writerEnabled = state.writerEnabled == true, commandReady = state.statusCommandReady,
        readbackAgeSeconds = age,
        bindingFingerprint = state.configFingerprint,
        phase = state.phase, reason = reason,
        faults = reason and { reason:sub(1, 128) } or {},
        requestedTargets = copyMap(state.requestedTargets), applied = applied,
        readbacks = readbacks, lastReceivedSeq = state.lastReceivedSeq,
        lastAppliedSeq = state.lastAppliedSeq, ackSeq = state.ackSeq, ackAccepted = state.ackAccepted,
    }
end
Thrust.statusPacket = statusPacket

-- @ama-summary: Revalidate the pending reboot against its request age, session and local boot.
local function restartStillAuthorized(state, command, now)
    return state.pendingSystemRestart == command and
        state.coreId == command.coreId and state.coreId == command.sender and
        state.session == command.session and state.role == command.role and
        state.nodeBoot == command.nodeBoot and state.writerToken == command.writerToken and
        finite(state.lastSessionAt) and now >= state.lastSessionAt and
        now - state.lastSessionAt <= SYSTEM_RESTART_MAX_AGE and
        now >= command.receivedAt and now - command.receivedAt <= SYSTEM_RESTART_MAX_AGE
end

-- @ama-summary: Write verified zero demand to each configured propulsion drive.
local function forceZeroConfiguredDrives(state, bindings, stillAuthorized, wait)
    if state.endpointKind == "sensor" then return true, "READ_ONLY_SENSOR" end
    bindings = bindings or {}
    wait = wait or function(seconds) sleep(seconds) end
    local verifiedAll, faults = true, {}
    if #state.drives == 0 then return false, "NO_CONFIGURED_TRANSMISSIONS" end
    for _, drive in ipairs(state.drives) do
        if not stillAuthorized() then return nil, "RESTART_AUTHORITY_EXPIRED_DURING_ZERO" end
        local binding = bindings[drive]
        if not binding or not binding.object then
            verifiedAll = false
            faults[#faults + 1] = "UNBOUND:" .. tostring(drive)
        else
            local wrote, writeReason = Hardware.writeSafeZero(binding, stillAuthorized)
            if not stillAuthorized() then return nil, "RESTART_AUTHORITY_EXPIRED_DURING_ZERO" end
            local driveVerified, lastReason = false, writeReason
            for attempt = 1, 10 do
                if not stillAuthorized() then return nil, "RESTART_AUTHORITY_EXPIRED_DURING_ZERO" end
                local level, readReason = Hardware.readShift(binding, stillAuthorized)
                if level == 0 then driveVerified = true; break end
                lastReason = readReason or ("ZERO_READBACK:" .. tostring(level))
                if attempt < 10 then
                    local waited, waitReason = pcall(wait, 0.1)
                    if not waited then lastReason = "ZERO_SETTLE_WAIT_FAILED:" .. tostring(waitReason); break end
                end
            end
            if not driveVerified then
                verifiedAll = false
                faults[#faults + 1] = tostring(drive) .. ":" .. tostring(lastReason or "ZERO_NOT_VERIFIED")
            elseif not wrote and writeReason then
                -- A verified zero is authoritative even if a setter reported
                -- a late error, but retain that hardware detail in the ACK.
                faults[#faults + 1] = tostring(drive) .. ":" .. tostring(writeReason)
            end
        end
    end
    local detail = verifiedAll and "ALL_CONFIGURED_TRANSMISSIONS_ZERO_VERIFIED" or table.concat(faults, "; ")
    return verifiedAll, wireText(detail, 160)
end

-- @ama-summary: Send the correlated restart acceptance or rejection to core.
local function sendSystemRestartAck(state, reply, rednetApi)
    if state.coreId ~= reply.sender or state.session ~= reply.session or
        state.nodeBoot ~= reply.currentNodeBoot then return false end
    local network = rednetApi or rednet
    if not network or type(network.send) ~= "function" then return false end
    local packet = {
        v = 1, kind = "system_restart_ack", session = reply.session,
        requestId = reply.requestId, targetLabel = reply.targetLabel,
        nodeBoot = reply.nodeBoot, bootToken = reply.bootToken,
        accepted = reply.accepted == true, zeroVerified = reply.zeroVerified == true,
        detail = wireText(reply.detail, 160),
    }
    local ok, sent = pcall(network.send, reply.sender, packet, Thrust.PROTOCOL)
    return ok and sent == true
end

-- @ama-summary: Acknowledge and execute a fresh authorized reboot after writer completion.
local function processPendingSystemRestart(state, bindings, now, rednetApi, wait, reboot)
    now = now or os.clock()
    local errorReply = state.pendingSystemRestartAck
    if errorReply then
        if not sendSystemRestartAck(state, errorReply, rednetApi) then
            state.systemRestartRetryAt = now + 0.5
            return false
        end
        if state.pendingSystemRestartAck == errorReply then state.pendingSystemRestartAck = nil end
        state.systemRestartRetryAt = nil
        return true
    end

    local command = state.pendingSystemRestart
    if not command or (state.systemRestartRetryAt and now < state.systemRestartRetryAt) then return false end
    if not restartStillAuthorized(state, command, now) then
        if state.coreId == command.coreId and state.session == command.session and
            state.nodeBoot == command.nodeBoot then
            state.pendingSystemRestartAck = {
                sender = command.sender, session = command.session,
                requestId = command.requestId, targetLabel = command.targetLabel,
                nodeBoot = command.nodeBoot, currentNodeBoot = state.nodeBoot,
                bootToken = command.bootToken, accepted = false, zeroVerified = false,
                detail = "RESTART_REQUEST_EXPIRED_OR_SUPERSEDED",
            }
            state.pendingSystemRestart = nil
            return processPendingSystemRestart(state, bindings, now, rednetApi, wait, reboot)
        end
        state.pendingSystemRestart = nil
        return false
    end

    local stillAuthorized = function() return restartStillAuthorized(state, command, os.clock()) end
    local zeroVerified, detail = forceZeroConfiguredDrives(state, bindings or state.bindings, stillAuthorized, wait)
    if zeroVerified == nil then
        if state.pendingSystemRestart == command then
            state.pendingSystemRestartAck = {
                sender = command.sender, session = command.session,
                requestId = command.requestId, targetLabel = command.targetLabel,
                nodeBoot = command.nodeBoot, currentNodeBoot = state.nodeBoot,
                bootToken = command.bootToken, accepted = false, zeroVerified = false,
                detail = detail,
            }
            state.pendingSystemRestart = nil
            return processPendingSystemRestart(state, bindings, os.clock(), rednetApi, wait, reboot)
        end
        return false
    end
    if not stillAuthorized() then
        state.pendingSystemRestart = nil
        return false
    end

    local reply = {
        sender = command.sender, session = command.session,
        requestId = command.requestId, targetLabel = command.targetLabel,
        nodeBoot = command.nodeBoot, currentNodeBoot = state.nodeBoot,
        bootToken = command.bootToken, accepted = true,
        zeroVerified = zeroVerified, detail = detail,
    }
    if not sendSystemRestartAck(state, reply, rednetApi) then
        state.systemRestartRetryAt = os.clock() + 0.5
        state.lastApplyFault = "SYSTEM_RESTART_ACK_SEND_FAILED"
        return false
    end
    if not stillAuthorized() then
        if state.pendingSystemRestart == command then state.pendingSystemRestart = nil end
        state.reason = "SYSTEM RESTART AUTHORITY EXPIRED AFTER ACK"
        return false
    end
    state.pendingSystemRestart = nil
    state.systemRestartRetryAt = nil
    state.systemRestarted = true
    if zeroVerified then state.reason = nil else state.reason = detail end
    state.phase = zeroVerified and "SYSTEM RESTART ACCEPTED; ZERO VERIFIED" or "SYSTEM RESTART ACCEPTED; ZERO FAULT"
    local restart = reboot or os.reboot
    if type(restart) == "function" then restart() end
    return true
end
Thrust.processSystemRestart = processPendingSystemRestart

-- @ama-summary: Validate the installed core, role and local computer identity.
local function validInstalledIdentity(config, role)
    local expected = role == "primary-left" and { role = "primary_l", packageId = "amaryllis.primary.l" }
        or role == "primary-right" and { role = "primary_r", packageId = "amaryllis.primary.r" }
    local install = config and config.install
    local computerID = type(os.getComputerID) == "function" and os.getComputerID() or nil
    if not expected or type(install) ~= "table" or install.protocol ~= "amaryllis.install.v1"
        or install.role ~= expected.role or config.role ~= expected.role
        or install.packageId ~= expected.packageId or not integer(install.version, 2, 2147483647)
        or not integer(install.coreID, 0, 65535) or config.coreId ~= install.coreID
        or not boundedText(install.coreSession, 128)
        or install.computerID ~= computerID or config.computerId ~= computerID or install.label ~= config.label
        or config.telemetryRole ~= role or config.protocol ~= Thrust.PROTOCOL then
        return false, "INSTALLED ROLE OR COMPUTER IDENTITY MISMATCH"
    end
    return true
end
Thrust.validInstalledIdentity = validInstalledIdentity
-- @ama-summary: Initialize the role's runtime context and start its supervised workers.
local function runtime()
    local config, configError = readConfig()
    if not config then error(configError, 0) end
    local role = canonicalRole(config.telemetryRole or config.role)
    local kind = roleKind(role)
    local configValid, validationReason = validateConfig(config, role, kind)
    local identityValid, identityReason = validInstalledIdentity(config, role)
    if not identityValid then configValid, validationReason = false, identityReason end
    local boot = bootToken()
    local state = makeState(config, role, boot)
    state.authorizedCoreId = identityValid and config.coreId or nil
    state.configValid, state.configReason = configValid, validationReason
    if not configValid then state.reason = validationReason end
    local opened, networkError = connectRednet()
    local networkReady = #opened > 0
    local configFingerprint = kind == "controller" and Hardware.inventoryFingerprint(role, config.bindings) or nil
    local bindings, bindingReady, bindingReason, found
    if kind == "controller" and configValid then
        bindings, bindingReady, bindingReason, found = refreshBindings(config, role)
    else
        bindings, bindingReady, bindingReason, found = {}, false, validationReason, nil
    end
    state.bindings, state.bindingReady, state.bindingReason = bindings, bindingReady, bindingReason
    if kind == "sensor" then
        local inventory, reason = Hardware.discover()
        state.inventory = inventory
        if not inventory then state.reason = reason end
        local _, _, usefulData = Hardware.readBearings(inventory)
        state.sensorAvailable = usefulData == true and configValid == true
        state.sensorReason = not state.sensorAvailable and (reason or validationReason or "BEARING_DATA_UNAVAILABLE") or nil
    end
    state.configFingerprint = configFingerprint
    if kind == "controller" and config.commissionZeroOnStartup == true then
        state.commissioningStatus = "PENDING"
        if not configValid then
            state.commissioningStatus = "FAULT"
            state.commissioningReason = validationReason or "CONTROLLER CONFIGURATION IS INVALID"
        elseif not bindingReady then
            state.commissioningStatus = "FAULT"
            state.commissioningReason = bindingReason or "BOUND TRANSMISSIONS ARE NOT READY"
        else
            -- This runs before any network or control task. The helper checks
            -- every configured peripheral first, writes only bounded zeros,
            -- verifies every zero, then changes only non-incremental modes.
            local commissioned, commissionReason = Hardware.commissionZeroAndIncremental(
                bindings, state.drives, nil, function(seconds) sleep(seconds) end)
            if commissioned then
                state.commissioningStatus = "READY"
                state.commissioningReason = nil
                state.phase = "STARTUP ZERO/INCREMENTAL VERIFIED"
            else
                state.commissioningStatus = "FAULT"
                state.commissioningReason = "STARTUP COMMISSIONING FAULT: " .. tostring(commissionReason)
                state.phase = "STARTUP COMMISSIONING FAULT"
            end
        end
    end
    refreshStatus(state, config, configValid, bindingReady, bindingReason or networkError, networkReady)
    local runtimeState = os.__amaryllisRuntime or {}
    runtimeState.components = runtimeState.components or {}
    runtimeState.running = true
    runtimeState.startedAt = runtimeState.startedAt or os.clock()
    runtimeState.snapshot = state
    -- @ama-summary: Publish the role's current cached state to the local runtime context.
    local function updateRuntime(now)
        runtimeState = os.__amaryllisRuntime or runtimeState
        runtimeState.components = runtimeState.components or {}
        local component = runtimeState.components.primary or {}
        runtimeState.components.primary = component
        local faults = {}
        if not identityValid then faults[#faults+1] = tostring(identityReason or "INSTALLED_IDENTITY_INVALID") end
        if state.sensorAvailable ~= true then faults[#faults+1] = tostring(state.sensorReason or "BEARING_DATA_UNAVAILABLE") end
        if not networkReady then faults[#faults+1] = tostring(networkError or "NETWORK_UNAVAILABLE") end
        component.running = true
        component.hardwareAvailable = state.sensorAvailable == true
        component.faults = faults
        component.faultSummary = #faults > 0 and table.concat(faults, "; "):sub(1, 256) or nil
        component.snapshot = state
        component.publishedAt = now or os.clock()
        runtimeState.running = true
        runtimeState.hardwareAvailable = component.hardwareAvailable
        runtimeState.faults = faults
        runtimeState.faultSummary = component.faultSummary
        runtimeState.snapshot = state
        runtimeState.publishedAt = component.publishedAt
        os.__amaryllisRuntime = runtimeState
    end
    updateRuntime(os.clock())
    print("Amaryllis thrust role: " .. tostring(role) .. " (" .. tostring(kind) .. ")")
    if kind == "controller" then
        print("Writer is " .. (state.writerEnabled and "enabled by config and binding check" or "disabled; no startup output write"))
        if config.commissionZeroOnStartup == true then
            print("Startup zero/incremental commissioning: " .. state.commissioningStatus ..
                (state.commissioningReason and (" (" .. state.commissioningReason .. ")") or ""))
        else
            print("Startup commissioning is disabled; no output write was requested.")
        end
    end
    if not networkReady then print(networkError or "Network unavailable; no remote command accepted.") end

    -- @ama-summary: Validate and dispatch received packets for the current role and session.
    local function dispatch(sender, message, protocol)
        if protocol ~= Thrust.PROTOCOL or type(message) ~= "table" then return end
        if message.kind == "system_restart" then
            local accepted = Thrust.processPacket(state, sender, message, protocol, os.clock())
            if accepted or state.pendingSystemRestartAck then os.queueEvent(SYSTEM_RESTART_EVENT) end
        elseif message.kind == "thrust_session" or message.kind == "thrust_command" or message.kind == "thrust_stop" then
            local accepted = Thrust.processPacket(state, sender, message, protocol, os.clock())
            if accepted and message.kind == "thrust_session" then print("Core session accepted from dynamic sender #" .. tostring(sender)) end
        end
        updateRuntime(os.clock())
    end
    -- @ama-summary: Receive network packets and pass matching requests to the role dispatcher.
    local function receiveLoop()
        while not state.stopping do
            local event, sender, message, protocol = os.pullEventRaw()
            if event == "terminate" then
                state.stopping = true
                state.writerToken = state.writerToken + 1
                return
            elseif event == "rednet_message" then dispatch(sender, message, protocol) end
        end
    end
    -- @ama-summary: Publish cached endpoint status at the configured interval.
    local function publishLoop()
        local nextHello, nextStatus, nextSensorScan = 0, 0, 0
        while not state.stopping do
            local now = os.clock()
            if kind == "sensor" and now >= nextSensorScan then
                local inventory, inventoryReason = Hardware.discover()
                state.inventory = inventory
                local _, _, usefulData = Hardware.readBearings(inventory)
                state.sensorAvailable = usefulData == true and configValid == true
                state.sensorReason = not state.sensorAvailable and (inventoryReason or validationReason or "BEARING_DATA_UNAVAILABLE") or nil
                updateRuntime(now)
                nextSensorScan = now + (config.statusIntervalSeconds or 0.5)
            end
            if now >= nextHello then
                local hello = { v = 1, kind = "thrust_hello", role = role,
                    endpointKind = kind, nodeBoot = boot }
                if kind == "controller" then
                    hello.drives = {}
                    for _, drive in ipairs(state.drives) do hello.drives[#hello.drives + 1] = drive end
                end
                sendBroadcast(hello)
                nextHello = now + 1
            end
            if state.session and state.coreId and now - (state.lastSessionAt or 0) <= SESSION_TIMEOUT and now >= nextStatus then
                if kind == "sensor" then
                    local inventory = Hardware.discover()
                    state.inventory = inventory
                end
                local packet = statusPacket(state)
                updateRuntime(now)
                sendDirect(state.coreId, packet)
                state.phase = state.phase or "STATUS PUBLISHED"
                nextStatus = now + (config.statusIntervalSeconds or 0.5)
            end
            -- Wait for this loops own timer only. Waking on every event and
            -- starting a fresh timer each time multiplies outstanding timers
            -- until the 256-event queue overflows and drops other events.
            local timer = os.startTimer(0.1)
            while true do
                local event, timerId = os.pullEventRaw()
                if event == "terminate" then state.stopping = true; return end
                if event == "timer" and timerId == timer then break end
            end
        end
    end
    -- @ama-summary: Serialize queued hardware operations and maintenance through the role's sole writer.
    local function writerLoop()
        if kind ~= "controller" then return end
        local last = os.clock()
        while not state.stopping do
            local started = os.clock()
            local dt = clamp(started - last, 0.01, 0.25); last = started
            local currentBindings, currentReady, currentReason = refreshBindings(config, role)
            state.bindings, state.bindingReady, state.bindingReason = currentBindings, currentReady, currentReason
            refreshStatus(state, config, configValid, currentReady, currentReason, networkReady)
            if state.pendingSystemRestart then
                state.commandReady = false
                if not state.systemRestartRetryAt or os.clock() >= state.systemRestartRetryAt then
                    processPendingSystemRestart(state, currentBindings, os.clock(), rednet, function(seconds) sleep(seconds) end)
                end
            else
                if state.pendingSystemRestartAck and
                    (not state.systemRestartRetryAt or os.clock() >= state.systemRestartRetryAt) then
                    processPendingSystemRestart(state, currentBindings, os.clock(), rednet, function(seconds) sleep(seconds) end)
                end
                -- Getter sampling remains read-only until ordinary commands
                -- grant writer authority. A forced reboot takes priority and
                -- uses this writer before any normal controller tick can run.
                if configValid and not state.pendingSystemRestart and state.systemRestarted ~= true then
                    controllerTick(state, config, currentBindings, started, dt)
                end
                local _, sampleFresh, sampleReadbacks = Thrust.readbackSnapshot(
                    state, os.clock(), config.readbackStaleSeconds)
                state.commandReady = state.writerEnabled == true and sampleFresh and
                    state.pendingSystemRestart == nil and state.systemRestarted ~= true
                for _, drive in ipairs(state.drives) do
                    local raw = sampleReadbacks[drive]
                    if not raw or raw.valid ~= true then state.commandReady = false end
                end
            end
            updateRuntime(os.clock())
            local wait = math.max(0.02, (config.controlIntervalSeconds or 0.1) - (os.clock() - started))
            local timer = os.startTimer(wait)
            while not state.stopping do
                local event, timerId = os.pullEventRaw()
                if event == "terminate" then state.stopping = true; return end
                if event == "timer" and timerId == timer then break end
            end
        end
    end
    -- @ama-summary: Handle the local sensor/endpoint restart request through its current authority.
    local function sensorRestartLoop()
        if kind ~= "sensor" then return end
        while not state.stopping do
            local now = os.clock()
            if (state.pendingSystemRestart or state.pendingSystemRestartAck) and
                (not state.systemRestartRetryAt or now >= state.systemRestartRetryAt) then
                processPendingSystemRestart(state, {}, now, rednet, function(seconds) sleep(seconds) end)
            end
            local timer = os.startTimer(0.1)
            while not state.stopping do
                local event, timerId = os.pullEventRaw()
                if event == "terminate" then state.stopping = true; return end
                if event == SYSTEM_RESTART_EVENT or (event == "timer" and timerId == timer) then break end
            end
        end
    end
    parallel.waitForAll(receiveLoop, publishLoop, writerLoop, sensorRestartLoop)
    state.stopping = true
    updateRuntime(os.clock())
    if os.__amaryllisRuntime then os.__amaryllisRuntime.running = false end
end

Thrust.run = runtime
if rawget(_ENV, "__THRUST_TEST") then return Thrust end
runtime()
