-- Section: Chamber lift | Lease validation, physical readbacks and serialized provider writes.
--[[
Amaryllis lift-node coordinator.

This file owns the wireless handshake, command checks, one-at-a-time writer,
status messages, and the optional read-only `inspect` command. hardware.lua is
the only module that knows how to inspect and call peripheral methods.

Important safety boundary:
  * The configured idle composition probe can bootstrap the one trim burner
    at five units while main lift control is inactive. Inspections, hello, status reports,
    timeouts and fault cancellation never change targets or activation.
    Confirmed operator STOP SYSTEMS parks trim, turns steam off, and retains
    provider ceilings. Authenticated KILL LIFT turns bulk steam off, retains
    the five-unit trim probe for envelope telemetry, and persists a latch until
    an explicit START SYSTEMS probe is accepted.
  * Normal flight writes require a freshly discovered local allowlist and a matching
    hello from the installed core identity, and a complete in-range integer target map.
  * This node owns its configured activation link. A fresh nonzero demand sets
    ceilings first, then activates at strength 15.
  * Explicit vent startup is a separate bounded operation: exactly 50 for
    every configured bulk vent, unchanged active trim, current node boot, no flight arm.
  * START SYSTEMS is a separate, user-authorized sequence. It first activates
    only the pinned trim probe, then accepts bounded bulk lift demands after
    local balloon data is readable. A short renewable lease retains ceilings
    on expiry and never sends an off signal.
]]
local Hardware = require("hardware").lift
local peripheral = Hardware.localPeripheral()
local Main = {}

local PROTOCOL = "amaryllis.v1"
local WRITE_EVENT = "amaryllis_lift_apply"
local STATUS_EVENT = "amaryllis_lift_status_requested"
local MAX_SESSION_LENGTH = 64
local MAX_RETIRED_CORE_SESSIONS = 32
local MAX_COMMAND_SEQUENCE = 2147483647
local SYSTEMS_LEASE_SECONDS = 15
local CONTROL_CONTEXT_MAX_LEASE_SECONDS = 2
local SYSTEM_RESTART_MAX_AGE = 15
local SYSTEM_RESTART_MAX_REQUESTS = 64
local MAX_BINDING_FINGERPRINT_LENGTH = 8192
local EMERGENCY_LATCH_PATH = "/avionics/data/emergency-stop.json"
local EMERGENCY_LATCH_TEMP = EMERGENCY_LATCH_PATH .. ".new"
local EMERGENCY_STOP_MODE = "BULK_OFF_PROBE_ON"

-- Diagnostic wall-clock stamps never participate in command authority.
local function diagnosticEpoch()
    if type(os.epoch)~="function" then return nil end
    local ok,value=pcall(os.epoch,"utc")
    if ok and type(value)=="number" and value==value and value>=0 and value<1e16 then return value end
end

-- Section: Chamber lift | Lease validation, physical readbacks and serialized provider writes.
-- Summary: Read the persisted emergency-stop marker and its validation result.
local function readEmergencyLatch()
    if type(fs) ~= "table" or type(fs.exists) ~= "function" or type(fs.open) ~= "function" then
        return false
    end
    for _, path in ipairs({ EMERGENCY_LATCH_PATH, EMERGENCY_LATCH_TEMP }) do
        local ok, exists = pcall(fs.exists, path)
        if not ok then return true, "could not read emergency-stop marker" end
        if exists then
            local opened, handle = pcall(fs.open, path, "r")
            if not opened or not handle then return true, "could not open emergency-stop marker" end
            local readOk, contents = pcall(handle.readAll)
            pcall(handle.close)
            if not readOk or type(contents) ~= "string" then return true, "could not read emergency-stop marker" end
            if contents == '{"schemaVersion":1,"emergencyStopLatched":true}' then return true end
            -- A present but malformed marker fails closed. Only an explicit
            -- fresh START SYSTEMS probe can remove the latch during this boot.
            return true, "emergency-stop marker is invalid"
        end
    end
    return false
end

-- Summary: Persist or clear the accepted emergency-stop marker.
local function writeEmergencyLatch(latched)
    if type(fs) ~= "table" or type(fs.exists) ~= "function" then
        return false, "filesystem unavailable"
    end
    local ok, reason = pcall(function()
        if latched then
            if fs.exists(EMERGENCY_LATCH_PATH) then return end
            if type(fs.makeDir) == "function" and not fs.exists("/avionics/data") then
                fs.makeDir("/avionics/data")
            end
            local handle = fs.open(EMERGENCY_LATCH_TEMP, "w")
            if not handle then error("could not open marker for writing") end
            handle.write('{"schemaVersion":1,"emergencyStopLatched":true}')
            handle.close()
            if type(fs.move) ~= "function" then error("atomic file move is unavailable") end
            if fs.exists(EMERGENCY_LATCH_PATH) then
                if type(fs.delete) == "function" then fs.delete(EMERGENCY_LATCH_TEMP) end
                return
            end
            fs.move(EMERGENCY_LATCH_TEMP, EMERGENCY_LATCH_PATH)
        else
            if type(fs.delete) ~= "function" then error("file delete is unavailable") end
            if fs.exists(EMERGENCY_LATCH_PATH) then fs.delete(EMERGENCY_LATCH_PATH) end
            if fs.exists(EMERGENCY_LATCH_TEMP) then fs.delete(EMERGENCY_LATCH_TEMP) end
        end
    end)
    if not ok then return false, tostring(reason):gsub("[%c]", " "):sub(1, 120) end
    return true
end

local function safeSystemRestartId(value)
    return type(value) == "string" and #value > 0 and #value <= 128 and
        value:match("^[A-Za-z0-9._:%-]+$") ~= nil
end

-- Summary: Resolve the role's installed trusted core ID.
local function installedCoreId(config)
    local install = type(config) == "table" and config.install
    local coreId = type(install) == "table" and install.coreID
    if type(install) ~= "table" or install.protocol ~= "amaryllis.install.v1" or
        not Hardware.isInteger(coreId) or coreId < 0 or coreId > 65535 or config.coreId ~= coreId or
        type(install.coreSession) ~= "string" or install.coreSession == "" then
        return nil
    end
    return coreId
end

local function copyTargets(targets)
    local result = {}
    for name, value in pairs(targets or {}) do result[name] = value end
    return result
end

-- Summary: Build the provider target map from validated physical readbacks.
local function readbackTargets(config, snapshot)
    local result = {}
    local providers = snapshot and snapshot.providers or {}
    for _, definition in ipairs(config.providers or {}) do
        local provider = providers[definition.name]
        if provider and provider.targetValid == true then
            result[definition.name] = provider.targetAmount
        end
    end
    return result
end

