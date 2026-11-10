local Mathx = require("avionics.mathx")
-- Section: Lift recovery | Retained target reconciliation and authority renewal.
-- Navigator information retry revision v1
-- Recoverable vessel telemetry v1
-- Pure lifecycle helpers for resuming an existing START SYSTEMS run after
-- telemetry loss. The caller remains responsible for coordinating commands.
local Recovery={}
local QUADS={"FL","FR","BL","BR"}

local finite = Mathx.finite
local function copyMap(source)
    local result={}
    for key,value in pairs(source or {}) do result[key]=value end
    return result
end
local function copyMaps(source)
    local result={}
    for quadrant,map in pairs(source or {}) do result[quadrant]=copyMap(map) end
    return result
end
local function closeEnoughFresh(now,at,limit)
    return finite(now) and finite(at) and now>=at and finite(limit) and now-at<=limit
end
local function contains(value,fragment)
    return type(value)=="string" and value:find(fragment,1,true)~=nil
end

local function boundedFingerprint(value)
    return type(value)=="string" and #value>0 and #value<=1024 and not value:find("[%c]")
end

-- Section: Lift recovery | Retained target reconciliation and authority renewal.
-- Summary: Compare observed provider identities, roles and bounds with the retained signature.
local function sameProviderSignature(s,node,q)
    local roles=s.providerRoles and s.providerRoles[q]
    local limits=s.providerLimits and s.providerLimits[q]
    if type(roles)~="table" or type(limits)~="table" or type(node.providers)~="table" then
        return "wait","LIFT PROVIDER SIGNATURE UNAVAILABLE"
    end
    local count=0
    for name,role in pairs(roles) do
        count=count+1
        local bound=limits[name]
        local provider=node.providers[name]
        if not provider or not bound then return "wait","LIFT PROVIDER SIGNATURE UNAVAILABLE" end
        if provider.controlRole~=role then
            return "terminal","LIFT PROVIDER ALLOWLIST CHANGED"
        end
        if provider.presenceValid==false or (provider.presenceValid==nil and provider.present~=true) then
            return "wait","LIFT PROVIDER PRESENCE READBACK UNAVAILABLE"
        end
        if provider.present~=true then return "terminal","LIFT PROVIDER CONFIRMED MISSING OR WRONG TYPE" end
        if provider.writableValid==false or (provider.writableValid==nil and provider.writable~=true) then
            return "wait","LIFT PROVIDER WRITE INTERFACE READBACK UNAVAILABLE"
        end
        if provider.writable~=true then return "terminal","LIFT PROVIDER CONFIRMED NOT WRITABLE" end
        if not finite(provider.maxTarget) or
            (provider.minimumNonzeroTarget~=nil and not finite(provider.minimumNonzeroTarget)) then
            return "wait","LIFT PROVIDER LIMIT READBACK UNAVAILABLE"
        end
        if provider.maxTarget~=bound.maximum or
            (provider.minimumNonzeroTarget or bound.minimum)~=bound.minimum then
            return "terminal","LIFT PROVIDER ALLOWLIST CHANGED"
        end
    end
    local observed=0
    for name in pairs(node.providers) do
        observed=observed+1
        if not roles[name] then return "terminal","LIFT PROVIDER ALLOWLIST CHANGED" end
    end
    if count~=(node.steamCount or 8)+1 or observed~=count then return "terminal","LIFT PROVIDER ALLOWLIST CHANGED" end
    return "trusted"
end

-- A different node boot is adoptable only after the same registered node has
-- answered a recent core Hello and reports the exact retained hardware and
-- provider identity. Reconcile live provider targets before issuing the fresh lease.
-- An unavailable UUID is not evidence of another vessel. Do not
-- authorize writes until a fresh complete sample confirms the retained UUID.
-- Summary: Classify fresh vessel observations against the retained identity.
function Recovery.vesselState(io,s,now)
    local vessel=io and io.vessel
    local stale=io and io.config and io.config.network and io.config.network.sensor_stale_seconds
    if not s or type(s.uuid)~="string" or #s.uuid==0 then
        return "terminal","RETAINED VESSEL IDENTITY UNAVAILABLE"
    end
    if type(vessel)~="table" or not closeEnoughFresh(now,vessel.at,stale) then
        return "wait","VESSEL TELEMETRY STALE"
    end
    if type(vessel.uuid)~="string" or #vessel.uuid==0 then
        return "wait","VESSEL IDENTITY UNAVAILABLE"
    end
    if vessel.valid~=true then return "wait","VESSEL TELEMETRY INCOMPLETE" end
    if vessel.uuid~=s.uuid then return "terminal","VESSEL IDENTITY CHANGED" end
    if not finite(vessel.altitude) or not finite(vessel.verticalSpeed) then
        return "wait","VESSEL TELEMETRY INCOMPLETE"
    end
    return "trusted"
