local Mathx = require("avionics.mathx")
-- Section: Systems restart | One-shot checkpoints, acknowledgements and retained-run restore.
-- Intentional core/navigator reboot. Chamber computers and lift outputs stay
-- running. A one-shot checkpoint restores intent through telemetry recovery.
local Recovery=require("avionics.telemetry_recovery")
local Anchor=require("avionics.anchor")
local Autopilot=require("avionics.autopilot")
local Restart={}
local QUADS={"FL","FR","BL","BR"}
local function copy(value)
    if type(value)~="table" then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end
    return result
end
local finite = Mathx.finite
local function token(s) return type(s)=="string" and #s>0 and #s<=128 and s:match("^[%w_%.%-:]+$")~=nil end
local function log(reason)
    local logger=os and os.__amaryllisLog
    if type(logger)=="function" then logger("Core systems restart: "..reason,"core.systems.restart")
    else print("Core systems restart: "..reason) end
end
function Restart.new(storage,dependencies,path)
    return setmetatable({storage=storage,dependencies=dependencies or {},
        path=path or "/avionics/data/systems-restart.json"},{__index=Restart})
end
-- Summary: Persist a coordinated-restart checkpoint and return its storage result.
function Restart:write(value)
    local called,ok,reason=pcall(self.storage.writeJson,self.path,value,self.dependencies)
    if not called then return false,tostring(ok) end
    return ok,reason
end
-- Section: Systems restart | One-shot checkpoints, acknowledgements and retained-run restore.
-- Summary: Load and validate a pending one-shot restart checkpoint.
function Restart:load()
    local fsApi=self.dependencies.fs or fs
    if not fsApi or not fsApi.exists(self.path) then return end
    local state,reason=self.storage.readJson(self.path,self.dependencies)
    if not state then self.reason="RESTART CHECKPOINT UNREADABLE: "..tostring(reason);log(self.reason);return end
    if state.pending~=true then return end
    if state.schemaVersion~=1 or not finite(state.coreID) or not token(state.uuid) or
        type(state.controls)~="table" or type(state.controls.targets)~="table" then
        self.reason="RESTART CHECKPOINT INVALID";log(self.reason);return
    end
    self.saved=state;self.reason="WAITING FOR FRESH TELEMETRY AFTER REBOOT"
end
-- Summary: Clear the restart job and persist its inactive checkpoint.
function Restart:cancel(reason)
    local ok,issue=self:write({schemaVersion=1,pending=false})
    self.job=nil;self.saved=nil;self.reason=reason or "RESTART CANCELLED"
    if not ok then log("CHECKPOINT CANCEL FAILED: "..tostring(issue)) end