local function copyArray(values)
    local result = {}
    for _, value in ipairs(values or {}) do result[#result + 1] = value end
    return result
end

local function addFault(faults, code)
    if not code then return end
    for _, existing in ipairs(faults) do
        if existing == code then return end
    end
    faults[#faults + 1] = code
end

-- Summary: Generate the bounded boot identity for this role instance.
local function newBootId(computerId)
    -- This is an ordering token, not a password. It only needs to distinguish
    -- node restarts so the core can ignore delayed packets from an older boot.
    local epoch = math.floor(os.clock() * 1000)
    if os and type(os.epoch) == "function" then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then epoch = value end
    end
    local salt = math.random(1, 2147483647)
    return tostring(computerId) .. ":" .. tostring(epoch) .. ":" .. tostring(salt)
end

local function coreSessionKey(coreId, session)
    return tostring(coreId) .. ":" .. tostring(#session) .. ":" .. session
end

-- Retain the last 32 core sessions, matching the display consumers, so a
-- delayed hello cannot restore old command authority without growing forever.
-- Summary: Record an obsolete core session in the bounded replay-rejection history.
local function retireCoreSession(state, coreId, session)
    if type(session) ~= "string" or session == "" then return end
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

local function boundedEmergencyReason(reason)
    return tostring(reason or "VERIFICATION_PENDING"):gsub("[%c]", " "):sub(1, 160)
end

-- A persisted latch is re-verified locally against the current provider map.
-- The operation is fixed: bulk activation off, trim probe at five and fifteen.
-- Summary: A persisted latch is re-verified locally against the current provider map. The operation is fixed: bulk activation off, trim probe at five and fifteen.
local function queueEmergencyStopVerification(state, reason)
    if state.emergencyStopLatched ~= true or state.emergencyDisarmPending then return false end
    state.emergencyStopVerified = false
    state.emergencyStopAppliedSeq = nil
    if state.bindingFailed or state.configValid ~= true then return false end

    local pending = state.pendingCommand
    local matchingPending = pending and pending.emergencyStop == true and
        pending.nodeBoot == state.boot and pending.bindingGeneration == state.bindingGeneration
    if matchingPending then
        -- Preserve a positive sequence and session for a still-current core KILL
        -- packet. A rejected START must not erase its eventual ACK identity.
        if type(state.emergencyStopFault) ~= "string" then
            state.emergencyStopFault = boundedEmergencyReason(reason)
        end
    else
        state.emergencyStopFault = boundedEmergencyReason(reason)
        state.pendingCommand = {
            emergencyStop = true, resumed = true, seq = 0,
            session = state.session, sessionGeneration = state.sessionGeneration,
            bindingGeneration = state.bindingGeneration, quadrant = state.config.quadrant,
            nodeBoot = state.boot,
        }
    end
    if type(os) == "table" and type(os.queueEvent) == "function" then
        pcall(os.queueEvent, WRITE_EVENT)
    end
    return true
end

-- State is explicit so protocol decisions can be tested without a live ship.
-- Summary: Construct chamber lift state from validated configuration and local computer identity.
function Main.newState(config, actualComputerId, boot)
    local configValid, configErrors = Hardware.validateConfig(config, actualComputerId)
    local emergencyLatched, persistenceFault = readEmergencyLatch()
    local state = {
        config = config, sourceConfig = config,
        configValid = configValid,
        configErrors = configErrors,
        actualComputerId = actualComputerId,
        boot = boot or newBootId(actualComputerId or -1),
        bootReason = "COMPONENT_STARTUP",
        bindingGeneration = 0,
        phase = "STARTUP",
        session = nil,
        lastSessionAt = nil,
        sessionGeneration = 0,
        retiredCoreSessions = {},
        retiredCoreSessionOrder = {},
        statusSeq = 0,
        lastReceivedSeq = 0,
        lastAppliedSeq = 0,
        appliedTargets = {},
        lastCommandAt = nil,
        lastCommandFault = nil,
        lastApplyFault = nil,
        pendingCommand = nil,
        pendingSystemRestart = nil,
        pendingSystemRestartAck = nil,
        systemRestartRequestIds = {},
        systemRestartRequestCount = 0,
        systemRestartRetryAt = nil,
        systemsLease = nil,
        controlContext = nil,
        appliedControlContext = nil,
        lastControlContextSeq = 0,
        commandInProgress = nil,
        armed = false,
        publicArmed = false,
        emergencyStopLatched = emergencyLatched == true,
        emergencyStopVerified = false,
        emergencyStopAppliedSeq = nil,
        emergencyStopFault = emergencyLatched == true and "VERIFICATION_PENDING_STARTUP" or nil,
        emergencyStopPersistenceFault = persistenceFault,
        ready = false,
        modemReady = false,
        modemError = nil,
        providerSnapshot = { providers = {}, faults = { "PROVIDER_ALLOWLIST_EMPTY" }, ready = false },
        faults = {},
    }
    if state.emergencyStopLatched then
        state.pendingCommand = {
            emergencyStop = true, resumed = true, seq = 0, sessionGeneration = state.sessionGeneration,
            bindingGeneration = state.bindingGeneration, quadrant = config and config.quadrant,
            nodeBoot = state.boot,
        }
    end
    return state
end

local function contextIsActive(context)
    return type(context)=="table" and context.pidActive==true and context.inputsActive==true and
        Hardware.isFiniteNumber(context.selectedAltitude)
end

local function disarmControlContext(state)
    state.controlContext=nil
    state.appliedControlContext=nil
    state.publicArmed=false
end

-- Summary: Disarm local control ownership and clear its accepted sequence.
local function clearControlContext(state)
    disarmControlContext(state)
    state.lastControlContextSeq=0
    state.armed=false
end

-- Summary: Validate the selected-altitude/input lease from the current core session.
local function validateControlContext(state,context,now)
    if type(context)~="table" or not Hardware.isInteger(context.contextSeq) or
        context.contextSeq<1 or context.contextSeq>MAX_COMMAND_SEQUENCE or
        type(context.pidActive)~="boolean" or type(context.inputsActive)~="boolean" or
        not Hardware.isFiniteNumber(context.leaseSeconds) or context.leaseSeconds<=0 or
        context.leaseSeconds>CONTROL_CONTEXT_MAX_LEASE_SECONDS then
        return nil,"CONTROL_CONTEXT_FIELDS_INVALID"
    end
    local altitude=context.selectedAltitude
    if altitude~=nil and (not Hardware.isFiniteNumber(altitude) or math.abs(altitude)>4096) then
        return nil,"CONTROL_CONTEXT_ALTITUDE_INVALID"
    end
    if context.pidActive and context.inputsActive and altitude==nil then
        return nil,"CONTROL_CONTEXT_TARGET_REQUIRED"
    end
    return {contextSeq=context.contextSeq,selectedAltitude=altitude,pidActive=context.pidActive,
        inputsActive=context.inputsActive,session=state.session,nodeBoot=state.boot,
        expires=now+context.leaseSeconds}
end

-- Summary: Publish the control-activity state derived from current authority and observations.
local function refreshPublicArmed(state,now)
    if not state.armed then state.publicArmed=false;return false end
    local context,applied=state.controlContext,state.appliedControlContext
    local active=state.configValid==true and state.ready==true and contextIsActive(context) and
        context.session==state.session and context.nodeBoot==state.boot and
        Hardware.isFiniteNumber(context.expires) and now<context.expires
    local systemsLeaseCurrent=applied and applied.systems=="control" and state.systemsLease and
        state.systemsLease.stage=="control" and state.systemsLease.seq==applied.systemsSeq and
        state.systemsLease.session==state.session and state.systemsLease.nodeBoot==state.boot and
        Hardware.isFiniteNumber(state.systemsLease.expires) and now<state.systemsLease.expires
    local commandApplied=applied and applied.session==state.session and applied.nodeBoot==state.boot and
        context and applied.selectedAltitude==context.selectedAltitude and
        Hardware.isFiniteNumber(applied.at) and now>=applied.at and state.lastApplyFault==nil and
        (applied.systems~="control" or systemsLeaseCurrent)
    if not active then
        disarmControlContext(state)
    elseif not commandApplied then
        state.publicArmed=false
    else
        state.publicArmed=true
    end
    return state.publicArmed
end

-- Summary: Apply the accepted core altitude/input context to chamber status.
local function applyControlContext(state,command,now)
    local context=command.controlContext
    local live=state.controlContext
    local systemsLease=state.systemsLease
    local commandAgeLimit=command.systems=="control" and SYSTEMS_LEASE_SECONDS or state.config.commandTimeoutSeconds
    local systemsLeaseCurrent=command.systems~="control" or systemsLease and
        systemsLease.stage=="control" and systemsLease.seq==command.seq and
        systemsLease.session==state.session and systemsLease.nodeBoot==state.boot and
        Hardware.isFiniteNumber(systemsLease.expires) and now<systemsLease.expires
    if contextIsActive(context) and contextIsActive(live) and
        Hardware.isInteger(context.contextSeq) and context.contextSeq<=live.contextSeq and
        context.selectedAltitude==live.selectedAltitude and context.session==state.session and
        context.nodeBoot==state.boot and live.session==state.session and live.nodeBoot==state.boot and
        now>=command.receivedAt and now-command.receivedAt<=commandAgeLimit and systemsLeaseCurrent and
        now<live.expires and state.configValid==true and state.ready==true then
        state.appliedControlContext={session=state.session,nodeBoot=state.boot,
            contextSeq=context.contextSeq,selectedAltitude=context.selectedAltitude,at=now,
            systems=command.systems,systemsSeq=command.systems=="control" and command.seq or nil}
        state.publicArmed=true
        refreshPublicArmed(state,now)
    else
        disarmControlContext(state)
    end
end

-- Summary: Validate and receive the chamber control-context lease.
local function receiveControlContext(state,message,now)
    if message.quadrant~=state.config.quadrant or message.nodeBoot~=state.boot then
        return false,"CONTROL_CONTEXT_IDENTITY_MISMATCH",true
    end
    local context,reason=validateControlContext(state,message.context,now)
    if not context then return false,reason,true end
    if context.contextSeq<=state.lastControlContextSeq then return false,"STALE_CONTROL_CONTEXT",false end
    state.lastControlContextSeq=context.contextSeq
    state.controlContext=context
    if not contextIsActive(context) then
        disarmControlContext(state)
    else
        refreshPublicArmed(state,now)
    end
    return true,"CONTROL_CONTEXT_UPDATED",true
end

local managedReady, systemsStartReady

-- Summary: Validate and queue the current core systems-stage target request.
local function receiveSystems(state,message,now)
    if not state.configValid or not Hardware.systemsSupported(state.config) or
        message.nodeBoot~=state.boot or message.enable~=true then
        return false,"SYSTEMS_IDENTITY_OR_CAPABILITY_INVALID",true
    end
    if state.tuningLease then return false,"TUNING_IN_PROGRESS",true end
    local lease=state.systemsLease
    if lease and now>=lease.expires then
        state.systemsLease=nil
        if state.pendingCommand and state.pendingCommand.systems then state.pendingCommand=nil end
        state.armed=false
        lease=nil
    end
    if not lease and state.armed then return false,"LIFT_CONTROLLER_ALREADY_ARMED",true end
    if message.stage=="probe" then
        if lease and lease.stage=="control" then return false,"SYSTEMS_CONTROL_ALREADY_STARTED",true end
        if not systemsStartReady(state) then return false,"SYSTEMS_PROBE_HARDWARE_NOT_READY",true end
    elseif message.stage=="control" then
        if not lease or lease.probeCompleted~=true then
            return false,"SYSTEMS_PROBE_REQUIRED",true
        end
        if not managedReady(state) then return false,"SYSTEMS_CONTROL_HARDWARE_NOT_READY",true end
    else
        return false,"INVALID_SYSTEMS_STAGE",true
    end
    local ok,reason=Hardware.validateSystemsTargets(state.config,state.config.quadrant,
        message.targets,message.stage,state.providerSnapshot,lease and lease.stage or nil)
    if not ok then state.lastCommandFault=reason;return false,reason,true end
    local controlContext
    if message.controlContext~=nil then
        if message.nodeBoot~=state.boot then return false,"CONTROL_CONTEXT_BOOT_MISMATCH",true end
        controlContext,reason=validateControlContext(state,message.controlContext,now)
        if not controlContext then return false,reason,true end
        if controlContext.contextSeq>state.lastControlContextSeq then
            state.lastControlContextSeq=controlContext.contextSeq
            state.controlContext=controlContext
        end
    end

    local systemsLease=lease or {session=state.session,nodeBoot=state.boot,probeCompleted=false}
    systemsLease.stage=message.stage
    systemsLease.expires=now+SYSTEMS_LEASE_SECONDS
    systemsLease.seq=message.seq
    state.systemsLease=systemsLease
    state.lastCommandAt=now
    state.lastCommandFault=nil
    state.lastApplyFault=nil
    state.lastApplyDetail=nil
    state.pendingCommand={seq=message.seq,session=message.session,
        sessionGeneration=state.sessionGeneration,quadrant=message.quadrant,
        targets=copyTargets(message.targets),receivedAt=now,systems=message.stage,
        nodeBoot=state.boot,controlContext=controlContext}
    state.systemsCommandTiming={seq=message.seq,session=message.session,
        stage=message.stage,receivedEpochMs=diagnosticEpoch()}
    state.armed=false
    state.appliedControlContext=nil
    return true,"QUEUED",true
end

-- Summary: Validate a core lease release or confirmed probe-preserving shutdown.
local function receiveSystemsStop(state,message)
    if message.nodeBoot~=state.boot then return false,"SYSTEMS_BOOT_CHANGED",true end
    if message.zeroLift==true then
        if message.confirmation~="STOP SYSTEMS ZERO LIFT" then return false,"SHUTDOWN_NOT_CONFIRMED",true end
        state.systemsLease=nil;state.tuningLease=nil;state.pendingMaintenance=nil
        state.armed=false;state.shutdownComplete=false
        state.pendingCommand={shutdown=true,seq=message.seq,session=message.session,
            sessionGeneration=state.sessionGeneration,nodeBoot=state.boot}
        return true,"QUEUED",true
    end
    state.systemsLease=nil
    if state.pendingCommand and state.pendingCommand.systems then state.pendingCommand=nil end
    state.armed=false
    -- Cancellation retains the failure that caused core to stop. A later
    -- accepted command clears it, so diagnostics survive timeout cleanup.
    return true,"SYSTEMS_STOPPED_RETAINING_TARGETS",true
end

-- Readiness to set known ceilings before activation, distinct from active
-- flight readiness. Off vents may start without invented balloon attachment.
-- Summary: Evaluate the configured activation and local startup prerequisites.
managedReady = function(state)
    local snapshot = state.providerSnapshot or {}
    if not state.configValid or not state.modemReady or not snapshot.altitude or
        not snapshot.altitude.valid or not snapshot.activation or not snapshot.activation.valid then return false end
    for _, definition in ipairs(state.config.providers or {}) do
        local p = snapshot.providers[definition.name]
        if not p or not p.present or not p.writable or not p.targetValid or
            not p.signalValid then return false end
        if p.signalStrength>1 and
            (not p.gasOutputValid or not p.attachedValid) then return false end
    end
    return #(state.config.providers or {}) > 0
end

-- Probe readiness deliberately does not depend on balloon getters or an
-- active trim signal. START SYSTEMS must be able to turn that probe on first.
-- Summary: Check current provider and envelope observations for systems-stage startup.
systemsStartReady = function(state,snapshot)
    snapshot=snapshot or state.providerSnapshot or {}
    if state.emergencyStopLatched == true and state.emergencyStopVerified ~= true then return false end
    if not state.configValid or not state.modemReady or
        not Hardware.systemsSupported(state.config) or
        not snapshot.altitude or snapshot.altitude.valid~=true or
        not snapshot.activation or snapshot.activation.valid~=true then return false end
    local count=0
    for _,definition in ipairs(state.config.providers or {}) do
        count=count+1
        local p=snapshot.providers and snapshot.providers[definition.name]
        if not p or p.present~=true or p.writable~=true or
            p.targetValid~=true or p.signalValid~=true then return false end
    end
    -- One bulk vent per discovered steam vent plus the single fine probe.
    return count>0 and count==Hardware.steamCount(state.config)+1
end

-- Summary: Describe the failed provider observation or activity requirement.
local function providerActivityFault(provider, name, suffix)
    if not provider or provider.activeSupported ~= true then return nil end
    suffix = suffix or ""
    local safelyParkedFine=provider.controlRole=="fine" and provider.signalValid==true and
        provider.signalStrength==0 and provider.targetValid==true and
        (provider.targetAmount==0 or provider.targetAmount>=(provider.minimumNonzeroTarget or 1)) and
        (provider.maxTarget==nil or provider.targetAmount<=provider.maxTarget)
    if safelyParkedFine and provider.activeValid==true and provider.active==false then return nil end
    if provider.activeValid ~= true then return "PROVIDER_ACTIVITY_UNKNOWN" .. suffix .. ":" .. name end
    if provider.active ~= true then return "PROVIDER_INACTIVE" .. suffix .. ":" .. name end
    return nil
end

-- Summary: Validate and queue a command under the current bounded tuning lease.
local function receiveTuning(state,message,now)
 if not state.configValid or state.config.tuningEnabled~=true or message.nodeBoot~=state.boot or
  type(message.id)~="string" or #message.id==0 or #message.id>128 then return false,"TUNING_IDENTITY_INVALID",true end
 if message.kind=="lift_tuning_stop" then
  if not state.tuningLease or state.tuningLease.id~=message.id then return false,"TUNING_LEASE_MISMATCH",true end
  state.tuningLease=nil;state.pendingCommand=nil;state.armed=false
  return true,"TUNING_STOPPED",true
 end
 local lease=state.tuningLease
 if lease and now>=lease.expires then state.tuningLease=nil;state.pendingCommand=nil;state.armed=false;lease=nil end
 if message.first==true then
  if lease or state.armed or not state.providerSnapshot.altitude or not state.providerSnapshot.altitude.valid then return false,"TUNING_ALREADY_ACTIVE_OR_ALTITUDE_INVALID",true end
  local ok,reason=Hardware.validateTuning(state.config,message.targets,message.baseline,state.providerSnapshot,true)
  if not ok then return false,reason,true end
  lease={id=message.id,baseline=copyTargets(message.baseline),expires=now+60,
   y=state.providerSnapshot.altitude.sensorWorldY,boot=state.boot}
 elseif not lease or lease.id~=message.id or now>=lease.expires then return false,"TUNING_LEASE_EXPIRED",true end
 local ok,reason=Hardware.validateTuning(state.config,message.targets,lease.baseline,state.providerSnapshot,message.first==true)
 if not ok then return false,reason,true end
 state.tuningLease=lease
 state.pendingCommand={seq=message.seq,session=message.session,sessionGeneration=state.sessionGeneration,
  quadrant=message.quadrant,targets=copyTargets(message.targets),receivedAt=now,tuning=message.id,nodeBoot=state.boot}
 state.armed=false;state.appliedControlContext=nil
 return true,"QUEUED",true
end

-- Summary: Stage a correlated rejection for the current restart request.
local function queueSystemRestartError(state, message, reason)
    if not safeSystemRestartId(message.requestId) or not safeSystemRestartId(message.bootToken) then return false end
    local reply = {
        session = message.session,
        requestId = message.requestId,
        targetLabel = safeSystemRestartId(message.targetLabel) and message.targetLabel or state.config.label,
        nodeBoot = type(message.nodeBoot) == "string" and #message.nodeBoot <= 128 and message.nodeBoot or state.boot,
        bootToken = message.bootToken,
        currentNodeBoot = state.boot,
        accepted = false,
        zeroVerified = nil,
        detail = tostring(reason):gsub("[%c]", " "):sub(1, 160),
    }
    state.pendingSystemRestartAck = reply
    state.systemRestartRetryAt = nil
    return true
end

-- Summary: Validate the role's requested reboot against its current core session and boot.
local function receiveSystemRestart(state, sender, message, now)
    -- A response is safe only for a packet from the configured core in its
    -- currently established session. The request's boot and target are then
    -- checked independently, so stale or misrouted requests get a negative ACK.
    local coreId = installedCoreId(state.config)
    if coreId == nil or sender ~= coreId or
        type(state.session) ~= "string" or message.session ~= state.session then
        return false, "UNTRUSTED_SYSTEM_RESTART", false
    end
    if not safeSystemRestartId(message.requestId) or not safeSystemRestartId(message.bootToken) then
        return false, "INVALID_RESTART_CORRELATION_ID", false
    end
    if state.systemRestartRequestIds[message.requestId] then
        if state.pendingSystemRestart and state.pendingSystemRestart.requestId == message.requestId then
            return false, "RESTART_REQUEST_ALREADY_PENDING", false
        end
        queueSystemRestartError(state, message, "RESTART_REQUEST_REPLAY")
        return false, "RESTART_REQUEST_REPLAY", true
    end
    if state.systemRestartRequestCount >= SYSTEM_RESTART_MAX_REQUESTS then
        queueSystemRestartError(state, message, "RESTART_REQUEST_LIMIT_REACHED")
        return false, "RESTART_REQUEST_LIMIT_REACHED", true
    end
    state.systemRestartRequestIds[message.requestId] = true
    state.systemRestartRequestCount = state.systemRestartRequestCount + 1

    local reason
    if message.v ~= 1 then reason = "INVALID_RESTART_VERSION"
    elseif message.targetLabel ~= state.config.label then reason = "RESTART_TARGET_MISMATCH"
    elseif message.nodeBoot ~= state.boot then reason = "RESTART_BOOT_MISMATCH"
    elseif type(state.lastSessionAt) ~= "number" or now < state.lastSessionAt or
        now - state.lastSessionAt > SYSTEM_RESTART_MAX_AGE then reason = "CORE_SESSION_STALE"
    elseif state.pendingSystemRestart then reason = "RESTART_ALREADY_PENDING"
    end
    if reason then
        queueSystemRestartError(state, message, reason)
        return false, reason, true
    end

    -- A new writer generation revokes any multi-provider operation as soon as
    -- its current peripheral call returns. The queued restart then outranks all
    -- flight, tuning, systems, and maintenance work while retaining targets.
    state.sessionGeneration = state.sessionGeneration + 1
    state.pendingCommand = nil
    state.pendingMaintenance = nil
    state.systemsLease = nil
    state.tuningLease = nil
    state.armed = false
    state.pendingSystemRestart = {
        session = state.session,
        sessionGeneration = state.sessionGeneration,
        requestId = message.requestId,
        targetLabel = message.targetLabel,
        nodeBoot = message.nodeBoot,
        bootToken = message.bootToken,
        receivedAt = now,
    }
    state.pendingSystemRestartAck = nil
    state.systemRestartRetryAt = nil
    return true, "SYSTEM_RESTART_QUEUED", true
end

-- Summary: Latch and queue the authenticated emergency-stop request.
local function receiveEmergencyStop(state, message, now)
    if message.nodeBoot ~= state.boot then return false, "EMERGENCY_STOP_BOOT_MISMATCH", true end
    if message.emergencyStopMode ~= EMERGENCY_STOP_MODE then
        return false, "EMERGENCY_STOP_MODE_MISMATCH", true
    end
    if message.confirmation ~= "KILL LIFT BULK OFF PROBE ON" then
        return false, "EMERGENCY_STOP_NOT_CONFIRMED", true
    end
    -- This fixed operation has no caller-selected targets or peripheral names.
    -- It outranks pending work and remains valid if the core starts a new hello
    -- while the sole writer is completing the bulk-off/probe readback sequence.
    state.sessionGeneration = state.sessionGeneration + 1
    state.pendingCommand = nil
    state.pendingMaintenance = nil
    state.pendingSystemRestart = nil
    state.pendingSystemRestartAck = nil
    state.systemRestartRetryAt = nil
    state.systemsLease = nil
    state.tuningLease = nil
    state.armed = false
    state.shutdownComplete = false
    state.emergencyDisarmAppliedSeq = nil
    state.emergencyDisarmPending = false
    state.emergencyStopLatched = true
    state.emergencyStopVerified = false
    state.emergencyStopAppliedSeq = nil
    state.emergencyStopFault = "VERIFICATION_QUEUED"
    local persisted, persistenceError = writeEmergencyLatch(true)
    state.emergencyStopPersistenceFault = persisted and nil or persistenceError
    state.lastCommandAt = now
    state.lastCommandFault = nil
    state.lastApplyFault = nil
    state.lastApplyDetail = nil
    state.pendingCommand = {
        emergencyStop = true,
        seq = message.seq,
        session = message.session,
        sessionGeneration = state.sessionGeneration,
        quadrant = message.quadrant,
        nodeBoot = state.boot,
        bindingGeneration = state.bindingGeneration,
        receivedAt = now,
    }
    return true, "QUEUED", true
end

-- Handles one already protocol-filtered rednet_message. It only updates local
-- state and can queue one writer event. The caller sends a status separately.
-- Summary: Handles one already protocol-filtered rednet_message. It only updates local state and can queue one writer event. The caller sends a status separately.
function Main.receiveMessage(state, sender, message, now)
    local config = state.config
    local coreId = installedCoreId(config)
    if coreId == nil or sender ~= coreId then
        return false, "UNTRUSTED_SENDER", false
    end
    if type(message) ~= "table" or type(message.kind) ~= "string" or
        (message.kind ~= "system_restart" and message.v ~= 1) then
        return false, "INVALID_PACKET", true
    end
    if message.kind == "hello" then
        local newSession = message.session
        if type(newSession) ~= "string" or newSession == "" or #newSession > MAX_SESSION_LENGTH then
            return false, "INVALID_SESSION", true
        end
        if state.session ~= newSession then
            local key = coreSessionKey(sender, newSession)
            if state.retiredCoreSessions and state.retiredCoreSessions[key] then
                return false, "RETIRED_SESSION", false
            end
            retireCoreSession(state, sender, state.session)
            -- A new session removes command authority and cancels any unfinished
            -- multi-provider update. The writer sees the changed generation
            -- immediately after its current peripheral call returns.
            state.session = newSession
            state.sessionGeneration = state.sessionGeneration + 1
            state.lastReceivedSeq = 0
            state.lastAppliedSeq = 0
            state.shutdownAppliedSeq=nil
            state.emergencyStopAppliedSeq=nil
            state.emergencyDisarmAppliedSeq=nil;state.emergencyDisarmPending=false
            state.appliedTargets = {}
            state.lastCommandAt = nil
            local emergencyPending = state.pendingCommand and state.pendingCommand.emergencyStop and state.pendingCommand or nil
            if emergencyPending then
                emergencyPending.resumed = true
                emergencyPending.seq = 0
                emergencyPending.session = newSession
                emergencyPending.sessionGeneration = state.sessionGeneration
            end
            state.pendingCommand = emergencyPending
            state.pendingMaintenance = nil
            state.pendingSystemRestart = nil
            state.pendingSystemRestartAck = nil
            state.systemRestartRetryAt = nil
            state.tuningLease=nil
            state.systemsLease=nil
            clearControlContext(state)
            state.lastCommandFault = nil
            state.lastApplyFault = nil
            state.lastApplyDetail = nil
        end
        state.lastSessionAt = now
        -- A duplicate hello for the same session only prompts a fresh status.
        -- It must not reset command counters or cancel an in-flight write.
        return true, "HELLO", true
    end

    if message.kind == "system_restart" then
        if state.emergencyStopLatched then return false, "EMERGENCY_STOP_LATCHED", false end
        return receiveSystemRestart(state, sender, message, now)
    end
    if state.pendingSystemRestart and message.kind ~= "lift_emergency_stop" and message.kind ~= "lift_emergency_disarm" then
        return false, "SYSTEM_RESTART_PENDING", true
    end

    if message.kind ~= "lift_command" and message.kind ~= "lift_maintenance" and
        message.kind~="lift_tuning" and message.kind~="lift_tuning_stop" and
        message.kind~="lift_systems" and message.kind~="lift_systems_stop" and
        message.kind~="lift_emergency_stop" and message.kind~="lift_emergency_disarm" and message.kind~="lift_control_context" then
        return false, "UNKNOWN_MESSAGE_KIND", false
    end
    if state.session == nil or type(message.session) ~= "string" or message.session ~= state.session then
        return false, "SESSION_MISMATCH", true
    end
    refreshPublicArmed(state,now)
    if message.kind=="lift_control_context" then
        if state.emergencyStopLatched then return false,"EMERGENCY_STOP_LATCHED",false end
        return receiveControlContext(state,message,now)
    end
    if not Hardware.isInteger(message.seq) or message.seq < 1 or message.seq > MAX_COMMAND_SEQUENCE then
        return false, "INVALID_SEQUENCE", true
    end
    if message.seq <= state.lastReceivedSeq then
        return false, "STALE_SEQUENCE", true
    end

    -- Consume a new sequence even when its payload is rejected. The core must
    -- send a newer sequence after correcting any command problem.
    state.lastReceivedSeq = message.seq
    if message.quadrant ~= config.quadrant then
        state.lastCommandFault = "WRONG_QUADRANT"
        return false, state.lastCommandFault, true
    end
    if message.kind == "lift_emergency_stop" then
        return receiveEmergencyStop(state, message, now)
    end
    if message.kind == "lift_emergency_disarm" then
        if message.nodeBoot ~= state.boot then return false,"EMERGENCY_DISARM_BOOT_MISMATCH",true end
        if message.confirmation ~= "DISARM LIFT KILL" then return false,"EMERGENCY_DISARM_NOT_CONFIRMED",true end
        -- Revoke pending writers before clearing the durable latch in the sole writer.
        state.sessionGeneration=state.sessionGeneration+1
        state.pendingMaintenance=nil;state.pendingSystemRestart=nil;state.pendingSystemRestartAck=nil
        state.systemsLease=nil;state.tuningLease=nil;disarmControlContext(state)
        state.emergencyDisarmPending=true;state.emergencyDisarmAppliedSeq=nil
        state.pendingCommand={emergencyDisarm=true,seq=message.seq,session=message.session,
            sessionGeneration=state.sessionGeneration,nodeBoot=state.boot,receivedAt=now}
        return true,"QUEUED",true
    end
    if state.emergencyStopLatched then return false,"EMERGENCY_STOP_LATCHED; DISARM KILL FIRST",true end
    if state.systemsLease and now>=state.systemsLease.expires then
        state.systemsLease=nil
        if state.pendingCommand and state.pendingCommand.systems then state.pendingCommand=nil end
        state.armed=false
        state.lastApplyFault="SYSTEMS_LEASE_EXPIRED_RETAINING_TARGETS"
    end
    if message.kind=="lift_systems" then return receiveSystems(state,message,now) end
    if message.kind=="lift_systems_stop" then return receiveSystemsStop(state,message) end
    if state.systemsLease then return false,"SYSTEMS_IN_PROGRESS",true end
    if message.kind=="lift_tuning" or message.kind=="lift_tuning_stop" then return receiveTuning(state,message,now) end
    if state.tuningLease then return false,"TUNING_IN_PROGRESS",true end
    if message.kind=="lift_maintenance" then
        if config.maintenanceEnabled~=true or not state.configValid then return false,"MAINTENANCE_DISABLED / CONFIG_INVALID",true end
        if message.nodeBoot~=state.boot then return false,"MAINTENANCE_BOOT_CHANGED",true end
        if message.operation~="restart" and message.operation~="recheck" and message.operation~="probe_cycle" then return false,"INVALID_MAINTENANCE_OPERATION",true end
        if message.operation=="restart" and message.confirmation~="RESTART LIFT CONTROLLER" then return false,"RESTART_NOT_CONFIRMED",true end
        state.pendingMaintenance={seq=message.seq,session=message.session,nodeBoot=message.nodeBoot,
            sessionGeneration=state.sessionGeneration,operation=message.operation,receivedAt=now}
        if message.operation=="restart" then
            state.pendingCommand=nil;state.systemsLease=nil;state.armed=false
        end
        return true,"QUEUED",true
    end
    if message.enable ~= true then
        state.lastCommandFault = "ENABLE_MUST_BE_TRUE"
        return false, state.lastCommandFault, true
    end
    local validTargets, targetError = Hardware.validateTargets(config, message.quadrant, message.targets)
    if not validTargets then
        state.lastCommandFault = targetError
        return false, targetError, true
    end
    if not state.configValid then
        state.lastCommandFault = "CONFIG_INVALID"
        return false, state.lastCommandFault, true
    end
    local controlContext
    if message.controlContext~=nil then
        if message.nodeBoot~=state.boot then return false,"CONTROL_CONTEXT_BOOT_MISMATCH",true end
        controlContext,targetError=validateControlContext(state,message.controlContext,now)
        if not controlContext then return false,targetError,true end
        if controlContext.contextSeq>state.lastControlContextSeq then
            state.lastControlContextSeq=controlContext.contextSeq
            state.controlContext=controlContext
        end
    end
    if message.startup==true then
        if message.nodeBoot~=state.boot then return false,"VENT_STARTUP_BOOT_CHANGED",true end
        local allowed,reason=Hardware.validateVentStartup(config,message.targets,state.providerSnapshot)
        if not allowed then state.lastCommandFault=reason;return false,reason,true end
        if state.armed then return false,"VENT_STARTUP_WHILE_ARMED",true end
    end
    if config.activationBridge then
        for _, definition in ipairs(config.providers) do
            if definition.controlRole == "fine" and message.targets[definition.name] > 0 then
                local trim = state.providerSnapshot.trimActivation or {valid=false,reason="TRIM_ACTIVATION_NOT_READY"}
                if not trim.valid then
                    state.lastCommandFault = trim.reason
                    return false, trim.reason, true
                end
            end
        end
        if not managedReady(state) then
            state.lastCommandFault = "LOCAL_START_CHECKS_NOT_READY"
            return false, state.lastCommandFault, true
        end
    else
    -- Where this peripheral exposes isActive(), require a fresh, valid true
    -- result. Older versions without the optional method remain supported.
    for _, definition in ipairs(config.providers) do
        local provider = state.providerSnapshot.providers[definition.name]
        local activityFault = provider and providerActivityFault(provider, definition.name)
        if activityFault then
            state.lastCommandFault = activityFault
            return false, activityFault, true
        end
    end
    if state.ready ~= true then
        state.lastCommandFault = "NODE_NOT_READY"
        return false, state.lastCommandFault, true
    end

    for _, definition in ipairs(config.providers) do
        local provider = state.providerSnapshot.providers[definition.name]
        if not provider or provider.present ~= true or provider.writable ~= true or
            provider.targetValid ~= true or provider.signalValid ~= true or
            provider.gasOutputValid ~= true or provider.attachedValid ~= true or
            provider.attached ~= true then
            state.lastCommandFault = "PROVIDER_NOT_READY"
            return false, state.lastCommandFault, true
        end
        if provider.signalStrength ~= 15 then
            state.lastCommandFault = "ACTIVATION_SIGNAL_NOT_15"
            return false, state.lastCommandFault, true
        end
    end

    end

    state.lastCommandAt = now
    state.lastCommandFault = nil
    state.lastApplyFault = nil
    state.lastApplyDetail = nil
    state.pendingCommand = {
        seq = message.seq,
        session = message.session,
        sessionGeneration = state.sessionGeneration,
        quadrant = message.quadrant,
        targets = copyTargets(message.targets),
        startup=message.startup==true,nodeBoot=message.nodeBoot,
        controlContext=controlContext,
        receivedAt = now,
    }
    state.armed=false
    state.appliedControlContext=nil
    return true, "QUEUED", true
end

-- Summary: Append provider observation and interface faults to chamber status.
local function addProviderFaults(faults, snapshot, suppressedProviders)
    for _, fault in ipairs(snapshot.faults or {}) do
        local raw=type(fault)=="string" and fault:find("^PROVIDER_UNREADY:")~=nil
        local providerName=type(fault)=="string" and
            (fault:match("^PROVIDER_UNREADY:(.-) | ") or fault:match("^PROVIDER_UNREADY:(.+)$") or
             fault:match("^VENT (%S+) ") or fault:match("^PROBE (%S+) "))
        if not providerName or not (suppressedProviders and suppressedProviders[providerName]) then
            local provider=providerName and snapshot.providers and snapshot.providers[providerName]
            -- Raw interface faults carry the provider detail; VENT/PROBE faults are complete as worded.
            addFault(faults,raw and provider and type(provider.error)=="string" and not fault:find(" | ",1,true) and
                (fault.." | "..provider.error) or fault)
        end
    end
end

local function bindingLabel(config)
    local install = type(config) == "table" and config.install
    local role = type(install) == "table" and install.role or config and config.role
    local short = type(role) == "string" and role:match("^chamber_(%w+)$")
    return string.upper(short or tostring(config and config.quadrant or "LIFT"))
end

-- Summary: Format the current event time for component logs.
local function logTimestamp()
    if type(os) == "table" and type(os.epoch) == "function" then
        local ok, value = pcall(os.epoch, "utc")
        if ok and type(value) == "number" then return tostring(math.floor(value)) .. "utc-ms" end
    end
    if type(os) == "table" and type(os.clock) == "function" then
        local ok, value = pcall(os.clock)
        if ok and type(value) == "number" then return tostring(math.floor(value * 1000)) .. "uptime-ms" end
    end
    return "unavailable"
end

local function boundedLogField(value, maxLength)
    local text = tostring(value == nil and "-" or value):gsub("[%c%s]+", "_")
    if #text > maxLength then return text:sub(1, maxLength - 3) .. "..." end
    return text
end

-- Summary: Write a bounded chamber component event with its scope.
local function emitNodeLog(message, key)
    local logger = type(os) == "table" and os.__amaryllisLog or nil
    if type(logger) == "function" then
        local ok, recorded = pcall(logger, message, key)
        if ok and recorded == true then return true end
        print(message)
        return false
    end
    print(message .. " at=" .. logTimestamp())
    return false
end

local function roleAndNetwork(config)
    local install = type(config) == "table" and config.install
    local role = type(install) == "table" and install.role or config and config.role
    local discovery = type(config) == "table" and config.providerDiscovery
    local network = type(discovery) == "table" and discovery.networkSide or nil
    return role, network
end

local function validBindingFingerprint(value)
    return type(value) == "string" and #value > 0 and
        #value <= MAX_BINDING_FINGERPRINT_LENGTH and value:find("[%c]") == nil
end

-- Summary: Record the role component's startup identity and program state.
local function reportComponentStartup(state)
    local role, network = roleAndNetwork(state.sourceConfig)
    emitNodeLog("LIFT_COMPONENT_STARTUP" ..
        " role=" .. boundedLogField(role, 32) ..
        " network=" .. boundedLogField(network, 32) ..
        " computer=" .. boundedLogField(state.actualComputerId, 16) ..
        " boot=" .. boundedLogField(state.boot, 80) ..
        " bindingGeneration=" .. tostring(state.bindingGeneration or 0), "lift.component.startup")
end

-- Summary: Record the changed hardware-binding identity and observation context.
local function reportBindingIdentityChange(state, cause, oldFingerprint, oldBoot, oldGeneration)
    local role, network = roleAndNetwork(state.sourceConfig)
    emitNodeLog("LIFT_BINDING_IDENTITY" ..
        " cause=" .. boundedLogField(cause, 32) ..
        " role=" .. boundedLogField(role, 32) ..
        " network=" .. boundedLogField(network, 32) ..
        " generation=" .. tostring(oldGeneration or 0) .. "->" .. tostring(state.bindingGeneration or 0) ..
        " binding=" .. boundedLogField(oldFingerprint, 64) .. "->" ..
            boundedLogField(state.bindingFingerprint, 64) ..
        " boot=" .. boundedLogField(oldBoot, 56) .. "->" .. boundedLogField(state.boot, 56),
        "lift.binding.identity")
end

-- Summary: Record the current hardware-binding failure reason.
local function reportBindingFault(state, reason)
    if state.reportedBindingError == reason then return end
    state.reportedBindingError = reason
    local label = bindingLabel(state.sourceConfig)
    print(label .. " CONFIG_INVALID")

    local vents, trim, bridges, altitude = tostring(reason):match(
        "^DISCOVERY_COUNTS: vents=(%d+) trim=(%d+) bridges=(%d+) altitude=(%d+)$")
    if vents then
        local counts = {
            { "vents", tonumber(vents), 8 },
            { "trim", tonumber(trim), 1 },
            { "bridges", tonumber(bridges), 1 },
            { "altitude", tonumber(altitude), 1 },
        }
        for _, item in ipairs(counts) do
            print(label .. " DISCOVERY_COUNTS " .. item[1] .. "=" .. item[2] .. " expected=" .. item[3])
        end
        return
    end
    print(label .. " " .. tostring(reason):gsub("[%c]", " "):sub(1, 512))
end

local function reportBindingRecovery(state)
    if state.reportedBindingError == nil then return end
    state.reportedBindingError = nil
    print(bindingLabel(state.sourceConfig) .. " CONFIG_RECOVERED discovery valid")
end

local function currentSystemsHandover(state)
    local seq=state.systemsHandoverPendingSeq
    local lease=state.systemsLease
    return seq~=nil and state.commandInProgress==seq and lease~=nil and
        lease.seq==seq and lease.stage=="control"
end

-- Summary: Rediscover role hardware and update its binding identity and availability.
local function refreshBindings(state, peripheralApi)
    if not state.sourceConfig.providerDiscovery then return end
    local resolved,reason,fingerprint=Hardware.resolveConfig(state.sourceConfig,peripheralApi)
    if not resolved then
        if not state.bindingFailed then
            state.sessionGeneration=state.sessionGeneration+1
            state.bindingGeneration=(state.bindingGeneration or 0)+1
            state.pendingCommand=nil; state.armed=false
        end
        state.bindingFailed=true; state.configValid=false; state.configErrors={reason}
        state.bindingError=reason
        if state.emergencyStopLatched == true then
            state.emergencyStopVerified=false
            state.emergencyStopAppliedSeq=nil
            state.emergencyStopFault=boundedEmergencyReason("VERIFICATION_PENDING_BINDING: " .. tostring(reason))
        end
        reportBindingFault(state, reason)
        return
    end
    local changed = state.bindingFingerprint~=fingerprint or state.bindingFailed
    local wasBindingFailed = state.bindingFailed == true
    if changed then
        local oldFingerprint, oldBoot, oldGeneration =
            state.bindingFingerprint, state.boot, state.bindingGeneration or 0
        local identityCause = wasBindingFailed and "BINDING_RECOVERY" or
            (state.bindingFingerprint == nil and "INITIAL_DISCOVERY" or "FINGERPRINT_CHANGED")
        -- An assembly/rebind is a new hardware generation. In-flight work must
        -- not continue against renamed devices, even if a name gets reused.
        state.sessionGeneration=state.sessionGeneration+1
        state.emergencyDisarmAppliedSeq=nil;state.emergencyDisarmPending=false
        state.bindingGeneration=(state.bindingGeneration or 0)+1
        state.pendingCommand=nil; state.commandInProgress=nil; state.systemsLease=nil; clearControlContext(state)
        state.systemsHandoverPendingSeq=nil; state.systemsHandoverReason=nil
        state.boot=newBootId(state.actualComputerId); state.statusSeq=0
        state.lastReceivedSeq=0; state.lastAppliedSeq=0; state.appliedTargets={}
        state.shutdownAppliedSeq=nil
        state.lastCommandAt=nil
        state.config=resolved
        state.bootReason = identityCause
        state.bindingFingerprint = fingerprint
        if state.emergencyStopLatched == true then
            state.emergencyStopVerified=false
            state.emergencyStopAppliedSeq=nil
        end
        reportBindingIdentityChange(state, identityCause, oldFingerprint, oldBoot, oldGeneration)
    end
    state.bindingFingerprint=fingerprint
    state.bindingFailed=false; state.bindingError=nil; state.configValid=true; state.configErrors={}
    reportBindingRecovery(state)
    if changed and state.emergencyStopLatched == true then
        local reasonCode = wasBindingFailed and "VERIFICATION_PENDING_AFTER_BINDING_RECOVERY" or
            (state.bindingFingerprint == fingerprint and state.bindingGeneration == 1 and
                "VERIFICATION_PENDING_AFTER_DISCOVERY" or "VERIFICATION_PENDING_AFTER_REBIND")
        queueEmergencyStopVerification(state, reasonCode)
    end
end

-- Summary: Sample the configured chamber hardware and update cached observations.
local function refreshSnapshot(state, peripheralApi, now)
    local runtime=os.__amaryllisRuntime or {};os.__amaryllisRuntime=runtime
    runtime.sampling=runtime.sampling or {}
    local progress=runtime.sampling.lift or {};runtime.sampling.lift=progress
    progress.phase="READING";progress.startedAt=os.clock();progress.stage="BINDINGS"
    if state.tuningLease and now>=state.tuningLease.expires then
        state.tuningLease=nil;state.pendingCommand=nil;state.armed=false
        state.lastApplyFault="TUNING_LEASE_EXPIRED"
    end
    if state.systemsLease and now>=state.systemsLease.expires then
        state.systemsLease=nil
        if state.pendingCommand and state.pendingCommand.systems then state.pendingCommand=nil end
        state.armed=false
        state.lastApplyFault="SYSTEMS_LEASE_EXPIRED_RETAINING_TARGETS"
    end
    refreshBindings(state,peripheralApi)
    progress.stage="PROVIDERS"
    local snapshot = Hardware.sampleConfigured(state.config, peripheralApi)
    -- Balloon and altitude reads are independent server-tick waits; share one window.
    progress.stage="BALLOON+ALTITUDE"
    local balloon,altitude
    local function readBalloon() balloon=Hardware.sampleBalloon(state.config, snapshot.providers, peripheralApi) end
    local function readAltitude() altitude=Hardware.sampleAltitude(state.config, peripheralApi, now) end
    if type(parallel)=="table" and type(parallel.waitForAll)=="function" then
        parallel.waitForAll(readBalloon,readAltitude)
    else readBalloon();readAltitude() end
    snapshot.balloon = balloon
    snapshot.altitude = altitude
    progress.stage="ACTIVATION"
    snapshot.activation = Hardware.sampleActivation(state.config, peripheralApi,nil,snapshot.providers)
    snapshot.trimActivation = Hardware.sampleActivation(state.config, peripheralApi, "fine",snapshot.providers)
    progress.phase="READY";progress.stage="COMPLETE";progress.completedAt=os.clock();progress.completedCount=(progress.completedCount or 0)+1
    state.providerSnapshot = snapshot
    -- Legacy fake/inspection configs without a sensor remain readable. Deployed
    -- nodes all have altitudeSensor configured and require a valid local sample.
    local altitudeReady = state.config.altitudeSensor == nil or snapshot.altitude.valid
    local bridgeReady = state.config.activationBridge == nil or snapshot.activation.valid
    state.localReady = state.configValid and snapshot.ready and altitudeReady and bridgeReady
    state.ready = state.localReady and state.modemReady
    refreshPublicArmed(state,now)

    local faults = {}
    if not state.configValid then addFault(faults, "CONFIG_INVALID") end
    if state.bindingError then addFault(faults,state.bindingError) end
    if not state.modemReady then addFault(faults, "WIRELESS_MODEM_UNAVAILABLE") end
    local suppressedProviders
    local handoverPending=currentSystemsHandover(state)
    if handoverPending then
        suppressedProviders={}
        for _,definition in ipairs(state.config.providers or {}) do
            local provider=snapshot.providers and snapshot.providers[definition.name]
            if definition.controlRole=="bulk" and provider and provider.present==true and
                provider.writable==true and provider.targetValid==true and provider.signalValid==true and
                provider.signalStrength==15 and provider.gasOutputValid==true and
                provider.attachedValid==true and provider.attached==false and
                (provider.activeSupported~=true or (provider.activeValid==true and provider.active==true)) then
                -- Hide only the generic no-balloon report while an explicitly
                -- commanded bulk link is settling. Missing methods, invalid
                -- getters, and bridge faults remain visible during the wait.
                suppressedProviders[definition.name]=true
            end
        end
    end
    addProviderFaults(faults, snapshot, suppressedProviders)
    if state.config.activationBridge and not snapshot.activation.valid then addFault(faults, snapshot.activation.reason) end
    if state.config.trimActivationFrequency and not snapshot.trimActivation.valid then addFault(faults,"TRIM_"..tostring(snapshot.trimActivation.reason or "ACTIVATION_UNKNOWN")) end
    if state.config.altitudeSensor and not snapshot.altitude.valid then
        addFault(faults, snapshot.altitude.reason)
    end
    for name, provider in pairs(snapshot.providers or {}) do
        -- Bulk-vent status faults come from signal-gated information checks
        -- in hardware.lua. Command/pre-write activity checks remain strict.
        if provider.controlRole~="bulk" and not (provider.controlRole=="fine" and provider.signalValid and provider.signalStrength==0 and provider.targetAmount==0) then addFault(faults, providerActivityFault(provider, name)) end
    end
    if state.lastCommandFault then addFault(faults, state.lastCommandFault) end
    if state.lastApplyFault then addFault(faults, state.lastApplyFault) end
    if state.emergencyStopPersistenceFault then addFault(faults, "EMERGENCY_STOP_PERSISTENCE_WARNING") end
    if state.emergencyStopLatched == true and state.emergencyStopVerified ~= true then
        addFault(faults, "EMERGENCY_STOP_UNVERIFIED: " .. boundedEmergencyReason(
            state.emergencyStopFault or "VERIFICATION_PENDING"))
    end

    local anySignalNot15 = false
    for _, provider in pairs(snapshot.providers or {}) do
        if provider.controlRole~="bulk" and provider.signalValid and provider.signalStrength>0 and provider.signalStrength ~= 15 then anySignalNot15 = true end
    end
    if anySignalNot15 then addFault(faults, "ACTIVATION_SIGNAL_NOT_15") end
    -- START SYSTEMS runs under a renewable lease. Core waits for every
    -- chamber's ACK before sending the next batch, so gaps between commands
    -- longer than commandTimeoutSeconds are normal there; only a lapsed lease
    -- is a real link loss. Plain commands keep the short timeout.
    local leaseCurrent = state.systemsLease and Hardware.isFiniteNumber(state.systemsLease.expires) and
        now < state.systemsLease.expires
    if state.armed and state.lastCommandAt and not leaseCurrent and
        now - state.lastCommandAt > state.config.commandTimeoutSeconds then
        addFault(faults, "COMMAND_LINK_TIMEOUT_HOLDING_LAST_TARGETS")
    end
    -- Commissioning gates are separate from read-only hardware readiness.
    -- A hello establishes identity, not flight authority. Timeout retains caps;
    -- coordinated PID fallback remains pending and must never be claimed here.
    local expired = not state.systemsLease and state.lastCommandAt and
        now - state.lastCommandAt > state.config.commandTimeoutSeconds
    if handoverPending then state.phase = "SYSTEMS CONTROL / WAITING FOR STEAM ENVELOPE"
    elseif not state.ready then state.phase = "DEGRADED"
    elseif state.systemsLease then state.phase = "SYSTEMS " .. string.upper(state.systemsLease.stage or "ACTIVE")
    elseif expired and state.armed then state.phase = "LINK LOST / RETAINING"
    elseif state.armed then state.phase = "CORE CONTROL"
    elseif state.session then state.phase = "READY / LINKED"
    else state.phase = "READY / NO UPLINK" end
    state.faults = faults
    return snapshot
end

-- Summary: Build the bounded chamber lift, thrust and authority status packet.
local function buildStatus(state, now, peripheralApi)
    local snapshot = refreshSnapshot(state, peripheralApi, now)
    state.statusSeq = state.statusSeq + 1
    local status = {
        v = 1,
        kind = "lift_status",
        session = state.session,
        boot = state.boot,
        bootReason = state.bootReason,
        bindingGeneration = state.bindingGeneration or 0,
        bindingFingerprintValid = state.bindingFailed ~= true and validBindingFingerprint(state.bindingFingerprint),
        statusSeq = state.statusSeq,
        id = state.actualComputerId,
        quadrant = state.config.quadrant,
        phase = state.phase,
        localReady = state.localReady == true,
        steamCount = Hardware.steamCount(state.config),
        startReady = managedReady(state),
        altitude = snapshot.altitude,
        activation = snapshot.activation,
        trimActivation = snapshot.trimActivation,
        ready = state.ready == true,
        armed = state.publicArmed == true,
        operationBusy=state.armed==true or state.commandInProgress~=nil or state.pendingCommand~=nil or
            state.pendingMaintenance~=nil or state.pendingSystemRestart~=nil or
            state.systemsLease~=nil or state.tuningLease~=nil,
        systemsSupported=state.configValid and Hardware.systemsSupported(state.config) or false,
        shutdownSupported=true,
        shutdownAppliedSeq=state.shutdownAppliedSeq,
        emergencyStopAppliedSeq=state.emergencyStopAppliedSeq,
        emergencyDisarmAppliedSeq=state.emergencyDisarmAppliedSeq,
        emergencyStopLatched=state.emergencyStopLatched==true,
        emergencyStopVerified=state.emergencyStopVerified==true,
        systemsStartReady=not state.emergencyStopLatched and systemsStartReady(state,snapshot),
        systemsStage=state.systemsLease and state.systemsLease.stage or nil,
        systemsProbeReady=state.systemsLease and state.systemsLease.probeCompleted==true or false,
        systemsHandoverPending=currentSystemsHandover(state),
        systemsHandoverReason=currentSystemsHandover(state) and state.systemsHandoverReason or nil,
        faults = copyArray(state.faults),
        providers = snapshot.providers or {},
        tuningSupported=state.config.tuningEnabled==true,
        lastReceivedSeq = state.lastReceivedSeq,
        lastAppliedSeq = state.lastAppliedSeq,
        appliedTargets = copyTargets(state.appliedTargets),
    }
    local thrust=(((os.__amaryllisRuntime or {}).components or {}).thrust or {})
    status.thrustControlState=thrust.controlState or "FAULT"
    local changing=state.commandInProgress~=nil or currentSystemsHandover(state)
    local command=state.pendingCommand
    if command then
        if command.emergencyStop or command.emergencyDisarm or command.shutdown then changing=true end
        for name,target in pairs(command.targets or {}) do
            local provider=(snapshot.providers or {})[name]
            if not provider or provider.targetValid~=true or provider.targetAmount~=target then changing=true end
        end
    end
    status.liftControlState=(#status.faults>0 or not state.configValid or state.bindingFailed) and "FAULT" or
        (changing and "CMD" or "RDY")
    if status.bindingFingerprintValid then status.bindingFingerprint = state.bindingFingerprint end
    local timing=state.systemsCommandTiming
    if timing and timing.session==state.session then
        status.systemsCommandTiming={seq=timing.seq,stage=timing.stage,
            receivedEpochMs=timing.receivedEpochMs,appliedEpochMs=timing.appliedEpochMs}
    end
    if snapshot.totalGasOutputValid then
        status.totalGasOutput = snapshot.totalGasOutput
        status.totalGasOutputUnit = "m3/tick"
    end
    if snapshot.balloon then status.balloon = snapshot.balloon end
    if state.emergencyStopLatched then status.emergencyStopMode = EMERGENCY_STOP_MODE end
    if state.commandInProgress then status.applyingSeq = state.commandInProgress end
    if state.lastApplyDetail then status.lastApplyDetail = state.lastApplyDetail end
    if state.emergencyStopFault then
        status.emergencyStopFault = tostring(state.emergencyStopFault):gsub("[%c]", " "):sub(1, 160)
    end
    if state.emergencyStopPersistenceFault then
        status.emergencyStopPersistenceFault = tostring(state.emergencyStopPersistenceFault):gsub("[%c]", " "):sub(1, 120)
    end
    -- Expose the existing sampled status to the local read-only diagnostic
    -- task. This does not sample providers again or alter command authority.
    if type(os) == "table" then
        local runtime=os.__amaryllisRuntime or {};runtime.components=runtime.components or {}
        runtime.components.lift={running=true,hardwareAvailable=state.localReady==true,faults=copyArray(status.faults or {}),snapshot=status,publishedAt=now}
        runtime.snapshot=status;runtime.publishedAt=now;os.__amaryllisRuntime=runtime
    end
    return status
end

-- Summary: Send the latest bounded role status to the current core.
local function sendStatus(state, rednetApi, peripheralApi, now)
    -- Publish locally even before any core contact; otherwise Status/Logs
    -- would stay empty throughout startup or a radio outage.
    local packet
    if type(parallel)=="table" and type(parallel.waitForAny)=="function" then
        -- Cancel only a read-only report attempt; leave old data visibly stale.
        local completed,issue=false,nil
        local deadline=os.clock()+5
        local timer=os.startTimer(5)
        parallel.waitForAny(function()
            local ok,value=pcall(buildStatus,state,now,peripheralApi)
            completed=true
            if ok then packet=value else issue=tostring(value) end
        end,function()
            while os.clock()<deadline do os.pullEventRaw() end
        end)
        pcall(os.cancelTimer,timer)
        if not completed or not packet then
            local rt=os.__amaryllisRuntime
            local progress=rt and rt.sampling and rt.sampling.lift
            if progress then
                progress.phase="RETRYING";progress.timeouts=(progress.timeouts or 0)+1
                progress.lastError=issue or "LIFT_STATUS_READ_TIMEOUT"
            end
            return false,issue or "LIFT_STATUS_READ_TIMEOUT"
        end
    else packet=buildStatus(state,now,peripheralApi) end
    if not state.session then return false end
    if type(rednetApi) ~= "table" or type(rednetApi.send) ~= "function" then
        return false, "rednet send is unavailable"
    end
    packet.statusSentEpochMs=diagnosticEpoch()
    local ok, result = pcall(rednetApi.send, state.config.coreId, packet, PROTOCOL)
    if not ok or result == false then return false, tostring(result) end
    return true
end

local function currentCommand(state, command)
    return state.session == command.session and
        state.sessionGeneration == command.sessionGeneration and
        state.lastReceivedSeq == command.seq and
        state.pendingSystemRestart == nil
end

local function applyOne(state, peripheralApi, name, target)
    -- Keep all direct peripheral setter access inside the hardware adapter.
    -- This point is reached only after complete command validation and a
    -- live pre-write safety check.
    return Hardware.applyTarget(peripheralApi, name, target)
end

-- Use the same single writer and expiry guards for demand-driven activation.
-- Ceilings are set first, preventing old settings from producing an initial surge.
-- Delayed attachment is reported as pending, never falsely acknowledged.
-- Summary: Validate live authority, apply provider targets and verify activation/readbacks.
local function applyManagedCommand(state, command, peripheralApi, rednetApi)
    local function validCommand()
        return currentCommand(state, command) and
            os.clock() - command.receivedAt <= (command.startup and
                (state.config.ventStartupTimeoutSeconds or 15) or state.config.commandTimeoutSeconds) and
            (not command.startup or
                (state.config.ventStartupEnabled==true and command.nodeBoot==state.boot))
    end
    local function fail(reason)
        state.commandInProgress = nil
        state.armed=false
        disarmControlContext(state)
        state.lastApplyFault = reason
        sendStatus(state, rednetApi, peripheralApi, os.clock())
    end
    if not validCommand() then fail("COMMAND_EXPIRED_OR_SUPERSEDED"); return end
    state.commandInProgress = command.seq
    -- A complete zero map would remove envelope telemetry before handover.
    -- Confirmed STOP uses the dedicated probe-preserving shutdown writer.
    local hasTrim,hasDemand=false,false
    for _,p in ipairs(state.config.providers) do
        hasTrim=hasTrim or p.controlRole=="fine"
        hasDemand=hasDemand or command.targets[p.name]>0
    end
    if hasTrim and not hasDemand then fail("AT_LEAST_ONE_ENVELOPE_PROVIDER_REQUIRED");return end
    refreshSnapshot(state, peripheralApi, os.clock())
    if command.startup then
        local allowed,reason=Hardware.validateVentStartup(state.config,command.targets,state.providerSnapshot)
        if not allowed then fail(reason);return end
    end
    if not managedReady(state) then fail("LOCAL_START_CHECKS_NOT_READY"); return end
    local nonzero = false
    local groups = {}
    -- Peripheral getters/setters each wait for a server tick. Every provider
    -- is still re-read before any write, but all providers' reads (and then
    -- all writes) are issued concurrently, so a 33-vent batch takes a few
    -- ticks instead of one tick per call per vent. The core's climb
    -- authority shrinks as this ACK time grows.
    -- Summary: Run the independent provider operations and collect their completions.
    local function runConcurrently(jobs)
        local wrapped={}
        for index,job in ipairs(jobs) do wrapped[index]=function() pcall(job) end end
        if #wrapped>1 and type(parallel)=="table" and type(parallel.waitForAll)=="function" then
            parallel.waitForAll(table.unpack(wrapped))
        else
            for _,job in ipairs(wrapped) do job() end
        end
    end
    if not validCommand() then fail("COMMAND_EXPIRED_OR_SUPERSEDED"); return end
    local sampled,sampleJobs={},{}
    for index, definition in ipairs(state.config.providers) do
        sampleJobs[index]=function()
            sampled[index]=Hardware.sampleConfigured({providers={definition}}, peripheralApi)
        end
    end
    runConcurrently(sampleJobs)
    for index, definition in ipairs(state.config.providers) do
        local checked=sampled[index]
        if not checked or not checked.providers or not checked.providers[definition.name] then
            fail("PROVIDER_SAMPLE_FAILED:"..definition.name);return
        end
        state.providerSnapshot.providers[definition.name] = checked.providers[definition.name]
    end
    if not validCommand() then fail("COMMAND_EXPIRED_OR_SUPERSEDED"); return end
    if not managedReady(state) then fail("LOCAL_START_CHECKS_NOT_READY"); return end
    local writes={}
    for _, definition in ipairs(state.config.providers) do
        local target = command.targets[definition.name]
        nonzero = nonzero or target > 0
        if target > 0 then groups[definition.controlRole == "fine" and "fine" or "bulk"] = true end
        local record = state.providerSnapshot.providers[definition.name]
        if command.startup and definition.controlRole=="fine" and record.targetAmount~=target then
            fail("TRIM_CHANGED_DURING_STARTUP");return
        end
        if command.startup and definition.controlRole=="bulk" and record.signalStrength>1 and record.targetAmount~=50 then
            fail("VENT_NOW_OPERATING");return
        end
        if record.targetAmount ~= target and not (definition.controlRole=="fine" and target==0 and not command.startup) then
            writes[#writes+1]={name=definition.name,target=target}
        end
    end
    if not validCommand() then fail("COMMAND_EXPIRED_OR_SUPERSEDED"); return end
    local results,writeJobs={},{}
    for index,write in ipairs(writes) do
        writeJobs[index]=function()
            results[index]={Hardware.applyTarget(peripheralApi, write.name, write.target)}
        end
    end
    runConcurrently(writeJobs)
    for index,write in ipairs(writes) do
        local result=results[index]
        if not result or not result[1] then
            state.lastApplyDetail = result and result[2] or "provider write did not complete"
            fail("PARTIAL_APPLY:" .. write.name); return
        end
    end
    state.providerSnapshot.altitude = Hardware.sampleAltitude(state.config, peripheralApi, os.clock())
    state.providerSnapshot.activation = Hardware.sampleActivation(state.config, peripheralApi)
    if not validCommand() then fail("COMMAND_EXPIRED_OR_SUPERSEDED"); return end
    if not managedReady(state) then fail("LOCAL_START_CHECKS_NOT_READY"); return end
    for _, group in ipairs({"bulk","fine"}) do
        if groups[group] and (not command.startup or group=="bulk") then
            if not validCommand() then fail("COMMAND_EXPIRED_OR_SUPERSEDED"); return end
            local ok, reason = Hardware.activate(state.config, peripheralApi, group, command.startup)
            if not ok then fail(reason); return end
        end
    end
    if not validCommand() then fail("COMMAND_EXPIRED_OR_SUPERSEDED"); return end
    local hasFine=false
    for _,p in ipairs(state.config.providers) do if p.controlRole=="fine" then hasFine=true end end
    if not command.startup and hasFine and not groups.fine then
        local ok,reason=Hardware.parkTrim(state.config,peripheralApi,validCommand)
        if not ok then fail(reason);return end
    end
    -- Attachment may settle later. A fresh command can retry; hello cannot.
    refreshSnapshot(state, peripheralApi, os.clock())
    if not validCommand() then fail("COMMAND_EXPIRED_OR_SUPERSEDED"); return end
    for _, definition in ipairs(state.config.providers) do
        if command.targets[definition.name] > 0 then
            local p = state.providerSnapshot.providers[definition.name]
            if not p or p.signalStrength ~= 15 or not p.gasOutputValid or not p.attachedValid or not p.attached or
                providerActivityFault(p, definition.name) then
                fail("ACTIVATION_OR_BALLOON_NOT_READY"); return
            end
        end
    end
    state.lastAppliedSeq = command.seq
    state.appliedTargets = readbackTargets(state.config, state.providerSnapshot)
    state.armed = not command.startup
    if command.startup then disarmControlContext(state)
    else applyControlContext(state,command,os.clock()) end
    state.lastApplyFault = nil
    state.lastApplyDetail = nil
    state.lastCommandFault = nil
    state.commandInProgress = nil
    -- Receipt time is retained: application must not extend demand validity.
    sendStatus(state, rednetApi, peripheralApi, os.clock())
end

-- Test writes never activate redstone or alter burner trim. They use the same
-- sole writer and pre/post-yield cancellation guards as normal lift commands.
-- Summary: Apply and verify the bounded tuning target map under its current lease.
local function applyTuningCommand(state,command,peripheralApi,rednetApi)
 local function current()
  local lease=state.tuningLease
  return currentCommand(state,command) and state.configValid and state.config.tuningEnabled==true and
   command.nodeBoot==state.boot and lease and lease.id==command.tuning and lease.boot==state.boot and
   os.clock()<lease.expires and os.clock()-command.receivedAt<=15
 end
 -- Summary: Record the active command's rejection and release its in-progress bookkeeping.
 local function fail(reason)
  state.lastApplyFault=reason;state.armed=false;state.commandInProgress=nil
  local pending=state.pendingCommand
  local superseded=state.session==command.session and state.sessionGeneration==command.sessionGeneration and
   state.lastReceivedSeq>command.seq and pending and pending.tuning==command.tuning and state.configValid
  if not superseded then state.tuningLease=nil end
  sendStatus(state,rednetApi,peripheralApi,os.clock())
 end
 if not current() then fail("TUNING_EXPIRED_OR_SUPERSEDED");return end
 state.commandInProgress=command.seq
 refreshSnapshot(state,peripheralApi,os.clock())
 if not current() then fail("TUNING_BINDINGS_CHANGED");return end
 local ok,reason=Hardware.validateTuning(state.config,command.targets,state.tuningLease.baseline,state.providerSnapshot,false)
 if not ok then fail(reason);return end
 for _,definition in ipairs(state.config.providers) do
  if not current() then fail("TUNING_EXPIRED_OR_SUPERSEDED");return end
  local altitude=Hardware.sampleAltitude(state.config,peripheralApi,os.clock())
  if not current() then fail("TUNING_SUPERSEDED");return end
  if not altitude.valid or math.abs(altitude.sensorWorldY-state.tuningLease.y)>4 then fail("TUNING_LOCAL_HEIGHT_LIMIT");return end
  local sample=Hardware.sampleConfigured({providers={definition}},peripheralApi)
  state.providerSnapshot.providers[definition.name]=sample.providers[definition.name]
  if not current() then fail("TUNING_SUPERSEDED");return end
  ok,reason=Hardware.validateTuning(state.config,command.targets,state.tuningLease.baseline,state.providerSnapshot,false)
  if not ok then fail(reason);return end
  local record=sample.providers[definition.name]
  if definition.controlRole=="bulk" and record.targetAmount~=command.targets[definition.name] then
   ok,reason=applyOne(state,peripheralApi,definition.name,command.targets[definition.name])
   if not ok then fail("TUNING_PARTIAL_APPLY: "..tostring(reason));return end
  end
  if not current() then fail("TUNING_SUPERSEDED");return end
 end
 if current() then state.lastAppliedSeq=command.seq;state.appliedTargets=copyTargets(command.targets);state.armed=true;disarmControlContext(state);state.lastApplyFault=nil end
 state.commandInProgress=nil;sendStatus(state,rednetApi,peripheralApi,os.clock())
end

-- Summary: Check command sequence, lease, boot and session before a systems write.
local function currentSystemsCommand(state,command)
    local lease=state.systemsLease
    return currentCommand(state,command) and state.configValid and
        Hardware.systemsSupported(state.config) and lease and lease.seq==command.seq and
        lease.session==command.session and lease.nodeBoot==state.boot and
        lease.stage==command.systems and command.nodeBoot==state.boot and
        os.clock()<lease.expires and os.clock()-command.receivedAt<=SYSTEMS_LEASE_SECONDS
end

-- START SYSTEMS is the dedicated staged startup path for bulk lift.
-- One writer applies the complete local provider map, then activates links.
-- Every provider boundary rechecks session, sequence, lease, and live hardware.
-- Summary: START SYSTEMS is the dedicated staged startup path for bulk lift. One writer applies the complete local provider map, then activates links. Every provider boundary rechecks session, sequence, lease, and live hardware.
local function applySystemsCommand(state,command,peripheralApi,rednetApi,handoverTestOptions)
    local function current() return currentSystemsCommand(state,command) end
    -- Summary: Record the active command's rejection and release its in-progress bookkeeping.
    local function fail(reason)
        state.commandInProgress=nil
        if state.systemsLease and state.systemsLease.seq==command.seq then
            state.systemsLease=nil
            state.armed=false
            state.lastApplyFault=reason
            print("START SYSTEMS command "..tostring(command.seq).." failed: "..tostring(reason))
        end
        sendStatus(state,rednetApi,peripheralApi,os.clock())
    end
    if not current() then return end
    state.commandInProgress=command.seq
    refreshSnapshot(state,peripheralApi,os.clock())
    if not current() then state.commandInProgress=nil;return end
    if not systemsStartReady(state,state.providerSnapshot) then fail("SYSTEMS_PROBE_HARDWARE_NOT_READY");return end
    if command.systems=="control" and not managedReady(state) then
        fail("SYSTEMS_CONTROL_HARDWARE_NOT_READY");return
    end
    local lease=state.systemsLease
    local requiredPrior=lease and lease.probeCompleted and "probe" or nil
    local ok,reason=Hardware.validateSystemsTargets(state.config,command.quadrant,
        command.targets,command.systems,state.providerSnapshot,requiredPrior)
    if not ok then fail(reason);return end

    local preservedProbeSignals={}
    -- The snapshot above was read inside this command's authority window and
    -- serves as the pre-write check. Every provider is validated before any
    -- write, then all writes (each with its own read-back) run concurrently.
    -- A sequential re-read and write per provider cost several server ticks
    -- each and stretched every START SYSTEMS ACK to about two seconds.
    local providers=state.providerSnapshot and state.providerSnapshot.providers or {}
    local writes={}
    for _,definition in ipairs(state.config.providers) do
        local provider=providers[definition.name]
        if not provider or not provider.present or not provider.writable or
            not provider.targetValid or not provider.signalValid then
            fail("SYSTEMS_PROVIDER_CHANGED:"..definition.name);return
        end
        local target=command.targets[definition.name]
        if command.systems=="probe" and definition.controlRole=="bulk" then
            -- Probe never changes a bulk ceiling or its existing link state.
            if target~=provider.targetAmount then
                fail("SYSTEMS_PROBE_BULK_CHANGED:"..definition.name);return
            end
            preservedProbeSignals[definition.name]=provider.signalStrength
        elseif provider.targetAmount~=target and not
            (command.systems=="control" and definition.controlRole=="fine" and target==0) then
            -- Keep the probe alive until steam envelope telemetry is verified.
            writes[#writes+1]={name=definition.name,target=target}
        end
    end
    if not current() then state.commandInProgress=nil;return end
    local writeResults,writeJobs={},{}
    for index,write in ipairs(writes) do
        writeJobs[index]=function()
            local called,applied,detail=pcall(Hardware.applyTarget,peripheralApi,write.name,write.target)
            if called then writeResults[index]={applied,detail} else writeResults[index]={false,applied} end
        end
    end
    if #writeJobs>1 and type(parallel)=="table" and type(parallel.waitForAll)=="function" then
        parallel.waitForAll(table.unpack(writeJobs))
    else
        for _,job in ipairs(writeJobs) do job() end
    end
    for index,write in ipairs(writes) do
        local result=writeResults[index]
        if not result or not result[1] then
            fail("SYSTEMS_PARTIAL_TARGET:"..write.name..":"..tostring(result and result[2] or "write did not complete"));return
        end
    end
    if not current() then state.commandInProgress=nil;return end

    if command.systems=="probe" then
        local activated,activationReason=Hardware.activate(state.config,peripheralApi,"fine","systems_probe",current)
        if not activated then fail("SYSTEMS_PROBE_ACTIVATION_FAILED:"..tostring(activationReason));return end
    else
        local trimTarget=0
        for _,p in ipairs(state.config.providers) do if p.controlRole=="fine" then trimTarget=command.targets[p.name] end end
        if trimTarget==0 then
            -- Hide only expected bulk attachment warm-up faults while the
            -- already active trim probe carries envelope telemetry.
            state.systemsHandoverPendingSeq=command.seq
            state.systemsHandoverReason="bulk steam activation is settling"
        end
        -- All requested ceilings have been set and read back before any bulk
        -- link is enabled, avoiding a transient full-capacity lift pulse.
        local activated,activationReason=Hardware.activate(state.config,peripheralApi,"bulk","systems_control",current)
        if not activated then
            state.systemsHandoverPendingSeq=nil;state.systemsHandoverReason=nil
            fail("SYSTEMS_BULK_ACTIVATION_FAILED:"..tostring(activationReason));return
        end
        if not current() then
            state.commandInProgress=nil
            state.systemsHandoverPendingSeq=nil;state.systemsHandoverReason=nil
            return
        end
        if trimTarget==0 then
            local injected=type(handoverTestOptions)=="table" and handoverTestOptions or {}
            local parkOptions={
                clockFn=injected.clockFn,
                waitFn=injected.waitFn,
                timeoutSeconds=injected.timeoutSeconds,
                pollIntervalSeconds=injected.pollIntervalSeconds,
                maxPolls=injected.maxPolls,
                -- Summary: Record the current provider handover prerequisite while its writer waits.
                onWaiting=function(waitReason,first)
                    if not current() then return end
                    state.systemsHandoverPendingSeq=command.seq
                    state.systemsHandoverReason=waitReason
                    if first then
                        print("START SYSTEMS command "..tostring(command.seq).." WAITING_HANDOVER: "..
                            tostring(waitReason):gsub("[%c]"," "):sub(1,160))
                    end
                end,
            }
            activated,activationReason=Hardware.parkTrim(state.config,peripheralApi,current,parkOptions)
            state.systemsHandoverPendingSeq=nil;state.systemsHandoverReason=nil
            if not activated and not current() then
                state.commandInProgress=nil
                sendStatus(state,rednetApi,peripheralApi,os.clock())
                return
            end
        else activated,activationReason=Hardware.activate(state.config,peripheralApi,"fine","systems_control",current) end
        if not activated then fail("SYSTEMS_TRIM_ACTIVATION_FAILED:"..tostring(activationReason));return end
    end
    if not current() then state.commandInProgress=nil;return end

    refreshSnapshot(state,peripheralApi,os.clock())
    if not current() then state.commandInProgress=nil;return end
    for _,definition in ipairs(state.config.providers) do
        local provider=state.providerSnapshot.providers[definition.name]
        local requested=command.targets[definition.name]
        local expected=requested
        if command.systems=="control" and definition.controlRole=="fine" and requested==0 then
            expected=definition.minimumNonzeroTarget or 5
        end
        if not provider or not provider.targetValid or provider.targetAmount~=expected then
            fail("SYSTEMS_TARGET_READBACK_FAILED:"..definition.name);return
        end
        local expectedSignal=0
        if command.systems=="control" then
            expectedSignal=definition.controlRole=="fine" and requested==0 and 0 or 15
        elseif definition.controlRole=="fine" then
            expectedSignal=15
        else
            expectedSignal=preservedProbeSignals[definition.name]
        end
        if not provider.signalValid or provider.signalStrength~=expectedSignal then
            fail("SYSTEMS_ACTIVATION_READBACK_FAILED:"..definition.name);return
        end
    end
    if command.systems=="control" then
        local checked,checkReason=Hardware.validateSystemsTargets(state.config,command.quadrant,
            command.targets,"control",state.providerSnapshot,"probe")
        if not checked then fail(checkReason);return end
    end
    if current() then
        state.lastAppliedSeq=command.seq
        state.appliedTargets=readbackTargets(state.config,state.providerSnapshot)
        local timing=state.systemsCommandTiming
        if timing and timing.seq==command.seq and timing.session==command.session then
            timing.appliedEpochMs=diagnosticEpoch()
        end
        state.armed=true
        if command.systems=="control" then applyControlContext(state,command,os.clock())
        else disarmControlContext(state) end
        if state.systemsLease then state.systemsLease.probeCompleted=true end
        state.lastApplyFault=nil
        state.lastApplyDetail=nil
        state.lastCommandFault=nil
    end
    state.commandInProgress=nil
    sendStatus(state,rednetApi,peripheralApi,os.clock())
end

-- Summary: Apply and verify the latched emergency shutdown through the sole writer.
local function applyEmergencyStop(state, command, peripheralApi, rednetApi)
    local bindingGeneration = state.bindingGeneration or 0
    local function current()
        return command.nodeBoot == state.boot and state.emergencyStopLatched == true and
            not state.emergencyDisarmPending and
            state.bindingFailed ~= true and state.configValid == true and
            bindingGeneration == (state.bindingGeneration or 0) and
            (command.bindingGeneration == nil or command.bindingGeneration == bindingGeneration)
    end
    if not current() then return end
    state.commandInProgress = command.seq
    local operationConfig = state.config
    local ok, reason = Hardware.emergencyStop(operationConfig, peripheralApi, current)
    if current() then
        disarmControlContext(state)
        state.systemsLease = nil
        state.tuningLease = nil
        refreshSnapshot(state, peripheralApi, os.clock())
        if current() then
            state.appliedTargets = readbackTargets(state.config, state.providerSnapshot)
            state.emergencyStopVerified = ok == true
            local sameSession = command.session == state.session
            state.emergencyStopAppliedSeq = ok and sameSession and not command.resumed and command.seq or nil
            if ok then
                state.emergencyStopFault = nil
                state.lastApplyFault = nil
                if type(state.lastCommandFault) == "string" and
                    state.lastCommandFault:find("SYSTEMS_COMMAND_REJECTED:EMERGENCY_STOP_NOT_VERIFIED", 1, true) then
                    state.lastCommandFault = nil
                end
                if sameSession and not command.resumed then state.lastAppliedSeq = command.seq end
            else
                state.emergencyStopFault = boundedEmergencyReason(reason or "readback failed")
                state.lastApplyFault = "EMERGENCY_STOP_FAILED"
            end
        end
    end
    state.commandInProgress = nil
    -- The supplied facade may belong to the retired binding. Do not sample it
    -- after a rebind and accidentally restore its fingerprint during status.
    if current() then sendStatus(state, rednetApi, peripheralApi, os.clock()) end
end

-- Summary: Dispatch the queued command to its verified actuator operation.
local function applyCommand(state, command, peripheralApi, rednetApi, handoverTestOptions)
    if command.emergencyDisarm then
        if not currentCommand(state,command) or command.nodeBoot~=state.boot then return end
        local ok,reason=writeEmergencyLatch(false)
        if not currentCommand(state,command) then
            if state.emergencyStopLatched then
                local restored,issue=writeEmergencyLatch(true)
                state.emergencyStopPersistenceFault=not restored and issue or nil
            end
            return
        end
        state.emergencyDisarmPending=false
        if ok then
            state.emergencyStopLatched=false;state.emergencyStopVerified=false
            state.emergencyStopAppliedSeq=nil;state.emergencyStopFault=nil;state.emergencyStopPersistenceFault=nil
            state.emergencyDisarmAppliedSeq=command.seq;state.lastAppliedSeq=command.seq
            state.lastApplyFault=nil;state.lastCommandFault=nil;state.lastApplyDetail=nil
            state.lastCommandAt=nil;state.shutdownComplete=false
        else
            state.lastApplyFault="EMERGENCY_DISARM_PERSISTENCE_FAILED"
            state.emergencyStopPersistenceFault=reason
        end
        -- No target, activation, burner, vent or thrust setter is called here.
        sendStatus(state,rednetApi,peripheralApi,os.clock())
        return
    end
    if command.emergencyStop then
        return applyEmergencyStop(state, command, peripheralApi, rednetApi)
    end
    if command.shutdown then
        local function current() return currentCommand(state,command) and command.nodeBoot==state.boot end
        if not current() then return end
        state.commandInProgress=command.seq
        local ok,reason=Hardware.shutdown(state.config,peripheralApi,current)
        if current() then
            state.armed=false;state.systemsLease=nil;state.tuningLease=nil
            if ok then
                refreshSnapshot(state,peripheralApi,os.clock())
                state.lastAppliedSeq=command.seq;state.shutdownAppliedSeq=command.seq
                state.appliedTargets=readbackTargets(state.config,state.providerSnapshot)
                state.shutdownComplete=true;state.lastApplyFault=nil;state.lastCommandFault=nil
            else state.lastApplyFault="SHUTDOWN_FAILED:"..tostring(reason) end
        end
        state.commandInProgress=nil
        sendStatus(state,rednetApi,peripheralApi,os.clock())
        return
    end
    if command.systems then return applySystemsCommand(state,command,peripheralApi,rednetApi,handoverTestOptions) end
    if command.tuning then return applyTuningCommand(state,command,peripheralApi,rednetApi) end
    if state.config.activationBridge then
        return applyManagedCommand(state, command, peripheralApi, rednetApi)
    end
    if not currentCommand(state, command) then return end
    state.commandInProgress = command.seq

    -- Re-sample immediately before the first write. A previously ready
    -- heartbeat is not enough evidence that links and peripherals are still
    -- present at the moment a command is applied.
    local snapshot = refreshSnapshot(state, peripheralApi, os.clock())
    if not state.ready then
        state.commandInProgress = nil
        state.lastApplyFault = "NODE_NOT_READY_BEFORE_APPLY"
        sendStatus(state, rednetApi, peripheralApi, os.clock())
        return
    end
    for _, definition in ipairs(state.config.providers) do
        local provider = snapshot.providers[definition.name]
        local activityFault = providerActivityFault(provider, definition.name, "_BEFORE_APPLY")
        if activityFault then
            state.commandInProgress = nil
            state.armed=false
            state.lastApplyFault = activityFault
            disarmControlContext(state)
            sendStatus(state, rednetApi, peripheralApi, os.clock())
            return
        end
        if not provider or provider.present ~= true or provider.writable ~= true or
            provider.targetValid ~= true or provider.signalValid ~= true or
            provider.signalStrength ~= 15 or provider.attachedValid ~= true or
            provider.attached ~= true then
            state.commandInProgress = nil
            state.lastApplyFault = "PROVIDER_NOT_READY_BEFORE_APPLY"
            sendStatus(state, rednetApi, peripheralApi, os.clock())
            return
        end
    end

    for _, definition in ipairs(state.config.providers) do
        if not currentCommand(state, command) then
            state.commandInProgress = nil
            state.armed = false
            state.lastApplyFault = "COMMAND_SUPERSEDED_PART_WAY_THROUGH"
            sendStatus(state, rednetApi, peripheralApi, os.clock())
            return
        end
        local name = definition.name
        local target = command.targets[name]
        if os.clock() - command.receivedAt > state.config.commandTimeoutSeconds then
            state.commandInProgress = nil
            state.armed = false
            state.lastApplyFault = "COMMAND_EXPIRED_BEFORE_FULL_APPLY"
            state.lastApplyDetail = "command exceeded commandTimeoutSeconds before all providers were confirmed"
            sendStatus(state, rednetApi, peripheralApi, os.clock())
            return
        end

        -- Sample the activation link, balloon attachment, and current target
        -- immediately before this provider is changed. Earlier telemetry can
        -- become stale while another setter yields for a server tick.
        local safety, safetyError = Hardware.readSafetyState(peripheralApi, name)
        local activityFault = providerActivityFault(safety, name, "_BEFORE_APPLY")
        if not safety or safety.signalStrength ~= 15 or activityFault then
            state.commandInProgress = nil
            state.armed = false
            state.lastApplyFault = activityFault or ("PROVIDER_PREWRITE_CHECK_FAILED:" .. name)
            state.lastApplyDetail = safetyError or (activityFault and "optional isActive() check failed" or "activation signal must read 15 before a target write")
            sendStatus(state, rednetApi, peripheralApi, os.clock())
            return
        end
        if not currentCommand(state, command) then
            state.commandInProgress = nil
            state.armed = false
            state.lastApplyFault = "COMMAND_SUPERSEDED_PART_WAY_THROUGH"
            sendStatus(state, rednetApi, peripheralApi, os.clock())
            return
        end

        if safety.targetAmount ~= target then
            local ok, reason = applyOne(state, peripheralApi, name, target)
            if not ok then
                state.commandInProgress = nil
                state.armed = false
                state.lastApplyFault = "PARTIAL_APPLY:" .. name
                state.lastApplyDetail = reason
                sendStatus(state, rednetApi, peripheralApi, os.clock())
                return
            end
        end

        -- peripheral setters may yield for a game tick. A new session or a
        -- newer command can arrive during that yield, so check before touching
        -- the next provider. Any completed write remains visible in telemetry,
        -- but the superseded sequence is never acknowledged as fully applied.
        if not currentCommand(state, command) then
            state.commandInProgress = nil
            state.armed = false
            state.lastApplyFault = "COMMAND_SUPERSEDED_PART_WAY_THROUGH"
            sendStatus(state, rednetApi, peripheralApi, os.clock())
            return
        end
        snapshot.providers[name].targetAmount = target
        snapshot.providers[name].targetValid = true
    end

    if currentCommand(state, command) then
        state.lastAppliedSeq = command.seq
        state.appliedTargets = copyTargets(command.targets)
        state.armed = true
        applyControlContext(state,command,os.clock())
        state.lastCommandAt = os.clock()
        state.lastApplyFault = nil
        state.lastApplyDetail = nil
        state.lastCommandFault = nil
    else
        state.armed = false
        state.lastApplyFault = "COMMAND_SUPERSEDED_PART_WAY_THROUGH"
    end
    state.commandInProgress = nil
    sendStatus(state, rednetApi, peripheralApi, os.clock())
end

-- Summary: Print the configured hardware inventory and getter observations.
local function printInspection(config, computerId)
    print("Amaryllis lift hardware inspection (read only)")
    print("Computer ID: " .. tostring(computerId))
    if type(config) == "table" then
        print("Label: " .. tostring(config.label) .. "   Quadrant: " .. tostring(config.quadrant))
        local frequency = config.activationFrequency or {}
        print("Redstone-link item IDs (metadata only): " .. tostring(frequency.first) .. " -> " .. tostring(frequency.second))
        print("Configured providers: " .. tostring(type(config.providers) == "table" and #config.providers or 0))
        for _, provider in ipairs(config.providers or {}) do
            print("  ALLOWLIST " .. tostring(provider.name) .. " targets " ..
                tostring(provider.minTarget) .. ".." .. tostring(provider.maxTarget) .. " step " .. tostring(provider.step))
        end
        if config.balloonRepresentative then
            print("Balloon representative: " .. tostring(config.balloonRepresentative))
        else
            print("Balloon representative: not configured")
        end
    end

    local inventory, inspectError = Hardware.inspectAll(peripheral)
    if not inventory then
        print("Peripheral scan failed: " .. tostring(inspectError))
        return
    end
    if #inventory == 0 then print("No peripherals found.") end
    for _, entry in ipairs(inventory) do
        print("")
        print(entry.name .. "  type=" .. tostring(entry.type or "unknown"))
        local kinds = {}
        for kind, present in pairs(entry.types) do
            if present then kinds[#kinds + 1] = kind end
        end
        table.sort(kinds)
        print("  detected kinds: " .. (#kinds > 0 and table.concat(kinds, ", ") or "none of the lift/modem types"))
        if next(entry.getters) then
            for _, method in ipairs({
                "getHeight", "getVerticalSpeed",
                "getTargetAmount", "getGasOutput", "getSignalStrength", "hasBalloon",
                "isActive", "getGasType", "getBoilerEfficiency",
                "getBalloonLift", "getBalloonFilledVolume", "getBalloonTargetVolume",
                "getBalloonCapacity", "getBalloonHeight", "getBalloonVolumeChange",
            }) do
                local sample = entry.getters[method]
                if sample then
                    local shown = sample.valid and tostring(sample.value) or ("unavailable (" .. tostring(sample.error) .. ")")
                    print("  " .. method .. " = " .. shown)
                end
            end
        end
        print("  methods: " .. (#entry.methods > 0 and table.concat(entry.methods, ", ") or tostring(entry.methodsError or "none reported")))
    end
    print("")
    print("Inspection made no target, redstone, or file changes.")
    print("Peripheral names are runtime addresses. Configure role counts and verified bounds, not names.")
end

-- Summary: Inspect role configuration and attached hardware for local diagnostics.
function Main.inspect()
    local config, configError = Hardware.loadConfig("/avionics/config.json")
    if not config then
        print("Configuration: " .. tostring(configError))
    else
        local valid, errors = Hardware.validateConfig(config, os.getComputerID())
        if not valid then
            print("Configuration needs attention:")
            for _, err in ipairs(errors) do print("  - " .. err) end
        end
    end
    if config then peripheral = Hardware.remotePeripheral(config) end
    printInspection(config, os.getComputerID())
end

-- Summary: Discover and open the role's current wireless modem interfaces.
local function tryOpenWireless(state)
    local names, findError = Hardware.findWirelessModems(Hardware.localPeripheral())
    if not names then
        state.modemReady = false
        state.modemError = findError
        return false
    end
    local opened, openError = Hardware.openWirelessModems(names, rednet)
    state.modemReady = opened
    state.modemError = openError
    return opened
end

-- Summary: Receive a core packet and wake the appropriate status/writer worker.
local function onNetworkMessage(state, sender, message, peripheralApi, rednetApi)
    local ok, reason, shouldReply = Main.receiveMessage(state, sender, message, os.clock())
    if not ok and type(message)=="table" and message.kind=="lift_systems" and
        sender==state.config.coreId and message.session==state.session and
        message.seq==state.lastReceivedSeq then
        state.lastCommandFault="SYSTEMS_COMMAND_REJECTED:"..tostring(reason)
        print("START SYSTEMS command "..tostring(message.seq).." rejected: "..tostring(reason))
    end
    -- Peripheral getters yield for server tasks. Never sample in the radio
    -- receiver: rednet messages arriving during that filtered wait are lost.
    -- The independent status worker samples and replies while we keep listening.
    if shouldReply and not state.statusWakeQueued then state.statusWakeQueued=true;os.queueEvent(STATUS_EVENT) end
    if (ok and (reason == "QUEUED" or reason == "SYSTEM_RESTART_QUEUED")) or
        (type(message) == "table" and message.kind == "system_restart" and state.pendingSystemRestartAck) then
        os.queueEvent(WRITE_EVENT)
    end
end

-- Summary: Receive role-protocol packets and queue their validated operations.
local function networkLoop(state)
    while true do
        local _, sender, message, protocol = os.pullEvent("rednet_message")
        if protocol == PROTOCOL then
            onNetworkMessage(state, sender, message, peripheral, rednet)
        end
    end
end

-- Summary: Sample cached hardware status and publish role reports at the configured cadence.
local function statusLoop(state)
    local nextStatus = os.startTimer(state.config.statusIntervalSeconds)
    local nextStatusAt=os.clock()+state.config.statusIntervalSeconds
    local nextModemCheck = os.clock()+5
    while true do
        local event, a = os.pullEvent()
        local hardwareChanged = event == "peripheral" or event == "peripheral_detach"
        if event==STATUS_EVENT then state.statusWakeQueued=false end
        if event == STATUS_EVENT or os.clock()>=nextStatusAt or (event == "timer" and a == nextStatus) or hardwareChanged then
            -- Modems and peripheral-hub sides can be detached while the node
            -- is running. Recheck the actual wireless devices periodically.
            if hardwareChanged or os.clock()>=nextModemCheck then
                tryOpenWireless(state)
                nextModemCheck=os.clock()+5
            end
            sendStatus(state, rednet, peripheral, os.clock())
            -- Start the next timer after sampling. An older timer can arrive
            -- during a getter's filtered wait and must not stop future reports.
            pcall(os.cancelTimer,nextStatus)
            nextStatusAt=os.clock()+state.config.statusIntervalSeconds
            nextStatus = os.startTimer(state.config.statusIntervalSeconds)
        end
    end
end

-- Apply at most the newest queued command without waiting for an event. A
-- command can arrive while a peripheral setter yields; in that case its wake
-- event may already have been consumed, but this state check still drains it.
-- Maintenance shares the sole writer, so a reboot cannot interrupt a setter.
-- A recheck discovers and samples hardware without activation or cap setters.
-- Summary: Revalidate the pending reboot against its request age, session and local boot.
local function restartStillAuthorized(state, command, now)
    return state.pendingSystemRestart == command and
        installedCoreId(state.config) ~= nil and state.config.label == command.targetLabel and
        state.session == command.session and state.sessionGeneration == command.sessionGeneration and
        state.boot == command.nodeBoot and state.commandInProgress == nil and
        type(state.lastSessionAt) == "number" and now >= state.lastSessionAt and
        now - state.lastSessionAt <= SYSTEM_RESTART_MAX_AGE and
        now >= command.receivedAt and now - command.receivedAt <= SYSTEM_RESTART_MAX_AGE
end

-- Summary: Send the correlated restart acceptance or rejection to core.
local function sendSystemRestartAck(state, reply, rednetApi)
    if installedCoreId(state.config) == nil or state.session ~= reply.session or
        state.boot ~= reply.currentNodeBoot or type(rednetApi) ~= "table" or
        type(rednetApi.send) ~= "function" then return false end
    local packet = {
        v = 1, kind = "system_restart_ack", session = reply.session,
        requestId = reply.requestId, targetLabel = reply.targetLabel,
        nodeBoot = reply.nodeBoot, bootToken = reply.bootToken,
        accepted = reply.accepted == true, detail = reply.detail,
    }
    if reply.zeroVerified ~= nil then packet.zeroVerified = reply.zeroVerified end
    local ok, sent = pcall(rednetApi.send, state.config.coreId, packet, PROTOCOL)
    return ok and sent == true
end

-- Summary: Acknowledge and execute a fresh authorized reboot after writer completion.
local function processPendingSystemRestart(state, rednetApi, reboot, now)
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
    if not command or state.commandInProgress ~= nil then return false end
    if state.systemRestartRetryAt and now < state.systemRestartRetryAt then return false end

    if not restartStillAuthorized(state, command, now) then
        -- A stale request may receive a negative reply while its established
        -- core session and this node boot are still present. It never reboots.
        if state.session == command.session and state.boot == command.nodeBoot and
            installedCoreId(state.config) ~= nil then
            state.pendingSystemRestartAck = {
                session = command.session, requestId = command.requestId,
                targetLabel = command.targetLabel, nodeBoot = command.nodeBoot,
                bootToken = command.bootToken, currentNodeBoot = state.boot,
                accepted = false, detail = "RESTART_REQUEST_EXPIRED_OR_SUPERSEDED",
            }
            state.pendingSystemRestart = nil
            return processPendingSystemRestart(state, rednetApi, reboot, now)
        end
        state.pendingSystemRestart = nil
        return false
    end

    local reply = {
        session = command.session, requestId = command.requestId,
        targetLabel = command.targetLabel, nodeBoot = command.nodeBoot,
        bootToken = command.bootToken, currentNodeBoot = state.boot,
        accepted = true, detail = "LIFT_TARGETS_RETAINED",
    }
    if not sendSystemRestartAck(state, reply, rednetApi) then
        state.systemRestartRetryAt = now + 0.5
        return false
    end
    -- rednet.send can yield on some runtimes. Recheck every authority token
    -- after the ACK so a replaced core session or an expired request cannot
    -- reboot this computer.
    now = os.clock()
    if not restartStillAuthorized(state, command, now) then
        if state.pendingSystemRestart == command then state.pendingSystemRestart = nil end
        state.lastApplyFault = "SYSTEM_RESTART_AUTHORITY_EXPIRED_AFTER_ACK"
        return false
    end
    state.pendingSystemRestart = nil
    state.systemRestartRetryAt = nil
    state.systemRestarted = true
    local restart = reboot or os.reboot
    if type(restart) == "function" then restart() end
    return true
end

-- Summary: Perform the queued hardware recheck or confirmed controller restart.
local function processPendingMaintenance(state,peripheralApi,rednetApi,reboot)
    local command=state.pendingMaintenance;state.pendingMaintenance=nil
    if not command then return false end
    if command.session~=state.session or command.sessionGeneration~=state.sessionGeneration or
        command.nodeBoot~=state.boot or command.seq~=state.lastReceivedSeq or not state.configValid or state.config.maintenanceEnabled~=true then return false end
    local now=os.clock()
    if now<command.receivedAt or now-command.receivedAt>15 then return false end
    local ok,detail=true,"RESTART ACCEPTED"
    if command.operation=="probe_cycle" then
        -- The idle probe keeper waits while the link is cycled.
        state.probeCycleActive=true
        local done,result,reason=pcall(Hardware.cycleProbeLink,state.config,peripheralApi,1)
        state.probeCycleActive=nil
        ok=done and result==true;detail=done and reason or tostring(result)
    elseif command.operation=="recheck" then
        local resolved,reason=Hardware.resolveConfig(state.sourceConfig or state.config,peripheralApi)
        if not resolved then ok=false;detail=reason
        else
            local providers=Hardware.sampleConfigured(resolved,peripheralApi)
            local balloon=Hardware.sampleBalloon(resolved,providers.providers,peripheralApi)
            local altitude=Hardware.sampleAltitude(resolved,peripheralApi,now)
            ok=altitude and altitude.valid==true and balloon and balloon.hasBalloonValid==true and balloon.hasBalloon==true
            detail=ok and "HARDWARE RECHECKED" or "SENSOR / ENVELOPE DATA UNAVAILABLE"
            for name,provider in pairs(providers.providers or {}) do
                if not provider.present or not provider.writable or not provider.targetValid or not provider.signalValid or
                    (provider.signalStrength>1 and (not provider.gasOutputValid or not provider.attachedValid or not provider.attached)) then
                    ok=false;detail="PROVIDER INTERFACE / ACTIVE DATA INVALID: "..name;break
                end
            end
        end
    end
    if command.session~=state.session or command.sessionGeneration~=state.sessionGeneration or command.nodeBoot~=state.boot then return false end
    local sent,result=pcall(rednetApi.send,state.config.coreId,{v=1,kind="lift_maintenance_ack",
        session=command.session,seq=command.seq,quadrant=state.config.quadrant,nodeBoot=state.boot,
        operation=command.operation,ok=ok,detail=tostring(detail):sub(1,160)},state.config.protocol)
    if command.operation=="restart" and ok then
        if not sent or result==false or command.session~=state.session or
            command.sessionGeneration~=state.sessionGeneration or command.nodeBoot~=state.boot or
            command.seq~=state.lastReceivedSeq or not state.configValid then return false end
        print("Core confirmed lift-controller restart. Applied output retention is unverified.")
        local restart=reboot or os.reboot
        restart()
    end
    return true
end

local function processPendingCommand(state, peripheralApi, rednetApi)
    local command = state.pendingCommand
    state.pendingCommand = nil
    if not command then return false end
    applyCommand(state, command, peripheralApi, rednetApi)
    return true
end

-- Summary: Clear the recovered idle-probe fault while retaining other operation faults.
local function clearIdleProbeFault(state)
    if type(state.lastApplyFault)=="string" and state.lastApplyFault:match("^IDLE_PROBE_FAILED:") then
        state.lastApplyFault=nil
    end
end

-- Summary: Retry eligible idle probes and clear their faults after cancellation or recovery.
local function maintainIdleProbe(state,api)
    -- Superseded maintenance is retried under the next eligible control context.
    if state.lastApplyFault=="IDLE_PROBE_FAILED:PROBE_HARDWARE_GENERATION_CHANGED" then
        clearIdleProbeFault(state)
    end
    if state.emergencyStopLatched == true then return end
    api=api or peripheral
    local generation
    local function available()
        return (not generation or state.sessionGeneration==generation) and state.configValid and not state.armed and not state.systemsLease and not state.tuningLease and
            not state.pendingCommand and not state.pendingMaintenance and not state.pendingSystemRestart and
            not state.pendingSystemRestartAck and not state.commandInProgress and not state.probeCycleActive
    end
    if not available() then return end
    local snapshot=refreshSnapshot(state,api,os.clock())
    generation=state.sessionGeneration
    if not available() then return end
    local operating=false
    for _,p in pairs(snapshot.providers or {}) do
        if p.signalValid and p.signalStrength>0 and p.targetValid and p.targetAmount>0 then
            operating=true
            if p.controlRole=="fine" and p.minimumNonzeroTarget==5 and p.targetAmount>=5 and
                Hardware.isFiniteNumber(p.maxTarget) and p.targetAmount<=p.maxTarget and
                snapshot.ready==true and snapshot.trimActivation.valid==true then
                clearIdleProbeFault(state)
            end
        end
    end
    if operating then return end
    local ok,reason=Hardware.startCompositionProbe(state.config,api,available)
    if not available() or reason=="PROBE_HARDWARE_GENERATION_CHANGED" then
        clearIdleProbeFault(state)
        return
    end
    if ok then clearIdleProbeFault(state)
    else state.lastApplyFault="IDLE_PROBE_FAILED:"..tostring(reason) end
end
-- Summary: Serialize queued hardware operations and maintenance through the role's sole writer.
local function writerLoop(state)
    while true do
        if state.pendingSystemRestart or state.pendingSystemRestartAck then
            local now=os.clock()
            if state.commandInProgress==nil and
                (not state.systemRestartRetryAt or now>=state.systemRestartRetryAt) then
                if processPendingSystemRestart(state,rednet) then sleep(0) end
            end
            if state.pendingSystemRestart or state.pendingSystemRestartAck then
                local delay=1
                if state.systemRestartRetryAt then delay=math.max(0.05,math.min(1,state.systemRestartRetryAt-os.clock())) end
                local timer=os.startTimer(delay)
                repeat
                    local event,id=os.pullEvent()
                until event=="timer" and id==timer
            end
        elseif not state.pendingCommand and not state.pendingMaintenance then
            maintainIdleProbe(state)
            if not state.pendingCommand and not state.pendingMaintenance then
                local timer=os.startTimer(1)
                repeat local event,id=os.pullEvent() until event==WRITE_EVENT or (event=="timer" and id==timer)
            end
        end
        if processPendingMaintenance(state,peripheral,rednet) or processPendingCommand(state, peripheral, rednet) then
            -- A setter may yield while the receiver accepts a newer command.
            -- Drain that latest pending snapshot instead of waiting for an old
            -- wake-up event which may already have been consumed.
            sleep(0)
        end
    end
end

-- Summary: Load role configuration and start its network, status and actuator-writer workers.
function Main.run()
    local computerId = os.getComputerID()
    local config, configError = Hardware.loadConfig("/avionics/config.json")
    if not config then
        print("Amaryllis lift node stopped safely: " .. tostring(configError))
        return false
    end
    peripheral = Hardware.remotePeripheral(config)
    local state = Main.newState(config, computerId)
    reportComponentStartup(state)
    if not state.configValid then
        print("Amaryllis lift node stopped safely. Fix config.json:")
        for _, err in ipairs(state.configErrors) do print("  - " .. err) end
        return false
    end

    print("Amaryllis lift node " .. tostring(computerId) .. " / " .. config.label .. " / " .. config.quadrant)
    print("Low trim probe is maintained while main lift is off.")
    -- Preliminary hardware tests/data collection precede opening the uplink.
    -- These checks use getters only; no production pulse or enable change.
    local preliminary = refreshSnapshot(state, peripheral, os.clock())
    state.preliminary = preliminary
    print("Startup local checks: " .. (state.localReady and "PASS" or "DEGRADED"))
    for _, fault in ipairs(preliminary.faults or {}) do
        if fault ~= "CONFIG_INVALID" and fault ~= state.bindingError then print("  " .. fault) end
    end
    if not preliminary.altitude.valid then print("  " .. tostring(preliminary.altitude.reason)) end
    tryOpenWireless(state)
    buildStatus(state, os.clock(), peripheral)
    if not state.modemReady then
        print("Wireless modem: " .. tostring(state.modemError))
        print("The node will keep checking. It will not alter targets or redstone while disconnected.")
    end
    parallel.waitForAll(
        function() networkLoop(state) end,
        function() statusLoop(state) end,
        function() writerLoop(state) end
    )
    return true
end

-- Worker entry points used by the host-side fake-hardware regression suite.
-- Normal startup and inspect mode never call applyCommand through this table.
Main._test = {
    maintainIdleProbe=maintainIdleProbe,
    networkLoop=networkLoop,
    statusLoop=statusLoop,
    processPendingMaintenance=processPendingMaintenance,
    processPendingSystemRestart=processPendingSystemRestart,
    restartStillAuthorized=restartStillAuthorized,
    refreshSnapshot = refreshSnapshot,
    buildStatus = buildStatus,
    applyCommand = applyCommand,
    processPendingCommand = processPendingCommand,
    currentCommand = currentCommand,
    reportComponentStartup = reportComponentStartup,
}

-- Returning the table when required keeps the module safe to inspect in tests.
-- Running with `avionics/main.lua inspect` is an explicit read-only inventory.
local arguments = { ... }
if arguments[1] == "avionics.main" then
    return Main
elseif arguments[1] == "inspect" then
    Main.inspect()
else
    Main.run()
end

return Main