end

-- Summary: Validate a changed chamber boot against registry, bindings and recent core Hello.
function Recovery.nodeBootState(io,s,q,now,flight)
    local node=io and io.nodes and io.nodes[q]
    if not node then return "wait","LIFT TELEMETRY UNAVAILABLE" end
    if node.boot==s.boots[q] then return "same" end
    if flight and flight.emergencyLiftLatched then return "terminal","EMERGENCY LIFT STOP LATCHED" end
    if not io or io.identityReady~=true or s.coreSession==nil or io.session~=s.coreSession or
        s.coreID==nil or io.localID~=s.coreID or not io.config or not io.config.node_ids or
        io.config.node_ids[q]~=node.id or not s.nodeIDs or s.nodeIDs[q]~=node.id then
        return "terminal","CORE OR LIFT REGISTRY IDENTITY CHANGED"
    end
    if io.hardwareFingerprint~=s.fingerprint then return "terminal","CORE SENSOR BINDINGS CHANGED" end
    local vesselState,vesselReason=Recovery.vesselState(io,s,now)
    if vesselState~="trusted" then return vesselState,vesselReason end
    if type(io.nodeFresh)=="function" and not io:nodeFresh(q,now) then
        return "wait","LIFT TELEMETRY STALE"
    end
    if node.bootRebindTrusted~=true then return "wait","LIFT BOOT AWAITING RECENT CORE HELLO" end
    local helloAt=node.bootChangeHelloAt
    local trustedAt=node.bootRebindTrustedAt
    local helloInterval=io.config.network and io.config.network.hello_interval_seconds
    if not finite(helloAt) or not finite(trustedAt) or not finite(helloInterval) or
        now<trustedAt or now-helloAt>helloInterval*2.5 or math.abs(trustedAt-helloAt)>helloInterval*2.5 then
        return "wait","LIFT BOOT AWAITING RECENT CORE HELLO"
    end
    if not finite(node.acceptedBootGeneration) or node.acceptedBootGeneration%1~=0 or
        node.acceptedBootGeneration<1 or node.acceptedBootGeneration>2147483647 or
        not finite(node.bindingGeneration) or node.bindingGeneration%1~=0 or
        node.bindingGeneration<0 or node.bindingGeneration>2147483647 then
        return "wait","LIFT BINDING DATA UNAVAILABLE"
    end
    local bootReasons={COMPONENT_STARTUP=true,INITIAL_DISCOVERY=true,BINDING_RECOVERY=true,FINGERPRINT_CHANGED=true}
    if not bootReasons[node.bootReason] then return "wait","LIFT BINDING DATA UNAVAILABLE" end
    if s.bindingFingerprints==nil or not boundedFingerprint(s.bindingFingerprints[q]) then
        return "terminal","CAPTURED LIFT BINDING IDENTITY UNAVAILABLE"
    end
    if node.bindingFingerprintValid~=true or not boundedFingerprint(node.bindingFingerprint) then
        return "wait","LIFT BINDING DATA UNAVAILABLE"
    end
    if node.bindingFingerprint~=s.bindingFingerprints[q] then
        return "terminal","LIFT HARDWARE BINDINGS CHANGED"
    end
    local signature,reason=sameProviderSignature(s,node,q)
    if signature~="trusted" then return signature,reason end
    return "trusted"
end