end
-- Summary: Capture current systems, selections and navigation state for restart.
function Restart:capture(flight,io,now)
    if flight.emergencyLiftLatched then
        local saved,reason=flight:persistEmergencyLock(true)
        if not saved then return nil,"KILL LATCH COULD NOT BE SAVED: "..tostring(reason) end
        -- This reload has no resumable flight checkpoint. Core reloads its
        -- independent durable kill marker; chambers retain their own markers.
        return {schemaVersion=1,pending=false,killLatched=true}
    end
    if flight.shutdownJob or flight.tuningRun or flight.maintenanceJob or flight.startupPending then
        return nil,"SYSTEMS OPERATION IN PROGRESS"
    end
    local controls=flight.controls
    if not controls then return nil,"COCKPIT CONTROL STATE UNAVAILABLE" end
    local selected=controls.targets.altitude
    if not finite(selected) or selected<flight.config.minimum_world_y or selected>flight.config.altitude_ceiling then
        return nil,"SELECTED ALTITUDE UNAVAILABLE / OUT OF LIMITS"
    end
    local run=flight.systemsRun or flight.systemsRetainedRun
    if not run then
        local prepared,reason=flight:systemsPreflight(io,now)
        if not prepared then return nil,reason end
        -- For a restart from STOPPED, seed the checkpoint with verified live provider ceilings.
        local maps={}
        for _,q in ipairs(QUADS) do
            maps[q]={}
            for name,provider in pairs(io.nodes[q].providers) do
                local amount=provider.targetAmount
                local minimum=prepared.limits[q][name].minimum
                if amount<minimum then
                    if provider.controlRole=="fine" and provider.signalStrength==0 then amount=0
                    else return nil,q.." EXISTING GAS TARGET BELOW CONTROL FLOOR" end
                end
                maps[q][name]=amount
            end
        end
        run={phase="READY",providerRoles=prepared.roles,providerLimits=prepared.limits,
            boots=prepared.boots,bindingFingerprints=prepared.bindingFingerprints,
            bindingGenerations=prepared.bindingGenerations,acceptedBootGenerations=prepared.acceptedBootGenerations,
            nodeIDs=prepared.nodeIDs,coreID=io.localID,uuid=prepared.uuid,fingerprint=prepared.fingerprint,
            currentTargets=maps,baseline=copy(maps),coarseTrimApplied={}}
    end
    local retained=run.telemetryRecovery and run.telemetryRecovery.targetMaps or run.batchTargets or run.currentTargets
    if type(retained)~="table" then return nil,"CORE GAS TARGET MAP UNAVAILABLE" end
    local state={schemaVersion=1,pending=true,coreID=io.localID,uuid=run.uuid,
        controls={modes=copy(controls.modes),targets=copy(controls.targets)},run={}}
    for _,key in ipairs({"providerRoles","providerLimits","boots","bindingFingerprints","bindingGenerations",
        "acceptedBootGenerations","nodeIDs","fingerprint","initialGasTarget","coarseTrimApplied",
        "baseline","liftResponseScale","startAltitude"}) do state.run[key]=copy(run[key]) end
    state.run.phase=run.phase=="MAIN_LIFT" and "MAIN_LIFT" or "READY"
    state.run.currentTargets=copy(retained)
    state.run.baseline=copy(run.baseline or flight.baseline or retained)
    state.run.coarseTrimApplied=copy(run.telemetryRecovery and run.telemetryRecovery.coarseTrimApplied or
        (run.batchTargets and run.batchCoarseTrimApplied) or run.coarseTrimApplied or {})
    state.trim=copy(flight.trim);state.coarseSteamTrim=copy(flight.coarseSteamTrim)
    state.coarseSteamTrimIntegral=copy(flight.coarseSteamTrimIntegral)
    state.coarseSteamTrimEngaged=copy(flight.coarseSteamTrimEngaged)
    state.integrals={outer=flight.outer.i,inner=flight.inner.i,
        roll=flight.rollTrim and flight.rollTrim.i,pitch=flight.pitchTrim and flight.pitchTrim.i}
    state.anchor=io.positionAnchor and io.positionAnchor:checkpoint() or nil
    state.autopilot=io.autopilot and io.autopilot:checkpoint() or nil
    return state
end
-- Summary: Save the restart checkpoint and request the navigator restart handshake.
function Restart:request(flight,io,now)
    if self.job or self.saved then return false,"SYSTEMS RESTART ALREADY IN PROGRESS" end
    local state,reason=self:capture(flight,io,now)
    if not state then return false,reason end
    local entry=io.computers and io.computers.navigator
    if not entry or entry.id~=io.config.bridge_id or not token(flight.bridgeBoot) then
        return false,"NAVIGATOR RESTART IDENTITY UNAVAILABLE"
    end
    local ok,issue=self:write(state)
    if not ok then return false,"RESTART STATE COULD NOT BE SAVED: "..tostring(issue) end
    self.job={since=now,nextSend=now,session=io.session,bridgeID=entry.id,bridgeLabel=entry.label,
        bridgeBoot=flight.bridgeBoot,requestId=io.session..":restart:"..tostring(flight.lastRequestSeq),
        bootToken=io.session,acknowledged=false,killLatched=state.killLatched==true}
    self.reason=state.killLatched and "RESTARTING; LIFT KILL REMAINS ARMED" or "RESTARTING NAVIGATOR; LIFT CONTROL RETAINED"
    log(self.reason)
    return true,self.reason
end
-- Summary: Validate the navigator acknowledgement for the pending restart.
function Restart:ack(sender,message,protocol,io)
    local job=self.job
    if not job or sender~=job.bridgeID or protocol~=io.config.protocol or type(message)~="table" or
        message.v~=1 or message.kind~="system_restart_ack" or message.session~=job.session or
        message.nodeBoot~=job.bridgeBoot or message.targetLabel~=job.bridgeLabel or
        message.requestId~=job.requestId or message.bootToken~=job.bootToken or message.accepted~=true then return false end
    job.acknowledged=true;return true
end
-- Summary: Advance restart handshakes and reboot core after their guards succeed.
function Restart:tick(flight,io,now,reboot)
    local job=self.job;if not job then return end
    if (flight.emergencyLiftLatched and not job.killLatched) or
        (job.killLatched and not flight.emergencyLiftLatched) or flight.shutdownJob then
        self:cancel("RESTART CANCELLED BY STOP");return
    end
    -- STOP stays available while restarting. Keep the current core alive
    -- until its shutdown confirmation is accepted, cancelled or expires.
    if flight.stopReview then return end
    -- An ACK can be lost after the navigator has already rebooted. A fresh
    -- authenticated subsystem report with a new boot also confirms restart.
    local report=io.subsystemReports and io.subsystemReports[job.bridgeID]
    if report and token(report.boot) and report.boot~=job.bridgeBoot and finite(report.at) and
        now>=report.at and now-report.at<=io.config.network.node_stale_seconds then job.acknowledged=true end
    if job.acknowledged then
        if job.nextSave and now<job.nextSave then return end
        job.nextSave=now+1.5
        -- Capture again immediately before reboot: the running PID and pilot
        -- may have changed targets while the navigator was acknowledging.
        local state,reason=self:capture(flight,io,now)
        local ok,issue=false,reason
        if state then ok,issue=self:write(state) end
        if not ok then
            self.reason="CORE REBOOT BLOCKED: "..tostring(issue)
            if self.logged~=self.reason then log(self.reason);self.logged=self.reason end
            return
        end
        if self.job~=job or (job.killLatched and not flight.emergencyLiftLatched) then return end
        self.reason=job.killLatched and "REBOOTING CORE; LIFT KILL REMAINS ARMED" or "REBOOTING CORE; CHAMBERS HOLD EXISTING GAS";log(self.reason)
        reboot();return
    end
    if now>=job.nextSend then
        job.nextSend=now+1.5
        local ok,result=pcall(io.rednet.send,job.bridgeID,{v=1,kind="system_restart",session=job.session,
            nodeBoot=job.bridgeBoot,targetLabel=job.bridgeLabel,requestId=job.requestId,bootToken=job.bootToken},io.config.protocol)
        if not ok or result~=true then self.reason="NAVIGATOR RESTART SEND FAILED; RETRYING"
        elseif now-job.since>=120 then self.reason="NAVIGATOR RESTART UNCONFIRMED AFTER 120 SECONDS; RETRYING" end
        if now-job.since>=120 then log(self.reason) end
    end