-- Missing observations and renewable output disagreements suspend control.
-- Verified vessel, binding and provider identity changes remain terminal.
-- Recovery revalidates provider targets before resuming control.
-- Summary: Classify guard faults for telemetry and command-authority recovery.
function Recovery.isTransientGuardFault(io,s,now,reason,flight)
    if type(reason)~="string" then return false end
    if contains(reason,"PROVIDER CEILING CHANGED") then return true end
    if contains(reason,"ACTIVATION SIGNAL ") and contains(reason,"EXPECTED") then return true end
    if contains(reason,"REPORTS INACTIVE") then return true end
    if contains(reason,"LIMIT READBACK UNAVAILABLE") then return true end
    local q=reason:match("^(%u%u) LIFT TELEMETRY STALE$")
    if q and (q=="FL" or q=="FR" or q=="BL" or q=="BR") then
        return not io or type(io.nodeFresh)~="function" or not io:nodeFresh(q,now)
    end
    q=reason:match("^(%u%u) LIFT BOOT CHANGED$") or
        reason:match("^(%u%u) LIFT BOOT AWAITING RECENT CORE HELLO$") or
        reason:match("^(%u%u) LIFT BINDING DATA UNAVAILABLE$") or
        reason:match("^(%u%u) LIFT PROVIDER SIGNATURE UNAVAILABLE$") or
        reason:match("^(%u%u) LIFT PROVIDER LIMIT READBACK UNAVAILABLE$")
    if q and (q=="FL" or q=="FR" or q=="BL" or q=="BR") then
        local node=io and io.nodes and io.nodes[q]
        if reason:find("BINDING DATA UNAVAILABLE",1,true) and node and
            node.bindingFingerprintValid~=true and type(io.nodeFresh)=="function" and io:nodeFresh(q,now) then
            return true
        end
        local state=Recovery.nodeBootState(io,s,q,now,flight)
        return state=="trusted" or state=="wait"
    end
    local vessel=io and io.vessel or {}
    if reason=="VESSEL SENSOR STALE / IDENTITY CHANGED" or reason=="VESSEL TELEMETRY STALE" or
        reason=="VESSEL IDENTITY UNAVAILABLE" or reason=="VESSEL TELEMETRY INCOMPLETE" then
        return Recovery.vesselState(io,s,now)=="wait"
    end
    if reason=="COCKPIT INPUTS STALE" or reason=="COCKPIT INPUT READ FAILED" or
        reason=="COCKPIT CONTROLS UNAVAILABLE" or reason=="COCKPIT CONTROL STATE STALE" then return true end
    if reason=="VESSEL MASS / GRAVITY UNAVAILABLE" then
        local gravity=vessel.environment and vessel.environment.gravity
        return not finite(vessel.mass) or not gravity or not finite(gravity.y)
    end
    if reason=="VESSEL AIR PRESSURE UNAVAILABLE" then
        local environment=vessel.environment
        return not environment or not finite(environment.airPressure)
    end
    if contains(reason,"ALTITUDE DATA UNAVAILABLE") or
        contains(reason,"BALLOON STATUS UNAVAILABLE") or
        contains(reason,"READBACK UNAVAILABLE") or
        contains(reason,"GAS MIX UNAVAILABLE") or
        contains(reason,"LIFT READBACK UNAVAILABLE") or
        contains(reason,"CEILING READBACK UNAVAILABLE") or
        contains(reason,"ACTIVATION SIGNAL READBACK UNAVAILABLE") or
        contains(reason,"ACTIVITY READBACK UNAVAILABLE") or
        contains(reason,"GAS TYPE READBACK UNAVAILABLE") then
        return true
    end
    return false
end

-- Convert provider readback into the core's logical target map. A fine
-- provider's logical zero may be stored at its minimum ceiling while its
-- signal is off; accept that representation only when zero was expected.
-- Summary: Convert provider readback into the core's logical target map. A fine provider's logical zero may be stored at its minimum ceiling while its signal is off; accept that representation only when zero was expected.
function Recovery.readTargetMap(node,expected,roles)
    if type(node)~="table" or type(node.providers)~="table" then
        return nil,"LIFT PROVIDER MAP UNAVAILABLE"
    end
    local actual,count={},0
    for name,role in pairs(roles or {}) do
        count=count+1
        local provider=node.providers[name]
        if type(provider)~="table" or provider.present~=true or provider.writable~=true or
            provider.targetValid~=true or not finite(provider.targetAmount) or
            provider.controlRole~=role then
            return nil,"PROVIDER READBACK INVALID: "..tostring(name)
        end
        local value=provider.targetAmount
        local minimum=provider.minimumNonzeroTarget
        local applied=node.appliedTargets and node.appliedTargets[name]
        if role=="fine" and expected and expected[name]==0 and provider.signalValid==true and
            provider.signalStrength==0 and finite(minimum) and value==minimum and applied==minimum then
            value=0
        end
        actual[name]=value
    end
    local observed=0
    for name in pairs(node.providers) do
        if not roles or roles[name]==nil then return nil,"PROVIDER ALLOWLIST CHANGED" end
        observed=observed+1
    end
    if count~=(node.steamCount or 8)+1 or observed~=count then return nil,"PROVIDER ALLOWLIST CHANGED" end
    return actual
end

-- Summary: Compare complete provider target maps.
function Recovery.mapsEqual(left,right)
    if type(left)~="table" or type(right)~="table" then return false end
    local count=0
    for key,value in pairs(left) do
        count=count+1
        if right[key]~=value then return false end
    end
    local otherCount=0
    for key in pairs(right) do otherCount=otherCount+1 end
    return count==otherCount
end

-- Core retains command authority across lost ACKs and partial application.
-- Validate the live provider identities and return core's last intended absolute target map.
-- Summary: Resolve physical target maps suitable for retained-run reconciliation.
function Recovery.authoritativeTargetMaps(s,nodes)
    local recovery=s.telemetryRecovery or {}
    local retained=recovery.targetMaps or s.currentTargets or s.probeTargets or s.controlStartTargets
    if type(retained)~="table" then return nil,"CORE TARGET MAP UNAVAILABLE" end
    local targets,coarse={},{}
    local mismatch=false
    local mismatchReason
    for _,q in ipairs(QUADS) do
        local pending=not recovery.targetMaps and s.pending and s.pending[q]
        local intendedBatch=not recovery.targetMaps and s.batchTargets and s.batchTargets[q]
        local expected=intendedBatch or (pending and pending.targets) or retained[q]
        if type(expected)~="table" then return nil,q.." CORE TARGET MAP UNAVAILABLE" end
        local actual,reason=Recovery.readTargetMap(nodes[q],expected,s.providerRoles and s.providerRoles[q])
        if not actual then return nil,q.." "..tostring(reason) end
        for name,value in pairs(expected or {}) do
            local provider=nodes[q].providers[name]
            local floor=provider and (provider.minimumNonzeroTarget or provider.minTarget or 0)
            local parked=provider and provider.controlRole=="fine" and value==0
            if not provider or not finite(value) or not finite(provider.maxTarget) or
                value>provider.maxTarget or (not parked and value<floor) then
                return nil,q.." CORE TARGET OUTSIDE PROVIDER LIMITS: "..tostring(name)
            end
        end
        for name in pairs(actual) do
            if expected[name]==nil then return nil,q.." CORE TARGET MAP INCOMPLETE: "..name end
        end
        targets[q]=copyMap(expected)
        local source=recovery.coarseTrimApplied or s.coarseTrimApplied or {}
        if (pending or intendedBatch) and s.batchStage=="control" then source=s.batchCoarseTrimApplied or source end
        coarse[q]=copyMap(source[q])
        if not Recovery.mapsEqual(actual,expected) then
            mismatch=true
            for name,value in pairs(expected) do
                if actual[name]~=value and not mismatchReason then
                    mismatchReason=q.." PROVIDER "..name.." TARGET MISMATCH: CORE="..
                        tostring(value).." READBACK="..tostring(actual[name])
                end
            end
        elseif pending or intendedBatch then mismatch=true end
        for name,value in pairs(expected) do
            local provider=nodes[q].providers[name]
            local signal=provider.controlRole=="fine" and value==0 and 0 or 15
            if provider.signalValid==true and provider.signalStrength~=signal then
                mismatch=true
                mismatchReason=mismatchReason or (q.." PROVIDER "..name.." SIGNAL MISMATCH: CORE="..
                    tostring(signal).." READBACK="..tostring(provider.signalStrength))
            end
        end
    end
    return targets,nil,coarse,mismatch,mismatchReason
end

-- Freeze/re-anchor derivative history without changing a target, baseline,
-- learned trim, or any actuator map. Existing integral values remain bounded
-- and are frozen during suspension, so resumption has no derivative kick or
-- unbounded stale-error accumulation.
-- Summary: Reset recovery measurements to the newly verified physical targets.
local function reanchor(pid,measurement)
    if type(pid)~="table" then return end
    if finite(pid.g and pid.g.integral_limit) and finite(pid.i) then
        local limit=math.max(0,pid.g.integral_limit)
        pid.i=math.max(-limit,math.min(limit,pid.i))
    elseif not finite(pid.i) then pid.i=0 end
    pid.previous=measurement
    pid.d=0
end