end
-- Summary: Revalidate fresh vessel data and restore retained systems through recovery.
function Restart:restore(flight,io,now)
    local state=self.saved;if not state then return false end
    -- Summary: Record the current restore prerequisite and retry it on a later update.
    local function wait(reason)
        self.reason=reason
        self.since=self.since or now
        if now-self.since>=120 then
            self.reason="RESTART RECOVERY FAILED AFTER 120 SECONDS: "..reason.."; RETRYING"
        end
        if self.logged~=self.reason then log(self.reason);self.logged=self.reason end
        return false
    end
    if flight.emergencyLiftLatched then
        self:write({schemaVersion=1,pending=false});self.saved=nil
        self.reason="RESTART BLOCKED BY EMERGENCY LIFT KILL";log(self.reason);return false
    end
    if io.identityReady~=true or io.localID~=state.coreID then return wait("CORE IDENTITY UNVERIFIED / CHANGED") end
    local assembled,why=flight.assemblyGate(io,now)
    if not assembled then return wait(why or "VESSEL ASSEMBLY UNAVAILABLE") end
    local vessel=io.vessel or {}
    if vessel.valid~=true or not finite(vessel.at) or now<vessel.at or
        now-vessel.at>io.config.network.sensor_stale_seconds then return wait("VESSEL TELEMETRY STALE") end
    if vessel.uuid~=state.uuid then return wait("VESSEL IDENTITY CHANGED") end
    -- Cockpit levers are not needed to restore lift control, and the control
    -- state is deliberately not updated while a restart is pending; waiting
    -- on it here deadlocked the restore. Saved modes are applied below.
    local s=copy(state.run)
    -- Resume durable snapshots saved before phases were renamed:
    -- HOLDING became READY, BUILDING_LIFT became MAIN_LIFT and CONTROL_START became VENT_IGNITION.
    local renamedPhases={HOLDING="READY",BUILDING_LIFT="MAIN_LIFT",CONTROL_START="VENT_IGNITION"}
    if type(s)=="table" and renamedPhases[s.phase] then s.phase=renamedPhases[s.phase] end
    -- Snapshots saved before the rear chambers were renamed key them RL and RR; they are BL and BR.
    if type(s)=="table" then
        for _,value in pairs(s) do
            if type(value)=="table" then
                for old,new in pairs({RL="BL",RR="BR"}) do
                    if value[old]~=nil and value[new]==nil then value[new]=value[old];value[old]=nil end
                end
            end
        end
    end
    if type(s)~="table" or type(s.currentTargets)~="table" or type(s.boots)~="table" or
        type(s.providerRoles)~="table" or type(s.providerLimits)~="table" or type(s.nodeIDs)~="table" then
        return wait("RESTART GAS / HARDWARE STATE INVALID")
    end
    local modes=state.controls.modes
    if type(modes)~="table" or (modes.heading~="MANUAL" and modes.heading~="SEL") or
        (modes.throttle~="MANUAL" and modes.throttle~="SEL" and modes.throttle~="DIRECT") then
        return wait("SAVED COCKPIT MODES INVALID")
    end
    if io.hardwareFingerprint~=s.fingerprint then return wait("CORE SENSOR BINDINGS CHANGED") end
    for _,q in ipairs(QUADS) do
        if not token(s.boots[q]) or type(s.providerRoles[q])~="table" or
            type(s.providerLimits[q])~="table" or type(s.currentTargets[q])~="table" or
            type(s.baseline)~="table" or type(s.baseline[q])~="table" then
            return wait(q.." SAVED PROVIDER STATE INVALID")
        end
        local count=0
        for name,role in pairs(s.providerRoles[q]) do
            count=count+1
            local bound=s.providerLimits[q][name]
            local target=s.currentTargets[q][name]
            local baseline=s.baseline[q][name]
            if (role~="bulk" and role~="fine") or type(bound)~="table" or
                not finite(bound.minimum) or not finite(bound.maximum) or not finite(target) or
                not finite(baseline) or target>bound.maximum or baseline>bound.maximum or
                target<(role=="fine" and 0 or bound.minimum) or baseline<(role=="fine" and 0 or bound.minimum) then
                return wait(q.." SAVED GAS TARGET OUT OF LIMITS")
            end
        end
        local node=io.nodes[q]
        if not node or not io:nodeFresh(q,now) then return wait(q.." LIFT TELEMETRY STALE") end
        if count~=(node.steamCount or 8)+1 then return wait(q.." SAVED PROVIDER STATE INCOMPLETE") end
        if io.config.node_ids[q]~=s.nodeIDs[q] then return wait(q.." REGISTERED COMPUTER CHANGED") end
        if not io.nodes[q] or not io:nodeFresh(q,now) then return wait(q.." LIFT TELEMETRY STALE") end
        if io.nodes[q].emergencyStopLatched then return wait(q.." EMERGENCY LIFT KILL LATCHED") end
    end
    s.uuid=state.uuid;s.coreID=io.localID;s.coreSession=io.session
    s.target=state.controls.targets.altitude
    -- A saved target above the ceiling (the ceiling was lowered) is lowered to it.
    if finite(s.target) and s.target>flight.config.altitude_ceiling then s.target=flight.config.altitude_ceiling end
    if not finite(s.target) or s.target<flight.config.minimum_world_y then
        return wait("SAVED ALTITUDE OUT OF LIMITS")
    end
    s.startedAt=now;s.phaseStartedAt=now;s.lastSystemsUpdateAt=now;s.lastControlAt=now;s.lastPidAt=now
    s.lastTargetCommandAt=now;s.lastTargetAppliedAt=now;s.lastLiftProgressAt=now;s.acquisitionTimeout=86400
    s.launchComplete=true;s.launchDurationSeconds=0;s.acquisitionPidActive=false
    Recovery.suspend(flight,s,now,"VERIFYING RETAINED TARGETS AFTER CORE REBOOT")
    s.telemetryRecovery.targetMaps=copy(s.currentTargets)
    s.telemetryRecovery.coarseTrimApplied=copy(s.coarseTrimApplied or {})
    -- Existing guards verify unchanged bindings, recipient boots and provider
    -- limits before the recovery worker can send its first command.
    local good,reason=flight:systemsGuard(io,now,s,true,true)
    if not good and not Recovery.isTransientGuardFault(io,s,now,reason,flight) then return wait(reason) end
    local ok,issue=self:write({schemaVersion=1,pending=false})
    if not ok then return wait("CHECKPOINT COULD NOT BE CONSUMED: "..tostring(issue)) end
    local controls=flight.controls
    controls.modes=copy(state.controls.modes);controls.targets=copy(state.controls.targets)
    if state.anchor then
        io.positionAnchor=io.positionAnchor or Anchor.new(io.config)
        if not io.positionAnchor:restore(state.anchor) then log("INVALID ANCHOR CHECKPOINT; ANCHOR NOT RESTORED") end
    end
    if state.autopilot then
        io.autopilot=io.autopilot or Autopilot.new(io.config,self.storage,io.navigationDependencies)
        if not io.autopilot:restore(state.autopilot) then log("INVALID AUTOPILOT CHECKPOINT; ROUTE NOT RESTORED") end
    end
    controls.uuid=state.uuid;controls.headingTargetUuid=state.uuid;controls.speedTargetUuid=state.uuid
    controls.linkBinding=io.inventory and io.inventory.linkBridge
    controls.lastSample=nil;controls.holds={}
    if type(controls.noteHandover)=="function" then controls:noteHandover() end
    flight.systemsRun=s;flight.enabled=true;flight.target=s.target;flight.baseline=copy(s.baseline)
    flight:resetTrim()
    flight.trim=copy(state.trim or flight.trim)
    flight.coarseSteamTrim=copy(state.coarseSteamTrim or flight.coarseSteamTrim)
    flight.coarseSteamTrimIntegral=copy(state.coarseSteamTrimIntegral or flight.coarseSteamTrimIntegral)
    flight.coarseSteamTrimEngaged=copy(state.coarseSteamTrimEngaged or flight.coarseSteamTrimEngaged)
    local integral=state.integrals or {}
    for name,pid in pairs({outer=flight.outer,inner=flight.inner,roll=flight.rollTrim,pitch=flight.pitchTrim}) do
        if finite(integral[name]) then pid.i=math.max(-pid.g.integral_limit,math.min(pid.g.integral_limit,integral[name])) end
    end
    flight.outer.previous=vessel.altitude;flight.outer.d=0
    flight.inner.previous=vessel.verticalSpeed;flight.inner.d=0
    self.saved=nil;self.reason="CORE RESTORED; RESLAVING CHAMBERS WITHOUT STARTUP BOOST";log(self.reason)
    return true
end
return Restart