-- Summary: Commit verified recovery targets and resume the retained control phase.
function Recovery.complete(flight,io,s,now,actualMaps,actualCoarseTrimApplied)
    local recovery=s.telemetryRecovery
    local suspendedFor=recovery and finite(recovery.since) and math.max(0,now-recovery.since) or 0
    -- Acquisition deadlines and phase timers count active control time only.
    -- A long communications outage must not turn into a timeout on return.
    if suspendedFor>0 then
        if finite(s.startedAt) then s.startedAt=s.startedAt+suspendedFor end
        if finite(s.phaseStartedAt) then s.phaseStartedAt=s.phaseStartedAt+suspendedFor end
        if finite(s.launchStartedAt) and not s.launchComplete then s.launchStartedAt=s.launchStartedAt+suspendedFor end
    end
    local vessel=io and io.vessel or {}
    reanchor(flight.outer,vessel.altitude)
    reanchor(flight.inner,vessel.verticalSpeed)
    local heights={}
    for _,q in ipairs(QUADS) do
        local altitude=io.nodes and io.nodes[q] and io.nodes[q].altitude
        if not altitude or altitude.valid~=true or not finite(altitude.sensorWorldY) then
            heights=nil;break
        end
        heights[q]=altitude.sensorWorldY
    end
    if heights then
        local config=flight.config or {}
        local roll=(heights.FL+heights.BL-heights.FR-heights.BR)/4
        local measuredPitch=(heights.FL+heights.FR-heights.BL-heights.BR)/4
        local deadband=finite(config.trim_deadband_blocks) and math.max(0,config.trim_deadband_blocks) or 0
        if math.abs(roll)<deadband then roll=0 end
        local manualBias=finite(config.manual_fore_aft_trim_blocks) and
            math.max(-2,math.min(2,config.manual_fore_aft_trim_blocks)) or 0
        local pitchTarget=manualBias/2
        local pitchMeasurement=measuredPitch
        local pitchDeadband=deadband
        if manualBias~=0 then pitchDeadband=math.min(pitchDeadband,math.abs(pitchTarget)*0.5) end
        if math.abs(pitchTarget-measuredPitch)<pitchDeadband then pitchMeasurement=pitchTarget end
        reanchor(flight.rollTrim,roll)
        reanchor(flight.pitchTrim,pitchMeasurement)
    else
        reanchor(flight.rollTrim,flight.rollTrim and flight.rollTrim.previous)
        reanchor(flight.pitchTrim,flight.pitchTrim and flight.pitchTrim.previous)
    end
    s.currentTargets=copyMaps(actualMaps or s.currentTargets)
    s.appliedMaps=copyMaps(s.currentTargets)
    s.coarseTrimApplied=copyMaps(actualCoarseTrimApplied or s.coarseTrimApplied)
    s.batchCoarseTrimApplied={}
    s.batchTargets=nil
    s.batchStage=nil
    s.pending=nil
    s.telemetryRecovery=nil
    s.acquisitionPidActive=false
    s.lastSystemsUpdateAt=now
    s.lastControlAt=now
    s.lastPidAt=now
    s.lastTargetCommandAt=now
    s.lastTargetAppliedAt=now
    s.lastAckWaitSeconds=0
    s.lastLiftProgressAt=now
    s.lastLiftRatio=nil
    s.dynamics=nil
    s.responseProbe=nil
    s.liftResponseLagSeconds=nil
    s.fillResponseLagSeconds=nil
    if s.phase=="MAIN_LIFT" then s.hoverSince=nil;s.wideHoverSince=nil end
    return true
end

-- Summary: Retain current operation intent and expose its retry state.
function Recovery.suspend(flight,s,now,reason)
    if not s.telemetryRecovery then
        s.telemetryRecovery={since=now,lastRetryAt=now,retryCount=0,reason=reason,
            resumePhase=s.phase,stage="WAITING_FOR_FRESH_STATUS"}
    else
        s.telemetryRecovery.reason=reason
    end
    s.acquisitionPidActive=false
    s.reason=tostring(reason or "LIFT TELEMETRY UNAVAILABLE")..
        "; RETAINING LAST APPLIED OUTPUTS; WAITING FOR FRESH TELEMETRY"
    flight.reason=s.reason
    flight.systemsSnapshot={active=true,available=false,phase="SUSPENDED",pending=false,
        complete=s.phase=="READY",target=s.target,reason=s.reason,
        warning=s.warning,curve=s.curve,demandProgress=s.demandProgress,
        capacityProgress=s.capacityProgress}
    local recovery=s.telemetryRecovery
    recovery.failed=false
    flight.systemsSnapshot.recovery={state="RETRYING ("..tostring(recovery.attemptCount or 0)..")",
        elapsedSeconds=math.max(0,now-recovery.since),failureAfterSeconds=120,
        retryCount=recovery.attemptCount or 0,reason=reason,background=true,
        resumePhase=recovery.resumePhase,sampleGapDetails=recovery.sampleGapDetails}
    return true,s.reason
end

return Recovery
