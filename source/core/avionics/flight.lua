-- @ama-section: Altitude authority | Startup, retained lift, PID demand and operator lifecycle.
-- Vessel association adoption v1
-- Navigator information startup revision v1
-- Recoverable vessel telemetry v1
-- Recoverable lift handshake v1
local function steamCount(node) return node and node.steamCount or 8 end
-- Altitude authority lives on core. CoM Y -> requested vertical speed ->
-- fractional gas-feed correction. Composition is a measured prerequisite and
-- baseline record, not an invented steam/hot-air lift coefficient. Capture a
-- quiet hover to learn current equilibrium feed, then regulate its change.
-- Bulk vents carry altitude demand; the burner carries small section trim.
local PID=require("avionics.pid")
local Controls=require("avionics.controls")
local TelemetryRecovery=require("avionics.telemetry_recovery")
local Anchor=require("avionics.anchor")
local Autopilot=require("avionics.autopilot")
local Flight={}
local QUADS={"FL","FR","RL","RR"}
local EMERGENCY_LIFT_KILL_ATTEMPTS=4
local EMERGENCY_LIFT_KILL_RETRY_SECONDS=1.5
local EMERGENCY_LIFT_KILL_DISCOVERY_SECONDS=30
local EMERGENCY_LIFT_KILL_QUADRANTS={"FL","FR","RL","RR"}
local MANUAL_TRIM_MIN=-2
local MANUAL_TRIM_MAX=2
local MANUAL_TRIM_STEPS={0.1,0.5}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function clamp(n,a,b) return math.max(a,math.min(b,n)) end
local function boundedBindingFingerprint(value)
    return type(value)=="string" and #value>0 and #value<=1024 and not value:find("[%c]")
end
local function logText(value,limit)
    return tostring(value or ""):gsub("[%c]"," "):sub(1,limit or 160)
end
-- @ama-section: Flight lifecycle | Operator actions, runtime gates and cached presentation.
-- @ama-summary: Write a bounded event to the core log with its operation scope.
local function emitCoreLog(message,key)
    local logger=type(os)=="table" and os.__amaryllisLog or nil
    if type(logger)=="function" then
        local ok,recorded=pcall(logger,message,key)
        if ok and recorded==true then return true end
    end
    print(message)
    return false
end
local function issueScope(component,operation)
    return component..":"..operation
end
-- @ama-summary: Record the active issue for a flight-operation scope.
local function logOperationIssue(self,component,operation,reason,details)
    reason=logText(reason,160)
    if reason=="" then return false end
    self.coreLogIssues=self.coreLogIssues or {}
    local scope=issueScope(component,operation)
    if self.coreLogIssues[scope]==reason then return false end
    self.coreLogIssues[scope]=reason
    self.coreLogHistory=self.coreLogHistory or {}
    self.coreLogHistory[scope]=true
    local message="Core "..component.." "..operation..": "..reason
    if details then message=message.." ("..logText(details,160)..")" end
    message=logText(message,240)
    local key=logText("core."..component.."."..operation..":"..reason,240)
    return emitCoreLog(message,key)
end
-- @ama-summary: Clear the recovered operation issue and record its recovery message.
local function clearOperationIssue(self,component,operation,message)
    local scope=issueScope(component,operation)
    local active=self.coreLogIssues and self.coreLogIssues[scope]
    local seen=self.coreLogHistory and self.coreLogHistory[scope]
    if not active and not seen then return false end
    if self.coreLogIssues then self.coreLogIssues[scope]=nil end
    if self.coreLogHistory then self.coreLogHistory[scope]=nil end
    return emitCoreLog(logText(message or ("Core "..component.." "..operation.." recovered"),240),
        "core."..component.."."..operation..":recovered")
end
-- @ama-section: Recovery | Physical target reconciliation and retained-run resumption.
-- @ama-summary: Record a change in the current systems telemetry-recovery state.
local function logSystemsTelemetryRecovery(self,reason,recovered)
    local scope=issueScope("flight","systems telemetry recovery")
    self.coreLogIssues=self.coreLogIssues or {}
    if recovered then
        local wasActive=self.coreLogIssues[scope]~=nil
        self.coreLogIssues[scope]=nil
        if wasActive then
            return emitCoreLog("Core flight systems telemetry recovered; existing operation resumed",
                "core.flight.systems.telemetry_recovery")
        end
        return false
    end
    reason=logText(reason or "LIFT TELEMETRY UNAVAILABLE",160)
    if reason=="" or self.coreLogIssues[scope]==reason then return false end
    self.coreLogIssues[scope]=reason
    return emitCoreLog("Core flight systems telemetry recovery: "..reason..
        "; retaining last applied outputs and retrying",
        "core.flight.systems.telemetry_recovery")
end
local function diagnosticNumber(value)
    return finite(value) and string.format("%.6g",value) or nil
end
-- @ama-section: Systems control | Startup, measured dynamics and bounded provider demand.
-- @ama-summary: Format the retained abort measurements and guard details for diagnostics.
local function systemsAbortText(details)
    if type(details)~="table" then return nil end
    local parts={}
    for _,field in ipairs({{"target","target Y"},{"actualWorldY","actual world Y"},
        {"verticalSpeed","vertical speed"},{"verticalSpeedLimit","vertical speed limit"},
        {"elapsedSeconds","runtime gap seconds"},
        {"sampleGapLimitSeconds","runtime gap limit seconds"},
        {"pendingAckSeconds","pending ACK wait seconds"},{"lastUpdateAt","last update"},
        {"lastControlAt","last control sample"},{"lastPidAt","last PID sample"},
        {"lastTargetCommandAt","last target command"}}) do
        local value=diagnosticNumber(details[field[1]])
        if value then parts[#parts+1]=field[2].."="..value end
    end
    if type(details.phase)=="string" then parts[#parts+1]="phase="..logText(details.phase,32) end
    return #parts>0 and table.concat(parts,"; ") or nil
end
-- @ama-section: Emergency lift | Latched operator shutdown and verified disarm.
-- @ama-summary: Collect chamber verification details for an incomplete emergency shutdown.
local function emergencyKillFailureDetails(job)
    local parts={}
    for _,q in ipairs(EMERGENCY_LIFT_KILL_QUADRANTS) do
        local item=job.quadrants[q]
        if item and item.status=="FAILED" then
            parts[#parts+1]=q..": "..logText(item.ackReason or "KILL NOT VERIFIED",72)
        end
    end
    return #parts>0 and table.concat(parts,"; ") or nil
end
local function airPressure(v)
    local p=v.environment and v.environment.airPressure
    return finite(p) and p>0 and p or nil
end
-- @ama-section: Persistent learning | Validated calibration and retained operating records.
-- @ama-summary: Resolve the configured activation level for a provider role.
local function configuredProviderStrength(config,provider)
    local strengths=config.verified_gas_lift_strengths or {}
    if provider.gasTypeValid and type(provider.gasType)=="string" then return strengths[provider.gasType] end
    -- An OFF provider is blind. Capacity planning can use its verified role's
    -- configured gas model without claiming a live gas-type measurement.
    if provider.present and provider.writable and provider.signalValid and finite(provider.signalStrength) and provider.signalStrength<=1 then
        if provider.controlRole=="bulk" then return strengths.steam end
        if provider.controlRole=="fine" then return strengths.default end
    end
end
-- @ama-section: Flight lifecycle | Operator actions, runtime gates and cached presentation.
-- @ama-summary: Construct altitude-control state, PID loops and runtime operation records from configuration.
function Flight.new(config)
    local c=config.altitude_control
    if config.thrust and config.thrust.primary_max_rpm==nil then
        config.thrust.primary_max_rpm=math.max(1,math.floor((config.thrust.direct_max_request or .25)*256+.5))
    end
    if c and c.startup_gas_target_m3_per_chamber==nil then
        -- Schema-1 installations without the optional startup seed retain
        -- minimum-floor startup exactly as before.
        c.startup_gas_target_m3_per_chamber=0
    end
    if c and c.launch_settle_seconds==nil then c.launch_settle_seconds=10 end
    if c and c.manual_fore_aft_trim_blocks==nil then
        -- Preserve older config files while giving manual trim a durable,
        -- neutral target in the same core JSON document.
        c.manual_fore_aft_trim_blocks=0
    end
    if c and not c.trim_pid then
        -- Existing JSON installations gain trim learning without losing any
        -- user-set altitude gains, ceiling limits or slew limits.
        c.trim_pid={ki=0.25,kd=1,integral_limit=100,derivative_filter_seconds=2}
    end
    return setmetatable({config=c,enabled=false,reason="NOT ENGAGED",lastRequestSeq=0,
        controls=config.cockpit and Controls.new(config),
        outer=c and PID.new(c.altitude_pid),inner=c and PID.new(c.vertical_speed_pid)}, {__index=Flight})
end
-- @ama-section: Emergency lift | Latched operator shutdown and verified disarm.
-- @ama-summary: Load the persisted Kill Lift latch and prepare its verification state.
function Flight:configureEmergencyLock(storage,dependencies,path)
    self.emergencyLockStorage=storage
    self.emergencyLockDependencies=dependencies or {}
    self.emergencyLockPath=path or "/avionics/data/emergency-lift-lock.json"
    local fsApi=self.emergencyLockDependencies.fs or fs
    if type(fsApi)~="table" or type(fsApi.exists)~="function" or
        type(storage)~="table" or type(storage.readJson)~="function" then
        self.emergencyLiftLatched=true
        self.emergencyLiftPersistenceWarning="EMERGENCY LOCK FILE STATUS UNAVAILABLE; START SYSTEMS REQUIRED"
    else
        local ok,exists=pcall(fsApi.exists,self.emergencyLockPath)
        if not ok then
            self.emergencyLiftLatched=true
            self.emergencyLiftPersistenceWarning="EMERGENCY LOCK FILE CHECK FAILED: "..tostring(exists)
        elseif exists then
            local readOk,state,reason=pcall(storage.readJson,self.emergencyLockPath,self.emergencyLockDependencies)
            if readOk and type(state)=="table" and state.schemaVersion==1 and type(state.latched)=="boolean" then
                self.emergencyLiftLatched=state.latched
            else
                self.emergencyLiftLatched=true
                self.emergencyLiftPersistenceWarning="EMERGENCY LOCK FILE INVALID; FAILING CLOSED: "..tostring(readOk and reason or state)
            end
        else
            self.emergencyLiftLatched=false
        end
    end
    if self.emergencyLiftLatched then
        self.emergencyLiftJob={recovering=true,complete=false,pending=true,phase="RECHECKING AFTER REBOOT",
            reason="Rechecking fresh chamber status; no automatic actuator command was sent",quadrants={}}
        for _,q in ipairs(EMERGENCY_LIFT_KILL_QUADRANTS) do
            self.emergencyLiftJob.quadrants[q]={status="WAITING_FOR_FRESH_NODE",attempts=0,
                ackReason="Waiting for fresh BULK OFF / PROBE ON readback; press KILL LIFT to reassert if needed"}
        end
    end
end
-- Level memory: the steam differential that held the ship level last time
-- is saved and used as the starting split for the next launch, so a fixed
-- weight imbalance does not have to be rediscovered by pitching first.
-- @ama-section: Leveling | Chamber-height feedback and retained trim allocation.
-- @ama-summary: Load the stored leveling bias and its persistence dependencies.
function Flight:configureLevelMemory(storage,dependencies,path)
    self.levelStorage=storage
    self.levelDependencies=dependencies or {}
    self.levelPath=path or "/avionics/data/level-bias.json"
    self.levelBias=nil
    if type(storage)~="table" or type(storage.readJson)~="function" then return end
    local fsApi=self.levelDependencies.fs or fs
    local okExists,exists=pcall(fsApi.exists,self.levelPath)
    if not okExists or not exists then return end
    local ok,state=pcall(storage.readJson,self.levelPath,self.levelDependencies)
    if ok and type(state)=="table" and state.schemaVersion==1 and finite(state.roll) and finite(state.pitch) and
        math.abs(state.roll)<=10000 and math.abs(state.pitch)<=10000 then
        self.levelBias={roll=state.roll,pitch=state.pitch}
    end
end
-- Hover correction memory. The lift model's hover support is a few percent
-- off and the error depends on height (logged ~4.8% near Y 144). The HOLD
-- speed integral learns it each flight; remember it per 20-block band so a
-- new hold starts from it instead of relearning during the approach.
local HOVER_BAND_BLOCKS=20
local function hoverBandKey(altitude) return tostring(math.floor(altitude/HOVER_BAND_BLOCKS)*HOVER_BAND_BLOCKS) end
-- @ama-section: Persistent learning | Validated calibration and retained operating records.
-- @ama-summary: Load learned hover offsets and configure their persistence.
function Flight:configureHoverMemory(storage,dependencies,path)
    self.hoverStorage=storage
    self.hoverDependencies=dependencies or {}
    self.hoverPath=path or "/avionics/data/hover-offset.json"
    self.hoverOffsets={}
    if type(storage)~="table" or type(storage.readJson)~="function" then return end
    local fsApi=self.hoverDependencies.fs or fs
    local okExists,exists=pcall(fsApi.exists,self.hoverPath)
    if not okExists or not exists then return end
    local ok,state=pcall(storage.readJson,self.hoverPath,self.hoverDependencies)
    if ok and type(state)=="table" and state.schemaVersion==1 and type(state.bands)=="table" then
        for key,entry in pairs(state.bands) do
            if tonumber(key) and type(entry)=="table" and finite(entry.offset) and math.abs(entry.offset)<=0.15 then
                self.hoverOffsets[tostring(key)]={offset=entry.offset,samples=finite(entry.samples) and entry.samples or 1}
            end
        end
    end
end
-- @ama-summary: Interpolate the learned hover offset for the current altitude.
function Flight:learnedHoverOffset(altitude)
    if not finite(altitude) or type(self.hoverOffsets)~="table" then return nil end
    local key=hoverBandKey(altitude)
    if self.hoverOffsets[key] then return self.hoverOffsets[key].offset end
    local best,bestDistance
    for band,entry in pairs(self.hoverOffsets) do
        local distance=math.abs(tonumber(band)-tonumber(key))
        if distance<=2*HOVER_BAND_BLOCKS and (not bestDistance or distance<bestDistance) then
            best,bestDistance=entry.offset,distance
        end
    end
    return best
end
-- @ama-summary: Apply the learned hover offset to the altitude-control baseline.
function Flight:seedHoverOffset(altitude)
    local offset=self:learnedHoverOffset(altitude)
    local g=self.inner and self.inner.g
    if not offset or not g or not finite(g.ki) or g.ki<=0 then return end
    local limit=finite(g.integral_limit) and g.integral_limit or 0
    self.inner.i=clamp(offset/g.ki,-limit,limit)
    self.hoverOffsetSeeded=offset
end
-- @ama-summary: Update learned hover offsets from stable measured hover conditions.
function Flight:rememberHoverOffset(v,s,actualRatio,now)
    local g=self.inner and self.inner.g
    local settled=s.phase=="READY" and finite(v.altitude) and finite(v.verticalSpeed) and
        math.abs(v.verticalSpeed)<=0.05 and finite(s.target) and math.abs(s.target-v.altitude)<=1.5 and
        finite(actualRatio) and finite(s.lastDesiredRatio) and math.abs(actualRatio-s.lastDesiredRatio)<=0.005 and
        g and finite(g.ki) and g.ki>0 and finite(self.inner.i)
    if not settled then self.hoverSettledSince=nil;return end
    self.hoverSettledSince=self.hoverSettledSince or now
    if now-self.hoverSettledSince<15 then return end
    local learned=clamp(g.ki*self.inner.i,-0.15,0.15)
    self.hoverOffsets=self.hoverOffsets or {}
    local key=hoverBandKey(v.altitude)
    local entry=self.hoverOffsets[key]
    if entry then entry.offset=entry.offset*0.7+learned*0.3;entry.samples=math.min(1000,(entry.samples or 1)+1)
    else self.hoverOffsets[key]={offset=learned,samples=1} end
    if self.hoverSavedAt and now-self.hoverSavedAt<30 then return end
    self.hoverSavedAt=now
    local storage=self.hoverStorage
    if type(storage)=="table" and type(storage.writeJson)=="function" then
        pcall(storage.writeJson,self.hoverPath or "/avionics/data/hover-offset.json",
            {schemaVersion=1,bandBlocks=HOVER_BAND_BLOCKS,bands=self.hoverOffsets},self.hoverDependencies)
    end
end
function Flight:seedLevelBias()
    local bias=self.levelBias
    if type(bias)~="table" then return end
    self.coarseSteamTrim={roll=bias.roll,pitch=bias.pitch}
    self.coarseSteamTrimIntegral={roll=bias.roll,pitch=bias.pitch}
    self.coarseSteamTrimEngaged={roll=bias.roll~=0,pitch=bias.pitch~=0}
end
-- @ama-section: Leveling | Chamber-height feedback and retained trim allocation.
-- @ama-summary: Persist the current leveling bias at the configured save cadence.
function Flight:rememberLevelBias(now,force)
    local trim=self.coarseSteamTrim
    if not trim or not finite(trim.roll) or not finite(trim.pitch) then return end
    local last=self.levelBiasSaved
    if not force and last and finite(now) and now-last.at<60 then return end
    if last and math.abs(last.roll-trim.roll)<1 and math.abs(last.pitch-trim.pitch)<1 then return end
    self.levelBias={roll=trim.roll,pitch=trim.pitch}
    self.levelBiasSaved={roll=trim.roll,pitch=trim.pitch,at=finite(now) and now or 0}
    local write=self.levelStorage and self.levelStorage.writeJson
    if type(write)=="function" then
        pcall(write,self.levelPath,{schemaVersion=1,roll=trim.roll,pitch=trim.pitch},self.levelDependencies)
    end
end
-- @ama-section: Emergency lift | Latched operator shutdown and verified disarm.
-- @ama-summary: Write the accepted Kill Lift latch to its persistent record.
function Flight:persistEmergencyLock(latched)
    if not self.emergencyLockStorage then return true end
    local write=self.emergencyLockStorage.writeJson
    if type(write)~="function" then
        self.emergencyLiftPersistenceWarning="EMERGENCY LOCK STORAGE UNAVAILABLE"
        return false,self.emergencyLiftPersistenceWarning
    end
    local callOk,ok,reason=pcall(write,self.emergencyLockPath,{schemaVersion=1,latched=latched==true},
        self.emergencyLockDependencies)
    if not callOk or not ok then
        if not callOk then reason=ok end
        self.emergencyLiftPersistenceWarning="EMERGENCY LOCK PERSISTENCE FAILED: "..tostring(reason)
        return false,self.emergencyLiftPersistenceWarning
    end
    self.emergencyLiftPersistenceWarning=nil
    return true
end

-- @ama-section: Leveling | Chamber-height feedback and retained trim allocation.
-- @ama-summary: Reset trim PID state and optionally retain the coarse trim allocation.
function Flight:resetTrim(preserveCoarse)
    local c=self.config
    local g={kp=c.trim_ceiling_per_block,ki=c.trim_pid.ki,kd=c.trim_pid.kd,
        integral_limit=c.trim_pid.integral_limit,derivative_filter_seconds=c.trim_pid.derivative_filter_seconds}
    self.rollTrim=PID.new(g);self.pitchTrim=PID.new(g)
    self.trim={FL=0,FR=0,RL=0,RR=0};self.trimStatus=nil;self.levelRates=nil
    if not preserveCoarse then
        self.coarseSteamTrim={roll=0,pitch=0}
        self.coarseSteamTrimIntegral={roll=0,pitch=0}
        self.coarseSteamTrimEngaged={roll=false,pitch=false}
    end
end

-- Height differences are in world blocks, not angles. Symmetric axis mixing
-- avoids learning four unrelated integrals and distinguishes roll from pitch.
-- The altitude PID absorbs any common lift added by clipping at probe floors.
-- @ama-summary: Check that chamber observations are aligned closely enough for trim calculations.
function Flight:coarseTrimSamplesAligned(io,now)
    local oldest,latest
    for _,q in ipairs(QUADS) do
        local node=io.nodes and io.nodes[q]
        local at=node and node.lastSeen
        if not finite(at) then return false,"STEAM TRIM SENSOR TIME UNAVAILABLE" end
        if type(io.nodeFresh)=="function" and finite(now) and not io:nodeFresh(q,now) then
            return false,"STEAM TRIM SENSOR STALE"
        end
        oldest=not oldest and at or math.min(oldest,at)
        latest=not latest and at or math.max(latest,at)
    end
    local sample=io.config and io.config.network and io.config.network.sample_interval_seconds or 0.5
    local maxSkew=math.max(1,finite(sample) and sample*2 or 1)
    if latest-oldest>maxSkew then return false,"STEAM TRIM SENSOR SKEW" end
    return true
end

-- @ama-summary: Compute bounded roll and pitch corrections from chamber heights and the selected trim bias.
function Flight:updateTrim(io,baseline,dt,slewDt,now)
    if not self.rollTrim then self:resetTrim() end
    -- While still resting on the ground, the measured tilt is the terrain
    -- and landing gear, not a lift imbalance. Leveling against it loads one
    -- end with extra lift that flips the ship the moment it lifts off.
    -- Until 1 block above the start height, hold the learned split.
    local run=self.systemsRun
    if run and not run.airborne then
        local v=io.vessel
        if v and finite(v.altitude) then
            run.groundAltitude=run.groundAltitude or v.altitude
            local ratio=run.dynamics and run.dynamics.actualRatio
            -- Lift carrying nearly all the weight also means the ground no
            -- longer holds the hull's attitude.
            if v.altitude>=run.groundAltitude+1 or (finite(ratio) and ratio>=0.97) then
                run.airborne=true;self.levelRates=nil
            end
        end
        if not run.airborne then
            local trim=self.coarseSteamTrim or {roll=0,pitch=0}
            self.trimStatus={active=true,grounded=true,reason="ON GROUND: HOLDING LEARNED LEVEL SPLIT",
                fineAuthorityLimited=false,authorityLimited=false,levelIndicated=false,
                coarseSteamTrimRoll=trim.roll,coarseSteamTrimPitch=trim.pitch,
                coarseSteamTrimActive=false,coarseSteamTrimLimited=false,
                rollIntegral=self.rollTrim.i,pitchIntegral=self.pitchTrim.i}
            return true
        end
    end
    local c=self.config;local y={}
    for _,q in ipairs(QUADS) do
        y[q]=io.nodes[q].altitude.sensorWorldY
        if not finite(y[q]) then return nil,"SECTION ALTITUDE UNAVAILABLE" end
    end
    local roll=(y.FL+y.RL-y.FR-y.RR)/4
    local measuredRoll=roll
    local measuredPitch=(y.FL+y.FR-y.RL-y.RR)/4
    local manualBias=finite(c.manual_fore_aft_trim_blocks) and
        clamp(c.manual_fore_aft_trim_blocks,MANUAL_TRIM_MIN,MANUAL_TRIM_MAX) or 0
    -- Existing pitch error is half the measured fore/aft average-height
    -- difference. A bow-up world-block target therefore maps to bias / 2.
    local pitchTarget=manualBias/2
    local leveledHeights={FL=y.FL-manualBias/2,FR=y.FR-manualBias/2,
        RL=y.RL+manualBias/2,RR=y.RR+manualBias/2}
    local lowest,highest
    for _,q in ipairs(QUADS) do
        lowest=not lowest and leveledHeights[q] or math.min(lowest,leveledHeights[q])
        highest=not highest and leveledHeights[q] or math.max(highest,leveledHeights[q])
    end
    local levelSpread=highest-lowest
    local levelTolerance=0.5
    local pitchControlMeasurement=measuredPitch
    local pitchDeadband=c.trim_deadband_blocks
    if manualBias~=0 then pitchDeadband=math.min(pitchDeadband,math.abs(pitchTarget)*0.5) end
    if math.abs(pitchTarget-measuredPitch)<pitchDeadband then pitchControlMeasurement=pitchTarget end
    if math.abs(roll)<c.trim_deadband_blocks then roll=0 end
    local oldRoll,oldPitch=self.rollTrim.i,self.pitchTrim.i
    local g=self.rollTrim.g;g.kp=c.trim_ceiling_per_block
    for key,value in pairs(c.trim_pid) do g[key]=value end
    local r,rs=self.rollTrim:step(0,roll,dt,-c.max_trim_ceiling_change,c.max_trim_ceiling_change)
    local pitchError=pitchTarget-pitchControlMeasurement
    local p,ps=self.pitchTrim:step(pitchTarget,pitchControlMeasurement,dt,
        -c.max_trim_ceiling_change,c.max_trim_ceiling_change)
    local rollSign={FL=1,FR=-1,RL=1,RR=-1}
    local pitchSign={FL=1,FR=1,RL=-1,RR=-1}
    -- PID rejects an integral increment before it crosses the output cap;
    -- that can leave output one increment below the limit. Still report the
    -- exhausted authority when the next outward increment cannot fit.
    local cap=c.max_trim_ceiling_change
    local nextR=r-g.ki*roll*dt;local nextP=p+g.ki*pitchError*dt
    local limited=rs or ps or (roll<0 and nextR>cap) or (roll>0 and nextR< -cap) or
        (pitchError>0 and nextP>cap) or (pitchError<0 and nextP< -cap)
    local freezeRoll,freezePitch=false,false
    for _,q in ipairs(QUADS) do
        local lo,hi=-c.max_trim_ceiling_change,c.max_trim_ceiling_change
        for name,provider in pairs(io.nodes[q].providers) do
            if provider.controlRole=="fine" then
                lo=math.max(lo,-baseline[q][name])
                hi=math.min(hi,provider.maxTarget-baseline[q][name])
            end
        end
        local raw=r*rollSign[q]+p*pitchSign[q]
        local wanted=clamp(raw,lo,hi)
        -- A high-side burner at its probe floor need not freeze learning on
        -- the low side: positive headroom can still correct the same moment.
        -- Stop axis integration when its requested positive lift is clipped.
        if raw>hi then
            limited=true
            if -roll*rollSign[q]>0 then freezeRoll=true end
            if pitchError*pitchSign[q]>0 then freezePitch=true end
        end
        -- Clipping the high side at zero must not prevent positive correction
        -- on the low side. Bulk altitude control absorbs the common lift.
        local step=c.trim_slew_ceiling_per_second*dt
        local previous=self.trim[q] or 0
        self.trim[q]=previous+clamp(wanted-previous,-step,step)
        if wanted>self.trim[q] then
            if -roll*rollSign[q]>0 then freezeRoll=true end
            if pitchError*pitchSign[q]>0 then freezePitch=true end
        end
        if wanted<self.trim[q] then
            if -roll*rollSign[q]<0 then freezeRoll=true end
            if pitchError*pitchSign[q]<0 then freezePitch=true end
        end
    end
    if freezeRoll and -roll*oldRoll>=0 then self.rollTrim.i=oldRoll end
    if freezePitch and pitchError*oldPitch>=0 then self.pitchTrim.i=oldPitch end
    local coarse={roll=0,pitch=0}
    local perBlock=finite(c.trim_ceiling_per_block) and math.max(0,c.trim_ceiling_per_block) or 0
    local fineBlocks=perBlock>0 and c.max_trim_ceiling_change/perBlock or math.huge
    local trimRate=finite(c.trim_slew_ceiling_per_second) and math.max(0,c.trim_slew_ceiling_per_second) or 0
    local coarseSeconds=finite(slewDt) and slewDt>0 and slewDt or dt
    coarseSeconds=math.min(coarseSeconds,3)
    local coarseFresh,coarseFreshReason=self:coarseTrimSamplesAligned(io,now)
    -- During BUILDING_LIFT the chambers fill unevenly and the trim burner's
    -- small authority is irrelevant, so steam (bulk vent) leveling responds
    -- from the deadband and its gain and slew are multiplied by
    -- climb_trim_boost. HOLDING keeps the original gentle behaviour.
    local climbing=self.systemsRun~=nil and self.systemsRun.phase=="BUILDING_LIFT"
    local climbBoost=climbing and finite(c.climb_trim_boost) and clamp(c.climb_trim_boost,1,20) or 1
    local coarseThreshold=climbBoost>1 and c.trim_deadband_blocks or fineBlocks
    -- Steam lift answers a vent change only after the envelope fills, so
    -- correcting the present tilt overshoots: the ship swings past level
    -- and the correction chases it (pitch-up, nosedive, repeat). Act on the
    -- tilt predicted one envelope response time ahead instead; this damps
    -- the swing and releases the correction while still tilted but recovering.
    -- Rates use the real time between samples; the PID dt can be shorter
    -- than the actual gap when commands wait on slow chamber ACKs.
    local rates=self.levelRates
    local elapsed=rates and finite(now) and finite(rates.at) and now-rates.at or nil
    if not rates or not elapsed or elapsed<0 or elapsed>15 then
        rates={roll=0,pitch=0,lastRoll=measuredRoll,lastPitch=measuredPitch,at=now};self.levelRates=rates
    elseif elapsed>0 then
        local filter=finite(c.trim_pid.derivative_filter_seconds) and c.trim_pid.derivative_filter_seconds or 2
        local alpha=elapsed/(filter+elapsed)
        rates.roll=rates.roll+alpha*((measuredRoll-rates.lastRoll)/elapsed-rates.roll)
        rates.pitch=rates.pitch+alpha*((measuredPitch-rates.lastPitch)/elapsed-rates.pitch)
        rates.lastRoll,rates.lastPitch,rates.at=measuredRoll,measuredPitch,now
    end
    local responseLag=self.systemsRun and self.systemsRun.responseLagSeconds
    local lead=clamp(finite(c.level_lead_seconds) and c.level_lead_seconds>0 and c.level_lead_seconds or
        (finite(responseLag) and responseLag or 5),1,30)
    local predictedRoll=measuredRoll+rates.roll*lead
    local predictedPitchError=(pitchTarget-measuredPitch)-rates.pitch*lead
    -- Use the prediction only to back off: never more correction than the
    -- present tilt asks for, less as the ship swings back, none once the
    -- predicted tilt has crossed level.
    local function damped(present,predicted)
        if present*predicted<=0 then return 0 end
        return (present>0 and 1 or -1)*math.min(math.abs(present),math.abs(predicted))
    end
    local dampedRoll=damped(measuredRoll,predictedRoll)
    local dampedPitchError=damped(pitchTarget-measuredPitch,predictedPitchError)
    local coarseIntegral=self.coarseSteamTrimIntegral or {roll=0,pitch=0}
    self.coarseSteamTrimIntegral=coarseIntegral
    local coarseEngaged=self.coarseSteamTrimEngaged or {roll=false,pitch=false}
    self.coarseSteamTrimEngaged=coarseEngaged
    local coarseLimit=0
    for _,q in ipairs(QUADS) do
        for _,provider in pairs(io.nodes[q].providers or {}) do
            if provider.controlRole=="bulk" and provider.gasType=="steam" and finite(provider.maxTarget) then
                coarseLimit=math.max(coarseLimit,provider.maxTarget-(provider.minimumNonzeroTarget or 0))
            end
        end
    end
    if coarseFresh and perBlock>0 and trimRate>0 then
        -- A slow bias transfer keeps a persistent weight imbalance from
        -- forcing the fine burners to hold a large steady offset. Coarse
        -- transfer follows the fine-control deadband, so it keeps learning
        -- toward zero inside the wider public level-acceptance tolerance.
        -- The resulting target still passes through the configured coarse
        -- output slew below, so learning can use half that rate without a
        -- per-batch lift discontinuity.
        -- A slower envelope gets a proportionally slower learned transfer;
        -- learning faster than the lift can respond is what winds up the swing.
        local transferRate=trimRate*0.5*climbBoost*clamp(5/lead,0.15,1)
        local rollDirection=measuredRoll>0 and -1 or (measuredRoll<0 and 1 or 0)
        if math.abs(measuredRoll)>c.trim_deadband_blocks and (climbBoost>1 or rs or math.abs(r)>=cap*0.8) then
            coarseEngaged.roll=true
        end
        if rollDirection~=0 and coarseIntegral.roll*rollDirection<0 then
            coarseIntegral.roll=coarseIntegral.roll+clamp(-coarseIntegral.roll,
                -transferRate*coarseSeconds,transferRate*coarseSeconds)
        elseif coarseEngaged.roll and math.abs(measuredRoll)>c.trim_deadband_blocks then
            coarseIntegral.roll=clamp(coarseIntegral.roll+rollDirection*transferRate*coarseSeconds,
                -coarseLimit,coarseLimit)
        end
        local rawPitchError=pitchTarget-measuredPitch
        local pitchDirection=rawPitchError>0 and 1 or (rawPitchError<0 and -1 or 0)
        if math.abs(rawPitchError)>c.trim_deadband_blocks and (climbBoost>1 or ps or math.abs(p)>=cap*0.8) then
            coarseEngaged.pitch=true
        end
        if pitchDirection~=0 and coarseIntegral.pitch*pitchDirection<0 then
            coarseIntegral.pitch=coarseIntegral.pitch+clamp(-coarseIntegral.pitch,
                -trimRate*climbBoost*coarseSeconds,trimRate*climbBoost*coarseSeconds)
        elseif coarseEngaged.pitch and math.abs(rawPitchError)>c.trim_deadband_blocks then
            coarseIntegral.pitch=clamp(coarseIntegral.pitch+pitchDirection*transferRate*coarseSeconds,
                -coarseLimit,coarseLimit)
        end
        local coarseRollP=math.min(cap*climbBoost,math.max(0,math.abs(dampedRoll)-coarseThreshold)*perBlock*climbBoost)
        local coarsePitchP=math.min(cap*climbBoost,math.max(0,math.abs(dampedPitchError)-coarseThreshold)*perBlock*climbBoost)
        -- Rate damping: oppose the tilt's motion over one response horizon so
        -- the learned (integral) correction cannot keep swinging the ship.
        local dampingLimit=cap*climbBoost
        local dampingGain=finite(c.level_damping_gain) and clamp(c.level_damping_gain,0,10) or 1
        local rollDamping=coarseEngaged.roll and clamp(-rates.roll*lead*perBlock*climbBoost*dampingGain,-dampingLimit,dampingLimit) or 0
        local pitchDamping=coarseEngaged.pitch and clamp(-rates.pitch*lead*perBlock*climbBoost*dampingGain,-dampingLimit,dampingLimit) or 0
        coarse.roll=-((dampedRoll>0 and 1 or (dampedRoll<0 and -1 or 0)))*coarseRollP+coarseIntegral.roll+rollDamping
        coarse.pitch=(dampedPitchError>0 and 1 or (dampedPitchError<0 and -1 or 0))*coarsePitchP+coarseIntegral.pitch+pitchDamping
    end
    local previousCoarse=self.coarseSteamTrim or {roll=0,pitch=0}
    local coarseStep=trimRate*coarseSeconds*climbBoost
    self.coarseSteamTrim=coarseFresh and {
        roll=(previousCoarse.roll or 0)+clamp(coarse.roll-(previousCoarse.roll or 0),-coarseStep,coarseStep),
        pitch=(previousCoarse.pitch or 0)+clamp(coarse.pitch-(previousCoarse.pitch or 0),-coarseStep,coarseStep)} or previousCoarse
    self.trimStatus={active=true,rollHeightError=-roll,pitchHeightError=pitchError,
        foreAftHeightDifferenceBlocks=2*measuredPitch,manualTargetForeAftHeightDifferenceBlocks=manualBias,
        levelIndicated=levelSpread<=levelTolerance,levelSpreadBlocks=levelSpread,
        levelToleranceBlocks=levelTolerance,
        fineAuthorityLimited=limited,authorityLimited=limited,reason=limited and "TRIM AUTHORITY EXHAUSTED" or "TRIM PID ACTIVE",
        coarseSteamTrimRoll=self.coarseSteamTrim.roll,coarseSteamTrimPitch=self.coarseSteamTrim.pitch,
        coarseSteamTrimActive=false,coarseSteamTrimLimited=false,coarseSteamTrimReason=coarseFresh and nil or coarseFreshReason,
        rollIntegral=self.rollTrim.i,pitchIntegral=self.pitchTrim.i}
    return true
end

-- Apply a symmetric steam-only differential to an untrimmed common-demand
-- map. Equal verified raw-lift capacity in all four quadrants lets paired
-- integer offsets preserve requested total support exactly. A single shared
-- scale honors the tightest provider/floor/quadrant-capacity bound.
-- @ama-summary: Apply a symmetric steam-only differential to an untrimmed common-demand map. Equal verified raw-lift capacity in all four quadrants lets paired integer offsets preserve requested total support exactly. A single shared scale honors the tightest provider/floor/quadrant-capacity bound.
function Flight:applyCoarseSteamTrim(io,baseMaps,model,now)
    local result={}
    for _,q in ipairs(QUADS) do
        result[q]={}
        for name,value in pairs(baseMaps[q] or {}) do result[q][name]=value end
    end
    local status=self.trimStatus
    if not status then return result,{} end
    status.coarseSteamTrimActive=false
    status.coarseSteamTrimLimited=false
    local roll=self.coarseSteamTrim and self.coarseSteamTrim.roll or 0
    local pitch=self.coarseSteamTrim and self.coarseSteamTrim.pitch or 0
    status.coarseSteamTrimRoll=roll;status.coarseSteamTrimPitch=pitch
    local aligned,alignmentReason=self:coarseTrimSamplesAligned(io,now)
    if not aligned then status.coarseSteamTrimReason=alignmentReason end

    local steamStrength=self.config.verified_gas_lift_strengths and
        self.config.verified_gas_lift_strengths.steam
    if not finite(steamStrength) or steamStrength<=0 then
        status.coarseSteamTrimReason="VERIFIED STEAM LIFT STRENGTH UNAVAILABLE";return result,{}
    end
    local providers,strengthSums,rawTotals={},{},{ }
    local strengthReference
    for _,q in ipairs(QUADS) do
        local node=io.nodes[q];providers[q]={};strengthSums[q]=0;rawTotals[q]=0
        for name,p in pairs(node.providers or {}) do
            local amount=baseMaps[q] and baseMaps[q][name]
            local strength=configuredProviderStrength(self.config,p)
            if not finite(amount) or amount<0 or amount%1~=0 or not finite(strength) or strength<=0 then
                status.coarseSteamTrimReason="STEAM TRIM TARGET / STRENGTH UNAVAILABLE";return result,{}
            end
            rawTotals[q]=rawTotals[q]+amount*strength
            if p.controlRole=="bulk" and p.gasType=="steam" and p.gasTypeValid==true and
                p.present==true and p.writable==true and p.targetValid==true and
                p.signalValid==true and p.signalStrength==15 and p.attachedValid==true and p.attached==true and
                finite(p.maxTarget) and finite(p.minimumNonzeroTarget) then
                providers[q][#providers[q]+1]={name=name,p=p,amount=amount,strength=strength}
                strengthSums[q]=strengthSums[q]+strength
            end
        end
        if #providers[q]==0 then status.coarseSteamTrimReason="ACTIVE STEAM AUTHORITY UNAVAILABLE";return result,{} end
        if not strengthReference then strengthReference=strengthSums[q]
        elseif math.abs(strengthSums[q]-strengthReference)>math.max(1e-7,strengthReference*1e-6) then
            status.coarseSteamTrimReason="STEAM AUTHORITY DOES NOT BALANCE BY QUADRANT";return result,{}
        end
    end

    -- Pair symmetry makes FL/RR and FR/RL equal-and-opposite even after
    -- integer quantization, preserving the total steam lift request.
    local requested={FL=roll+pitch,FR=pitch-roll,RL=roll-pitch,RR=-roll-pitch}
    local availableScale=1
    for _,q in ipairs(QUADS) do
        local delta=requested[q]
        if math.abs(delta)>1e-9 then
            local perVent=math.huge
            for _,entry in ipairs(providers[q]) do
                local p,amount=entry.p,entry.amount
                local floor=math.max(p.minimumNonzeroTarget,p.minTarget or p.minimumNonzeroTarget)
                local headroom=delta>0 and (p.maxTarget-amount) or (amount-floor)
                perVent=math.min(perVent,math.max(0,headroom))
            end
            if delta>0 and model and finite(model.rawPerQuadrantMaximum) then
                perVent=math.min(perVent,math.max(0,(model.rawPerQuadrantMaximum-rawTotals[q])/strengthSums[q]))
            end
            availableScale=math.min(availableScale,perVent/math.abs(delta))
        end
    end
    availableScale=clamp(availableScale,0,1)
    local steps={}
    for _,q in ipairs(QUADS) do
        local delta=requested[q]*availableScale
        steps[q]=delta<0 and -math.floor(-delta+1e-9) or math.floor(delta+1e-9)
    end
    -- Protect exact paired symmetry if a floating-point boundary is hit.
    steps.RR=-steps.FL;steps.RL=-steps.FR
    for _,q in ipairs(QUADS) do
        local step=steps[q]
        if step~=0 then
            for _,entry in ipairs(providers[q]) do
                result[q][entry.name]=entry.amount+step
            end
            status.coarseSteamTrimActive=true
        end
    end
    status.coarseSteamTrimLimited=availableScale<1-1e-9
    if status.coarseSteamTrimLimited then
        -- Back-calculate the slowly learned correction against the shared
        -- provider/headroom scale so a pinned steam allocator cannot wind up.
        local integral=self.coarseSteamTrimIntegral
        if integral then integral.roll=integral.roll*availableScale;integral.pitch=integral.pitch*availableScale end
    end
    status.authorityLimited=status.fineAuthorityLimited==true and status.coarseSteamTrimLimited
    status.reason=status.authorityLimited and "TRIM AUTHORITY EXHAUSTED" or "TRIM PID ACTIVE"
    if status.coarseSteamTrimLimited then status.coarseSteamTrimReason="STEAM TRIM SCALED TO AVAILABLE HEADROOM"
    elseif aligned then status.coarseSteamTrimReason=nil end
    local applied={}
    for _,q in ipairs(QUADS) do
        applied[q]={}
        for _,entry in ipairs(providers[q]) do
            applied[q][entry.name]=result[q][entry.name]-baseMaps[q][entry.name]
        end
    end
    return result,applied
end

-- A small registry keeps the Settings pages and core validation in agreement.
-- Values are committed to JSON before changing any live controller reference.
local FIELDS={}
local NavigationSettings=require("avionics.navigation_settings")
local InputTuning=require("avionics.input_tuning")
local function field(group,key,label,path,min,max,step,unit)
    FIELDS[#FIELDS+1]={group=group,key=key,label=label,path=path,min=min,max=max,step=step,unit=unit}
end
field("GENERAL","cockpit_timeout","Cockpit timeout (s)",{"cockpit","input_stale_seconds"},.5,10,.5)
field("LATERAL","lateral_strength_percent","Manual strafe strength (%)",{"cockpit","lateral_strength_percent"},5,100,5)
field("LATERAL","lateral_offset_step_blocks","Offset per pull (blocks)",{"cockpit","lateral_offset_step_blocks"},.1,10,.1)
field("LATERAL","lateral_hold_delay_seconds","Hold delay (seconds)",{"cockpit","lateral_hold_delay_seconds"},.1,3,.1)
field("LATERAL","lateral_adjustment_blocks_per_second","Held adjustment speed (blocks/s)",{"cockpit","lateral_adjustment_blocks_per_second"},.1,10,.1)
for _,f in ipairs(NavigationSettings.fields) do
    field(f.group=="anchor" and "NAV ANCHOR" or "NAV AUTOPILOT","nav_"..f.group.."_"..f.key,
        f.label,{"navigation",f.group,f.key},f.min,f.max,f.step)
end
field("PROPULSION","primary_max_rpm","Maximum primary RPM",{"thrust","primary_max_rpm"},1,256,1)
  field("PROPULSION","lateral_max_rpm","Maximum lateral RPM",{"thrust","lateral_max_rpm"},1,256,1)
  field("PROP LIMITS","manual_acceleration_maximum","Forward acceleration b/s^2",{"thrust","manual_acceleration","maximum"},.01,5,.05)
  field("PROP LIMITS","manual_acceleration_minimum","Reverse acceleration b/s^2",{"thrust","manual_acceleration","minimum"},-5,-.01,.05)
  field("PROP LIMITS","propulsion_slew","Throttle slew / second",{"thrust","speed_output_slew_per_second"},.01,1,.05)
  field("PROP LIMITS","manual_speed_hold_gain","Zero acceleration speed gain",{"thrust","manual_speed_hold_gain"},.01,10,.05)
  field("PROP LIMITS","maximum_yaw_rate","Maximum turn rate deg/s",{"thrust","heading_control","maximum_yaw_rate_degrees_per_second"},.1,90,.5)
  field("PROP LIMITS","heading_rate_gain","Turn rate / heading error",{"thrust","heading_control","heading_rate_per_degree"},.01,10,.05)
  field("PROP LIMITS","heading_output_slew","Steering slew / second",{"thrust","heading_control","output_slew_per_second"},.01,1,.05)
  for _,axis in ipairs({{"PROP SPEED PID","speed_pid"},{"PROP ACCEL PID","manual_acceleration_pid"},
      {"PROP YAW PID","heading_control","rate_pid"}}) do
      for _,gain in ipairs({{"kp",0,100,.01},{"ki",0,100,.005},{"kd",0,100,.005},
          {"integral_limit",0,100,1},{"derivative_filter_seconds",.01,100,.1}}) do
          local path={"thrust",axis[2]};if axis[3] then path[#path+1]=axis[3] end;path[#path+1]=gain[1]
          field(axis[1],axis[2].."_"..gain[1],gain[1],path,gain[2],gain[3],gain[4])
      end
  end
field("GENERAL","restart_y","Restart lock CoM Y",{"maintenance","restart_altitude_limit"},-2048,2048,1)
for _,f in ipairs(InputTuning.fields) do
 field(f.group,f.key,f.label,{"cockpit",f.key},f.min,f.max,f.step)
end
field("INPUT HEADING","coarse_heading_degrees","Heading tap degrees",{"cockpit","coarse_heading_degrees"},1,90,1)
field("INPUT HEADING","fine_heading_degrees","Fine heading tap degrees",{"cockpit","fine_heading_degrees"},.1,10,.1)
field("INPUT HEADING","repeat_delay_seconds","Shared repeat delay s",{"cockpit","repeat_delay_seconds"},.1,2,.1)
field("INPUT SPEED","speed_target_rate","Speed start (b/s)/s",{"cockpit","speed_selection_blocks_per_second_per_second"},.01,10,.1)
local targets={
 {"altitude_rate_slow","Altitude slow",0.1,10,0.5},{"altitude_rate_medium","Altitude medium",0.1,20,1},
 {"altitude_rate_fast","Altitude fast",0.1,50,1},{"altitude_medium_after_seconds","Medium after",1,10,0.5},
 {"altitude_fast_after_seconds","Fast after",2,30,0.5}}
for _,f in ipairs(targets) do field("INPUT ALTITUDE",f[1],f[2],{"cockpit",f[1]},f[3],f[4],f[5]) end
for _,axis in ipairs({"altitude_pid","vertical_speed_pid"}) do
 for _,f in ipairs({{"kp",0,100,0.01},{"ki",0,100,0.01},{"kd",0,100,0.01},
  {"integral_limit",0,100,1},{"derivative_filter_seconds",0.01,100,0.1}}) do
  field(axis=="altitude_pid" and "ALT PID" or "VS PID",axis.."_"..f[1],f[1],{"altitude_control",axis,f[1]},f[2],f[3],f[4])
 end
end
for _,f in ipairs({{"ki",0,100,0.01},{"kd",0,100,0.1},{"integral_limit",0,100,1},
 {"derivative_filter_seconds",0.01,100,0.1}}) do
 field("TRIM PID","trim_pid_"..f[1],f[1],{"altitude_control","trim_pid",f[1]},f[2],f[3],f[4])
end
for _,f in ipairs({{"max_vertical_speed","Max vertical speed",0.01,5,0.1},
 {"startup_max_vertical_speed","Startup climb V/S",0.01,20,0.1},
 {"startup_vertical_speed_limit","Startup hard V/S limit",0.01,20,0.1},
 {"max_feed_fraction","Max feed fraction",0.001,0.25,0.01},{"minimum_world_y","Minimum target Y",-2048,2048,1},
 {"maximum_world_y","Maximum target Y",-2048,2048,1},{"hover_capture_seconds","Hover capture seconds",1,60,1},
 {"hover_max_vertical_speed","Hover max V/S",0.01,.5,0.01},{"lift_balance_tolerance_fraction","Lift balance tolerance",0.01,.25,0.01},
 {"trim_deadband_blocks","Trim deadband",0,10,0.05},{"trim_ceiling_per_block","Trim gain",0,50,1},
 {"trim_slew_ceiling_per_second","Trim slew",0.01,10,0.1},{"max_trim_ceiling_change","Max trim change",0,100,1}}) do
 field("LIMITS",f[1],f[2],{"altitude_control",f[1]},f[3],f[4],f[5])
end
field("LIMITS","startup_gas_target_m3_per_chamber","Initial gas target / chamber (m3)",
    {"altitude_control","startup_gas_target_m3_per_chamber"},0,100000,1,"m3/chamber")
field("LIMITS","launch_settle_seconds","Launch settling (seconds)",
    {"altitude_control","launch_settle_seconds"},0,60,1)
field("STARTUP","startup_acceleration_seconds","Time to reach startup climb V/S (s)",
    {"altitude_control","startup_acceleration_seconds"},5,600,1)
field("STARTUP","startup_braking_lookahead_seconds","Braking look-ahead (s)",
    {"altitude_control","startup_braking_lookahead_seconds"},5,120,1)
field("STARTUP","ceiling_soft_start_rate","Vent soft-start rate (fraction/s)",
    {"altitude_control","ceiling_soft_start_rate"},0.0005,0.05,0.0005)
field("STARTUP","ceiling_rise_rate","Vent rise rate (fraction/s)",
    {"altitude_control","ceiling_rise_rate"},0.005,0.1,0.005)
field("STARTUP","ceiling_fast_rate","Vent fast rate (fraction/s)",
    {"altitude_control","ceiling_fast_rate"},0.02,0.25,0.01)
field("STARTUP","climb_trim_boost","Leveling boost while building lift (x)",
    {"altitude_control","climb_trim_boost"},1,20,0.5)
field("STARTUP","level_damping_gain","Leveling damping (x)",
    {"altitude_control","level_damping_gain"},0,10,0.5)
field("STARTUP","level_lead_seconds","Leveling look-ahead (s, 0 = measured lag)",
    {"altitude_control","level_lead_seconds"},0,60,1)
local function clone(t)
 if type(t)~="table" then return t end
 local out={};for k,v in pairs(t) do out[k]=clone(v) end;return out
end
local function readPath(c,path)
 for _,key in ipairs(path) do if type(c)~="table" then return nil end;c=c[key] end;return c
end
-- @ama-section: Flight lifecycle | Operator actions, runtime gates and cached presentation.
-- @ama-summary: Validate a settings edit, save its configured value and update the affected live controller.
function Flight:setting(io,action,now)
 local holding=self.systemsRun and self.systemsRun.phase=="READY"
 if (self.enabled and not holding) or self.tuningRun or self.startupPending or
  (self.systemsRun and not holding) or self.maintenanceJob then return false,"DISENGAGE / FINISH LIFT OPERATION FIRST" end
 if holding then
  if self.systemsRun.telemetryRecovery then return false,"WAIT FOR LIFT TELEMETRY RECOVERY" end
  local available,reason=self:systemsGuard(io,now,self.systemsRun)
  if not available then return false,reason end
 end
 if not holding and (io.anchor=="ANCHORED" or io.anchor=="BRAKING") then return false,"ANCHOR LOCKS FLIGHT SETTINGS" end
 local definition
 for _,f in ipairs(FIELDS) do if f.key==action.key then definition=f;break end end
 if not definition or not finite(action.value) or action.value<definition.min or action.value>definition.max then return false,"SETTING OUT OF RANGE" end
 if definition.group:match("^NAV") and ((io.autopilot and io.autopilot.active) or
    (io.positionAnchor and io.positionAnchor.active)) then return false,"DISENGAGE AP / RELEASE ANCHOR BEFORE TUNING" end
 local navOk,navReason=NavigationSettings.ensure(io.config)
 if not navOk then return false,navReason end
 local candidate=clone(io.config);local node=candidate
 for i=1,#definition.path-1 do node=node[definition.path[i]];if type(node)~="table" then return false,"SETTING UNAVAILABLE" end end
 node[definition.path[#definition.path]]=action.value
 if action.key=="cockpit_timeout" then node.maximum_input_gap_seconds=action.value end
 if action.key=="primary_max_rpm" then candidate.thrust.direct_max_request=action.value/256 end
   if action.key=="speed_target_rate" then candidate.thrust.speed_target_rate_bps2=action.value end
 if not self.storage then return false,"CONFIGURATION STORAGE UNAVAILABLE" end
 local ok,reason=self.storage.validateConfig(candidate);if not ok then return false,reason end
 local changes={{path=definition.path,value=action.value}}
 if action.key=="cockpit_timeout" then
  local p={};for i=1,#definition.path-1 do p[i]=definition.path[i] end
  p[#p+1]="maximum_input_gap_seconds";changes[#changes+1]={path=p,value=action.value}
 end
 if action.key=="primary_max_rpm" then changes[#changes+1]={path={"thrust","direct_max_request"},value=action.value/256} end
 if action.key=="speed_target_rate" then changes[#changes+1]={path={"thrust","speed_target_rate_bps2"},value=action.value} end
 local differed
 if type(self.storage.saveConfigChanges)=="function" then
  ok,reason,differed=self.storage.saveConfigChanges("/avionics/config.json",io.config,changes,self.settingsDependencies)
 else ok,reason=self.storage.writeJson("/avionics/config.json",candidate,self.settingsDependencies) end
 if not ok then return false,"CONFIGURATION NOT SAVED: "..tostring(reason) end
 if differed then
  emitCoreLog("Setting "..tostring(action.key).." saved; config.json also holds edits not yet loaded (they apply on reboot)","core.flight.settings")
 end
 -- Keep existing PID and cockpit references, rather than replacing their tables.
 node=io.config;for i=1,#definition.path-1 do node=node[definition.path[i]] end
 node[definition.path[#definition.path]]=action.value
 if action.key=="cockpit_timeout" then node.maximum_input_gap_seconds=action.value end
 if action.key=="primary_max_rpm" then io.config.thrust.direct_max_request=action.value/256 end
   if action.key=="speed_target_rate" then io.config.thrust.speed_target_rate_bps2=action.value end
   local inputSetting=definition.group:match("^INPUT")~=nil
   if self.controls and inputSetting then
    self.controls.holds={};self.controls.headingKind=nil
    if definition.group=="INPUT HEADING" then self.controls.waitHeading=true end
    if definition.group=="INPUT ALTITUDE" or action.key=="repeat_delay_seconds" then self.controls.waitAltitude=true end
    if definition.group=="INPUT SPEED" and self.controls.modes.throttle=="SEL" then self.controls.waitSpeedSelection=true end
   end
   if io.thrust and definition.group:match("^PROP") and action.key~="speed_target_rate" then
       io.thrust:resetSpeedLoop();io.thrust:resetManualAccelerationLoop();io.thrust:resetHeadingLoop()
   end
 -- Editing a live HOLD must preserve its acquired support and PID history.
 if not holding and not inputSetting and action.key~="speed_target_rate" then
  if self.outer then self.outer:reset() end;if self.inner then self.inner:reset() end
 end
 self.maintenanceReview=nil;self.tuningReview=nil
 return true,"SETTING SAVED"
end
-- @ama-section: Leveling | Chamber-height feedback and retained trim allocation.
-- @ama-summary: Evaluate whether the current vessel observations permit a manual fore/aft bias edit.
function Flight:manualTrimAvailability(io,now)
 if type(io)~="table" then return false,"CORE STATE UNAVAILABLE" end
 if not finite(now) and type(io.nowSeconds)=="function" then
  local ok,current=pcall(io.nowSeconds,io);if ok and finite(current) then now=current end
 end
 local routeAllowed,routeReason=true,nil
 if type(io.routeAllowed)=="function" then
  local ok,allowed,reason=pcall(io.routeAllowed,io)
  routeAllowed=ok and allowed==true;routeReason=ok and reason or allowed
 elseif io.identityReady==false then routeAllowed=false;routeReason=io.identityReason end
 if not routeAllowed then return false,routeReason or "CORE IDENTITY / ROUTE UNVERIFIED" end
 local config=io.config and io.config.altitude_control
 local bias=config and config.manual_fore_aft_trim_blocks
 if not finite(bias) or bias<MANUAL_TRIM_MIN or bias>MANUAL_TRIM_MAX then
  return false,"MANUAL TRIM CONFIGURATION INVALID"
 end
 if not self.storage or type(self.storage.validateConfig)~="function" or
  type(self.storage.writeJson)~="function" then return false,"CONFIGURATION STORAGE UNAVAILABLE" end
 local validated,valid,validationReason=pcall(self.storage.validateConfig,io.config)
 if not validated or not valid then
  return false,"CONFIGURATION INVALID: "..tostring(validated and validationReason or valid)
 end
 if self.shutdownJob or self.stopReview then return false,"STOPPING / STOP REVIEW IN PROGRESS" end
 if self.tuningRun or self.tuningReview then return false,"PID TUNING IN PROGRESS" end
 if self.maintenanceJob or self.maintenanceReview then return false,"LIFT MAINTENANCE IN PROGRESS" end
 if self.startupPending then return false,"VENT STARTUP IN PROGRESS" end
 if self.emergencyLiftLatched then
  local kill=self.emergencyLiftJob
  if not kill or kill.complete~=true then
   return false,(kill and kill.reason) or "EMERGENCY LIFT KILL IN PROGRESS"
  end
 end
 if self.systemsRun then
  if self.systemsRun.phase~="READY" then return false,"AVAILABLE AFTER SYSTEMS READY" end
   if self.systemsRun.acquisitionPidActive~=true then
    return false,"ALTITUDE CONTROL PLANT INPUTS UNAVAILABLE"
   end
  if not finite(now) then return false,"FRESH CONTROL STATE UNAVAILABLE" end
  local ok,reason=self:systemsGuard(io,now,self.systemsRun)
  if not ok then return false,reason or "SYSTEMS HOLD STATE STALE" end
  return true,"READY"
 end
 if self.enabled then
  if not finite(now) then return false,"FRESH CONTROL STATE UNAVAILABLE" end
  local ok,reason=self:check(io,now)
  if not ok then return false,reason or "ALTITUDE PID HOLD STATE STALE" end
 end
 return true,"READY"
end
-- @ama-summary: Apply an accepted fore/aft trim adjustment and persist the selected bias.
function Flight:manualTrimRequest(io,action,now)
 local available,reason=self:manualTrimAvailability(io,now)
 if not available then return false,reason end
 local c=io.config and io.config.altitude_control
 local current=c and c.manual_fore_aft_trim_blocks
 if not finite(current) then return false,"MANUAL TRIM CONFIGURATION INVALID" end
 local value
 if action.type=="manual_trim_reset" then
  value=0
 elseif action.type=="manual_trim_adjust" then
  local delta=action.delta
  local validStep=delta==0.1 or delta== -0.1 or delta==0.5 or delta== -0.5
  if not finite(delta) or not validStep then return false,"USE A MANUAL TRIM STEP OF 0.1 OR 0.5 BLOCKS" end
  local tenths=(current+delta)*10
  value=(tenths>=0 and math.floor(tenths+0.5) or math.ceil(tenths-0.5))/10
  if value<MANUAL_TRIM_MIN or value>MANUAL_TRIM_MAX then
   return false,"MANUAL TRIM LIMIT IS 2 BLOCKS FORE / AFT"
  end
 else
  return false,"INVALID MANUAL TRIM ACTION"
 end
 local candidate=clone(io.config)
 if type(candidate)~="table" or type(candidate.altitude_control)~="table" then
  return false,"MANUAL TRIM CONFIGURATION UNAVAILABLE"
 end
 candidate.altitude_control.manual_fore_aft_trim_blocks=value
 if not self.storage or type(self.storage.validateConfig)~="function" or
  type(self.storage.writeJson)~="function" then return false,"CONFIGURATION STORAGE UNAVAILABLE" end
 local called,valid,validationReason=pcall(self.storage.validateConfig,candidate)
 if not called or not valid then
  return false,"CONFIGURATION INVALID: "..tostring(called and validationReason or valid)
 end
 local writeCalled,saved,saveReason
 if type(self.storage.saveConfigChanges)=="function" then
  writeCalled,saved,saveReason=pcall(self.storage.saveConfigChanges,"/avionics/config.json",io.config,
   {{path={"altitude_control","manual_fore_aft_trim_blocks"},value=value}},self.settingsDependencies)
 else
  writeCalled,saved,saveReason=pcall(self.storage.writeJson,"/avionics/config.json",candidate,
   self.settingsDependencies)
 end
 if not writeCalled then saveReason=saved;saved=false end
 if not saved then return false,"CONFIGURATION NOT SAVED: "..tostring(saveReason) end
 c.manual_fore_aft_trim_blocks=value
 if self.config and self.config~=c then self.config.manual_fore_aft_trim_blocks=value end
 emitCoreLog("Core manual fore-aft trim bias set to "..string.format("%.1f",value).." world blocks",
  "core.flight.manual-trim")
 return true,"MANUAL TRIM BIAS SAVED"
end
function Flight:maintenanceState(io,now)
 local v=io.vessel or {};local c=io.config.maintenance or {}
 local valid=v.valid==true and finite(v.altitude) and finite(v.at) and now>=v.at and now-v.at<=io.config.network.sensor_stale_seconds
 return {threshold=c.restart_altitude_limit or 165,altitude=valid and v.altitude or nil,altitudeValid=valid,
  locked=not valid or v.altitude>(c.restart_altitude_limit or 165),review=self.maintenanceReview,
  job=self.maintenanceJob,status=self.maintenanceStatus}
end
local function failMaintenance(self,job,status)
 self.maintenanceStatus=status
 self.maintenanceJob=nil
 logOperationIssue(self,"flight","maintenance",job.operation..": "..status)
end
-- @ama-section: Maintenance | Reviewed chamber rechecks and restarts.
-- @ama-summary: Validate and stage chamber restart or hardware-recheck maintenance.
function Flight:maintenanceRequest(io,action,now)
 local kind=action.type
 if kind=="maintenance_cancel" then self.maintenanceReview=nil;return true end
 if self.maintenanceJob or self.startupPending or self.systemsRun or self.tuningRun then return false,"LIFT OPERATION ALREADY PENDING" end
 if kind=="maintenance_review" or kind=="maintenance_recheck" then
  local scope=action.scope or "ALL";local list={}
  if scope=="ALL" then for _,q in ipairs(QUADS) do list[#list+1]=q end
  else for _,q in ipairs(QUADS) do if q==scope then list[1]=q end end end
  if #list==0 then return false,"INVALID MAINTENANCE SCOPE" end
  local boots={};for _,q in ipairs(list) do
   if not io:nodeFresh(q,now) or not io.nodes[q].boot then return false,q.." LIFT NODE STALE" end
   boots[q]=io.nodes[q].boot
  end
  if kind=="maintenance_recheck" then
   if self.enabled then return false,"DISENGAGE ALTITUDE CONTROL FIRST" end
   self.coreLogIssues=self.coreLogIssues or {};self.coreLogIssues[issueScope("flight","maintenance")]=nil
   self.maintenanceJob={operation="recheck",list=list,index=1,boots=boots};self:updateMaintenance(io,now);return true
  end
  if self.enabled then return false,"DISENGAGE ALTITUDE CONTROL FIRST" end
  self.reviewSeq=(self.reviewSeq or 0)+1
  self.maintenanceReview={token=tostring(self.reviewSeq)..":"..tostring(now),scope=scope,list=list,boots=boots,
   expires=now+(io.config.maintenance and io.config.maintenance.confirmation_seconds or 30),override=false}
  return true,"REVIEW RESTART"
 end
 local r=self.maintenanceReview
 if not r or action.token~=r.token or now>r.expires then self.maintenanceReview=nil;return false,"RESTART REVIEW EXPIRED" end
 local state=self:maintenanceState(io,now)
 if not state.altitudeValid then return false,"FRESH CoM ALTITUDE REQUIRED" end
 if kind=="maintenance_override" then r.override=true;return true,"ONE RESTART OVERRIDE READY; CONFIRM SEPARATELY" end
 if kind~="maintenance_confirm" then return false,"INVALID MAINTENANCE ACTION" end
 if state.locked and not r.override then return false,"ALTITUDE LOCK: OVERRIDE REQUIRED" end
 for _,q in ipairs(r.list) do
  if not io:nodeFresh(q,now) or io.nodes[q].boot~=r.boots[q] then self.maintenanceReview=nil;return false,q.." NODE CHANGED; REVIEW AGAIN" end
 end
 self.coreLogIssues=self.coreLogIssues or {};self.coreLogIssues[issueScope("flight","maintenance")]=nil
 self.maintenanceReview=nil;self:stop("LIFT RESTART REQUESTED")
 self.maintenanceJob={operation="restart",list=r.list,index=1,boots=r.boots,override=r.override}
 self:updateMaintenance(io,now);return true,"RESTART QUEUED"
end
-- @ama-summary: Advance the current chamber maintenance operation through acknowledgement and reconnect.
function Flight:updateMaintenance(io,now)
 if self.maintenanceReview and now>self.maintenanceReview.expires then self.maintenanceReview=nil end
 local job=self.maintenanceJob;if not job then return end
 local q=job.list[job.index]
 if not q then
  self.maintenanceStatus=string.upper(job.operation).." COMPLETE";self.maintenanceJob=nil
  clearOperationIssue(self,"flight","maintenance","Core flight maintenance recovered: "..job.operation.." complete")
  return
 end
 if job.seq then
  if job.operation=="restart" and io:nodeFresh(q,now) and io.nodes[q].boot~=job.boots[q] and
   io.nodes[q].startReady and io.nodes[q].altitude and io.nodes[q].altitude.valid and
   io.nodes[q].balloon and io.nodes[q].balloon.hasBalloonValid and io.nodes[q].balloon.hasBalloon then
   job.index=job.index+1;job.seq=nil;self.maintenanceStatus=q.." RECONNECTED";return
  end
  if now-job.sentAt>(io.config.maintenance and io.config.maintenance.reconnect_timeout_seconds or 20) then
   failMaintenance(self,job,q.." "..string.upper(job.operation).." TIMED OUT; CHECK CONSOLE")
  end
  return
 end
 if job.operation=="restart" then
  local state=self:maintenanceState(io,now)
  if not state.altitudeValid or (state.locked and not job.override) then
   failMaintenance(self,job,"ALTITUDE LOCK CHANGED; REMAINING RESTARTS STOPPED");return
  end
 end
 -- Each ALL restart is sent only after the previous node has reconnected.
 if not io:nodeFresh(q,now) or io.nodes[q].boot~=job.boots[q] then
  failMaintenance(self,job,q.." NODE CHANGED; OPERATION STOPPED");return
 end
 local ok,seq=io:sendLiftMaintenance(q,job.operation)
 if not ok then failMaintenance(self,job,q.." SEND FAILED: "..tostring(seq));return end
 job.seq=seq;job.sentAt=now;job.quadrant=q
 self.maintenanceStatus=q..(job.operation=="restart" and " WAITING FOR RECONNECT" or " RECHECKING HARDWARE")
end
-- @ama-summary: Correlate a chamber maintenance reply with the active operation.
function Flight:maintenanceAck(io,sender,message,now)
 local job=self.maintenanceJob
 if not job or type(message)~="table" or message.v~=1 or message.kind~="lift_maintenance_ack" or
  message.session~=io.session or message.seq~=job.seq or message.operation~=job.operation or
  message.quadrant~=job.quadrant or message.nodeBoot~=job.boots[job.quadrant] or
  sender~=io.config.node_ids[job.quadrant] then return false end
 if message.ok~=true then failMaintenance(self,job,job.quadrant.." FAILED: "..tostring(message.detail or "REMOTE OPERATION FAILED"):sub(1,160))
 elseif job.operation=="recheck" then
  self.maintenanceStatus=job.quadrant.." "..tostring(message.detail or "RECHECKED"):sub(1,160)
  job.index=job.index+1;job.seq=nil
 end
 return true
end


-- Tuning is temporary authority, never permanent commissioning. Tests capture
-- actual provider ceilings, bypass approval flags only, and keep burner trim fixed.
-- @ama-section: Bounded tests | Captured baselines, bounded demand and result persistence.
-- @ama-summary: Check telemetry, hover stability and vent headroom for a bounded PID test.
function Flight:tuningReady(io,now)
 if not io.config.tuning or io.config.tuning.enabled~=true then return false,"TUNING MODE DISABLED" end
 if self.enabled or self.maintenanceJob or self.startupPending or self.systemsRun then return false,"FINISH OTHER LIFT OPERATION FIRST" end
 if io.anchor=="ANCHORED" or io.anchor=="BRAKING" then return false,"RELEASE DIGITAL ANCHOR FIRST" end
 local ok,reason=self:check(io,now,true);if not ok then return false,reason end
 if io.inputs.raw then for _,value in pairs(io.inputs.raw) do if value~=0 then return false,"RETURN COCKPIT CONTROLS TO NEUTRAL" end end end
 for _,q in ipairs(QUADS) do
  local n=io.nodes[q]
  if not self.tuningRun and (n.armed or n.operationBusy) then return false,q.." CONTROLLER STILL OPERATING" end
  if n.tuningSupported~=true then return false,q.." LOAD TUNING RECEIVER" end
  for _,p in pairs(n.providers) do if p.controlRole=="bulk" and
   (math.floor(p.targetAmount*.95)<p.minimumNonzeroTarget or math.ceil(p.targetAmount*1.05)>p.maxTarget) then
   return false,q.." HOVER BASELINE NEEDS +/-5% VENT HEADROOM"
  end end
 end
 local baseline={}
 for _,q in ipairs(QUADS) do
  baseline[q]={}
  for name,p in pairs(io.nodes[q].providers) do baseline[q][name]=p.targetAmount end
 end
 local within,capReason=self:balancedTargetsFit(io,baseline,now,io.vessel.altitude)
 if not within then return false,capReason end
 return true
end
-- @ama-summary: Store the PID test measurements and its baseline-restoration result.
function Flight:finishTuning(io,status)
 local t=self.tuningRun;if not t then return end
 for _,q in ipairs(QUADS) do io:cancelTuning(q,t.id) end
 local report={schema_version=1,id=t.id,mode=t.mode,direction=t.direction,status=status,
  baselineY=t.y,target=t.target,gains=clone(t.gains),baselineCeilings=clone(t.baseline),samples=t.samples,
  peakError=t.peakError or 0,rmsError=t.count>0 and math.sqrt(t.errorSquares/t.count) or 0,
  saturationSamples=t.saturationSamples,baselineRestored=t.restored==true}
 self.tuningResult={status=status,peakError=report.peakError,rmsError=report.rmsError,
  saturationSamples=report.saturationSamples,baselineRestored=report.baselineRestored,mode=t.mode}
 self.tuningRun=nil;self.tuningHoverSince=nil
 if self.storage then
  local ok,reason=self.storage.writeJson("/avionics/data/tuning-last.json",report,self.settingsDependencies)
  if not ok then self.tuningResult.saveError=tostring(reason) end
 else self.tuningResult.saveError="RECORD STORAGE UNAVAILABLE" end
 self.reason="ALTITUDE TUNING NOT COMMISSIONED"
 local line=logText("PID tuning: "..status.."; baseline restored="..tostring(report.baselineRestored),240)
 if status:sub(1,9)=="ABORTED:" then
  emitCoreLog(line,logText("core.flight.tuning:"..status,240))
  self.coreLogIssues=self.coreLogIssues or {}
  self.coreLogIssues[issueScope("flight","tuning")]=status
 elseif not clearOperationIssue(self,"flight","tuning",line) then
  emitCoreLog(line,logText("core.flight.tuning:"..status,240))
 end
end
function Flight:abortTuning(io,reason)
 -- Faults cancel queued/future writes. No blind restoration against stale devices.
 self:finishTuning(io,"ABORTED: "..tostring(reason))
end
-- @ama-summary: Review, confirm, cancel or stop a bounded PID test.
function Flight:tuningRequest(io,action,now)
 if action.type=="tuning_cancel" then self.tuningReview=nil;return true end
 if action.type=="tuning_stop" then
  if not self.tuningRun then return false,"NO ACTIVE TUNING TEST" end
  self.tuningRun.phase="RESTORING";self.tuningRun.endReason="STOPPED";self.tuningRun.pending=nil;return true,"RESTORING CAPTURED CEILINGS"
 end
 if self.tuningRun then return false,"TUNING TEST ALREADY ACTIVE" end
 if action.type=="tuning_review" then
  if action.mode~="VS" and action.mode~="ALT" then return false,"INVALID TUNING TEST" end
  if action.direction~=1 and action.direction~=-1 then return false,"INVALID TEST DIRECTION" end
  local ok,reason=self:tuningReady(io,now);if not ok then return false,reason end
  if not self.tuningHoverSince or now-self.tuningHoverSince<self.config.hover_capture_seconds then return false,"WAIT FOR STABLE HOVER BASELINE" end
  self.tuningReviewSeq=(self.tuningReviewSeq or 0)+1
  self.tuningReview={token="tune-"..self.tuningReviewSeq..":"..now,expires=now+30,
   mode=action.mode,direction=action.direction,uuid=io.vessel.uuid,fingerprint=io.hardwareFingerprint,boots={}}
  for _,q in ipairs(QUADS) do self.tuningReview.boots[q]=io.nodes[q].boot end
  return true,"REVIEW BOUNDED PID TEST"
 end
 local r=self.tuningReview
 if action.type~="tuning_confirm" or not r or r.token~=action.token or now>r.expires then self.tuningReview=nil;return false,"TUNING REVIEW EXPIRED" end
 local ok,reason=self:tuningReady(io,now);if not ok then return false,reason end
 if io.vessel.uuid~=r.uuid or io.hardwareFingerprint~=r.fingerprint then self.tuningReview=nil;return false,"VESSEL CHANGED; REVIEW AGAIN" end
 if not self.tuningHoverSince or now-self.tuningHoverSince<self.config.hover_capture_seconds or math.abs(io.vessel.verticalSpeed)>self.config.hover_max_vertical_speed then return false,"WAIT FOR STABLE HOVER BASELINE" end
 for _,q in ipairs(QUADS) do if io.nodes[q].boot~=r.boots[q] then self.tuningReview=nil;return false,"LIFT BOOT CHANGED" end end
 local c=io.config.tuning
 local target=r.mode=="VS" and r.direction*c.speed_step or io.vessel.altitude+r.direction*c.altitude_step
 if r.mode=="ALT" and (target<self.config.minimum_world_y or target>self.config.maximum_world_y) then return false,"TEST TARGET OUTSIDE WORLD Y LIMITS" end
  self.coreLogIssues=self.coreLogIssues or {};self.coreLogIssues[issueScope("flight","tuning")]=nil
  self.tuningRun={id=r.token,mode=r.mode,direction=r.direction,target=target,y=io.vessel.altitude,
  uuid=r.uuid,fingerprint=r.fingerprint,boots=r.boots,start=now,lastUpdate=now,phase="RUNNING",
  baseline={},samples={},count=0,errorSquares=0,peakError=0,saturationSamples=0,effort=0,
  gains={altitude=clone(self.config.altitude_pid),verticalSpeed=clone(self.config.vertical_speed_pid)}}
 for _,q in ipairs(QUADS) do
  self.tuningRun.baseline[q]={};for name,p in pairs(io.nodes[q].providers) do self.tuningRun.baseline[q][name]=p.targetAmount end
 end
 self.tuningReview=nil;self.maintenanceReview=nil
 self.outer:reset(io.vessel.altitude);self.inner:reset(io.vessel.verticalSpeed)
 -- First writes are the unchanged captured caps; nodes establish a bounded lease.
 self:sendTuningTargets(io,self.tuningRun.baseline,now,true)
 return self.tuningRun~=nil,self.tuningRun and "TUNING STARTED" or "TUNING SEND FAILED"
end
-- @ama-summary: Send the bounded test target maps to their configured chambers.
function Flight:sendTuningTargets(io,maps,now,first)
 local t=self.tuningRun
 if not t then return false end
 local within,reason=self:balancedTargetsFit(io,maps,now,io.vessel and io.vessel.altitude)
 if not within then self:abortTuning(io,reason or "LIFT CAPACITY CHANGED");return false end
 t.pending={};t.sentAt=now
 for _,q in ipairs(QUADS) do
  local ok,seq=io:sendTuningCommand(q,maps[q],t.id,t.baseline[q],first)
  if not ok then self:abortTuning(io,q.." SEND FAILED: "..tostring(seq));return false end
  t.pending[q]={seq=seq,targets=maps[q]}
 end
 return true
end
-- @ama-summary: Advance the active PID test and restore its captured provider ceilings.
function Flight:updateTuning(io,now)
 if self.tuningReview and now>self.tuningReview.expires then self.tuningReview=nil end
 local ready,reason=self:tuningReady(io,now)
 local t=self.tuningRun
 if not t then
  if ready and math.abs(io.vessel.verticalSpeed)<=self.config.hover_max_vertical_speed then self.tuningHoverSince=self.tuningHoverSince or now else self.tuningHoverSince=nil end
  local available=ready and self.tuningHoverSince~=nil and now-self.tuningHoverSince>=self.config.hover_capture_seconds
  self.tuningSnapshot={available=available,
   reason=not available and (reason or "WAIT FOR STABLE HOVER BASELINE") or nil,review=self.tuningReview,result=self.tuningResult,active=false}
  return
 end
 local good,fault=self:check(io,now,true)
 if not good then self:abortTuning(io,fault)
 elseif io.vessel.uuid~=t.uuid or io.hardwareFingerprint~=t.fingerprint then self:abortTuning(io,"VESSEL / SENSOR BINDINGS CHANGED")
 elseif (((io.inputs or {}).raw or {}).ap_disconnect or 0)>0 then self:abortTuning(io,"MANUAL DISCONNECT")
 elseif math.abs(io.vessel.altitude-t.y)>3 or math.abs(io.vessel.verticalSpeed)>.5 or
  io.vessel.altitude<self.config.minimum_world_y or io.vessel.altitude>self.config.maximum_world_y then self:abortTuning(io,"TEST MOTION LIMIT EXCEEDED")
 else
  for _,q in ipairs(QUADS) do if io.nodes[q].boot~=t.boots[q] then self:abortTuning(io,"LIFT BOOT CHANGED");break end end
 end
 if not self.tuningRun then self.tuningSnapshot={active=false,result=self.tuningResult};return end
 self.tuningSnapshot={active=true,mode=t.mode,phase=t.phase,target=t.target,elapsed=now-t.start,
  remaining=math.max(0,io.config.tuning.duration_seconds-(now-t.start)),effort=t.effort,
  sampleCount=t.count,peakError=t.peakError,rmsError=t.count>0 and math.sqrt(t.errorSquares/t.count) or 0}
 if now-t.start>=io.config.tuning.duration_seconds and t.phase=="RUNNING" then t.phase="RESTORING";t.endReason="COMPLETE" end
 if t.pending then
  local applied=true;for _,q in ipairs(QUADS) do if not io:commandWasApplied(q,t.pending[q].seq,t.pending[q].targets) then applied=false end end
  if not applied then
   t.lastUpdate=now -- Freeze integration during wired writes, rather than replaying the wait.
   if now-t.sentAt>15 then self:abortTuning(io,"COMMAND ACK TIMEOUT") end
   return
  end
  t.pending=nil
  if t.restoringSent then t.restored=true;self:finishTuning(io,t.endReason or "COMPLETE");self.tuningSnapshot={active=false,result=self.tuningResult};return end
 end
 if t.phase=="RESTORING" then t.restoringSent=true;self:sendTuningTargets(io,t.baseline,now,false);return end
 local dt=now-t.lastUpdate;if dt<io.config.network.sample_interval_seconds then return end
 if dt<=0 or dt>3 then self:abortTuning(io,"CONTROL SAMPLE GAP");return end
 t.lastUpdate=now
 local limit=math.min(.05,self.config.max_feed_fraction)
 local oldI=self.inner.i;local oldOuterI=self.outer.i
 local verticalTarget=t.mode=="VS" and t.target or self.outer:step(t.target,io.vessel.altitude,dt,-.1,.1)
 local effort,saturated=self.inner:step(verticalTarget,io.vessel.verticalSpeed,dt,-limit,limit)
 local bounded=clamp(effort,t.effort-.01*dt,t.effort+.01*dt)
 if bounded~=effort then saturated=true;self.inner.i=oldI;self.outer.i=oldOuterI end
 t.effort=bounded;local maps={}
 for _,q in ipairs(QUADS) do maps[q]={};for name,p in pairs(io.nodes[q].providers) do
  local base=t.baseline[q][name]
  maps[q][name]=p.controlRole=="bulk" and clamp(math.floor(base*(1+t.effort)+.5),math.ceil(base*.95),math.floor(base*1.05)) or base
 end end
 local error=t.target-(t.mode=="VS" and io.vessel.verticalSpeed or io.vessel.altitude)
 t.count=t.count+1;t.errorSquares=t.errorSquares+error*error;t.peakError=math.max(t.peakError,math.abs(error))
 if saturated then t.saturationSamples=t.saturationSamples+1 end
 if #t.samples<200 then
  local quadrants={}
  for _,q in ipairs(QUADS) do
   local node=io.nodes[q];local b=node.balloon
   quadrants[q]={lift=b.lift,gasAmount=b.gasMixAmount,filledVolume=b.filledVolume,gasOutput=node.totalGasOutput}
  end
  t.samples[#t.samples+1]={seconds=now-t.start,y=io.vessel.altitude,verticalSpeed=io.vessel.verticalSpeed,
   target=t.target,verticalTarget=verticalTarget,effort=t.effort,error=error,saturated=saturated,quadrants=quadrants}
 end
 self:sendTuningTargets(io,maps,now,false)
end

-- @ama-section: Flight lifecycle | Operator actions, runtime gates and cached presentation.
-- @ama-summary: Validate vessel, cockpit and chamber observations for altitude-control authority.
function Flight:check(io,now,tuning)
    if self.maintenanceJob then return false,"LIFT MAINTENANCE IN PROGRESS" end
    local c=self.config
    if self.controls and not self.controls.available then return false,self.controls.reason or "COCKPIT INPUTS UNAVAILABLE" end
    if not c or not c.enabled or (not tuning and not c.tuning_confirmed) then return false,"ALTITUDE TUNING NOT COMMISSIONED" end
    if not tuning and (not io.config.commissioning.enabled or not io.config.commissioning.confirm_supported) then
        return false,"CORE HARDWARE NOT COMMISSIONED"
    end
    if io.sensorBindingError then return false,"CORE HARDWARE DISCOVERY: "..io.sensorBindingError end
    if self.enabled and self.hardwareFingerprint~=io.hardwareFingerprint then return false,"CORE SENSOR BINDINGS CHANGED" end
    local v=io.vessel
    if not v or not v.valid or not finite(v.at) or now<v.at or now-v.at>io.config.network.sensor_stale_seconds or
        not finite(v.altitude) or not finite(v.verticalSpeed) or not v.uuid then return false,"CoM ALTITUDE / VERTICAL SPEED UNAVAILABLE" end
    local inputs=io.inputs
    if self.controls then
        local inputFresh,inputReason=self.controls:usable(io,now)
        if not inputFresh then return false,inputReason or "COCKPIT CONTROLS UNAVAILABLE" end
    elseif not inputs or not inputs.valid or not finite(inputs.at) or now<inputs.at or
        now-inputs.at>io.config.network.sensor_stale_seconds then return false,"COCKPIT INPUTS STALE" end
    for _,q in ipairs(QUADS) do
        local n=io.nodes[q]
        if not io:nodeFresh(q,now) or (not tuning and not n.commissioned) then return false,q..(tuning and " LIFT STATUS STALE" or " LIFT NOT READY / STALE") end
        if not n.altitude or not n.altitude.valid then return false,q.." SECTION ALTITUDE UNAVAILABLE" end
        local b=n.balloon
        if not b or not b.hasBalloonValid or not b.hasBalloon or not b.gasMixValid or
            not b.liftValid or not finite(b.lift) or b.lift<=0 then return false,q.." ENVELOPE COMPOSITION / LIFT UNAVAILABLE" end
        local bulk,fine=0,0
        for _,p in pairs(n.providers) do
            local parkedFine=p.controlRole=="fine" and p.signalStrength==0 and
                (p.targetAmount==0 or p.targetAmount==(p.minimumNonzeroTarget or 5))
            if not p.present or not p.writable or not p.targetValid or not finite(p.targetAmount) or
                not p.signalValid or (not parkedFine and not p.gasTypeValid) or
                (not parkedFine and
                 (not p.gasOutputValid or not finite(p.gasOutput) or p.gasOutput<=0 or
                  p.signalStrength~=15 or not p.attachedValid or not p.attached or
                  not b.gasMix[p.gasType] or b.gasMix[p.gasType]<=0)) then
                return false,q.." PROVIDER TELEMETRY NOT READY"
            end
            if p.targetAmount>0 and not parkedFine and p.activeSupported and (not p.activeValid or not p.active) then return false,q.." PROVIDER INACTIVE" end
            if (p.targetAmount<(p.minimumNonzeroTarget or 1) and not (p.controlRole=="fine" and p.targetAmount==0)) or p.targetAmount>p.maxTarget then
                return false,q.." PROVIDER TARGET OUT OF BOUNDS"
            end
            if p.controlRole=="bulk" and p.gasType=="steam" then bulk=bulk+1
            elseif p.controlRole=="fine" and p.gasType=="default" then fine=fine+1
            else return false,q.." UNVERIFIED GAS / CONTROL ROLE" end
        end
        if bulk~=steamCount(n) or fine~=1 then return false,q.." EXPECTED CONFIGURED VENTS AND ONE TRIM BURNER" end
        if self.enabled and (self.boots[q]~=n.boot or self.uuid~=v.uuid) then return false,"VESSEL / LIFT BOOT CHANGED" end
    end
    local targetY=self.controls and self.controls.targets and self.controls.targets.altitude or self.target or v.altitude
    local balanced,balancedReason=self:balancedLiftModel(io,targetY,now)
    self.balancedLift=balanced
    if balanced.phase=="UNAVAILABLE" or balanced.phase=="INFEASIBLE" then
        return false,balancedReason or balanced.reason or "BALANCED LIFT CAPACITY UNAVAILABLE"
    end
    if not self.enabled and not self.tuningRun then
        -- Zero vertical speed alone also describes a ship sitting on terrain.
        -- Require envelope lift near vessel weight before capturing equilibrium.
        -- Aeronautics applies -gravity * totalLift * local air pressure.
        -- CoM pressure estimates envelope pressure; measured motion remains
        -- the final hover test, because balloon centres may be at different Y.
        local gravity=v.environment and v.environment.gravity
        if not finite(v.mass) or v.mass<=0 or not gravity or not finite(gravity.y) or gravity.y>=0 then
            return false,"MASS / GRAVITY REQUIRED FOR HOVER CAPTURE"
        end
        local lift=0
        for _,q in ipairs(QUADS) do lift=lift+io.nodes[q].balloon.lift end
        if not airPressure(v) then return false,"AIR PRESSURE REQUIRED FOR HOVER CAPTURE" end
        local ratio=lift*airPressure(v)/v.mass
        if math.abs(ratio-1)>c.lift_balance_tolerance_fraction then
            return false,"ENVELOPE LIFT IS NOT NEAR HOVER EQUILIBRIUM"
        end
    end
    return true
end
-- @ama-summary: Disengage altitude feedback while retaining applied provider settings.
function Flight:stop(reason)
    local wasEnabled=self.enabled==true
    local outcome=logText(reason or "OPERATOR DISENGAGED",160)
    self.enabled=false; self.reason=reason or "OPERATOR DISENGAGED"
    self.pending=nil; self.hoverSince=nil
    -- Disengagement retains applied caps and activation.
    -- Retained systems intent governs validated resumption after reboot.
    if wasEnabled and outcome~="OPERATOR DISENGAGED" then
        logOperationIssue(self,"flight","altitude",outcome)
    end
end
-- @ama-summary: Capture a verified hover baseline and engage the altitude PID loops.
function Flight:engage(io,now)
    if self.systemsRun then return false,"START SYSTEMS SEQUENCE ACTIVE" end
    if self.tuningRun then return false,"PID TUNING IN PROGRESS" end
    if self.enabled then return false,"ALTITUDE ALREADY ENGAGED" end
    local ok,reason=self:check(io,now)
    if not ok then return false,reason end
    if not self.hoverSince or now-self.hoverSince<self.config.hover_capture_seconds then
        return false,"WAIT FOR STABLE HOVER BASELINE"
    end
    self.target=self.controls and self.controls.targets.altitude or io.vessel.altitude
    self.uuid=io.vessel.uuid; self.hardwareFingerprint=io.hardwareFingerprint
    self.baseline,self.boots,self.mixBaseline={},{},{}
    for _,q in ipairs(QUADS) do
        self.baseline[q]={}; self.boots[q]=io.nodes[q].boot
        self.mixBaseline[q]={}
        for gas,amount in pairs(io.nodes[q].balloon.gasMix) do self.mixBaseline[q][gas]=amount end
        for name,p in pairs(io.nodes[q].providers) do self.baseline[q][name]=p.targetAmount end
    end
    self.outer:reset(io.vessel.altitude); self.inner:reset(io.vessel.verticalSpeed)
    self.enabled=true; self.reason=nil; self.at=now; self.lastUpdate=now
    self.pending=nil; self:resetTrim(); self.effort=0
    clearOperationIssue(self,"flight","altitude","Core altitude control recovered: altitude hold engaged")
    return true
end
function Flight:cancelLateral(locked)
 local controls=self.controls
 if not controls then return end
 controls.lateralStopLock=locked==true
 if controls.lateral then controls.lateral:cancel() end
 if controls.modes then controls.modes.lateral="MANUAL" end
end
function Flight:shutdownReview(io,now)
    self:cancelLateral(true)
    self.reviewSeq=(self.reviewSeq or 0)+1
    self.stopReview={token="stop:"..self.reviewSeq..":"..now,expires=now+30}
    return true,"WARNING: MAIN LIFT OFF; LOW PROBE REMAINS"
end
-- @ama-summary: Send the confirmed probe-preserving shutdown and track each chamber acknowledgement.
function Flight:updateShutdown(io,now)
    local job=self.shutdownJob;if not job then return end
    local all=true;local missing={}
    for _,q in ipairs(QUADS) do
        local item=job[q]
        if not (item.seq and io:shutdownWasApplied(q,item.seq)) then
            all=false;missing[#missing+1]=q
            if not item.sentAt or now-item.sentAt>12 or (io.nodes[q] and item.boot~=io.nodes[q].boot) then
                local sent,seq=io:sendSystemsStop(q,true)
                item.sentAt=now;item.boot=io.nodes[q] and io.nodes[q].boot
                item.seq=sent and seq or nil;item.error=not sent and tostring(seq) or nil
            end
        end
    end
    self.reason=all and "SYSTEMS STOPPED / LOW PROBE ACTIVE" or "STOPPING / PROBE HANDOVER ACK: "..table.concat(missing,", ")
    self.systemsSnapshot={active=false,available=false,phase=all and "STOPPED" or "STOPPING",
        pending=not all,complete=false,reason=self.reason}
    if all then
        self.shutdownJob=nil;self.systemsLastOutcome={phase="STOPPED",reason=self.reason}
    end
end
-- Systems intent: whether the pilot wants lift control running. Only STOP
-- SYSTEMS and KILL LIFT clear it; reboots, aborts and lease expiry do not.
-- It survives reboots so control can resume on its own while airborne.
local SYSTEMS_INTENT_PATH="/avionics/data/systems-intent.json"
-- @ama-section: Systems control | Startup, measured dynamics and bounded provider demand.
-- @ama-summary: Load and return the persisted operator intent to keep systems running.
function Flight:systemsIntent()
    if self.systemsIntentLoaded then return self.systemsIntentActive==true end
    self.systemsIntentLoaded=true;self.systemsIntentActive=false
    if self.storage and type(self.storage.readJson)=="function" then
        local ok,value=pcall(self.storage.readJson,SYSTEMS_INTENT_PATH)
        if ok and type(value)=="table" and value.schemaVersion==1 then self.systemsIntentActive=value.active==true end
    end
    return self.systemsIntentActive
end
-- @ama-summary: Persist a change to the operator's systems-running intent.
function Flight:setSystemsIntent(active)
    active=active==true
    if self.systemsIntentLoaded and self.systemsIntentActive==active then return end
    self.systemsIntentLoaded=true;self.systemsIntentActive=active
    if self.storage and type(self.storage.writeJson)=="function" then
        pcall(self.storage.writeJson,SYSTEMS_INTENT_PATH,{schemaVersion=1,active=active})
    end
end
-- Resume lift control without pilot action after a core reboot, a lapsed
-- lease or a fault abort - but only while the pilot's intent is still
-- "running" and the ship is airborne (current lift >= 90% of weight). It
-- adopts the existing ceilings (no takeoff or build) and retries every 5 s.
-- @ama-summary: Attempt validated recovery or airborne adoption while retained running intent is active.
function Flight:autoResumeSystems(io,now)
    if self.systemsRun or self.shutdownJob or self.stopReview or self.emergencyLiftLatched or
        self.tuningRun or self.tuningReview or self.startupPending or self.maintenanceJob or
        (self.restart and (self.restart.job or self.restart.saved)) then return end
    if not self:systemsIntent() then return end
    if self.nextAutoResumeAt and now<self.nextAutoResumeAt then return end
    self.nextAutoResumeAt=now+5
    local ok,reason
    if self.systemsLastOutcome and self.systemsLastOutcome.phase=="ABORTED" and
        type(self.systemsRetainedRun)=="table" then
        ok,reason=self:recoverSystems(io,now)
    elseif self:systemsAirborneAtStart(io) then
        ok,reason=self:startSystems(io,now)
    else
        reason="NOT AIRBORNE; WAITING FOR PILOT START"
    end
    local text=(ok and "Auto-resume: " or "Auto-resume waiting: ")..tostring(reason)
    if text~=self.lastAutoResumeLog then
        self.lastAutoResumeLog=text
        if type(os)=="table" and type(os.__amaryllisLog)=="function" then pcall(os.__amaryllisLog,text,"core.systems")
        else print(text) end
    end
end
-- @ama-section: Flight lifecycle | Operator actions, runtime gates and cached presentation.
-- @ama-summary: Accept the matching stop confirmation and start probe-preserving main-lift shutdown.
function Flight:confirmShutdown(io,action,now)
    local review=self.stopReview
    if not review or action.token~=review.token or now>review.expires then return false,"STOP CONFIRMATION EXPIRED" end
    self.stopReview=nil
    self:cancelLateral(true)
    self:setSystemsIntent(false)
    if self.systemsRun then self:stopSystems(io,"CONFIRMED SYSTEMS SHUTDOWN",now) end
    self:stop("STOPPING / MAIN LIFT OFF")
    self.tuningRun=nil;self.tuningReview=nil;self.maintenanceJob=nil;self.maintenanceReview=nil
    self.startupPending=nil;self.trimStatus=nil
    self.shutdownJob={FL={},FR={},RL={},RR={}}
    self:updateShutdown(io,now)
    return true,"PROBE-PRESERVING SHUTDOWN REQUESTED"
end
-- @ama-section: Emergency lift | Latched operator shutdown and verified disarm.
-- @ama-summary: Latch the accepted Kill Lift action and start its dedicated shutdown sequence.
function Flight:emergencyKillLift(io,now)
    self.emergencyLiftDisarmJob=nil
    self:cancelLateral(true)
    self:setSystemsIntent(false)
    self.emergencyLiftLatched=true
    self.coreLogIssues=self.coreLogIssues or {}
    self.coreLogIssues[issueScope("flight","emergency lift kill")]=nil
    -- Persistence protects the explicit-restart interlock after a core reboot.
    -- A disk error remains visible but never blocks the physical stop packets.
    self:persistEmergencyLock(true)
    self.stopReview=nil;self.shutdownJob=nil
    -- Retire propulsion authority too. The main runtime also suppresses its
    -- normal renewals while latched, so a held cockpit input cannot re-arm it.
    if io.thrust and type(io.thrust.stop)=="function" then
        pcall(io.thrust.stop,io.thrust,io,"EMERGENCY LIFT KILL")
    end
    self.systemsRun=nil;self.systemsAvailable=false;self.systemsBlockedReason="EMERGENCY LIFT KILL LATCHED"
    self.enabled=false;self.available=false;self.pending=nil;self.hoverSince=nil
    self.startupPending=nil;self.startupAvailable=false;self.startupReason="EMERGENCY LIFT KILL LATCHED"
    self.maintenanceJob=nil;self.maintenanceReview=nil;self.tuningRun=nil;self.tuningReview=nil
    self.trimStatus=nil;self.baseline=nil;self.boots=nil;self.mixBaseline=nil
    -- Revoke the previous lift PID lease once on operator acceptance. The
    -- normal update loop skips context renewals while latched, leaving status
    -- reception, sensors and cockpit selector sampling independent of KILL.
    if type(io.sendLiftControlContext)=="function" then
        local inactive={selectedAltitude=nil,pidActive=false,inputsActive=false}
        for _,q in ipairs(QUADS) do pcall(io.sendLiftControlContext,io,q,inactive) end
    end
    self.reason="EMERGENCY LIFT KILL IN PROGRESS"
    self.emergencyLiftJob={requestedAt=now,deadline=now+EMERGENCY_LIFT_KILL_DISCOVERY_SECONDS,quadrants={}}
    for _,q in ipairs(EMERGENCY_LIFT_KILL_QUADRANTS) do
        self.emergencyLiftJob.quadrants[q]={status="WAITING_FOR_FRESH_NODE",attempts=0,
            nextAt=now,ackReason="Waiting for fresh lift-node status"}
    end
    self:updateEmergencyLiftKill(io,now)
    self.systemsSnapshot={active=false,available=false,phase="EMERGENCY KILL",pending=true,complete=false,
        reason="Emergency lift kill is being verified"}
    return true,"EMERGENCY LIFT KILL REQUESTED"
end
-- @ama-summary: Send the active emergency-stop request to each required chamber.
function Flight:sendEmergencyLiftKill(io,q,item,now)
    local node=io.nodes and io.nodes[q]
    if type(io.nodeFresh)~="function" or not io:nodeFresh(q,now) or not node or type(node.boot)~="string" then
        item.status="WAITING_FOR_FRESH_NODE";item.ackReason="Waiting for fresh lift-node status"
        return false
    end
    if type(io.sendEmergencyLiftStop)~="function" then
        item.status="FAILED";item.ackReason="Emergency lift-stop interface unavailable"
        return false
    end
    local ok,seq,boot=io:sendEmergencyLiftStop(q,now)
    item.attempts=item.attempts+1
    item.sentAt=now;item.nextAt=now+EMERGENCY_LIFT_KILL_RETRY_SECONDS
    if ok and finite(seq) and boot==node.boot then
        item.seq=seq;item.boot=boot;item.status="PENDING_ACK"
        item.ackReason="Waiting for eight bulk-off links and the fine probe floor to read back"
        return true
    end
    item.status=item.attempts>=EMERGENCY_LIFT_KILL_ATTEMPTS and "FAILED" or "PENDING_ACK"
    item.seq=nil;item.boot=node.boot
    item.ackReason=tostring(seq or "Emergency lift-stop send failed")
    return false
end
-- @ama-summary: Retry emergency shutdown and verify each chamber's stop readback.
function Flight:updateEmergencyLiftKill(io,now)
    local job=self.emergencyLiftJob
    if not job or self.emergencyLiftLatched~=true then return end
    if job.recovering then
        local confirmed,pending=0,0
        local missing={}
        for _,q in ipairs(EMERGENCY_LIFT_KILL_QUADRANTS) do
            local item=job.quadrants[q]
            local node=io.nodes and io.nodes[q]
            local fresh=type(io.nodeFresh)=="function" and io:nodeFresh(q,now)
            if fresh and node and type(io.emergencyLiftStopStateVerified)=="function" then
                local verified,why=io:emergencyLiftStopStateVerified(q,node.boot,now)
                if verified then
                    item.status="CONFIRMED";item.boot=node.boot;item.seq=node.emergencyStopAppliedSeq
                    item.ackReason="Fresh readbacks confirm BULK OFF / PROBE ON after reboot"
                else
                    item.status="FAILED";item.boot=node.boot
                    item.ackReason="Fresh status cannot verify BULK OFF / PROBE ON: "..tostring(why)
                end
            elseif fresh then
                item.status="FAILED";item.ackReason="Endpoint lacks emergency latch readback; press KILL LIFT to reassert"
            else
                item.status="WAITING_FOR_FRESH_NODE";item.ackReason="Waiting for fresh endpoint state after reboot"
            end
            if item.status=="CONFIRMED" then confirmed=confirmed+1
            elseif item.status=="WAITING_FOR_FRESH_NODE" then pending=pending+1;missing[#missing+1]=q
            else missing[#missing+1]=q end
        end
        job.complete=confirmed==#EMERGENCY_LIFT_KILL_QUADRANTS
        job.pending=pending>0
        job.phase=job.complete and "KILL CONFIRMED" or (pending>0 and "RECHECKING AFTER REBOOT" or "KILL INCOMPLETE")
        job.reason=job.complete and "ALL FOUR CHAMBERS REPORTED BULK OFF / PROBE ON AFTER REBOOT" or
            ("RECHECK / REASSERT REQUIRED: "..table.concat(missing,", ").." ("..confirmed.."/4 confirmed)")
        self.reason=job.reason
        self.systemsSnapshot={active=false,available=false,phase=job.phase,pending=job.pending,
            complete=job.complete,reason=job.reason}
        if job.phase=="KILL INCOMPLETE" then
            local details=emergencyKillFailureDetails(job)
            logOperationIssue(self,"flight","emergency lift kill",job.reason..(details and "; "..details or ""))
        elseif job.phase=="KILL CONFIRMED" then
            clearOperationIssue(self,"flight","emergency lift kill","Core emergency lift kill recovered: BULK OFF / PROBE ON verified")
        end
        return
    end
    for _,q in ipairs(EMERGENCY_LIFT_KILL_QUADRANTS) do
        local item=job.quadrants[q]
        local node=io.nodes and io.nodes[q]
        local fresh=type(io.nodeFresh)=="function" and io:nodeFresh(q,now)
        if item.status=="CONFIRMED" then
            if not fresh or not node or node.boot~=item.boot then
                item.status="WAITING_FOR_FRESH_NODE";item.attempts=0;item.seq=nil;item.boot=nil
                item.nextAt=now;item.ackReason="Node boot changed or became stale after BULK OFF / PROBE ON was confirmed"
            else
                local stillOff,why=false,"Emergency stop readback unavailable"
                if item.seq and type(io.emergencyLiftStopWasApplied)=="function" then
                    stillOff,why=io:emergencyLiftStopWasApplied(q,item.seq,item.boot,now)
                end
                if not stillOff then
                    if item.attempts>=EMERGENCY_LIFT_KILL_ATTEMPTS then
                        item.status="FAILED";item.ackReason="BULK OFF / PROBE ON no longer verified after bounded retries: "..tostring(why)
                    else
                        item.status="PENDING_ACK";item.nextAt=now
                        item.ackReason="BULK OFF / PROBE ON changed; reasserting KILL: "..tostring(why)
                    end
                end
            end
        end
        if item.status=="PENDING_ACK" then
            local applied,why=false,"Emergency stop acknowledgement unavailable"
            if item.seq and type(io.emergencyLiftStopWasApplied)=="function" then
                applied,why=io:emergencyLiftStopWasApplied(q,item.seq,item.boot,now)
            end
            if applied then
                item.status="CONFIRMED";item.ackReason="Eight bulk links off; fine probe verified at target 5 / signal 15"
            else
                item.ackReason=tostring(why or "Waiting for emergency stop acknowledgement")
                if now>=(item.nextAt or now) then
                    if item.attempts>=EMERGENCY_LIFT_KILL_ATTEMPTS then
                        item.status="FAILED";item.ackReason="No verified BULK OFF / PROBE ON acknowledgement after bounded retries: "..item.ackReason
                    else self:sendEmergencyLiftKill(io,q,item,now) end
                end
            end
        elseif item.status=="WAITING_FOR_FRESH_NODE" and now>=(item.nextAt or now) then
            if fresh then
                self:sendEmergencyLiftKill(io,q,item,now)
            elseif now>=job.deadline then
                item.status="FAILED";item.ackReason="No fresh node status before bounded discovery timeout"
            else
                item.ackReason="Waiting for fresh lift-node status"
            end
        end
    end
    local confirmed,pending=0,0
    local missing={}
    for _,q in ipairs(EMERGENCY_LIFT_KILL_QUADRANTS) do
        local item=job.quadrants[q]
        if item.status=="CONFIRMED" then confirmed=confirmed+1
        elseif item.status=="WAITING_FOR_FRESH_NODE" or item.status=="PENDING_ACK" then
            pending=pending+1;missing[#missing+1]=q
        else missing[#missing+1]=q end
    end
    job.complete=confirmed==#EMERGENCY_LIFT_KILL_QUADRANTS
    job.pending=pending>0
    job.phase=job.complete and "KILL CONFIRMED" or (pending>0 and "KILLING" or "KILL INCOMPLETE")
    job.reason=job.complete and "ALL FOUR CHAMBERS CONFIRMED BULK OFF / PROBE ON" or
        ("WAITING FOR / FAILED: "..table.concat(missing,", ").." ("..confirmed.."/4 confirmed)")
    self.reason=job.reason
    self.systemsSnapshot={active=false,available=false,phase=job.phase,pending=job.pending,complete=job.complete,
        reason=job.reason}
    if job.phase=="KILL INCOMPLETE" then
        local details=emergencyKillFailureDetails(job)
        logOperationIssue(self,"flight","emergency lift kill",job.reason..(details and "; "..details or ""))
    elseif job.phase=="KILL CONFIRMED" then
        clearOperationIssue(self,"flight","emergency lift kill","Core emergency lift kill recovered: BULK OFF / PROBE ON verified")
    end
end
-- @ama-summary: Start the confirmed disarm operation against the retained emergency latch.
function Flight:disarmLiftKill(io,now)
    if not self.emergencyLiftLatched then return false,"LIFT KILL IS NOT LATCHED" end
    if self.emergencyLiftDisarmJob then return true,"DISARM KILL ALREADY IN PROGRESS" end
    if self.restart and (self.restart.job or self.restart.saved) then self.restart:cancel("RESTART CANCELLED BY DISARM KILL") end
    self:setSystemsIntent(false)
    self.emergencyLiftDisarmJob={quadrants={},reason="WAITING FOR CHAMBER DISARM ACKNOWLEDGEMENTS"}
    return true,"DISARM KILL REQUESTED; SYSTEMS REMAIN STOPPED"
end

-- @ama-summary: Track disarm acknowledgements and clear the completed core latch.
function Flight:updateLiftDisarm(io,now)
    local job=self.emergencyLiftDisarmJob
    if not job then return end
    local complete=true
    for _,q in ipairs(EMERGENCY_LIFT_KILL_QUADRANTS) do
        local item=job.quadrants[q] or {};job.quadrants[q]=item
        local node=io.nodes and io.nodes[q]
        local fresh=node and io:nodeFresh(q,now)
        local ack=fresh and item.seq and node.boot==item.boot and
            node.emergencyDisarmAppliedSeq==item.seq and node.emergencyStopLatched==false
        item.status=ack and "DISARMED" or "WAITING"
        if not ack then
            complete=false
            if not item.sentAt or now-item.sentAt>=2 or (fresh and node.boot~=item.boot) then
                local ok,seq,boot=io:sendEmergencyLiftDisarm(q,now)
                item.sentAt=now
                if ok then item.seq=seq;item.boot=boot else item.ackReason=seq end
            end
        end
    end
    if self.emergencyLiftDisarmJob~=job or not self.emergencyLiftLatched or not complete then return end
    -- The stopped intent must survive reboot before the durable kill interlock
    -- is released. A cached setSystemsIntent(false) alone is insufficient.
    if self.storage and type(self.storage.writeJson)=="function" then
        local callOk,saved,reason=pcall(self.storage.writeJson,SYSTEMS_INTENT_PATH,{schemaVersion=1,active=false})
        if not callOk or not saved then
            job.reason="DISARM STOPPED STATE SAVE FAILED: "..tostring(callOk and reason or saved)
            return
        end
    end
    if self.emergencyLiftDisarmJob~=job or not self.emergencyLiftLatched then return end
    self.systemsIntentLoaded=true;self.systemsIntentActive=false
    local saved,reason=self:persistEmergencyLock(false)
    if self.emergencyLiftDisarmJob~=job then
        if self.emergencyLiftLatched then self:persistEmergencyLock(true) end
        return
    end
    if not saved then job.reason="DISARM SAVE FAILED: "..tostring(reason);return end
    self.emergencyLiftLatched=false;self.emergencyLiftJob=nil;self.emergencyLiftDisarmJob=nil
    self.systemsAvailable=false;self.systemsRun=nil;self.enabled=false;self.pending=false
    self.reason="LIFT KILL DISARMED; SYSTEMS STOPPED"
    self.systemsSnapshot={active=false,available=false,phase="STOPPED",reason=self.reason}
end

-- @ama-summary: Build the current kill, verification and disarm state for displays.
function Flight:emergencyLiftState()
    local disarm=self.emergencyLiftDisarmJob
    if disarm then return {latched=true,disarming=true,pending=true,phase="DISARMING",
        reason=disarm.reason,quadrants=clone(disarm.quadrants),persistenceWarning=self.emergencyLiftPersistenceWarning} end
    local job=self.emergencyLiftJob
    if not job then return {latched=self.emergencyLiftLatched==true,active=false,complete=false,pending=false,
        phase=self.emergencyLiftLatched and "KILL REQUIRED" or "IDLE",reason=self.emergencyLiftLatched and
        "DISARM KILL BEFORE START SYSTEMS" or nil,
        mode=self.emergencyLiftLatched and "BULK_OFF_PROBE_ON" or nil,
        persistenceWarning=self.emergencyLiftPersistenceWarning,quadrants={}} end
    local quadrants={}
    for _,q in ipairs(EMERGENCY_LIFT_KILL_QUADRANTS) do
        local item=job.quadrants[q] or {}
        quadrants[q]={status=item.status,ackReason=item.ackReason,attempts=item.attempts or 0,
            boot=item.boot,seq=item.seq}
    end
    return {latched=self.emergencyLiftLatched==true,active=self.emergencyLiftLatched==true and job.complete~=true,
        complete=job.complete==true,pending=job.pending==true,phase=job.phase or "KILLING",
        reason=job.reason,mode=self.emergencyLiftLatched and "BULK_OFF_PROBE_ON" or nil,
        persistenceWarning=self.emergencyLiftPersistenceWarning,quadrants=quadrants}
end
-- Read-only gate for explicitly recovering from a latched emergency stop.
-- A prior complete job is not enough if any endpoint has since gone stale,
-- changed boot, or stopped reporting the exact probe-preserving policy.
-- @ama-summary: Verify the retained emergency-stop observations during recovery.
function Flight:emergencyLiftRecoveryVerified(io,now)
    if self.emergencyLiftLatched~=true then return true end
    local disarm=self.emergencyLiftDisarmJob
    if disarm then return {latched=true,disarming=true,pending=true,phase="DISARMING",
        reason=disarm.reason,quadrants=clone(disarm.quadrants),persistenceWarning=self.emergencyLiftPersistenceWarning} end
    local job=self.emergencyLiftJob
    if not job then return false,"EMERGENCY KILL STATUS NOT VERIFIED" end
    for _,q in ipairs(EMERGENCY_LIFT_KILL_QUADRANTS) do
        local item=job.quadrants and job.quadrants[q]
        local node=io.nodes and io.nodes[q]
        if not item or item.status~="CONFIRMED" then
            local detail=item and item.ackReason or job.reason or "NO CONFIRMED READBACK"
            return false,"EMERGENCY KILL "..q.." NOT VERIFIED: "..tostring(detail)
        end
        if not node or type(io.nodeFresh)~="function" or not io:nodeFresh(q,now) then
            return false,"EMERGENCY KILL "..q.." STATUS STALE"
        end
        if type(item.boot)~="string" or node.boot~=item.boot then
            return false,"EMERGENCY KILL "..q.." BOOT CHANGED"
        end
        local verified,reason
        if job.recovering or item.seq==nil then
            if type(io.emergencyLiftStopStateVerified)~="function" then
                return false,"EMERGENCY KILL "..q.." READBACK VERIFIER UNAVAILABLE"
            end
            verified,reason=io:emergencyLiftStopStateVerified(q,item.boot,now)
        elseif type(io.emergencyLiftStopWasApplied)=="function" then
            verified,reason=io:emergencyLiftStopWasApplied(q,item.seq,item.boot,now)
        else
            return false,"EMERGENCY KILL "..q.." ACKNOWLEDGEMENT VERIFIER UNAVAILABLE"
        end
        if not verified then
            return false,"EMERGENCY KILL "..q.." NO LONGER VERIFIED: "..tostring(reason or "READBACK INVALID")
        end
    end
    if job.complete~=true then return false,job.reason or "ALL FOUR EMERGENCY KILL READBACKS NOT CONFIRMED" end
    return true
end
local ASSEMBLY_GATED={start_systems=true,restart_systems=true,recover_systems=true,altitude_engage=true,vent_startup=true,cockpit_mode=true,
    tuning_review=true,tuning_confirm=true}
-- Fake IO tables in older tests have no gate; real IO always does.
function Flight.assemblyGate(io,now)
    if type(io.assemblyGate)~="function" then return true end
    return io:assemblyGate(now)
end
function Flight:ensureAutopilot(io)
    io.autopilot=io.autopilot or Autopilot.new(io.config,self.storage,io.navigationDependencies)
    return io.autopilot
end
-- @ama-section: Flight lifecycle | Operator actions, runtime gates and cached presentation.
-- @ama-summary: Validate a pilot action and dispatch it to the corresponding flight operation.
function Flight:request(io,action,now)
    if type(action)~="table" or type(action.type)~="string" then return false,"INVALID ACTION" end
    if action.type=="debug_mode" then
        if not io.debugRecorder or io.debugRecorder.workerAvailable==false then return false,"DEBUG RECORDER UNAVAILABLE" end
        return io.debugRecorder:request(action.enabled)
    end
    if action.type=="ap_disengage" then
        if io.autopilot then io.autopilot:cancel(io,self.controls,"DISENGAGED; SELECTED MODES RETAINED") end
        return true,"AUTOPILOT DISENGAGED; SELECTED MODES RETAINED"
    end
    if action.type=="ap_engage" or action.type=="ap_edit" or action.type=="ap_current" or action.type:match("^destination_") then
        local ap=self:ensureAutopilot(io)
        if action.type=="ap_engage" then
            if self.emergencyLiftLatched or self.shutdownJob or self.tuningRun or self.maintenanceJob or
                (self.restart and (self.restart.job or self.restart.saved)) then return false,"SYSTEMS OPERATION IN PROGRESS" end
            if not self.enabled or (self.systemsRun and self.systemsRun.phase~="READY") then return false,"ESTABLISH ALTITUDE HOLD BEFORE ENGAGING AUTOPILOT" end
            local ok,why=ap:engage(io,self.controls,now)
            if not ok then logOperationIssue(self,"flight","autopilot engage",why) end
            return ok,why
        elseif action.type=="destination_save" or action.type=="destination_rename" or action.type=="destination_delete" then
            local entry={name=action.name or ap.draft.name,x=ap.draft.x,z=ap.draft.z}
            local operation=action.type:sub(13)
            local ok,why=ap.library:change(operation,action.index,entry)
            if not ok then logOperationIssue(self,"flight","destination library",why) end
            return ok,why
        else
            local ok,why=ap:edit(io,self.controls,action,now)
            if not ok then logOperationIssue(self,"flight","autopilot configuration",why) end
            return ok,why
        end
    end
    if action.type=="cockpit_mode" and io.autopilot and io.autopilot.active then return false,"DISENGAGE AUTOPILOT BEFORE CHANGING MODES" end
    if action.type=="anchor_cancel" then
        if io.autopilot and io.autopilot.active then io.autopilot:cancel(io,self.controls,"ARRIVAL ANCHOR RELEASED") end
        if io.positionAnchor then io.positionAnchor:cancel(self.controls) end
        if io.thrust then io.thrust:stop(io,"ANCHOR RELEASED") end
        return true,"ANCHOR RELEASED; SELECTED MODE RETAINED; NEUTRAL REQUIRED"
    end
    if action.type=="anchor_engage" then
        if io.autopilot and io.autopilot.active then return false,"DISENGAGE AUTOPILOT BEFORE ENGAGING ANCHOR" end
        if self.emergencyLiftLatched or self.shutdownJob or (self.restart and (self.restart.job or self.restart.saved)) then
            return false,"SYSTEMS STOP / RESTART IN PROGRESS"
        end
        if not io.thrust or (io.config.thrust or {}).enabled~=true then return false,"ENABLE PROPULSION FIRST" end
        local ready,why=io.thrust:activationReady(io,now,self.controls)
        if not ready then logOperationIssue(self,"flight","anchor engage",why);return false,why end
        io.positionAnchor=io.positionAnchor or Anchor.new(io.config)
        local ok,reason=io.positionAnchor:engage(io,now)
        if not ok then logOperationIssue(self,"flight","anchor engage",reason) end
        return ok,reason
    end
    if action.type=="propulsion_disable" then
        if io.autopilot then io.autopilot:cancel(io,self.controls,"PROPULSION DISABLED",false) end
        if io.positionAnchor then io.positionAnchor:cancel(self.controls,"PROPULSION DISABLED") end
        if not io.thrust then return false,"PROPULSION CONTROLLER UNAVAILABLE" end
        local accepted,reason=io.thrust:setEnabled(io,now,self.controls,false,self.storage,self.settingsDependencies)
        if not accepted then logOperationIssue(self,"flight","propulsion disable",reason) end
        return accepted,reason
    end
    if action.type=="emergency_kill_lift" then
        if io.autopilot then io.autopilot:cancel(io,self.controls,"KILL LIFT",false) end
        if io.positionAnchor then io.positionAnchor:cancel(self.controls,"KILL LIFT") end
        if self.restart then self.restart:cancel("RESTART CANCELLED BY KILL LIFT") end
        return self:emergencyKillLift(io,now)
    end
    if action.type=="disarm_lift_kill" then return self:disarmLiftKill(io,now) end
    if self.emergencyLiftLatched and action.type~="restart_systems" and action.type~="setting_update" and
        action.type~="manual_trim_adjust" and action.type~="manual_trim_reset" then
        return false,"EMERGENCY LIFT KILL LATCHED; DISARM KILL FIRST"
    end
    if action.type=="systems_stop" then return self:shutdownReview(io,now) end
    if action.type=="systems_stop_cancel" then
        if not self.stopReview then return false,"NO STOP REVIEW TO CANCEL" end
        self.stopReview=nil;self:cancelLateral(false);return true,"STOP CANCELLED"
    end
    if action.type=="systems_stop_confirm" then
        local accepted,reason=self:confirmShutdown(io,action,now)
        if accepted and io.autopilot then io.autopilot:cancel(io,self.controls,"STOP SYSTEMS",false) end
        if accepted and io.positionAnchor then io.positionAnchor:cancel(self.controls,"STOP SYSTEMS") end
        if accepted and self.restart then self.restart:cancel("RESTART CANCELLED BY STOP SYSTEMS") end
        return accepted,reason
    end
    local routeRequired=action.type=="recover_systems" or action.type=="start_systems" or action.type=="restart_systems" or action.type=="altitude_engage" or
        action.type=="vent_startup" or action.type=="cockpit_mode" or
        action.type=="tuning_confirm" or action.type=="tuning_start" or
        action.type=="maintenance_restart" or action.type=="maintenance_recheck" or
        action.type=="manual_trim_adjust" or action.type=="manual_trim_reset"
    if routeRequired and type(io.routeAllowed)=="function" then
        local allowed,why=io:routeAllowed()
        if not allowed then return false,why end
    elseif routeRequired and io.identityReady==false then
        return false,io.identityReason or "CORE IDENTITY UNVERIFIED"
    end
    if self.shutdownJob then return false,"SHUTDOWN IN PROGRESS" end
    -- Assembly gate: anything that could create lift, thrust or cockpit
    -- authority is refused. Stops, cancels, settings and lift-computer
    -- maintenance stay available on a disassembled vessel.
    if ASSEMBLY_GATED[action.type] and not (action.type=="restart_systems" and self.emergencyLiftLatched) then
        local assembled,why=Flight.assemblyGate(io,now)
        if not assembled then return false,why end
    end
    if action.type=="manual_trim_adjust" or action.type=="manual_trim_reset" then
        return self:manualTrimRequest(io,action,now)
    end
    if action.type=="recover_systems" then return self:recoverSystems(io,now) end
    if action.type=="restart_systems" then
        if not self.restart then return false,"SYSTEMS RESTART UNAVAILABLE" end
        if self.emergencyLiftDisarmJob then return false,"DISARM KILL IN PROGRESS" end
        local accepted,reason=self.restart:request(self,io,now)
        if not accepted then logOperationIssue(self,"flight","restart",reason) end
        return accepted,reason
    end
    if action.type=="propulsion_enable" then
        if not io.thrust then return false,"PROPULSION CONTROLLER UNAVAILABLE" end
        local accepted,reason=io.thrust:setEnabled(io,now,self.controls,true,self.storage,self.settingsDependencies)
        if not accepted then logOperationIssue(self,"flight","propulsion enable",reason) end
        return accepted,reason
    end
    if self.systemsRun then
        if action.type=="altitude_disengage" then return self:shutdownReview(io,now) end
        if action.type=="start_systems" then return false,"START SYSTEMS ALREADY ACTIVE" end
        if action.type=="cockpit_mode" and self.controls then
        local ok,reason=self.controls:mode(io,action,now)
        if ok and io.controlPresets then
            io.controlPresets:cancelRestore()
            -- Persist the explicit selection before its acknowledgement.
            io.controlPresets:update(io,self,now)
        end
        return ok,reason
    end
        if action.type=="setting_update" and self.systemsRun.phase=="READY" then
            return self:setting(io,action,now)
        end
        return false,"START SYSTEMS SEQUENCE ACTIVE"
    end
    if action.type=="start_systems" then
        local callOk,started,reason=pcall(self.startSystems,self,io,now)
        if not callOk then
            reason="START SYSTEMS ERROR: "..tostring(started);started=false
            logOperationIssue(self,"flight","systems",reason)
        end
        if started then self:cancelLateral(false) end
        if not callOk then return false,reason end
        return started,reason
    end
    if type(action.type)=="string" and action.type:match("^tuning_") then return self:tuningRequest(io,action,now) end
    if self.tuningRun and action.type=="altitude_disengage" then return self:tuningRequest(io,{type="tuning_stop"},now) end
    if self.tuningRun then return false,"PID TUNING IN PROGRESS" end
    if action.type=="setting_update" then return self:setting(io,action,now) end
    if type(action.type)=="string" and action.type:match("^maintenance_") then return self:maintenanceRequest(io,action,now) end
    if self.maintenanceJob and action.type~="altitude_disengage" then return false,"LIFT MAINTENANCE IN PROGRESS" end
    if action.type=="cockpit_mode" and self.controls then
        local ok,reason=self.controls:mode(io,action,now)
        if ok and io.controlPresets then
            io.controlPresets:cancelRestore()
            -- Persist the explicit selection before its acknowledgement.
            io.controlPresets:update(io,self,now)
        end
        return ok,reason
    end
    if action.type=="vent_startup" then return false,"USE START SYSTEMS" end
    if action.type=="altitude_disengage" then self:stop(); return true end
    if action.type=="altitude_engage" then return self:engage(io,now) end
    return false,"FLIGHT ACTION UNAVAILABLE"
end
-- Minimum-output preparation is a separate, explicitly requested operation.
-- It cannot grant altitude authority, raise an already operating vent ceiling,
-- reset the trim probe, or restore itself on boot.
-- @ama-section: Systems control | Startup, measured dynamics and bounded provider demand.
-- @ama-summary: Build bounded startup provider targets from the configured vent request.
function Flight:startupTargets(io,now)
    if self.tuningRun then return nil,"PID TUNING IN PROGRESS" end
    if self.maintenanceJob then return nil,"LIFT MAINTENANCE IN PROGRESS" end
    if io.config.vent_startup_enabled~=true then return nil,"VENT STARTUP DISABLED" end
    if self.enabled then return nil,"ALTITUDE CONTROL ALREADY ENGAGED" end
    if self.controls and not self.controls:usable(io,now) then return nil,"COCKPIT CONTROLS UNAVAILABLE" end
    if io.anchor=="ANCHORED" or io.anchor=="BRAKING" then return nil,"ANCHOR SUPPRESSES STARTUP" end
    local v=io.vessel
    if not v or not v.valid or not v.uuid or not finite(v.at) or now<v.at or
        now-v.at>io.config.network.sensor_stale_seconds then return nil,"VESSEL DATA UNAVAILABLE" end
    local maps={}
    for _,q in ipairs(QUADS) do
        local n=io.nodes[q]
        if not n or not io:nodeFresh(q,now) or not n.startReady or n.armed or n.operationBusy or not n.boot or
            not n.altitude or not n.altitude.valid then return nil,q.." STARTUP INTERFACES NOT READY" end
        local b=n.balloon
        if not b or not b.hasBalloonValid or not b.hasBalloon or not b.gasMixValid then return nil,q.." PROBE ENVELOPE UNAVAILABLE" end
        local bulk,fine=0,0;maps[q]={}
        for name,p in pairs(n.providers) do
            if not p.present or not p.writable or not p.targetValid or not finite(p.targetAmount) or
                not p.signalValid or not finite(p.signalStrength) then return nil,q.." STARTUP PROVIDER INTERFACE INVALID" end
            if p.controlRole=="bulk" then
                bulk=bulk+1
                if p.minimumNonzeroTarget~=50 or p.maxTarget<50 or
                    (p.signalStrength>1 and p.targetAmount~=50) then return nil,q.." VENT ALREADY OPERATING / FLOOR INVALID" end
                maps[q][name]=50
            elseif p.controlRole=="fine" then
                fine=fine+1
                if p.signalStrength~=15 or not p.attachedValid or not p.attached or p.targetAmount<5 then
                    return nil,q.." ACTIVE TRIM PROBE REQUIRED"
                end
                maps[q][name]=p.targetAmount
            else return nil,q.." PROVIDER ROLE INVALID" end
        end
        if bulk~=steamCount(n) or fine~=1 then return nil,q.." EXPECTED CONFIGURED VENTS AND ONE PROBE" end
    end
    local model,modelReason=self:balancedLiftModel(io,self.controls and self.controls.targets and
        self.controls.targets.altitude or v.altitude,now)
    self.balancedLift=model
    if model.phase=="UNAVAILABLE" or model.phase=="INFEASIBLE" then
        if self:isFloorOnlyTargets(io,maps,false,true) then return maps end
        return nil,modelReason or model.reason or "BALANCED LIFT CAPACITY UNAVAILABLE"
    end
    local capped,capReason,limited=self:capBalancedTargets(io,maps,model)
    if not capped then return nil,capReason end
    if limited then
        for _,q in ipairs(QUADS) do
            for name,value in pairs(capped[q]) do
                if value~=maps[q][name] then return nil,"BALANCED LIFT LIMIT BELOW VERIFIED STARTUP FLOOR" end
            end
        end
    end
    maps=capped
    return maps
end
-- @ama-section: Flight lifecycle | Operator actions, runtime gates and cached presentation.
-- @ama-summary: Validate and send the requested initial vent-start operation.
function Flight:startVents(io,now)
    if self.startupPending then return false,"VENT STARTUP ALREADY PENDING" end
    if self.startupComplete then return false,"VENTS ALREADY OPERATING" end
    local maps,reason=self:startupTargets(io,now)
    if not maps then return false,reason end
    self.startupPending={};self.startupSentAt=now;self.startupReason="WAITING FOR VENT TELEMETRY"
    for _,q in ipairs(QUADS) do
        local sent,seq=io:sendVentStartup(q,maps[q])
        if not sent then
            self.startupPending=nil;self.startupReason=q.." STARTUP SEND FAILED: "..tostring(seq)
            return false,self.startupReason
        end
        self.startupPending[q]={seq=seq,targets=maps[q],boot=io.nodes[q].boot}
    end
    return true
end

-- START SYSTEMS is an explicit, session-limited route from an idle vessel to
-- an altitude hold. The controller uses measured balloon lift and vessel
-- weight; ceiling slew is only a safety limit and does not assume a gas/lift
-- conversion factor.
local SYSTEMS_PROBE_RENEW_SECONDS=5
local SYSTEMS_TARGET_TOLERANCE_BLOCKS=1
local SYSTEMS_LIFT_PROGRESS_EPSILON=0.005
-- A separate lower threshold marks response onset. The larger progress epsilon
-- is for stall detection; using it to time plant lag includes the startup
-- ceiling ramp and can mistake actuator excitation time for envelope delay.
local SYSTEMS_LIFT_RESPONSE_ONSET_EPSILON=0.0001
local SYSTEMS_ACK_TIMEOUT_SECONDS=12
local SYSTEMS_RECOVERY_RETRY_SECONDS=1.5
local SYSTEMS_SAMPLE_GAP_SECONDS=3
local SYSTEMS_ENVELOPE_TIMEOUT_SECONDS=120
local SYSTEMS_FULL_BOILER_EFFICIENCY=0.95
local SYSTEMS_RAMP_FRACTION_PER_SECOND=0.02
local SYSTEMS_FAST_RAMP_FRACTION_PER_SECOND=0.08
-- Keep the first ceiling steps small while the envelope is still near its
-- floor. Measured support and vessel response earn the faster existing rates.
local SYSTEMS_SOFT_START_RAMP_FRACTION_PER_SECOND=0.002
local SYSTEMS_FAST_RELEASE_FRACTION_PER_SECOND=0.12
-- Preserve the proven feedback slew when reducing ceilings. A faster release
-- caused repeated over-correction in the delayed-fill model and did not
-- remove lift already accumulated in the envelope.
local SYSTEMS_RELEASE_RAMP_FRACTION_PER_SECOND=SYSTEMS_RAMP_FRACTION_PER_SECOND
local SYSTEMS_RATE_STABLE_SAMPLES=3
local SYSTEMS_FAST_FILL_TAPER_FRACTION=0.8
local SYSTEMS_FAST_FILL_STOP_FRACTION=0.98
local SYSTEMS_STARTUP_CONTROL_HORIZON_SECONDS=30
local SYSTEMS_STARTUP_SPEED_RAMP_SECONDS=60
local SYSTEMS_MAX_SLEW_CATCHUP_SECONDS=3
-- Operator-tunable startup shaping (altitude_control.*). Missing or
-- out-of-range values fall back to the original constants above.
local function startupSetting(config,key,default,minimum,maximum)
    local control=type(config)=="table" and (type(config.altitude_control)=="table" and config.altitude_control or config) or nil
    local value=control and control[key]
    if finite(value) and value>=minimum and value<=maximum then return value end
    return default
end
local function startupRampSeconds(config)
    return startupSetting(config,"startup_acceleration_seconds",SYSTEMS_STARTUP_SPEED_RAMP_SECONDS,5,600)
end
local function startupLookaheadSeconds(config)
    return startupSetting(config,"startup_braking_lookahead_seconds",SYSTEMS_STARTUP_CONTROL_HORIZON_SECONDS,5,120)
end
local function ceilingRiseRates(config)
    local soft=startupSetting(config,"ceiling_soft_start_rate",SYSTEMS_SOFT_START_RAMP_FRACTION_PER_SECOND,0.0005,0.05)
    local normal=math.max(soft,startupSetting(config,"ceiling_rise_rate",SYSTEMS_RAMP_FRACTION_PER_SECOND,0.005,0.1))
    local fast=math.max(normal,startupSetting(config,"ceiling_fast_rate",SYSTEMS_FAST_RAMP_FRACTION_PER_SECOND,0.02,0.25))
    return soft,normal,fast
end
-- @ama-summary: Refresh PID measurement history using the observed elapsed sample time.
local function observePidMeasurement(pid,measurement,elapsed)
    if not pid or not finite(measurement) then return end
    local gains=pid.g
    if finite(elapsed) and elapsed>0 and elapsed<=SYSTEMS_SAMPLE_GAP_SECONDS and
        gains and finite(gains.derivative_filter_seconds) and gains.derivative_filter_seconds>=0 and
        finite(pid.previous) and finite(pid.d) then
        local alpha=elapsed/(gains.derivative_filter_seconds+elapsed)
        local rawDerivative=-(measurement-pid.previous)/elapsed
        pid.d=pid.d+alpha*(rawDerivative-pid.d)
    else
        -- Long ACK waits are deliberately not fed to the next PID sample as a
        -- single derivative or integral interval. Re-anchor to current data.
        pid.d=0
    end
    pid.previous=measurement
end
local function systemsStartupControlHorizon(config,onset,sampleSeconds)
    local sample=finite(sampleSeconds) and math.max(0,sampleSeconds) or 0
    return math.max(startupLookaheadSeconds(config),
        finite(onset) and math.max(0,onset)*2 or 0,sample)
end
local function systemsStartupEnvelopeHorizon(onset,sampleSeconds)
    local sample=finite(sampleSeconds) and math.max(0,sampleSeconds) or 0
    return math.max(6,finite(onset) and math.max(0,onset)*3 or 0,sample)
end
local function systemsStartupNominalSpeed(config)
    local speed=config and config.startup_max_vertical_speed
    if finite(speed) and speed>0 then return speed end
    speed=config and config.max_vertical_speed
    return finite(speed) and speed>0 and speed or 1
end
local function systemsStartupSpeedLimit(config)
    local limit=config and config.startup_vertical_speed_limit
    if finite(limit) and limit>0 then return limit end
    local legacy=config and config.max_vertical_speed
    if not finite(legacy) or legacy<=0 then legacy=1 end
    return legacy+1
end
-- @ama-section: Systems control | Startup, measured dynamics and bounded provider demand.
-- @ama-summary: Bound startup acceleration using configured limits and measured command/response delay.
local function systemsStartupAcceleration(config,lag,sampleSeconds,ackWaitSeconds)
    local nominal=systemsStartupNominalSpeed(config)
    -- Earn nominal startup speed over a fixed conservative physical horizon,
    -- extended when measured vessel response is slower. Certification dwell
    -- settings do not determine the takeoff curve.
    local horizon=math.max(startupRampSeconds(config),
        finite(lag) and math.max(0,lag)*2 or 0)
    if finite(sampleSeconds) and sampleSeconds>0 and finite(ackWaitSeconds) and
        ackWaitSeconds>sampleSeconds*1.5 then
        -- A command that is only applied after a multi-sample ACK wait cannot
        -- safely use the fast-ACK acceleration budget. Scale the existing
        -- ramp horizon by the observed command cadence, bounded by the ACK
        -- timeout, while leaving nominal and hard vertical-speed limits alone.
        local cadence=clamp((ackWaitSeconds+sampleSeconds)/sampleSeconds,1,
            (SYSTEMS_ACK_TIMEOUT_SECONDS+sampleSeconds)/sampleSeconds)
        horizon=math.max(horizon,startupRampSeconds(config)*cadence)
    end
    return nominal/horizon
end
local function systemsStartupSpeedRampHorizon(config,lag,sampleSeconds,ackWaitSeconds)
    local nominal=systemsStartupNominalSpeed(config)
    local acceleration=systemsStartupAcceleration(config,lag,sampleSeconds,ackWaitSeconds)
    return math.max(systemsStartupControlHorizon(config,lag,sampleSeconds),nominal/math.max(acceleration,0.0001))
end
-- @ama-summary: Project the lift-to-weight support ratio over the measured response horizon.
local function systemsProjectedSupportRatio(actual,rate,horizon,supportDemand)
    if not finite(actual) then return nil end
    local future=actual
    if finite(rate) and finite(horizon) and horizon>0 then
        future=actual+rate*horizon
        if rate>0 and finite(supportDemand) then
            -- Let measured fill progress forecast through hover demand, with
            -- one continuous post-demand ceiling. Capping only while actual
            -- support is below demand creates a jump at the crossing that
            -- can flip the speed governor every sample.
            future=math.max(actual,math.min(future,supportDemand+rate*horizon))
        end
    end
    return future
end
-- @ama-summary: Estimate climb distance from current velocity and the observed lift response.
local function systemsProjectedClimbDistance(v,state,horizon,gravity,supportDemand)
    local rise=finite(v and v.verticalSpeed) and math.max(0,v.verticalSpeed) or 0
    if not finite(horizon) or horizon<=0 then return 0 end
    local actual=state and state.actualRatio
    local rate=state and (finite(state.projectedLiftRate) and state.projectedLiftRate or state.liftRate)
    local drag=state and state.verticalDragEstimate
    local acceleration
    if finite(actual) and finite(rate) and finite(gravity) and gravity>0 then
        local future=systemsProjectedSupportRatio(actual,rate,horizon,supportDemand)
        local meanSupport=(actual+future)*0.5
        drag=finite(drag) and math.max(0,drag) or 0
        acceleration=gravity*(meanSupport-1)-drag*rise
    elseif state and finite(state.verticalAccelerationRaw) then
        acceleration=state.verticalAccelerationRaw
    elseif state and finite(state.verticalAcceleration) then
        acceleration=state.verticalAcceleration
    end
    if not finite(acceleration) then return rise*horizon end
    local distance=rise*horizon+0.5*acceleration*horizon*horizon
    if acceleration<0 and rise>0 then
        local stopTime=rise/(-acceleration)
        if horizon>=stopTime then
            -- After the vertical speed reaches zero the vessel does not
            -- travel the negative portion of the constant-acceleration
            -- parabola. Keep the full ascent to the peak for any longer
            -- prediction horizon.
            distance=rise*rise/(2*-acceleration)
        end
    end
    return math.max(0,distance)
end
-- Keep the pure trajectory projection available to deterministic controller
-- regressions, including stopping-time horizons that outlast the ascent.
Flight._systemsProjectedClimbDistance=systemsProjectedClimbDistance
Flight._systemsProjectedSupportRatio=systemsProjectedSupportRatio
local function systemsSupportProgress(actualRatio,targetRatio)
    if not finite(actualRatio) or actualRatio<=0 then return 0 end
    local target=finite(targetRatio) and math.max(targetRatio,0.05) or 1
    local x=clamp(actualRatio/target,0,1)
    return x*x*(3-2*x)
end
-- @ama-summary: Sum configured bulk-vent ceilings across the selected target maps.
local function systemsBulkCeilingSum(maps,nodes)
    local total=0
    for _,q in ipairs(QUADS) do
        for name,value in pairs(maps and maps[q] or {}) do
            local provider=nodes and nodes[q] and nodes[q].providers and nodes[q].providers[name]
            if provider and provider.controlRole=="bulk" and finite(value) then total=total+value end
        end
    end
    return total
end
-- @ama-summary: Compare the requested bulk-vent target maps with the applied maps.
local function systemsBulkTargetsChanged(targets,previous,nodes)
    if type(previous)~="table" then return true end
    for _,q in ipairs(QUADS) do
        for name,provider in pairs(nodes and nodes[q] and nodes[q].providers or {}) do
            if provider.controlRole=="bulk" then
                local nextValue=targets and targets[q] and targets[q][name]
                local oldValue=previous[q] and previous[q][name]
                if nextValue~=oldValue then return true end
            end
        end
    end
    return false
end
local function copyMaps(maps)
    local out={}
    for q,targets in pairs(maps or {}) do out[q]=clone(targets) end
    return out
end
local BALANCED_LIFT_MATCH_FRACTION=0.05

-- @ama-summary: Calculate balanced chamber support bounds from verified provider capacity.
function Flight:balancedLiftModel(io,targetY,now)
    local function unavailable(reason)
        return {phase="UNAVAILABLE",reason=reason,targetSupportKnown=false,
            targetUnreachable=false},reason
    end
    local strengths=self.config and self.config.verified_gas_lift_strengths
    if type(strengths)~="table" then
        return unavailable("VERIFIED GAS LIFT STRENGTHS UNAVAILABLE")
    end
    now=now or (io.nowSeconds and io:nowSeconds()) or 0
    local vessel=io.vessel or {}
    if not finite(targetY) then targetY=vessel.altitude end
    local capacities,liftSum={},0
    local weakest,limiting=nil,nil
    local maxStrengthByQuadrant={}
    for _,q in ipairs(QUADS) do
        local node=io.nodes and io.nodes[q]
        if not node or (io.nodeFresh and not io:nodeFresh(q,now)) then
            return unavailable(q.." CAPACITY STATUS STALE")
        end
        local balloon=node.balloon or {}
        if balloon.hasBalloonValid~=true or balloon.hasBalloon~=true then
            return unavailable(q.." BALLOON ATTACHMENT NOT VERIFIED")
        end
        if balloon.capacityValid~=true or not finite(balloon.capacity) or balloon.capacity<=0 then
            return unavailable(q.." BALLOON CAPACITY UNAVAILABLE")
        end
        if balloon.gasMixValid~=true or type(balloon.gasMix)~="table" or
            balloon.liftValid~=true or not finite(balloon.lift) then
            return unavailable(q.." LIFT / COMPOSITION READBACK UNAVAILABLE")
        end
        local source=type(balloon.source)=="string" and node.providers and node.providers[balloon.source]
        if not source or source.present~=true or source.writable~=true or source.controlRole~="bulk" or
            source.signalValid~=true or source.signalStrength~=15 or
            source.attachedValid~=true or source.attached~=true or not source.gasTypeValid or
            (source.activeSupported==true and (source.activeValid~=true or source.active~=true)) or
            type(source.gasType)~="string" or not finite(balloon.gasMix[source.gasType]) or
            balloon.gasMix[source.gasType]<=0 then
            return unavailable(q.." WAITING FOR BULK ENVELOPE CAPACITY")
        end
        local expectedLift,gasAmount,positiveGases=0,0,0
        for gas,amount in pairs(balloon.gasMix) do
            if type(gas)~="string" or not finite(amount) or amount<0 then
                return unavailable(q.." GAS MIX INVALID")
            end
            if amount>0 then
                local strength=strengths[gas]
                if not finite(strength) or strength<=0 then
                    return unavailable(q.." LIFT STRENGTH UNVERIFIED FOR "..gas:sub(1,32))
                end
                expectedLift=expectedLift+amount*strength
                gasAmount=gasAmount+amount
                positiveGases=positiveGases+1
            end
        end
        if gasAmount<=0 or positiveGases==0 or not finite(expectedLift) or expectedLift<=0 then
            return unavailable(q.." POSITIVE GAS MIX REQUIRED")
        end
        local tolerance=math.max(1,expectedLift*BALANCED_LIFT_MATCH_FRACTION)
        if math.abs(balloon.lift-expectedLift)>tolerance then
            return unavailable(q.." RAW LIFT DOES NOT MATCH VERIFIED GAS MIX")
        end
        local maxStrength,count,bulk,fine=0,0,0,0
        local outputSlots,providerOutputMaximum=0,0
        local rankedOutputs={}
        for _,provider in pairs(node.providers or {}) do
            count=count+1
            if provider.present~=true or provider.writable~=true then
                return unavailable(q.." PROVIDER PRESENCE / WRITE CAPABILITY UNAVAILABLE")
            end
            local strength=configuredProviderStrength(self.config,provider)
            if not finite(strength) then
                return unavailable(q.." PROVIDER GAS TYPE UNAVAILABLE")
            end
            if not finite(strength) or strength<=0 then
                return unavailable(q.." PROVIDER LIFT STRENGTH UNVERIFIED FOR "..tostring(provider.gasType):sub(1,32))
            end
            maxStrength=math.max(maxStrength,strength)
            local maximum=provider.maxTarget
            if not finite(maximum) or maximum<0 then
                return unavailable(q.." PROVIDER MAXIMUM TARGET UNAVAILABLE")
            end
            outputSlots=outputSlots+maximum
            providerOutputMaximum=providerOutputMaximum+maximum*strength
            rankedOutputs[#rankedOutputs+1]={amount=maximum,strength=strength}
            if provider.controlRole=="bulk" then bulk=bulk+1
            elseif provider.controlRole=="fine" then fine=fine+1
            else return unavailable(q.." PROVIDER ROLE UNVERIFIED") end
        end
        if count~=steamCount(node)+1 or bulk~=steamCount(node) or fine~=1 then
            return unavailable(q.." EXPECTED CONFIGURED VENTS AND ONE TRIM BURNER")
        end
        table.sort(rankedOutputs,function(a,b)
            if a.strength==b.strength then return a.amount>b.amount end
            return a.strength>b.strength
        end)
        local remainingCapacity=balloon.capacity
        local capacityMaximum=0
        for _,slot in ipairs(rankedOutputs) do
            if remainingCapacity<=0 then break end
            local amount=math.min(slot.amount,remainingCapacity)
            capacityMaximum=capacityMaximum+amount*slot.strength
            remainingCapacity=remainingCapacity-amount
        end
        local maximum=math.min(capacityMaximum,providerOutputMaximum)
        capacities[q]={capacity=balloon.capacity,rawMaximum=maximum,
            providerRawMaximum=providerOutputMaximum,currentRawLift=balloon.lift,
            gasAmount=gasAmount,maxGasStrength=maxStrength}
        maxStrengthByQuadrant[q]=maxStrength
        liftSum=liftSum+balloon.lift
        if not weakest or maximum<weakest then weakest,limiting=maximum,q end
    end
    if not finite(weakest) or weakest<=0 then return unavailable("BALANCED CAPACITY LIMIT UNAVAILABLE") end
    local model={phase="READY",limitingQuadrant=limiting,
        rawPerQuadrantMaximum=weakest,rawVesselMaximum=weakest*#QUADS,
        quadrants=capacities,maxGasStrengthByQuadrant=maxStrengthByQuadrant,
        currentSupportRatio=nil,targetSupportRatio=nil,targetSupportKnown=false,targetUnreachable=false}
    local pressure=airPressure(vessel)
    if pressure and finite(vessel.mass) and vessel.mass>0 then
        model.currentSupportRatio=model.rawVesselMaximum*pressure/vessel.mass
        model.actualSupportRatio=liftSum*pressure/vessel.mass
    end
    local targetPressure,targetPressureError
    if finite(targetY) and type(io.airPressureAtWorldY)=="function" then
        targetPressure,targetPressureError=io:airPressureAtWorldY(targetY)
    elseif finite(targetY) and finite(vessel.altitude) and math.abs(targetY-vessel.altitude)<0.001 then
        targetPressure=pressure
    end
    if finite(targetPressure) and targetPressure>0 and finite(vessel.mass) and vessel.mass>0 then
        model.targetSupportKnown=true
        model.targetPressure=targetPressure
        model.targetSupportRatio=model.rawVesselMaximum*targetPressure/vessel.mass
        if model.targetSupportRatio<1 then
            model.phase="LIMITED"
            model.targetUnreachable=true
            model.reason="INSUFFICIENT BALANCED LIFT / TARGET UNREACHABLE: "..limiting..
                " LIMIT "..string.format("%.1f",weakest).." RAW LIFT PER QUADRANT"
        end
    elseif targetPressureError then
        model.pressureError=tostring(targetPressureError):sub(1,100)
    end
    return model
end

-- @ama-summary: Clamp requested chamber target maps to the balanced provider bounds.
function Flight:capBalancedTargets(io,maps,model)
    if type(model)~="table" or not finite(model.rawPerQuadrantMaximum) then
        return nil,"BALANCED LIFT CAPACITY UNAVAILABLE",false
    end
    local result=copyMaps(maps)
    local anyLimited=false
    for _,q in ipairs(QUADS) do
        local node=io.nodes and io.nodes[q]
        local targets=result[q]
        if type(node)~="table" or type(targets)~="table" then
            return nil,q.." BALANCED TARGET MAP UNAVAILABLE",false
        end
        local floorLift,totalLift=0,0
        local entries={}
        for name,provider in pairs(node.providers or {}) do
            local amount=targets[name]
            local strength=configuredProviderStrength(self.config,provider)
            if not finite(amount) or amount<0 or amount%1~=0 or not finite(strength) or strength<=0 then
                return nil,q.." BALANCED PROVIDER TARGET / STRENGTH INVALID",false
            end
            local floor=0
            if provider.controlRole=="bulk" then
                floor=provider.minimumNonzeroTarget or provider.minTarget or 0
            elseif amount>0 then
                floor=provider.minimumNonzeroTarget or provider.minTarget or 0
            end
            if amount<floor then return nil,q.." TARGET BELOW REQUIRED PROVIDER FLOOR",false end
            floorLift=floorLift+floor*strength
            totalLift=totalLift+amount*strength
            entries[#entries+1]={name=name,amount=amount,floor=floor,strength=strength}
        end
        if floorLift>model.rawPerQuadrantMaximum+1e-7 then
            model.phase="INFEASIBLE"
            model.reason="INSUFFICIENT BALANCED LIFT / PROVIDER FLOORS EXCEED "..
                tostring(q).." LIMIT "..string.format("%.1f",model.rawPerQuadrantMaximum)
            return nil,model.reason,false
        end
        if totalLift>model.rawPerQuadrantMaximum+1e-7 then
            anyLimited=true
            local discretionary=totalLift-floorLift
            local scale=discretionary>0 and clamp(
                (model.rawPerQuadrantMaximum-floorLift)/discretionary,0,1) or 0
            for _,entry in ipairs(entries) do
                local amount=entry.floor+math.floor((entry.amount-entry.floor)*scale+1e-9)
                result[q][entry.name]=amount
            end
        end
    end
    model.capApplied=anyLimited
    model.demandLimited=anyLimited
    if anyLimited and not model.reason then
        model.reason="BALANCED RAW LIFT CAP ACTIVE: "..tostring(model.limitingQuadrant)..
            " LIMIT "..string.format("%.1f",model.rawPerQuadrantMaximum).." PER QUADRANT"
    end
    return result,nil,anyLimited
end

-- @ama-summary: Sum the provider target amounts for each chamber.
local function systemsProviderTargetTotals(io,maps)
    local totals={}
    for _,q in ipairs(QUADS) do
        local total=0
        for name,provider in pairs(io.nodes[q].providers or {}) do
            if provider.controlRole=="bulk" or provider.controlRole=="fine" then
                local amount=maps[q] and maps[q][name]
                if not finite(amount) then return nil,q.." INITIAL GAS TARGET MAP INCOMPLETE" end
                total=total+amount
            end
        end
        totals[q]=total
    end
    return totals
end

-- @ama-summary: Allocate a chamber's initial gas request across its permitted providers.
local function distributeInitialGasTotal(entries,total)
    local result={};local minimum=0
    table.sort(entries,function(a,b) return a.name<b.name end)
    for _,entry in ipairs(entries) do result[entry.name]=entry.floor;minimum=minimum+entry.floor end
    local remaining=total-minimum
    if remaining<0 then return nil,"INITIAL GAS TARGET BELOW PROVIDER FLOORS" end
    while remaining>0 do
        local active={}
        for _,entry in ipairs(entries) do
            if result[entry.name]<entry.maximum then active[#active+1]=entry end
        end
        if #active==0 then break end
        table.sort(active,function(a,b)
            local av,bv=result[a.name],result[b.name]
            if av==bv then return a.name<b.name end
            return av<bv
        end)
        local lowest=result[active[1].name]
        local group={}
        local nextLevel=math.huge
        for _,entry in ipairs(active) do
            local amount=result[entry.name]
            if amount==lowest then
                group[#group+1]=entry
                nextLevel=math.min(nextLevel,entry.maximum)
            elseif amount>lowest then
                nextLevel=math.min(nextLevel,amount)
            end
        end
        if #group==0 or not finite(nextLevel) or nextLevel<=lowest then break end
        local share=math.floor(remaining/#group)
        if share<=0 then
            for i=1,math.min(remaining,#group) do
                result[group[i].name]=result[group[i].name]+1
            end
            remaining=0
        else
            local increment=math.min(share,nextLevel-lowest)
            if increment<=0 then break end
            for _,entry in ipairs(group) do result[entry.name]=result[entry.name]+increment end
            remaining=remaining-increment*#group
        end
    end
    return result,remaining
end

-- @ama-summary: Calculate initial fill targets from configured gas demand and verified capacity.
function Flight:systemsStartupGasSeedTargets(io,maps,model,startupState)
    local requested=self.config.startup_gas_target_m3_per_chamber
    if not finite(requested) or requested<0 then requested=0 end
    local info={requestedM3PerChamber=requested,unit="m3/chamber",
        targetBasis="sum of provider target ceilings; not measured gas volume",
        limited=false,seeded=false,status=requested>0 and "PENDING" or "DISABLED"}
    if requested<=0 then return copyMaps(maps),info end
    if type(model)~="table" or (model.phase~="READY" and model.phase~="LIMITED") or
        not finite(model.rawPerQuadrantMaximum) then
        return nil,info,"WAITING FOR VERIFIED BALANCED CAPACITY"
    end
    local entriesByQ={};local minimumTotal=0;local maximumTotal=math.huge
    for _,q in ipairs(QUADS) do
        local node=io.nodes and io.nodes[q]
        if type(node)~="table" then return nil,info,q.." INITIAL GAS NODE UNAVAILABLE" end
        local fineProvider=nil;local fineTarget=nil;local bulkEntries={};local bulkFloor=0;local bulkMax=0
        local steamStrength=nil
        for name,provider in pairs(node.providers or {}) do
            if provider.controlRole=="fine" then
                if fineProvider then return nil,info,q.." HAS MULTIPLE FINE PROVIDERS" end
                fineProvider=provider;fineTarget=maps[q] and maps[q][name]
            elseif provider.controlRole=="bulk" then
                if provider.gasTypeValid~=true or provider.gasType~="steam" then
                    return nil,info,q.." BULK STEAM TYPE NOT VERIFIED"
                end
                local strength=self.config.verified_gas_lift_strengths and
                    self.config.verified_gas_lift_strengths[provider.gasType]
                local floor=provider.minimumNonzeroTarget or provider.minTarget
                if not finite(strength) or strength<=0 or not finite(floor) or floor<1 or
                    not finite(provider.maxTarget) or provider.maxTarget<floor then
                    return nil,info,q.." BULK PROVIDER LIMITS / STRENGTH UNAVAILABLE"
                end
                if steamStrength and math.abs(steamStrength-strength)>1e-9 then
                    return nil,info,q.." STEAM STRENGTH READBACK IS INCONSISTENT"
                end
                steamStrength=strength;bulkFloor=bulkFloor+floor;bulkMax=bulkMax+provider.maxTarget
                bulkEntries[#bulkEntries+1]={name=name,floor=floor,maximum=provider.maxTarget}
            end
        end
        if #bulkEntries~=steamCount(node) or not fineProvider or not finite(fineTarget) or fineTarget<0 or
            not finite(fineProvider.maxTarget) or fineTarget>fineProvider.maxTarget then
            return nil,info,q.." STARTUP GAS PROVIDER MAP INVALID"
        end
        local fineStrength=fineProvider.gasTypeValid and self.config.verified_gas_lift_strengths and
            self.config.verified_gas_lift_strengths[fineProvider.gasType]
        if not finite(fineStrength) or fineStrength<=0 then
            return nil,info,q.." FINE PROVIDER STRENGTH UNAVAILABLE"
        end
        local fineFloor=fineTarget>0 and (fineProvider.minimumNonzeroTarget or fineProvider.minTarget or 0) or 0
        if fineTarget<fineFloor then return nil,info,q.." FINE TARGET BELOW PROVIDER FLOOR" end
        local rawForBulk=model.rawPerQuadrantMaximum-fineTarget*fineStrength
        local capacityBulk=math.floor(math.max(0,rawForBulk)/steamStrength+1e-9)
        local allowedBulk=math.min(bulkMax,capacityBulk)
        local lowTotal=fineTarget+bulkFloor
        local highTotal=fineTarget+allowedBulk
        if highTotal<lowTotal then return nil,info,q.." BALANCED CAPACITY IS BELOW PROVIDER FLOORS" end
        minimumTotal=math.max(minimumTotal,lowTotal)
        maximumTotal=math.min(maximumTotal,highTotal)
        entriesByQ[q]={fineTarget=fineTarget,fineStrength=fineStrength,
            steamStrength=steamStrength,bulkEntries=bulkEntries}
    end
    if maximumTotal<minimumTotal then return nil,info,"NO COMMON STARTUP GAS TARGET FITS ALL QUADRANTS" end
    local effective=clamp(requested,minimumTotal,maximumTotal)
    if effective~=requested then
        info.limited=true
        if requested<minimumTotal then
            info.limitReason="PROVIDER FLOORS REQUIRE AT LEAST "..tostring(minimumTotal).." m3/chamber"
        else
            info.limitReason="WEAKEST VERIFIED PROVIDER / BALANCED CAPACITY LIMITS TARGET TO "..
                tostring(maximumTotal).." m3/chamber"
        end
    end
    if type(startupState)=="table" then
        local vessel=io.vessel or {}
        local gravity=vessel.environment and vessel.environment.gravity and math.abs(vessel.environment.gravity.y)
        local pressure=airPressure(vessel)
        if not finite(vessel.mass) or vessel.mass<=0 or not finite(gravity) or gravity<=0 or not pressure or
            not finite(vessel.altitude) or not finite(vessel.verticalSpeed) or not finite(startupState.target) then
            return nil,info,"INITIAL GAS SEED ALTITUDE DEMAND INPUTS UNAVAILABLE"
        end
        local network=io.config and io.config.network or {}
        local sampleSeconds=finite(network.sample_interval_seconds) and network.sample_interval_seconds or 0.5
        local ackWait=math.max(finite(startupState.lastAckWaitSeconds) and startupState.lastAckWaitSeconds or 0,
            finite(network.commission_ack_seconds) and network.commission_ack_seconds or 0)
        local acceleration=systemsStartupAcceleration(self.config,startupState.responseLagSeconds,
            (startupState.dynamics or {}).sampleSeconds or sampleSeconds,ackWait)
        local remaining=startupState.target-vessel.altitude
        local maxSpeed=systemsStartupNominalSpeed(self.config)
        local desiredSpeed=clamp(remaining/startupLookaheadSeconds(self.config),-maxSpeed,maxSpeed)
        if remaining>0 then
            desiredSpeed=math.min(desiredSpeed,math.sqrt(2*acceleration*remaining))
        end
        local speedHorizon=startupLookaheadSeconds(self.config)
        local requestedAcceleration=clamp((desiredSpeed-vessel.verticalSpeed)/speedHorizon,
            -acceleration,acceleration)
        local dynamics=startupState.dynamics or {}
        local drag=finite(dynamics.verticalDragEstimate) and math.max(0,dynamics.verticalDragEstimate) or 0
        local supportDemand=math.max(0,1+(drag*vessel.verticalSpeed+requestedAcceleration)/gravity)
        local demandCap=math.huge
        for _,q in ipairs(QUADS) do
            local qInfo=entriesByQ[q]
            local rawRequired=vessel.mass*supportDemand/(4*pressure)
            local bulkRequired=math.floor(math.max(0,rawRequired-qInfo.fineTarget*qInfo.fineStrength)/
                qInfo.steamStrength+1e-9)
            demandCap=math.min(demandCap,qInfo.fineTarget+bulkRequired)
        end
        info.altitudeDemandSupportRatio=supportDemand
        info.altitudeDemandMaximumM3PerChamber=demandCap
        info.altitudeDemandAccelerationLimit=acceleration
        if effective>demandCap then
            effective=math.max(minimumTotal,demandCap)
            info.limited=true;info.altitudeLimited=true
            info.limitReason="STARTUP ALTITUDE / VERTICAL-SPEED DEMAND LIMITS INITIAL TARGET TO "..
                tostring(effective).." m3/chamber"
        end
    end
    local result=copyMaps(maps)
    for _,q in ipairs(QUADS) do
        local qInfo=entriesByQ[q]
        local allocated,remaining=distributeInitialGasTotal(qInfo.bulkEntries,effective-qInfo.fineTarget)
        if not allocated or remaining~=0 then
            return nil,info,q.." COULD NOT DISTRIBUTE INITIAL GAS TARGET WITHIN PROVIDER LIMITS"
        end
        for name,value in pairs(allocated) do result[q][name]=value end
    end
    info.effectiveRequestedM3PerChamber=effective
    return result,info
end

-- Once a configured seed has handed control to the acquisition PID, keep each
-- commanded chamber map inside the support ratio the measured controller has
-- requested. The seed is only an initial ceiling; it must not be treated as a
-- minimum while delayed gas is still entering the envelope.
-- @ama-summary: Limit startup fill targets against the measured support envelope.
local function capSeededStartupSupportTargets(io,maps,supportRatio,config)
    local vessel=io.vessel or {}
    local pressure=airPressure(vessel)
    local strengths=config and config.verified_gas_lift_strengths
    if not finite(vessel.mass) or vessel.mass<=0 or not pressure or type(strengths)~="table" or
        not finite(supportRatio) or supportRatio<0 then
        return nil,"STARTUP SEED SUPPORT CAP INPUTS UNAVAILABLE"
    end
    local capped=copyMaps(maps)
    local limited,floorLimited=false,false
    local maximumM3PerChamber=math.huge
    for _,q in ipairs(QUADS) do
        local node=io.nodes and io.nodes[q]
        local fineTarget,fineStrength=nil,nil
        local bulkEntries,bulkFloor,bulkCurrent,bulkStrength={},0,0,nil
        for name,provider in pairs(node and node.providers or {}) do
            local amount=maps[q] and maps[q][name]
            if not finite(amount) then return nil,q.." STARTUP SUPPORT MAP INCOMPLETE" end
            if provider.controlRole=="fine" then
                fineTarget=amount
                fineStrength=configuredProviderStrength(config,provider)
            elseif provider.controlRole=="bulk" then
                local strength=configuredProviderStrength(config,provider)
                local floor=math.max(provider.minimumNonzeroTarget or provider.minTarget or 50,
                    provider.minTarget or 0)
                if not finite(strength) or strength<=0 or not finite(floor) or
                    not finite(provider.maxTarget) or amount<floor or amount>provider.maxTarget then
                    return nil,q.." STARTUP SUPPORT PROVIDER LIMITS / STRENGTH UNAVAILABLE"
                end
                if bulkStrength and math.abs(bulkStrength-strength)>1e-9 then
                    return nil,q.." STARTUP STEAM STRENGTHS DO NOT MATCH"
                end
                bulkStrength=strength;bulkFloor=bulkFloor+floor;bulkCurrent=bulkCurrent+amount
                bulkEntries[#bulkEntries+1]={name=name,amount=amount,floor=floor}
            end
        end
        if not finite(fineTarget) or not finite(fineStrength) or fineStrength<=0 or
            not finite(bulkStrength) or bulkStrength<=0 or #bulkEntries==0 then
            return nil,q.." STARTUP SUPPORT PROVIDER MAP INVALID"
        end
        local rawBudget=vessel.mass*supportRatio/(4*pressure)
        local desiredBulk=math.floor(math.max(0,rawBudget-fineTarget*fineStrength)/bulkStrength+1e-9)
        maximumM3PerChamber=math.min(maximumM3PerChamber,fineTarget+desiredBulk)
        if desiredBulk<bulkFloor then floorLimited=true end
        if bulkCurrent>desiredBulk then
            limited=true
            local extra=math.max(0,bulkCurrent-bulkFloor)
            local allowed=math.max(0,desiredBulk-bulkFloor)
            local scale=extra>0 and math.min(1,allowed/extra) or 0
            for _,entry in ipairs(bulkEntries) do
                capped[q][entry.name]=entry.floor+math.floor(math.max(0,entry.amount-entry.floor)*scale)
            end
        end
    end
    return capped,nil,{limited=limited,floorLimited=floorLimited,
        maximumM3PerChamber=maximumM3PerChamber}
end

-- @ama-summary: Check requested chamber targets against the balanced capacity model.
function Flight:balancedTargetsFit(io,maps,now,targetY)
    local model,reason=self:balancedLiftModel(io,targetY,now)
    if model.phase=="UNAVAILABLE" or model.phase=="INFEASIBLE" then
        return false,reason or model.reason or "BALANCED LIFT CAPACITY UNAVAILABLE"
    end
    local capped,capReason=self:capBalancedTargets(io,maps,model)
    if not capped then return false,capReason or "BALANCED LIFT CAPACITY LIMIT UNAVAILABLE" end
    for _,q in ipairs(QUADS) do
        for name,value in pairs(maps[q] or {}) do
            if capped[q][name]~=value then
                return false,q.." LIFT CAP LIMIT: TUNING CEILING WOULD EXCEED BALANCED MAXIMUM"
            end
        end
    end
    return true,nil,model
end

-- @ama-section: Flight lifecycle | Operator actions, runtime gates and cached presentation.
-- @ama-summary: Recognize target maps at the configured provider floors and fine-provider state.
function Flight:isFloorOnlyTargets(io,maps,parkFine,preserveExistingFine,allowTrimBaseline)
    if type(maps)~="table" then return false end
    for _,q in ipairs(QUADS) do
        local node=io.nodes and io.nodes[q]
        local targets=maps[q]
        if type(node)~="table" or type(targets)~="table" then return false end
        for name,provider in pairs(node.providers or {}) do
            local value=targets[name]
            if provider.controlRole=="bulk" then
                if value~=(provider.minimumNonzeroTarget or 50) then return false end
            elseif provider.controlRole=="fine" then
                local wanted=parkFine and 0 or (preserveExistingFine and provider.targetAmount or
                    (provider.minimumNonzeroTarget or 5))
                local neutralTrimBaseline
                if allowTrimBaseline then
                    local floor=math.max(5,provider.minimumNonzeroTarget or 5)
                    local authority=finite(self.config.max_trim_ceiling_change) and
                        math.max(0,self.config.max_trim_ceiling_change) or 25
                    neutralTrimBaseline=math.min(provider.maxTarget,math.ceil(floor+authority))
                end
                if value~=wanted and not (parkFine and neutralTrimBaseline and value==neutralTrimBaseline) then
                    return false
                end
            else return false end
        end
    end
    return true
end

local function freshAt(now,at,limit)
    return finite(at) and now>=at and now-at<=limit
end
-- @ama-section: Systems control | Startup, measured dynamics and bounded provider demand.
-- @ama-summary: Resolve and validate the selected startup altitude.
function Flight:systemsTarget(io)
    local c=self.config
    local minimum,maximum=c and c.minimum_world_y,c and c.maximum_world_y
    if not finite(minimum) or not finite(maximum) or minimum>=maximum then return nil,"ALTITUDE LIMITS INVALID" end
    local selected=self.controls and self.controls.targets and self.controls.targets.altitude
    if finite(selected) and selected>=minimum and selected<=maximum then return selected,"SELECTED ALTITUDE" end
    return minimum,"MINIMUM ALTITUDE FALLBACK"
end
-- @ama-summary: Collect verified vessel, cockpit, provider and chamber identity for a systems run.
function Flight:systemsPreflight(io,now)
    if not self.config or not self.outer or not self.inner then return nil,"SYSTEMS FLIGHT CONTROL CONFIGURATION UNAVAILABLE" end
    local c=self.config
    if self.tuningRun or self.tuningReview then return nil,"PID TUNING IN PROGRESS" end
    if self.maintenanceJob then return nil,"LIFT MAINTENANCE IN PROGRESS" end
    if self.startupPending then return nil,"VENT STARTUP ALREADY PENDING" end
    if self.enabled then return nil,"ALTITUDE CONTROL ALREADY ENGAGED" end
    if io.anchor=="ANCHORED" or io.anchor=="BRAKING" then return nil,"ANCHOR SUPPRESSES START SYSTEMS" end
    local stale=io.config.network.sensor_stale_seconds
    local v=io.vessel
    if not v or v.valid~=true or type(v.uuid)~="string" or v.uuid=="" or
        not freshAt(now,v.at,stale) or not finite(v.altitude) or not finite(v.verticalSpeed) then
        return nil,"VESSEL ALTITUDE / VERTICAL SPEED UNAVAILABLE"
    end
    local gravity=v.environment and v.environment.gravity
    if not finite(v.mass) or v.mass<=0 or not gravity or not finite(gravity.y) or gravity.y>=0 then
        return nil,"VESSEL MASS / GRAVITY UNAVAILABLE"
    end
    if not airPressure(v) then return nil,"VESSEL AIR PRESSURE UNAVAILABLE" end
    local inputs=io.inputs
    local inputFresh,inputReason
    if self.controls then inputFresh,inputReason=self.controls:usable(io,now)
    else
        inputFresh=inputs and inputs.valid==true and freshAt(now,inputs.at,stale) and type(inputs.raw)=="table"
        inputReason="COCKPIT INPUTS STALE"
    end
    if not inputFresh then return nil,inputReason or "COCKPIT INPUTS STALE" end
    if type(io.sendSystemsCommand)~="function" or type(io.sendSystemsStop)~="function" then
        return nil,"SYSTEMS COMMAND INTERFACE UNAVAILABLE"
    end
    local target,targetReason=self:systemsTarget(io)
    if not target then return nil,targetReason end
    local maps,controlTargets,boots,roles,limits={},{},{},{},{}
    local retainedBulk={}
    local bindingFingerprints,bindingGenerations,acceptedBootGenerations,nodeIDs={},{},{},{}
    for _,q in ipairs(QUADS) do
        local n=io.nodes[q]
        if not n or not io:nodeFresh(q,now) or type(n.boot)~="string" or n.boot=="" then
            return nil,q.." LIFT NODE STALE"
        end
        if n.systemsStartReady~=true then
            return nil,q.." SYSTEMS RECEIVER UNAVAILABLE"
        end
        if n.armed==true or n.operationBusy==true then return nil,q.." LIFT CONTROLLER ALREADY OPERATING" end
        if type(n.providers)~="table" then return nil,q.." PROVIDER INTERFACES UNAVAILABLE" end
        local bulk,fine=0,0;maps[q]={};controlTargets[q]={};roles[q]={};limits[q]={};boots[q]=n.boot
        nodeIDs[q]=n.id
        if n.bindingFingerprintValid==true and boundedBindingFingerprint(n.bindingFingerprint) then
            bindingFingerprints[q]=n.bindingFingerprint
        end
        if finite(n.bindingGeneration) and n.bindingGeneration%1==0 and
            n.bindingGeneration>=0 and n.bindingGeneration<=2147483647 then
            bindingGenerations[q]=n.bindingGeneration
        end
        if finite(n.acceptedBootGeneration) and n.acceptedBootGeneration%1==0 and
            n.acceptedBootGeneration>=1 and n.acceptedBootGeneration<=2147483647 then
            acceptedBootGenerations[q]=n.acceptedBootGeneration
        end
        for name,p in pairs(n.providers) do
            if not p.present or not p.writable or p.targetValid~=true or not finite(p.targetAmount) or
                p.signalValid~=true or not finite(p.signalStrength) or not finite(p.maxTarget) then
                return nil,q.." START SYSTEMS PROVIDER INTERFACE INVALID"
            end
            if p.controlRole=="bulk" then
                bulk=bulk+1
                local floor=p.minimumNonzeroTarget or 50
                if not finite(floor) or floor<1 or p.maxTarget<floor then return nil,q.." VENT CEILING BOUNDS INVALID" end
                if p.targetAmount<0 or p.targetAmount>p.maxTarget then return nil,q.." VENT CEILING READBACK INVALID" end
                if p.signalStrength>0 and p.targetAmount<floor then
                    return nil,q.." ACTIVE VENT CEILING INVALID"
                end
                maps[q][name]=p.targetAmount
                -- Inactive vents enter the control lease at the known minimum.
                -- An active vent keeps its current ceiling: START SYSTEMS at
                -- altitude must take over the existing lift, never drop it.
                -- Only STOP SYSTEMS (or explicit control) lowers it.
                if p.signalStrength>0 and p.targetAmount>floor then
                    controlTargets[q][name]=p.targetAmount
                    retainedBulk[q]=retainedBulk[q] or {}
                    retainedBulk[q][name]=p.targetAmount
                else
                    controlTargets[q][name]=floor
                end
                roles[q][name]="bulk";limits[q][name]={minimum=floor,maximum=p.maxTarget}
            elseif p.controlRole=="fine" then
                fine=fine+1
                local floor=math.max(5,p.minimumNonzeroTarget or 5)
                if p.targetAmount<0 or p.targetAmount>p.maxTarget then return nil,q.." PROBE CEILING READBACK INVALID" end
                local value=p.signalStrength==0 and floor or math.max(p.targetAmount,floor)
                if p.signalStrength>0 and p.targetAmount<floor then return nil,q.." ACTIVE PROBE CEILING INVALID" end
                if p.maxTarget<floor or value>p.maxTarget then return nil,q.." PROBE CEILING BOUNDS INVALID" end
                maps[q][name]=math.ceil(value)
                -- Keep the trim burner on a low, symmetric baseline during
                -- acquisition. Starting exactly at its floor leaves no room
                -- for negative pitch/roll corrections. The existing trim cap
                -- remains the authority limit in both directions.
                local trimAuthority=finite(c.max_trim_ceiling_change) and
                    math.max(0,c.max_trim_ceiling_change) or 25
                controlTargets[q][name]=math.min(p.maxTarget,math.ceil(floor+trimAuthority))
                roles[q][name]="fine";limits[q][name]={minimum=floor,maximum=p.maxTarget}
            else return nil,q.." PROVIDER ROLE UNVERIFIED" end
        end
        if bulk~=steamCount(n) or fine~=1 then return nil,q.." EXPECTED CONFIGURED BULK VENTS AND ONE PROBE" end
    end
    return {probeTargets=maps,controlTargets=controlTargets,retainedBulk=retainedBulk,boots=boots,roles=roles,limits=limits,target=target,targetReason=targetReason,
        uuid=v.uuid,fingerprint=io.hardwareFingerprint,bindingFingerprints=bindingFingerprints,
        bindingGenerations=bindingGenerations,acceptedBootGenerations=acceptedBootGenerations,
        nodeIDs=nodeIDs,coreSession=io.session,coreID=io.localID}
end
-- @ama-summary: Revalidate the active run's observations, identities and configured provider boundaries.
function Flight:systemsGuard(io,now,s,allowInactiveLease,skipTargetMatch)
    if io.anchor=="ANCHORED" or io.anchor=="BRAKING" then return false,"ANCHOR ENGAGED" end
    local stale=io.config.network.sensor_stale_seconds
    local v=io.vessel
    local vesselState,vesselReason=TelemetryRecovery.vesselState(io,s,now)
    if vesselState~="trusted" then return false,vesselReason end
    -- Elapsed acquisition time is diagnostic, not a reason to revoke airborne
    -- control. Keep the same targets, PID history and leveling authority.
    s.acquisitionOverdue=s.phase~="READY" and finite(s.startedAt) and
        finite(s.acquisitionTimeout) and now-s.startedAt>s.acquisitionTimeout or false
    -- Startup gets its own nominal command speed and hard transient limit.
    -- Ordinary hover keeps the existing flight limit. A legacy config without
    -- the startup fields retains the old max+1 guard.
    local speedLimit=(self.config.max_vertical_speed or 1)+1
    local speedFault=v.verticalSpeed>speedLimit or
        (s.phase=="READY" and v.verticalSpeed< -speedLimit)
    if s.phase=="BUILDING_LIFT" then
        speedLimit=systemsStartupSpeedLimit(self.config)
        speedFault=math.abs(v.verticalSpeed)>speedLimit
    end
    if speedFault then
        return false,"VERTICAL SPEED LIMIT EXCEEDED",{
            target=s.target,actualWorldY=v.altitude,verticalSpeed=v.verticalSpeed,
            verticalSpeedLimit=speedLimit}
    end
    local gravity=v.environment and v.environment.gravity
    if not finite(v.mass) or not gravity or not finite(gravity.y) then
        return false,"VESSEL MASS / GRAVITY UNAVAILABLE"
    end
    if v.mass<=0 or gravity.y>=0 then return false,"VESSEL MASS / GRAVITY INVALID" end
    local pressure=v.environment and v.environment.airPressure
    if not finite(pressure) then return false,"VESSEL AIR PRESSURE UNAVAILABLE" end
    if pressure<=0 then return false,"VESSEL AIR PRESSURE INVALID" end
    if io.hardwareFingerprint~=s.fingerprint then return false,"CORE SENSOR BINDINGS CHANGED" end
    local inputs=io.inputs
    local good,reason
    if self.controls then good,reason=self.controls:usable(io,now)
    else good=inputs and inputs.valid==true and freshAt(now,inputs.at,stale) and type(inputs.raw)=="table" end
    if not good then return false,reason or "COCKPIT INPUTS STALE" end
    for _,q in ipairs(QUADS) do
        local n=io.nodes[q]
        if not n or not io:nodeFresh(q,now) then return false,q.." LIFT TELEMETRY STALE" end
        if s.bindingFingerprints and s.bindingFingerprints[q] then
            if n.bindingFingerprintValid~=true or not boundedBindingFingerprint(n.bindingFingerprint) then
                return false,q.." LIFT BINDING DATA UNAVAILABLE"
            end
            if n.bindingFingerprint~=s.bindingFingerprints[q] then
                return false,q.." LIFT HARDWARE BINDINGS CHANGED"
            end
        end
        if n.boot~=s.boots[q] then
            if not s.telemetryRecovery then return false,q.." LIFT BOOT CHANGED" end
            local state,bootReason=TelemetryRecovery.nodeBootState(io,s,q,now,self)
            if state=="wait" then return false,q.." "..tostring(bootReason) end
            if state~="trusted" then return false,bootReason or q.." LIFT BOOT CHANGED" end
        end
        local count=0
        for name,p in pairs(n.providers or {}) do
            count=count+1
            local expectedRole=s.providerRoles[q][name]
            local bound=s.providerLimits[q][name]
            if not expectedRole or not bound or p.controlRole~=expectedRole then
                return false,q.." PROVIDER ALLOWLIST CHANGED"
            end
            if p.presenceValid==false or (p.presenceValid==nil and p.present~=true) then
                return false,q.." PROVIDER "..name.." PRESENCE READBACK UNAVAILABLE"
            end
            if p.present~=true then return false,q.." PROVIDER "..name.." CONFIRMED MISSING OR WRONG TYPE" end
            if p.writableValid==false or (p.writableValid==nil and p.writable~=true) then
                return false,q.." PROVIDER "..name.." WRITE INTERFACE READBACK UNAVAILABLE"
            end
            if p.writable~=true then return false,q.." PROVIDER "..name.." CONFIRMED NOT WRITABLE" end
            if p.targetValid~=true or not finite(p.targetAmount) then
                return false,q.." PROVIDER "..name.." CEILING READBACK UNAVAILABLE"
            end
            if p.signalValid~=true or not finite(p.signalStrength) then
                return false,q.." PROVIDER "..name.." ACTIVATION SIGNAL READBACK UNAVAILABLE"
            end
            if not finite(p.maxTarget) or
                (p.minimumNonzeroTarget~=nil and not finite(p.minimumNonzeroTarget)) then
                return false,q.." PROVIDER "..name.." LIMIT READBACK UNAVAILABLE"
            end
            if p.maxTarget~=bound.maximum or (p.minimumNonzeroTarget or bound.minimum)~=bound.minimum then
                return false,q.." PROVIDER ALLOWLIST CHANGED"
            end
            if not skipTargetMatch and not (s.pending and s.pending[q]) then
                local expectedTargets=s.currentTargets and s.currentTargets[q] or s.probeTargets[q]
                local expected=expectedTargets and expectedTargets[name]
                local parkedFine=expected==0 and expectedRole=="fine" and p.signalStrength==0 and
                    p.targetAmount==bound.minimum
                if expected~=nil and p.targetAmount~=expected and not parkedFine then
                    return false,q.." PROVIDER CEILING CHANGED"
                end
            end
        end
        if count~=steamCount(n)+1 then return false,q.." PROVIDER ALLOWLIST CHANGED" end
    end
    if (s.phase=="BUILDING_LIFT" or s.phase=="READY") then
        local live,liveReason=self:systemsEnvelopeReady(io,false,not allowInactiveLease,allowInactiveLease)
        if not live then return false,liveReason or "BALLOON / PROVIDER TELEMETRY LOST" end
    end
    return true
end
-- @ama-summary: Check chamber envelope composition and lift observations for startup.
function Flight:systemsEnvelopeReady(io,requireProbeReady,requireLiveProviders,allowInactiveLease)
    for _,q in ipairs(QUADS) do
        local n=io.nodes[q]
        if requireProbeReady~=false and n.systemsProbeReady~=true then return false,q.." PROBE NOT ACKNOWLEDGED" end
        if not n.altitude or n.altitude.valid~=true or not finite(n.altitude.sensorWorldY) then return false,q.." ALTITUDE DATA UNAVAILABLE" end
        local b=n.balloon
        local source=b and type(b.source)=="string" and b.source or "representative provider"
        if not b then return false,q.." BALLOON STATUS UNAVAILABLE" end
        if b.hasBalloonValid~=true then return false,q.." PROVIDER "..source.." BALLOON ATTACHMENT READBACK UNAVAILABLE" end
        if b.hasBalloon~=true then return false,q.." PROVIDER "..source.." REPORTS NO ATTACHED BALLOON" end
        if b.gasMixValid~=true or type(b.gasMix)~="table" then return false,q.." PROVIDER "..source.." BALLOON GAS MIX UNAVAILABLE" end
        if b.liftValid~=true or not finite(b.lift) then return false,q.." PROVIDER "..source.." BALLOON LIFT READBACK UNAVAILABLE" end
        if b.lift<=0 then return false,q.." PROVIDER "..source.." REPORTS NO POSITIVE BALLOON LIFT" end
        local bulk,fine,mixAvailable=0,0,false
        for _,amount in pairs(b.gasMix) do if finite(amount) and amount>0 then mixAvailable=true;break end end
        if not mixAvailable then return false,q.." PROVIDER "..source.." BALLOON GAS MIX HAS NO POSITIVE AMOUNT" end
        for name,p in pairs(n.providers or {}) do
            if p.presenceValid==false or (p.presenceValid==nil and p.present~=true) then return false,q.." PROVIDER "..name.." PRESENCE READBACK UNAVAILABLE" end
            if not p.present then return false,q.." PROVIDER "..name.." CONFIRMED MISSING OR WRONG TYPE" end
            if p.writableValid==false or (p.writableValid==nil and p.writable~=true) then return false,q.." PROVIDER "..name.." WRITE INTERFACE READBACK UNAVAILABLE" end
            if not p.writable then return false,q.." PROVIDER "..name.." CONFIRMED NOT WRITABLE" end
            if p.targetValid~=true then return false,q.." PROVIDER "..name.." CEILING READBACK UNAVAILABLE" end
            if p.signalValid~=true or not finite(p.signalStrength) then return false,q.." PROVIDER "..name.." ACTIVATION SIGNAL READBACK UNAVAILABLE" end
            if p.controlRole=="bulk" then
                bulk=bulk+1
                if requireLiveProviders and p.signalStrength~=15 then return false,q.." PROVIDER "..name.." ACTIVATION SIGNAL "..tostring(p.signalStrength).." (EXPECTED 15)" end
                if (requireLiveProviders or allowInactiveLease) and p.signalStrength>1 then
                    if not p.attachedValid then return false,q.." PROVIDER "..name.." BALLOON ATTACHMENT READBACK UNAVAILABLE" end
                    if not p.attached then return false,q.." PROVIDER "..name.." REPORTS NO ATTACHED BALLOON" end
                    if not p.gasTypeValid or type(p.gasType)~="string" then return false,q.." PROVIDER "..name.." GAS TYPE READBACK UNAVAILABLE" end
                    if p.gasType~="steam" then return false,q.." PROVIDER "..name.." GAS TYPE "..p.gasType.." (EXPECTED steam)" end
                    if requireLiveProviders then
                        if p.signalStrength~=15 then return false,q.." PROVIDER "..name.." ACTIVATION SIGNAL "..tostring(p.signalStrength).." (EXPECTED 15)" end
                        if p.activeSupported and not p.activeValid then return false,q.." PROVIDER "..name.." ACTIVITY READBACK UNAVAILABLE" end
                        if p.activeSupported and not p.active then return false,q.." PROVIDER "..name.." REPORTS INACTIVE" end
                    end
                end
            elseif p.controlRole=="fine" then
                fine=fine+1
                local floor=p.minimumNonzeroTarget or 5
                local parkedFine=requireLiveProviders and p.signalStrength==0 and
                    (p.targetAmount==0 or p.targetAmount==floor)
                if p.signalStrength>1 then
                if not p.attachedValid then return false,q.." PROVIDER "..name.." BALLOON ATTACHMENT READBACK UNAVAILABLE" end
                if not p.attached then return false,q.." PROVIDER "..name.." REPORTS NO ATTACHED BALLOON" end
                if not p.gasTypeValid or type(p.gasType)~="string" then return false,q.." PROVIDER "..name.." GAS TYPE READBACK UNAVAILABLE" end
                end
                if requireLiveProviders and not parkedFine and p.signalStrength~=15 then return false,q.." PROVIDER "..name.." ACTIVATION SIGNAL "..tostring(p.signalStrength).." (EXPECTED 15)" end
                if requireLiveProviders and not parkedFine and p.activeSupported and not p.activeValid then return false,q.." PROVIDER "..name.." ACTIVITY READBACK UNAVAILABLE" end
                if requireLiveProviders and not parkedFine and p.activeSupported and not p.active then return false,q.." PROVIDER "..name.." REPORTS INACTIVE" end
            else return false,q.." PROVIDER ROLE UNVERIFIED" end
        end
        if bulk~=steamCount(n) or fine~=1 then return false,q.." EXPECTED CONFIGURED BULK VENTS AND ONE PROBE" end
    end
    return true
end
-- @ama-summary: Estimate lift response, vertical acceleration and drag from successive vessel/chamber samples.
function Flight:observeSystemsDynamics(io,s,now)
    local v=io.vessel
    local pressure=airPressure(v)
    if not pressure or not finite(v.mass) or v.mass<=0 then return end
    local totalLift=0
    local current={at=now,quadrants={},outputsValid=true,efficienciesValid=true,
        fullEfficiency=true,knownLowEfficiency=false,complete=true}
    for _,q in ipairs(QUADS) do
        local node=io.nodes[q];local balloon=node and node.balloon or {}
        local item={}
        if balloon.liftValid==true and finite(balloon.lift) then
            item.lift=balloon.lift;totalLift=totalLift+balloon.lift
        end
        if balloon.filledVolumeValid==true and balloon.capacityValid==true and
            finite(balloon.filledVolume) and finite(balloon.capacity) and balloon.capacity>0 and
            balloon.filledVolume>=0 and balloon.filledVolume<=balloon.capacity then
            item.filledVolume=balloon.filledVolume;item.capacity=balloon.capacity
            item.fillFraction=balloon.filledVolume/balloon.capacity
        end
        local output,outputCount,efficiency,efficiencyCount=0,0,0,0
        local minimumEfficiency
        for _,provider in pairs(node and node.providers or {}) do
            if provider.controlRole=="bulk" then
                if provider.gasOutputValid==true and finite(provider.gasOutput) and provider.gasOutput>=0 then
                    output=output+provider.gasOutput;outputCount=outputCount+1
                end
                if provider.boilerEfficiencyValid==true and finite(provider.boilerEfficiency) and
                    provider.boilerEfficiency>=0 then
                    efficiency=efficiency+provider.boilerEfficiency;efficiencyCount=efficiencyCount+1
                    minimumEfficiency=minimumEfficiency and math.min(minimumEfficiency,provider.boilerEfficiency) or
                        provider.boilerEfficiency
                end
            end
        end
        if outputCount==steamCount(node) then item.gasOutput=output else current.outputsValid=false end
        if efficiencyCount==steamCount(node) then
            item.boilerEfficiency=efficiency/efficiencyCount
            item.minimumBoilerEfficiency=minimumEfficiency
            if minimumEfficiency<SYSTEMS_FULL_BOILER_EFFICIENCY then
                current.fullEfficiency=false;current.knownLowEfficiency=true
            end
        else current.efficienciesValid=false;current.fullEfficiency=false end
        if not item.filledVolume or not item.lift then current.complete=false end
        current.quadrants[q]=item
    end
    current.actualRatio=totalLift*pressure/v.mass
    current.verticalSpeed=v.verticalSpeed
    local previous=s.dynamics
    local sampleSeconds=(io.config.network and io.config.network.sample_interval_seconds) or 0.5
    if previous and now>previous.at then
        local dt=now-previous.at
        current.sampleSeconds=dt
        current.liftRate=(current.actualRatio-previous.actualRatio)/dt
        local liftRateHorizon=finite(s.responseLagSeconds) and
            math.max(s.responseLagSeconds,sampleSeconds) or sampleSeconds
        local liftRateAlpha=dt/(liftRateHorizon+dt)
        local previousLiftRate=finite(previous.projectedLiftRate) and
            previous.projectedLiftRate or current.liftRate
        current.projectedLiftRate=previousLiftRate+liftRateAlpha*(current.liftRate-previousLiftRate)
        local measuredAcceleration=(v.verticalSpeed-previous.verticalSpeed)/dt
        current.verticalAccelerationRaw=measuredAcceleration
        local priorAcceleration=finite(previous.verticalAcceleration) and previous.verticalAcceleration or measuredAcceleration
        local accelerationFilterSeconds=math.max(2,4*sampleSeconds)
        local accelerationAlpha=dt/(accelerationFilterSeconds+dt)
        current.verticalAcceleration=priorAcceleration+accelerationAlpha*(measuredAcceleration-priorAcceleration)
        local meanSpeed=(v.verticalSpeed+previous.verticalSpeed)*0.5
        local gravity=v.environment and v.environment.gravity and math.abs(v.environment.gravity.y)
        local meanRatio=(current.actualRatio+previous.actualRatio)*0.5
        local minimumDragSpeed=0.02
        if s.phase=="BUILDING_LIFT" and finite(s.startAltitude) and finite(v.altitude) and
            v.altitude>s.startAltitude+0.1 then s.launchMotionVerified=true end
        local groundedStartup=s.phase=="BUILDING_LIFT" and finite(s.startAltitude) and not s.launchMotionVerified
        current.groundedStartup=groundedStartup
        if groundedStartup then
            -- Ground contact supplies an unknown force. Dividing that force
            -- residual by a tiny vibration velocity invents enormous drag.
            -- Use the reported environment value until actual CoM ascent
            -- demonstrates free motion; also discard any earlier bad fit.
            local environmentDrag=v.environment and v.environment.universalDrag
            current.verticalDragEstimate=finite(environmentDrag) and environmentDrag>=0 and environmentDrag or 0
            current.verticalDragCandidate=nil;current.verticalDragSamples=0
            current.lowSpeedDragCandidate=nil;current.lowSpeedDragSamples=0
        elseif finite(gravity) and gravity>0 and finite(meanSpeed) and
            math.abs(meanSpeed)>minimumDragSpeed and finite(meanRatio) then
            local dragSample=(gravity*(meanRatio-1)-measuredAcceleration)/meanSpeed
            if finite(dragSample) and dragSample>0 then
                local lowSpeedDrag=math.abs(meanSpeed)<=0.05 and finite(previous.verticalDragEstimate)
                if lowSpeedDrag then
                    -- A low-speed sample can repair a biased initial estimate,
                    -- but do not divide noisy near-zero motion into an
                    -- unbounded drag jump. Require three mutually consistent
                    -- finite readings that also remain within a bounded step
                    -- of the established estimate.
                    local estimate=previous.verticalDragEstimate
                    local withinEstimate=math.abs(dragSample-estimate)<=math.max(estimate*0.5,0.25)
                    local priorCandidate=withinEstimate and previous.lowSpeedDragCandidate or nil
                    local consistent=priorCandidate and
                        math.abs(dragSample-priorCandidate)<=math.max(math.abs(priorCandidate)*0.25,0.02)
                    current.lowSpeedDragSamples=withinEstimate and consistent and
                        (previous.lowSpeedDragSamples or 0)+1 or (withinEstimate and 1 or 0)
                    current.lowSpeedDragCandidate=withinEstimate and (consistent and
                        (priorCandidate+dragSample)*0.5 or dragSample) or nil
                    current.verticalDragEstimate=estimate
                    if current.lowSpeedDragSamples>=3 then
                        local dragAlpha=dt/(math.max(3*sampleSeconds,4)+dt)
                        current.verticalDragEstimate=estimate+
                            (current.lowSpeedDragCandidate-estimate)*dragAlpha
                    end
                elseif finite(previous.verticalDragEstimate) then
                    current.lowSpeedDragCandidate=nil;current.lowSpeedDragSamples=0
                    local dragFilterSeconds=math.max(3*sampleSeconds,4)
                    local dragAlpha=dt/(dragFilterSeconds+dt)
                    current.verticalDragEstimate=previous.verticalDragEstimate+
                        (dragSample-previous.verticalDragEstimate)*dragAlpha
                else
                    -- Infer low-speed resistance only after three consistent
                    -- moving samples; this avoids dividing a single noisy
                    -- acceleration residual by a near-zero velocity.
                    local priorCandidate=previous.verticalDragCandidate
                    local consistent=finite(priorCandidate) and
                        math.abs(dragSample-priorCandidate)<=math.max(math.abs(priorCandidate)*0.25,0.02)
                    current.verticalDragSamples=consistent and (previous.verticalDragSamples or 0)+1 or 1
                    current.verticalDragCandidate=consistent and
                        (priorCandidate+dragSample)*0.5 or dragSample
                    if current.verticalDragSamples>=3 then
                        current.verticalDragEstimate=current.verticalDragCandidate
                    end
                end
            else
                current.verticalDragEstimate=previous.verticalDragEstimate
                current.verticalDragCandidate=nil;current.verticalDragSamples=0
            end
        else
            current.verticalDragEstimate=previous.verticalDragEstimate
            current.verticalDragCandidate=previous.verticalDragCandidate
            current.verticalDragSamples=previous.verticalDragSamples
        end
        local supplyStable=previous.outputsValid and current.outputsValid and
            previous.efficienciesValid and current.efficienciesValid
        local responseRatesStable=true
        local supplyStep=false
        for _,q in ipairs(QUADS) do
            local before,after=previous.quadrants[q],current.quadrants[q]
            if not before or not after or before.gasOutput==nil or after.gasOutput==nil or
                before.boilerEfficiency==nil or after.boilerEfficiency==nil then
                supplyStable=false
            else
                local outputJump=before.gasOutput>0 and after.gasOutput>before.gasOutput*1.5
                local efficiencyJump=before.boilerEfficiency>0 and
                    after.boilerEfficiency>before.boilerEfficiency*1.5 and
                    after.boilerEfficiency-before.boilerEfficiency>0.05
                if outputJump or efficiencyJump then supplyStep=true end
                local outputChange=math.abs(after.gasOutput-before.gasOutput)
                local efficiencyChange=math.abs(after.boilerEfficiency-before.boilerEfficiency)
                if outputChange>math.max(math.abs(before.gasOutput)*0.1,0.001) or efficiencyChange>0.05 then
                    supplyStable=false
                end
                if before.filledVolume and after.filledVolume and before.capacity and after.capacity then
                    local oldRate=(before.fillRate or 0)
                    local newRate=(after.filledVolume-before.filledVolume)/dt
                    after.fillRate=newRate
                    local fillRateTolerance=math.max(0.01,math.abs(oldRate)*0.2)
                    if math.abs(newRate-oldRate)>fillRateTolerance then responseRatesStable=false end
                else responseRatesStable=false end
            end
            if previous.quadrants[q] and current.quadrants[q] and
                previous.quadrants[q].lift and current.quadrants[q].lift then
                local oldRate=previous.quadrants[q].liftRate or 0
                local newRate=(current.quadrants[q].lift-previous.quadrants[q].lift)/dt
                current.quadrants[q].liftRate=newRate
                if math.abs(newRate-oldRate)>math.max(SYSTEMS_LIFT_PROGRESS_EPSILON,math.abs(oldRate)*0.2) then
                    responseRatesStable=false
                end
            else responseRatesStable=false end
        end
        if supplyStep then s.supplyStableSamples=0;s.supplyStepAt=now
        elseif supplyStable then s.supplyStableSamples=(s.supplyStableSamples or 0)+1
        else s.supplyStableSamples=0 end
        current.supplyStep=supplyStep
        current.supplyStable=(s.supplyStableSamples or 0)>=SYSTEMS_RATE_STABLE_SAMPLES
        current.responseRatesStable=responseRatesStable
        if supplyStep and s.responseProbe and s.responseProbe.excitation==true and current.fullEfficiency then
            -- A sudden source restoration is a new excitation. Restart the
            -- response measurement here so outage/recovery time is not folded
            -- into the normal envelope-fill lag.
            s.responseProbe={excitation=true,at=now,actualRatio=current.actualRatio,
                quadrants=clone(current.quadrants),ceilingSum=s.responseProbe.ceilingSum,
                liftRiseSamples=0,fillRiseSamples=0}
        end
        if s.responseProbe and s.responseProbe.excitation==true and current.fullEfficiency and current.outputsValid then
            local probe=s.responseProbe
            if not s.fillResponseLagSeconds then
                for _,q in ipairs(QUADS) do
                    local start=probe.quadrants[q];local after=current.quadrants[q]
                    if start and after and start.filledVolume and after.filledVolume and
                        finite(after.gasOutput) and after.gasOutput>0 and
                        math.abs(after.filledVolume-start.filledVolume)>1 then
                        if after.filledVolume<start.filledVolume then
                            start.filledVolume=after.filledVolume
                            probe.fillRiseSamples=0
                        else
                            start.filledVolume=after.filledVolume
                            probe.fillRiseSamples=(probe.fillRiseSamples or 0)+1
                            if probe.fillRiseSamples>=3 then
                                s.fillResponseLagSeconds=now-probe.at;break
                            end
                        end
                    end
                end
            end
            local positiveOutput=false
            for _,q in ipairs(QUADS) do
                local quadrant=current.quadrants[q]
                if quadrant and finite(quadrant.gasOutput) and quadrant.gasOutput>0 then positiveOutput=true;break end
            end
            if not s.liftResponseLagSeconds and positiveOutput then
                local change=current.actualRatio-probe.actualRatio
                if change< -SYSTEMS_LIFT_RESPONSE_ONSET_EPSILON then
                    -- START SYSTEMS can begin with residual lift from the
                    -- probe phase. Follow its measured decay so we do not
                    -- mistake the later return to that stale high level for
                    -- the beginning of an upward response.
                    probe.actualRatio=current.actualRatio
                    probe.liftRiseSamples=0
                elseif change>SYSTEMS_LIFT_RESPONSE_ONSET_EPSILON then
                    probe.actualRatio=current.actualRatio
                    probe.liftRiseSamples=(probe.liftRiseSamples or 0)+1
                    if probe.liftRiseSamples>=3 then
                        s.liftResponseLagSeconds=now-probe.at
                    end
                else
                    probe.liftRiseSamples=0
                end
            end
            if s.liftResponseLagSeconds then
                s.responseLagSeconds=math.max(s.liftResponseLagSeconds,s.fillResponseLagSeconds or 0,sampleSeconds)
                s.responseProbe=nil
            end
        end
    else
        current.supplyStable=false
        current.responseRatesStable=false
        s.supplyStableSamples=0
    end
    if previous then
        for _,q in ipairs(QUADS) do
            local before,after=previous.quadrants[q],current.quadrants[q]
            if before and after and before.filledVolume and after.filledVolume and now>previous.at then
                after.fillRate=(after.filledVolume-before.filledVolume)/(now-previous.at)
            end
        end
    end
    s.dynamics=current
end

-- START SYSTEMS uses the same equilibrium feed-forward as normal flight: raw
-- envelope lift is checked against the configured gas strengths, then local
-- pressure and vessel mass convert it to support. Gravity is included on both
-- sides because Aeronautics applies it to balloon lift as well as vessel
-- weight. Fresh bulk output and current ceilings are recorded to ground the
-- response estimate; ceiling commands still use the conservative slew below.
-- @ama-summary: START SYSTEMS uses the same equilibrium feed-forward as normal flight: raw envelope lift is checked against the configured gas strengths, then local pressure and vessel mass convert it to support. Gravity is included on both sides because Aeronautics applies it to balloon lift as well as vessel weight. Fresh bulk output and current ceilings are recorded to ground the response estimate; ceiling commands still use the conservative slew below.
function Flight:systemsHoverFeedForward(io,s,now)
    local vessel=io.vessel or {}
    local gravity=vessel.environment and vessel.environment.gravity and
        math.abs(vessel.environment.gravity.y)
    local pressure=airPressure(vessel)
    if not finite(vessel.mass) or vessel.mass<=0 or not finite(gravity) or gravity<=0 or
        not pressure then return nil,"MASS / GRAVITY / PRESSURE UNAVAILABLE" end
    local strengths=self.config and self.config.verified_gas_lift_strengths
    if type(strengths)~="table" then return nil,"VERIFIED GAS LIFT STRENGTHS UNAVAILABLE" end
    local mixedLift,bulkOutput,bulkCeiling=0,0,0
    for _,q in ipairs(QUADS) do
        local node=io.nodes and io.nodes[q]
        if not node or not io:nodeFresh(q,now) then return nil,q.." BULK DATA STALE" end
        local balloon=node.balloon or {}
        if balloon.gasMixValid~=true or type(balloon.gasMix)~="table" then
            return nil,q.." GAS MIX UNAVAILABLE"
        end
        for gas,amount in pairs(balloon.gasMix) do
            if type(gas)~="string" or not finite(amount) or amount<0 then
                return nil,q.." GAS MIX INVALID"
            end
            if amount>0 then
                local strength=strengths[gas]
                if not finite(strength) or strength<=0 then return nil,"LIFT STRENGTH UNVERIFIED FOR "..gas end
                mixedLift=mixedLift+amount*strength
            end
        end
        for name,provider in pairs(node.providers or {}) do
            if provider.controlRole=="bulk" then
                if provider.gasTypeValid~=true or type(provider.gasType)~="string" or
                    not finite(strengths[provider.gasType]) or strengths[provider.gasType]<=0 then
                    return nil,q.." PROVIDER "..name.." GAS STRENGTH UNAVAILABLE"
                end
                if provider.gasOutputValid~=true or not finite(provider.gasOutput) or provider.gasOutput<0 or
                    not finite(provider.targetAmount) or provider.targetAmount<0 then
                    return nil,q.." PROVIDER "..name.." OUTPUT / CEILING UNAVAILABLE"
                end
                bulkOutput=bulkOutput+provider.gasOutput*strengths[provider.gasType]
                bulkCeiling=bulkCeiling+provider.targetAmount*strengths[provider.gasType]
            end
        end
    end
    if mixedLift<=0 then return nil,"POSITIVE VERIFIED ENVELOPE LIFT REQUIRED" end
    local weight=vessel.mass*gravity
    local requiredLift=weight/(pressure*gravity)
    local targetSupportRatio=requiredLift*pressure*gravity/weight
    local currentSupportRatio=mixedLift*pressure*gravity/weight
    local feedForward={source="VERIFIED MASS / PRESSURE / GAS MIX / BULK OUTPUT",
        targetSupportRatio=targetSupportRatio,currentSupportRatio=currentSupportRatio,
        requiredRawLift=requiredLift,measuredRawLift=mixedLift,
        bulkLiftOutput=bulkOutput,bulkLiftCeiling=bulkCeiling,
        bulkOutputPerCeiling=bulkCeiling>0 and bulkOutput/bulkCeiling or nil}
    s.hoverFeedForward=feedForward
    return feedForward
end

-- @ama-summary: Allocate bounded provider targets from the requested support ratio and trim corrections.
function Flight:systemsControlTargets(io,s,dt,desiredRatio,actualRatio,now,slewDt)
    slewDt=finite(slewDt) and slewDt>0 and math.min(slewDt,SYSTEMS_MAX_SLEW_CATCHUP_SECONDS) or dt
    local tolerance=self.config.lift_balance_tolerance_fraction or 0.2
    local gravity=math.abs(io.vessel.environment.gravity.y)
    local responseSeconds=math.max(self.config.hover_capture_seconds or 5,1)
    local hoverSpeed=self.config.hover_max_vertical_speed or 0.2
    local state=s.dynamics or {}
    local lag=s.responseLagSeconds
    local v=io.vessel
    local maxVs=s.phase=="BUILDING_LIFT" and systemsStartupNominalSpeed(self.config) or
        (self.config.max_vertical_speed or 1)
    -- Keep the lift deadband narrow enough that the commanded ratio can still
    -- correct vertical-speed errors inside the hover capture band.
    local releaseDelay=0
    if s.phase=="BUILDING_LIFT" and actualRatio>desiredRatio and actualRatio>0 then
        -- Predict the ceiling slew needed to reduce the current measured lift.
        -- Ceiling travel and envelope fill both continue after a control batch,
        -- so include both in the response horizon used for braking.
        local reduction=clamp((actualRatio-desiredRatio)/actualRatio,0,1)
        releaseDelay=reduction/math.max(SYSTEMS_RELEASE_RAMP_FRACTION_PER_SECOND,0.001)
    end
    local startupHorizon=s.phase=="BUILDING_LIFT" and
        systemsStartupControlHorizon(self.config,lag,state.sampleSeconds) or lag
    local supportProjectionHorizon=math.max(finite(state.sampleSeconds) and state.sampleSeconds or 0,
        finite(lag) and lag or 0)
    local deadbandHorizon=s.phase=="BUILDING_LIFT" and startupHorizon or responseSeconds
    local deadband=math.max(0.0001,math.min(tolerance*0.005,
        hoverSpeed/(gravity*math.max(deadbandHorizon or responseSeconds,1))*0.25))
    local controlRatio=actualRatio
    local forecastLiftRate=finite(state.projectedLiftRate) and state.projectedLiftRate or state.liftRate
    if startupHorizon and startupHorizon>0 and finite(forecastLiftRate) then
        -- Project measured support during both acquisition and the normal HOLD
        -- handoff. The same continuous envelope prevents a delayed plant from
        -- accumulating repeated ceiling increases while current lift catches up.
        controlRatio=systemsProjectedSupportRatio(actualRatio,forecastLiftRate,
            supportProjectionHorizon+releaseDelay,desiredRatio) or actualRatio
    end
    local error=desiredRatio-controlRatio
    local direction=error>deadband and 1 or (error< -deadband and -1 or 0)
    -- Keep each batch's ceiling correction proportional to the measured
    -- support error and the live ceiling. Do not bake the test plant's
    -- nonlinear response curve into production control.
    local correctionFraction=clamp(math.abs(desiredRatio-controlRatio)/
        math.max(desiredRatio,0.05),0,1)
    local sampleSeconds=finite(state.sampleSeconds) and math.max(state.sampleSeconds,0.1) or 0.5
    local appliedCommandAge=now-(s.lastTargetAppliedAt or s.lastTargetCommandAt or now)
    local envelopeHorizon=systemsStartupEnvelopeHorizon(lag,state.sampleSeconds)
    if s.phase=="BUILDING_LIFT" and startupHorizon and controlRatio>desiredRatio and actualRatio<desiredRatio and
        finite(v.verticalSpeed) and v.verticalSpeed<=(self.config.hover_max_vertical_speed or 0.2) and
        finite(v.altitude) and finite(s.target) and s.target>v.altitude then
        -- A forecast may show that the current ceiling is still filling toward
        -- hover support. While actual lift is below demand and the vessel has
        -- not begun a controlled climb, hold the ceiling and let that measured
        -- fill response arrive instead of reversing the ramp abruptly.
        direction=0
    end
    if s.phase=="BUILDING_LIFT" and direction>0 then
        local requestedSpeed=finite(self.verticalTarget) and self.verticalTarget or 0
        local requestedAcceleration=s.lastRequestedAcceleration
        local measuredAcceleration=state.verticalAccelerationRaw
        local accelerationSatisfied=finite(requestedAcceleration) and finite(measuredAcceleration) and
            (measuredAcceleration>=requestedAcceleration or
             (requestedAcceleration<0 and finite(v.verticalSpeed) and v.verticalSpeed>requestedSpeed))
        local supportSatisfied=actualRatio>=desiredRatio-deadband and finite(v.verticalSpeed) and
            v.verticalSpeed>=requestedSpeed
        if supportSatisfied or accelerationSatisfied then
            -- A delayed lift-rate forecast can ask for another upward batch
            -- after actual support/speed already satisfy the command. Hold the
            -- current ceiling until measured acceleration falls behind the
            -- requested motion; genuine positive speed error with support
            -- below demand remains eligible for an upward correction.
            direction=0
        end
    end
    s.lastSupportCorrectionFraction=correctionFraction
    s.lastSupportCorrectionDirection=direction
    s.lastCeilingSlewSeconds=slewDt
    local remainders=s.supportCorrectionRemainders or {}
    s.supportCorrectionRemainders=remainders
    -- @ama-summary: Calculate a bounded provider change from measured support error and actuator limits.
    local function supportStepFor(q,name,available)
        local quadrant=remainders[q]
        if not quadrant then quadrant={};remainders[q]=quadrant end
        local entry=quadrant[name]
        if not entry then entry={direction=direction,remainder=0};quadrant[name]=entry end
        if direction==0 then return 0 end
        if entry.direction~=direction then
            if entry.direction~=0 then entry.remainder=0 end
            entry.direction=direction
        end
        if available<=0 then entry.remainder=0;return 0 end
        local budget=available*correctionFraction+clamp(entry.remainder or 0,0,0.999999)
        local whole=math.min(available,math.floor(budget))
        entry.remainder=math.max(0,budget-whole)
        return whole
    end
    local maps={};local allAtMaximum=direction>0
    -- An observed lag remains useful for braking during a temporary supply
    -- step. Supply instability blocks upward boost, but should not erase the
    -- measured stopping horizon.
    local altitudeBudget,verticalBudget,liftBudget=0,0,0
    local releaseUrgency=0
    local forecastOnlyRelease=false
    if startupHorizon and startupHorizon>0 and finite(v.altitude) and finite(v.verticalSpeed) then
        local response=math.max(self.config.hover_capture_seconds or 5,1)
        local rise=math.max(0,v.verticalSpeed)
        local controlDelay=(s.phase=="BUILDING_LIFT" and
            systemsStartupEnvelopeHorizon(lag,state.sampleSeconds) or
            math.max(6,finite(lag) and lag or 0,finite(state.sampleSeconds) and state.sampleSeconds or 0))+releaseDelay
        local projectedY=v.altitude+systemsProjectedClimbDistance(v,state,controlDelay,gravity,desiredRatio)
        local brakeAcceleration=s.phase=="BUILDING_LIFT" and systemsStartupAcceleration(self.config,lag,
            state.sampleSeconds,s.lastAckWaitSeconds) or maxVs/response
        local commandInterval=finite(state.sampleSeconds) and math.max(0,state.sampleSeconds) or 0
        local brakingResponse=s.phase=="BUILDING_LIFT" and startupHorizon or
            (finite(lag) and lag or response)
        local stoppingDistance=rise*rise/(2*math.max(brakeAcceleration,0.01))+rise*(brakingResponse+commandInterval)
        local altitudeMargin=s.phase=="BUILDING_LIFT" and hoverSpeed*response or maxVs*response
        local altitudeScale=s.phase=="BUILDING_LIFT" and math.max(hoverSpeed*response,1) or
            math.max(maxVs*response,1)
        local remaining=(s.target or v.altitude)-projectedY-stoppingDistance-altitudeMargin
        altitudeBudget=clamp(remaining/altitudeScale,0,1)
        verticalBudget=clamp((maxVs*0.5-rise)/math.max(maxVs*0.5,0.01),0,1)
        local projectedRatio=systemsProjectedSupportRatio(actualRatio,forecastLiftRate,
            supportProjectionHorizon+releaseDelay,desiredRatio) or actualRatio
        liftBudget=clamp((desiredRatio-projectedRatio)/math.max(desiredRatio-1,deadband*4),0,1)
        if state.complete and state.outputsValid and state.efficienciesValid then
            local measuredLiftUrgency=clamp((actualRatio-desiredRatio)/
                math.max(desiredRatio-1,0.02),0,1)
            releaseUrgency=math.max(1-altitudeBudget,1-verticalBudget,measuredLiftUrgency)
        end
        local nominal=systemsStartupNominalSpeed(self.config)
        local remainingTarget=(s.target or v.altitude)-v.altitude
        if s.phase=="BUILDING_LIFT" and actualRatio<desiredRatio and controlRatio>desiredRatio and
            rise<nominal*0.5 and remainingTarget>maxVs*response then
            -- Linear projection can cross demand while the vessel is still
            -- well below neutral lift. Use its distance beyond demand to ask
            -- for a small, proportional ceiling correction, not the full
            -- altitude/vertical braking release. Once lift or climb is
            -- actually excessive, the regular braking urgency applies.
            forecastOnlyRelease=true
            releaseUrgency=clamp((controlRatio-desiredRatio)/
                math.max(desiredRatio-1,deadband*4),0,1)
        end
    end
    local demandProgress,capacityProgress,capacityLimited={},{},{}
    local fastBoost={}
    local startupProgress=1
    local startupMotionProgress=1
    if s.phase=="BUILDING_LIFT" then
        local supportTarget=(s.hoverFeedForward and s.hoverFeedForward.targetSupportRatio) or desiredRatio
        local nominal=systemsStartupNominalSpeed(self.config)
        local speedProgress=clamp(1-math.max(0,v.verticalSpeed)/math.max(nominal*0.75,0.01),0,1)
        local accelerationLimit=systemsStartupAcceleration(self.config,lag,state.sampleSeconds,s.lastAckWaitSeconds)
        local accelerationProgress=clamp(1-math.max(0,state.verticalAcceleration or 0)/
            math.max(accelerationLimit,0.01),0,1)
        if state.supplyStep then
            s.acquisitionMotionSamples=0
            s.acquisitionMotionReadyAt=nil
            s.acquisitionMotionLostAt=nil
        elseif finite(v.verticalSpeed) and v.verticalSpeed>0.1 then
            s.acquisitionMotionSamples=(s.acquisitionMotionSamples or 0)+1
            s.acquisitionMotionLostAt=nil
        else
            s.acquisitionMotionSamples=0
            -- Brief deceleration or a hover capture does not erase response
            -- already demonstrated by the vessel. Invalidate that proof only
            -- after support is measurably lost for a full response horizon
            -- while the selected target still calls for a meaningful climb.
            local responseHorizon=systemsStartupControlHorizon(self.config,lag,state.sampleSeconds)
            local meaningfulClimb=finite(s.target) and finite(v.altitude) and
                s.target-v.altitude>maxVs*math.max(self.config.hover_capture_seconds or 5,1)
            local supportLost=finite(actualRatio) and actualRatio<math.min(0.98,supportTarget-0.02)
            if s.acquisitionMotionReadyAt and meaningfulClimb and supportLost then
                s.acquisitionMotionLostAt=s.acquisitionMotionLostAt or now
                if now-s.acquisitionMotionLostAt>=responseHorizon then
                    s.acquisitionMotionReadyAt=nil
                    s.acquisitionMotionLostAt=nil
                end
            else
                s.acquisitionMotionLostAt=nil
            end
        end
        if s.acquisitionMotionSamples>=3 then
            s.acquisitionMotionReadyAt=s.acquisitionMotionReadyAt or now
        end
        startupMotionProgress=0
        if s.acquisitionMotionReadyAt then
            startupMotionProgress=clamp((now-s.acquisitionMotionReadyAt)/
                systemsStartupSpeedRampHorizon(self.config,lag,state.sampleSeconds,s.lastAckWaitSeconds),0,1)
        end
        startupProgress=math.min(systemsSupportProgress(actualRatio,supportTarget),
            speedProgress,accelerationProgress,startupMotionProgress)
    end
    local correctionBand=math.max(deadband*4,0.005)
    local commandCadence=finite(s.lastAckWaitSeconds) and math.max(sampleSeconds,
        s.lastAckWaitSeconds+sampleSeconds) or sampleSeconds
    local actualSupportError=math.abs(actualRatio-desiredRatio)
    local rawAcceleration=state.verticalAccelerationRaw
    local responseSettled=finite(rawAcceleration) and
        math.abs(rawAcceleration)<=math.max(0.02,gravity*0.005)
    local slowAckCorrection=direction~=0 and finite(s.lastAckWaitSeconds) and
        s.lastAckWaitSeconds>sampleSeconds*1.5 and envelopeHorizon>0 and
        state.complete and state.outputsValid and state.efficienciesValid and state.supplyStep~=true and
        finite(v.verticalSpeed) and math.abs(v.verticalSpeed)<=hoverSpeed and responseSettled and
        actualSupportError<=correctionBand and math.abs(actualRatio-1)<=math.max(0.02,correctionBand) and
        releaseUrgency<0.5
    if slowAckCorrection then
        -- A slow command cadence repeats a small near-neutral correction only
        -- once per actuator ACK, while the fill response spans many seconds.
        -- Apply the same measured response-share to increase and decrease
        -- corrections in this settled regime. Excess lift, unsafe climb,
        -- rising acceleration, and high vertical speed keep full release.
        local responseShare=clamp((math.max(0,appliedCommandAge)+commandCadence)/
            (envelopeHorizon+commandCadence),0,1)
        local proximity=clamp(1-actualSupportError/correctionBand,0,1)
        correctionFraction=correctionFraction*(1-proximity*(1-responseShare))
    end
    for _,q in ipairs(QUADS) do
        maps[q]={}
        local quadrant=state.quadrants and state.quadrants[q] or {}
        local quadrantHasHeadroom=false
        for name,provider in pairs(io.nodes[q].providers) do
            if provider.controlRole=="bulk" and s.currentTargets[q][name]<provider.maxTarget then
                quadrantHasHeadroom=true
                break
            end
        end
        local quadrantReleaseUrgency=releaseUrgency
        local projectedFill
        if lag and finite(quadrant.fillFraction) then
            local fillRate=math.max(0,quadrant.fillRate or 0)
            projectedFill=quadrant.fillFraction+fillRate*lag/math.max(quadrant.capacity or 1,0.000001)
            capacityProgress[q]=projectedFill
        end
        local fillBudget=1
        if projectedFill then
            fillBudget=clamp((SYSTEMS_FAST_FILL_STOP_FRACTION-projectedFill)/
                (SYSTEMS_FAST_FILL_STOP_FRACTION-SYSTEMS_FAST_FILL_TAPER_FRACTION),0,1)
            if state.complete and state.outputsValid and state.efficienciesValid then
                quadrantReleaseUrgency=math.max(quadrantReleaseUrgency,1-fillBudget)
            end
            local node=io.nodes[q];local measuredLift=node and node.balloon and node.balloon.lift
            local requiredPerQuad=io.vessel.mass*desiredRatio/(4*airPressure(io.vessel))
            if projectedFill>=SYSTEMS_FAST_FILL_TAPER_FRACTION and finite(measuredLift) and measuredLift<requiredPerQuad then
                capacityLimited[q]=true
            end
        end
        demandProgress[q]=clamp((quadrant.lift or 0)*4*airPressure(io.vessel)/io.vessel.mass,0,2)
        for name,p in pairs(io.nodes[q].providers) do
            local value=s.currentTargets[q][name]
            if p.controlRole=="bulk" then
                local applied=s.coarseTrimApplied and s.coarseTrimApplied[q] and
                    s.coarseTrimApplied[q][name]
                if finite(applied) then value=value-applied end
                local floor=p.minimumNonzeroTarget or 50
                local maximum=p.maxTarget
                    local demandScale=(s.phase=="BUILDING_LIFT" or s.phase=="READY") and 0.02 or tolerance
                local magnitude=math.min(1,math.max(0,(math.abs(error)-deadband)/
                    math.max(demandScale,deadband*4,0.01)))
                if direction>0 then
                    local supplySettled=not s.supplyStepAt or (lag and now-s.supplyStepAt>=lag)
                    local fastReady=s.phase=="BUILDING_LIFT" and quadrantHasHeadroom and lag and supplySettled and state.supplyStable and state.complete and
                        state.outputsValid and state.efficienciesValid and state.fullEfficiency==true and state.quadrants[q] and
                        projectedFill~=nil and not state.supplyStep
                    -- Neutral support with no vessel motion is the most
                    -- dangerous instant to accelerate filling: the plant may
                    -- still be waiting on envelope lag. Keep the soft startup
                    -- rate until positive motion is observed across multiple
                    -- samples and one further measured response horizon.
                    if s.phase=="BUILDING_LIFT" then
                        fastReady=fastReady and startupMotionProgress>=1
                    end
                    local boost=fastReady and math.min(altitudeBudget,verticalBudget,liftBudget,fillBudget,
                        startupProgress) or 0
                    fastBoost[q]=boost
                    local softRate,riseRate,fastRate=ceilingRiseRates(self.config)
                    local rate=riseRate
                    if s.phase=="BUILDING_LIFT" then
                        rate=softRate+(riseRate-softRate)*startupProgress
                    end
                    rate=rate+(fastRate-riseRate)*boost
                    local slewScale=maximum
                    if s.phase=="READY" then
                        -- HOLD remains incremental after a restart/recovery
                        -- with no lag estimate. Maximum capacity is not the
                        -- amount currently keeping the vessel near hover.
                        slewScale=math.max(1,value-(p.minimumNonzeroTarget or 50))
                    end
                    local step=math.max(1,math.floor(slewScale*rate*slewDt*magnitude+0.5))
                    local headroom=maximum-value
                    local supportStep=supportStepFor(q,name,value)
                    step=headroom>0 and math.min(step,headroom,supportStep) or 0
                    value=math.min(maximum,value+step)
                elseif direction<0 then
                    local releaseRate=s.phase=="READY" and SYSTEMS_RELEASE_RAMP_FRACTION_PER_SECOND or
                        SYSTEMS_RELEASE_RAMP_FRACTION_PER_SECOND+
                        (SYSTEMS_FAST_RELEASE_FRACTION_PER_SECOND-SYSTEMS_RELEASE_RAMP_FRACTION_PER_SECOND)*
                        clamp(quadrantReleaseUrgency,0,1)
                    -- In HOLD, or with a measured response horizon, slew down
                    -- from the applied ceiling. Using the configured maximum
                    -- as the scale can remove a large share of a much smaller
                    -- live ceiling in a single batch. Unknown-lag legacy
                    -- fixtures retain the maximum-based emergency slew.
                    local floor=p.minimumNonzeroTarget or 50
                    local releaseScale=(s.phase=="READY" or lag) and math.max(1,value-floor) or maximum
                    if forecastOnlyRelease then releaseScale=math.max(1,value-floor) end
                    local step=math.max(1,math.floor(releaseScale*releaseRate*slewDt*magnitude+0.5))
                    local available=value-floor
                    local supportStep=supportStepFor(q,name,available)
                    step=available>0 and math.min(step,available,supportStep) or 0
                    value=math.max(floor,value-step)
                end
                value=clamp(value,floor,maximum)
                if value<maximum then allAtMaximum=false end
            elseif p.controlRole=="fine" and s.baseline and s.baseline[q] then
                local base=s.baseline[q][name] or value
                value=clamp(math.floor(base+(self.trim[q] or 0)+0.5),
                    p.minimumNonzeroTarget or 5,p.maxTarget)
            end
            maps[q][name]=value
        end
        if fastBoost[q]==nil then fastBoost[q]=0 end
    end
    local anyBoost=false
    for _,boost in pairs(fastBoost) do if boost>0 then anyBoost=true;break end end
    return maps,direction,allAtMaximum,{curve=anyBoost and "ALTITUDE-AWARE FAST SLEW" or "CONSERVATIVE FEEDBACK",
        fastBoost=fastBoost,demandProgress=demandProgress,capacityProgress=capacityProgress,capacityLimited=capacityLimited}
end
-- @ama-summary: Describe observed provider-capacity and efficiency limitations during lift acquisition.
local function systemsWarning(io,s)
    local lowEfficiency,capacityLimited={},{}
    for _,q in ipairs(QUADS) do
        local node=io.nodes[q]
        local lowestName,lowestEfficiency
        for name,provider in pairs(node and node.providers or {}) do
            if provider.controlRole=="bulk" and provider.signalValid==true and provider.signalStrength==15 and
                provider.boilerEfficiencyValid==true and finite(provider.boilerEfficiency) and
                (not lowestEfficiency or provider.boilerEfficiency<lowestEfficiency) then
                lowestName,lowestEfficiency=name,provider.boilerEfficiency
            end
        end
        if lowestEfficiency and lowestEfficiency<SYSTEMS_FULL_BOILER_EFFICIENCY then
            lowEfficiency[#lowEfficiency+1]=q.."/"..tostring(lowestName):sub(1,20).." "..
                string.format("%.1f%%",lowestEfficiency*100)
        end
        if s.capacityLimited and s.capacityLimited[q] then capacityLimited[#capacityLimited+1]=q end
    end
    local warnings={}
    if s.acquisitionStallRecovery then
        warnings[#warnings+1]="STATIONARY BELOW TARGET; APPLYING GENTLE LIFT CORRECTION"
    end
    if s.acquisitionOverdue then
        warnings[#warnings+1]="ACQUISITION TAKING LONGER THAN EXPECTED; CONTROL CONTINUING"
    end
    if #lowEfficiency>0 then
        warnings[#warnings+1]="LOW BOILER EFFICIENCY "..table.concat(lowEfficiency,", ").." (EXPECTED 100%)"
    end
    if #capacityLimited>0 then
        warnings[#warnings+1]="BALLOON CAPACITY NEAR FULL WITH LIFT BELOW DEMAND "..table.concat(capacityLimited,",")
    end
    return #warnings>0 and table.concat(warnings,"; ") or nil
end
-- @ama-summary: Capture stable hover targets and transition the systems run to READY.
function Flight:captureSystemsBaseline(io,s,now)
    s.baseline=copyMaps(s.currentTargets)
    s.supportCorrectionRemainders={}
    self.baseline=copyMaps(s.baseline);self.boots=clone(s.boots)
    self.uuid=s.uuid;self.hardwareFingerprint=s.fingerprint;self.target=s.target
    self.mixBaseline={}
    for _,q in ipairs(QUADS) do self.mixBaseline[q]=clone(io.nodes[q].balloon.gasMix) end
    self.outer:reset(io.vessel.altitude);self.inner:reset(io.vessel.verticalSpeed)
    self:seedHoverOffset(io.vessel.altitude)
    self.verticalTarget=io.vessel.verticalSpeed
    self:resetTrim(true);self.effort=0;self.saturated=false
    if s.dynamics and finite(s.dynamics.actualRatio) then s.lastDesiredRatio=s.dynamics.actualRatio
    else s.lastDesiredRatio=1 end
    self.initialAcquisitionEnded=true
    s.phase="READY";s.phaseStartedAt=now;s.lastControlAt=now
    -- Startup's extra takeoff margin is not a learned hover requirement.
    -- Carrying it into READY adds lift after the braking limiter and can
    -- overpower a negative speed-loop correction through the selected height.
    s.climbStallBoost=0;s.climbStallSince=nil;s.holdDriftSince=nil
    self:rememberLevelBias(now,true)
    s.reason="HOLDING SELECTED ALTITUDE"
    clearOperationIssue(self,"flight","systems","Core flight systems recovered: stable altitude hold reached")
end
-- @ama-summary: Combine trim and altitude demand into the next hold target maps.
function Flight:systemsHoldTargets(io,s,dt,actualRatio,now,slewDt)
    local trimOk,trimReason=self:updateTrim(io,s.baseline,dt,slewDt,now)
    if not trimOk then return nil,trimReason end
    local desiredRatio,reason=self:systemsAcquisitionControl(io,s,dt,actualRatio,now,slewDt)
    if not finite(desiredRatio) then return nil,reason or "HOLD PLANT INPUTS UNAVAILABLE" end
    local maps=self:systemsControlTargets(io,s,dt,desiredRatio,actualRatio,now,slewDt)
    return maps
end

-- @ama-summary: Compute bounded vertical-speed and lift-ratio demand from altitude error and measured dynamics.
function Flight:systemsAcquisitionControl(io,s,dt,actualRatio,now,slewDt)
    local c=self.config;local v=io.vessel
    local startupDemand=s.phase=="BUILDING_LIFT"
    -- Keep virtual speed-target slew bounded across an ACK wait. The startup
    -- acceleration itself has already been reduced by the measured command
    -- cadence, so this capped elapsed budget lets a braking target respond
    -- without feeding the entire wait into either PID integrator.
    local commandSlewDt=finite(slewDt) and slewDt>0 and
        math.min(slewDt,SYSTEMS_MAX_SLEW_CATCHUP_SECONDS) or dt
    local maxVs=startupDemand and systemsStartupNominalSpeed(c) or (c.max_vertical_speed or 1)
    local responseSeconds=math.max(c.hover_capture_seconds or 5,1)
    local gravity=math.abs(v.environment.gravity.y)
    local feedForward,feedReason=self:systemsHoverFeedForward(io,s,now)
    if not feedForward then
        if not startupDemand then
            s.acquisitionPidActive=false;s.feedForwardReason=feedReason
            return nil,feedReason or "HOLD PLANT INPUTS UNAVAILABLE"
        end
        -- Preserve the slow measured-lift ramp if output telemetry is absent,
        -- but do not claim a nested PID is active without its verified plant
        -- inputs. No integrator or trim state is changed on this fallback.
        s.acquisitionPidActive=false;s.feedForwardReason=feedReason
        s.speedLimiter="NO LIFT OUTPUT DATA"
        local desired=clamp((s.target-v.altitude)/responseSeconds,-maxVs,maxVs)
        local lag=s.responseLagSeconds
        local horizon=systemsStartupControlHorizon(c,lag,(s.dynamics or {}).sampleSeconds)
        if startupDemand and v.altitude<s.target then
            local state=s.dynamics or {}
            local releaseDelay=0
            if finite(s.lastDesiredRatio) and actualRatio>s.lastDesiredRatio and actualRatio>0 then
                releaseDelay=clamp((actualRatio-s.lastDesiredRatio)/actualRatio,0,1)/
                    math.max(SYSTEMS_RELEASE_RAMP_FRACTION_PER_SECOND,0.001)
            end
            local envelopeHorizon=systemsStartupEnvelopeHorizon(lag,state.sampleSeconds)
            local projectedRise=systemsProjectedClimbDistance(v,state,
                envelopeHorizon+releaseDelay,gravity,s.lastDesiredRatio)
            local speedLead=math.max(0,v.verticalSpeed)*horizon
            local remaining=math.max(0,s.target-v.altitude-projectedRise-speedLead)
            desired=math.min(desired,math.sqrt(2*systemsStartupAcceleration(c,lag,state.sampleSeconds,
                s.lastAckWaitSeconds)*remaining))
        end
        if desired>0 then
            desired=math.min(desired,maxVs*systemsSupportProgress(actualRatio,1))
            local acceleration=systemsStartupAcceleration(c,lag,state.sampleSeconds,s.lastAckWaitSeconds)
            desired=math.min(desired,(self.verticalTarget or 0)+acceleration*commandSlewDt)
        end
        self.verticalTarget=desired
        self.effort=0;self.feedLimited=false;self.speedLimited=false
        return clamp(1+(self.verticalTarget-v.verticalSpeed)/(gravity*responseSeconds),
            math.max(0,1-c.lift_balance_tolerance_fraction),1+c.lift_balance_tolerance_fraction)
    end
    s.feedForwardReason=nil
    local oldOuterI,oldInnerI=self.outer.i,self.inner.i
    -- READY hold lead. A support change takes effect only after the command
    -- ACK and balloon fill (several seconds), so reacting to the present
    -- altitude and speed overshoots both ways: logged 2026-10-20 as a ~20 s,
    -- +/-5 block limit cycle. Steer both loops on values predicted part of
    -- the measured response lag ahead.
    local leadSeconds=0
    if s.phase=="READY" and not startupDemand then
        -- After an airborne start or recovery no response lag has been
        -- measured; estimate it from the measured command ACK wait plus ~2 s
        -- of balloon fill.
        local responseLag=s.responseLagSeconds
        if not finite(responseLag) then
            responseLag=(finite(s.lastAckWaitSeconds) and s.lastAckWaitSeconds or 2.5)+2
        end
        leadSeconds=clamp(responseLag*0.6,0,4)
    end
    local leadDynamics=s.dynamics or {}
    local leadAcceleration=finite(leadDynamics.verticalAcceleration) and
        clamp(leadDynamics.verticalAcceleration,-1,1) or 0
    local leadVs=v.verticalSpeed+leadAcceleration*leadSeconds
    local leadAltitude=v.altitude+(v.verticalSpeed+0.5*leadAcceleration*leadSeconds)*leadSeconds
    s.holdLeadSeconds=leadSeconds
    local desiredVs,outerLimited=self.outer:step(s.target,leadAltitude,dt,-maxVs,maxVs)
    -- Names the bound that set this sample's climb command, for the displays.
    local limiter=outerLimited and "MAX CLB" or "ALTITUDE PID"
    local lag=s.responseLagSeconds
    local state=s.dynamics or {}
    local horizon=systemsStartupControlHorizon(c,lag,state.sampleSeconds)
    local envelopeHorizon=systemsStartupEnvelopeHorizon(lag,state.sampleSeconds)
    local hoverSpeed=c.hover_max_vertical_speed or 0.2
    local remainingTarget=s.target-v.altitude
    local holdApproachActive=s.phase=="READY" and
        math.abs(remainingTarget)<=math.max(4,maxVs*responseSeconds)
    if not holdApproachActive then s.holdApproach=nil end
    if holdApproachActive then
        -- A delayed envelope must begin braking while still on the approach
        -- side of the target. Project the current signed travel over the
        -- response horizon, rather than waiting for the altitude error to
        -- change sign. Bound noisy lag estimates to two response horizons;
        -- a measured ACK wait is still included in full.
        local delay=math.max(responseSeconds,math.min(finite(lag) and lag or 0,responseSeconds*2),
            finite(s.lastAckWaitSeconds) and s.lastAckWaitSeconds or 0,state.sampleSeconds or .5)
        -- Use HOLD's gentle braking authority, not startup acceleration.
        -- Otherwise the stopping-distance governor assumes a faster brake
        -- than the support-demand cap is actually allowed to command.
        local acceleration=maxVs/math.max(SYSTEMS_STARTUP_SPEED_RAMP_SECONDS,responseSeconds,delay,.5)
        local distance=math.abs(remainingTarget)
        local approachSpeed=2*acceleration*distance/
            (math.sqrt((acceleration*delay)^2+2*acceleration*distance)+acceleration*delay)
        local bounded=remainingTarget>0 and clamp(desiredVs,0,approachSpeed) or
            (remainingTarget<0 and clamp(desiredVs,-approachSpeed,0) or 0)
        s.holdApproach={responseSeconds=delay,projectedAltitude=v.altitude+v.verticalSpeed*delay,
            approachVerticalSpeed=approachSpeed,braking=finite(v.verticalSpeed) and
                v.verticalSpeed*(bounded-v.verticalSpeed)<0}
        if math.abs(bounded-desiredVs)>1e-9 then
            desiredVs=bounded;outerLimited=true;limiter="APPROACH"
            local g=self.outer.g
            if finite(g.ki) and g.ki>0 then
                local integral=(desiredVs-g.kp*remainingTarget-g.kd*self.outer.d)/g.ki
                local limit=math.max(0,g.integral_limit or 0)
                -- Remove accumulated approach demand, without leaving an
                -- opposing offset that could strand a quiet ship off target.
                if remainingTarget>0 then integral=math.max(0,integral)
                elseif remainingTarget<0 then integral=math.min(0,integral)
                else integral=0 end
                self.outer.i=clamp(integral,-limit,limit)
            else self.outer.i=oldOuterI end
        end
    end
    local approachSupportTolerance=math.max(0.02,hoverSpeed/math.max(gravity*responseSeconds,0.1))
    local captureApproach=startupDemand and remainingTarget>0 and
        remainingTarget<=math.max(3,hoverSpeed*envelopeHorizon) and
        finite(v.verticalSpeed) and math.abs(v.verticalSpeed)<=hoverSpeed and
        math.abs(actualRatio-1)<=approachSupportTolerance
    if captureApproach then
        -- The long startup acceleration horizon is appropriate for shaping a
        -- takeoff, but would reserve the entire final one-to-three blocks as
        -- stopping distance at hover speed. Near a settled target, retain the
        -- measured envelope projection below and use the actual response
        -- horizon for current-speed travel.
        horizon=math.max(state.sampleSeconds or 0.5,finite(lag) and lag or 0)
        desiredVs=math.min(desiredVs,hoverSpeed)
    end
    if startupDemand and remainingTarget<0 and desiredVs>0 then
        -- Do not let a positive altitude-loop integral keep requesting ascent
        -- after the selected height has already been crossed. Start a bounded
        -- hover-speed descent target and clear the conflicting positive bias.
        desiredVs=-math.min(hoverSpeed,(-remainingTarget)/responseSeconds)
        self.outer.i=math.min(0,self.outer.i)
        outerLimited=true
    end
    if startupDemand and desiredVs>0 then
        -- Do not wind the climb-speed target to its nominal limit while the
        -- envelope is still filling against a grounded vessel. Allow only a
        -- small initial takeoff speed, then earn the larger command from
        -- sustained measured motion over the response horizon.
        local motionProgress=0
        if s.acquisitionMotionReadyAt then
            motionProgress=clamp((now-s.acquisitionMotionReadyAt)/
                systemsStartupSpeedRampHorizon(c,lag,state.sampleSeconds,s.lastAckWaitSeconds),0,1)
        end
        local initialSpeed=math.min(maxVs,math.max(c.hover_max_vertical_speed or 0.2,maxVs*0.05))
        local motionSpeedCap=initialSpeed+(maxVs-initialSpeed)*motionProgress
        if desiredVs>motionSpeedCap then
            desiredVs=motionSpeedCap;limiter="TAKEOFF RAMP"
            local g=self.outer.g
            if finite(g.ki) and g.ki>0 and finite(g.kp) and finite(g.kd) then
                local error=s.target-v.altitude
                local integral=(desiredVs-g.kp*error-g.kd*self.outer.d)/g.ki
                local limit=finite(g.integral_limit) and math.max(0,g.integral_limit) or 0
                self.outer.i=clamp(math.max(0,integral),-limit,limit)
            else self.outer.i=math.min(self.outer.i,oldOuterI) end
            outerLimited=true
        end
    end
    if startupDemand and v.altitude<s.target then
        local releaseDelay=0
        if finite(s.lastDesiredRatio) and actualRatio>s.lastDesiredRatio and actualRatio>0 then
            releaseDelay=clamp((actualRatio-s.lastDesiredRatio)/actualRatio,0,1)/
                math.max(SYSTEMS_RELEASE_RAMP_FRACTION_PER_SECOND,0.001)
        end
        local projectedRise=systemsProjectedClimbDistance(v,state,
            envelopeHorizon+releaseDelay,gravity,s.lastDesiredRatio)
        local brakeAcceleration=systemsStartupAcceleration(c,lag,state.sampleSeconds,s.lastAckWaitSeconds)
        local speedLead=math.max(0,v.verticalSpeed)*horizon
        local remaining=math.max(0,s.target-v.altitude-projectedRise-speedLead)
        local safeSpeed=math.sqrt(2*brakeAcceleration*remaining)
        if desiredVs>safeSpeed then
            desiredVs=safeSpeed;limiter="BRAKING"
            -- Back-calculate the altitude integral to the lag-limited speed
            -- command. Merely freezing it would preserve a saturated climb
            -- offset through a long fill delay and slow recovery after braking.
            local g=self.outer.g
            if finite(g.ki) and g.ki>0 and finite(g.kp) and finite(g.kd) then
                local limit=finite(g.integral_limit) and math.max(0,g.integral_limit) or 0
                local altitudeError=s.target-v.altitude
                local integral=(desiredVs-g.kp*altitudeError-g.kd*self.outer.d)/g.ki
                integral=clamp(integral,-limit,limit)
                -- The lag limiter already constrains commanded climb/descent.
                -- Do not back-calculate an opposing integral large enough to
                -- cancel a target error and strand acquisition below target.
                if altitudeError>0 then integral=math.max(0,integral)
                elseif altitudeError<0 then integral=math.min(0,integral)
                else integral=0 end
                self.outer.i=integral
            elseif self.outer.i>oldOuterI then self.outer.i=oldOuterI end
            outerLimited=true
        end
    end
    -- Startup speed grows with measured support. Shape both acceleration and
    -- braking with the same physical bound so a noisy forecast cannot drop a
    -- positive command to zero in one sample and restart the climb next tick.
    local requestedVs=desiredVs
    if startupDemand and requestedVs>0 then
        local unsupported=requestedVs
        requestedVs=math.min(requestedVs,maxVs*systemsSupportProgress(actualRatio,1))
        if requestedVs<unsupported-1e-9 then limiter="V/S DEMAND LIM" end
    end
    if startupDemand then
        local acceleration=systemsStartupAcceleration(c,lag,state.sampleSeconds,s.lastAckWaitSeconds)
        local slew=acceleration*commandSlewDt
        local previousVs=self.verticalTarget or 0
        local bounded=clamp(requestedVs,previousVs-slew,previousVs+slew)
        if math.abs(bounded-desiredVs)>1e-9 then
            desiredVs=bounded;limiter=bounded>previousVs and "ACCEL LIMIT" or "DECEL LIMIT"
            local g=self.outer.g
            if finite(g.ki) and g.ki>0 and finite(g.kp) and finite(g.kd) then
                local altitudeError=s.target-v.altitude
                local integral=(desiredVs-g.kp*altitudeError-g.kd*self.outer.d)/g.ki
                local limit=finite(g.integral_limit) and math.max(0,g.integral_limit) or 0
                self.outer.i=clamp(integral,-limit,limit)
            else self.outer.i=oldOuterI end
            outerLimited=true
        end
    end
    s.speedLimiter=limiter
    self.verticalTarget=clamp(desiredVs,-maxVs,maxVs)
    self.speedLimited=outerLimited==true
    local speedError=self.verticalTarget-leadVs
    local effort,innerLimited=self.inner:step(self.verticalTarget,leadVs,dt,
        -(c.max_feed_fraction or 0.15),c.max_feed_fraction or 0.15)
    local state=s.dynamics or {}
    local supplySettled=state.supplyStable==true and state.responseRatesStable==true and
        state.outputsValid==true and state.efficienciesValid==true and
        state.knownLowEfficiency~=true and state.supplyStep~=true and
        -- After an airborne start or recovery no response lag is measured
        -- until a large lift step happens, which a steady HOLD never makes.
        -- Requiring it froze the speed integral (logged 2026-10-21: 11
        -- blocks below target at +0.01 b/s for minutes, integral pinned).
        -- HOLD already estimates the lag for its lead; takeoff still waits.
        (lag~=nil or (s.phase=="READY" and not startupDemand))
    local unwindingIntegral=oldInnerI*speedError<0
    -- READY hold: the gas supply changes continuously during every climb
    -- (more gas per block as pressure falls), so supply-stability gating froze
    -- the integral upward for whole climbs while letting it wind down freely
    -- in descents (logged 2026-10-22: integral flat at 6.1 for 60 s of a climb,
    -- -6 after a descent, 7.5 block undershoot). Takeoff keeps the gate.
    local holdIntegral=s.phase=="READY" and not startupDemand
    if not supplySettled and not holdIntegral and self.inner.i>oldInnerI and not unwindingIntegral then
        -- A cold/stepped boiler and unmeasured fill delay are not evidence
        -- that extra integral demand is safe. Opposing error can still unwind.
        self.inner.i=oldInnerI
        effort=clamp(self.inner.g.kp*speedError+self.inner.g.ki*self.inner.i+
            self.inner.g.kd*self.inner.d,-(c.max_feed_fraction or 0.15),c.max_feed_fraction or 0.15)
    end
    self.effort=effort;self.feedLimited=innerLimited==true
    s.acquisitionPidActive=true
    local state=s.dynamics or {}
    local dragKnown=finite(state.verticalDragEstimate) and state.verticalDragEstimate>=0
    local drag=dragKnown and state.verticalDragEstimate or 0
    -- Account for signed vertical drag: it opposes ascent and helps brake a
    -- descent. The speed PID supplies the remaining support demand.
    -- Feed drag forward for the COMMANDED vertical speed, never more than the
    -- speed actually reached in that direction. Feeding it from measured
    -- speed was positive feedback: the drag estimate also absorbs hover-model
    -- error and runs high, so a faster climb asked for more lift and climbed
    -- faster (logged 2026-10-20: desired support 1.2 while commanded -5 b/s,
    -- runaway to +7 b/s, then the mirror image to -6 b/s). Bounded to 5% of
    -- weight; the speed PID supplies the rest.
    local commanded=finite(self.verticalTarget) and self.verticalTarget or 0
    local speedForDrag=commanded
    if commanded*v.verticalSpeed>0 and math.abs(v.verticalSpeed)<math.abs(commanded) then
        speedForDrag=v.verticalSpeed
    end
    local measuredResistance=dragKnown and drag*speedForDrag or 0
    local dragCompensation=finite(gravity) and gravity>0 and measuredResistance/gravity or 0
    -- The estimate runs high, so a 5% bound sat saturated through every
    -- commanded descent as a constant bias; keep it small.
    dragCompensation=clamp(dragCompensation,-0.02,0.02)
    -- READY hold uses no drag feed-forward: the estimate is unreliable and
    -- every way of switching the term caused a 2% lift step. The speed
    -- integral learns steady error instead. Startup keeps it.
    if not startupDemand then dragCompensation=0 end
    local supportBaseline=feedForward.targetSupportRatio+dragCompensation
    local holdBraking=not startupDemand and v.verticalSpeed*speedError<0
    s.holdFeedForwardLimited=false
    s.dragSupportCompensation=dragCompensation
    if holdBraking and dragCompensation*v.verticalSpeed>0 then
        -- While braking, drop the drag term only if it pushes in the
        -- direction of the motion being arrested. A term that already
        -- opposes the motion stays: removing a negative (descent) term the
        -- moment she drifted upward was a +2% lift step that restarted the
        -- climb (logged 2026-10-20 as gas jumps of ~1500 per chamber). Do NOT anchor the baseline
        -- to measured support: measured support lags the request by the ACK
        -- and fill delay, so "measured minus correction" ratcheted support
        -- down for the whole rise and up for the whole fall (logged
        -- 2026-10-20: ~25 s, +/-8 block cycle independent of PID gains).
        s.holdFeedForwardLimited=math.abs(dragCompensation)>1e-9
        supportBaseline=feedForward.targetSupportRatio
    end
    -- READY vertical drag feed-forward. Her vertical drag balances about
    -- 1.9% of weight per b/s (logged 2026-10-22: +1.5% above hover held
    -- +0.85 b/s, -2% held -1.0 b/s; time constant ~5.3 s, like horizontal).
    -- Without it the speed PID (0.012 per b/s of error) supplied only ~1.7%
    -- and climbs crept at 0.3-0.9 b/s against a 2.4 b/s command. Fed from the
    -- COMMANDED speed only (never measured speed: that was positive
    -- feedback), so it shrinks smoothly as the altitude loop closes in.
    if not startupDemand then
        local perBps=finite(c.vertical_drag_support_per_bps) and clamp(c.vertical_drag_support_per_bps,0,0.05) or 0.019
        local vsFeedForward=clamp(perBps*commanded,-(c.max_feed_fraction or 0.15),c.max_feed_fraction or 0.15)
        supportBaseline=supportBaseline+vsFeedForward
        s.verticalSpeedFeedForward=vsFeedForward
    end
    s.appliedDragSupportCompensation=supportBaseline-feedForward.targetSupportRatio
    local minimumSupport=math.max(0,1-c.lift_balance_tolerance_fraction)
    local maximumSupport=1+c.lift_balance_tolerance_fraction
    local uncappedSupportRequest=clamp(supportBaseline+effort,minimumSupport,maximumSupport)
    local desiredRatio=uncappedSupportRequest
    if (startupDemand or s.phase=="READY") and finite(gravity) and gravity>0 then
        -- Bound total support demand by the speed-loop acceleration request in
        -- both startup and the delayed-response HOLD handoff. HOLD uses its
        -- measured response horizon; only takeoff uses the deliberately slow
        -- startup speed ramp. Signed measured drag remains separate.
        local horizon=startupDemand and systemsStartupControlHorizon(c,lag,state.sampleSeconds) or
            math.max(finite(lag) and lag or 0,state.sampleSeconds or 0.5)
        local holdAccelerationHorizon=math.max(responseSeconds,
            finite(lag) and lag or 0,finite(state.sampleSeconds) and state.sampleSeconds or 0.5)
        local accelerationLimit
        if startupDemand then
            accelerationLimit=systemsStartupAcceleration(c,lag,state.sampleSeconds,s.lastAckWaitSeconds)
        else
            -- Preserve gentle normal HOLD corrections around the setpoint.
            -- Away from target, taper in measured-response authority in both
            -- directions. A distant ascent needs the same ability to leave
            -- hover as a distant descent; the gentle cap alone can settle at
            -- neutral support without producing the requested motion.
            local normalHoldAcceleration=maxVs/SYSTEMS_STARTUP_SPEED_RAMP_SECONDS
            accelerationLimit=normalHoldAcceleration
            local holdError=s.target-v.altitude
            local brakingClearance=math.max(3,hoverSpeed*responseSeconds)
            if self.verticalTarget~=0 then
                local direction=self.verticalTarget>0 and 1 or -1
                local responseAcceleration=maxVs/holdAccelerationHorizon
                local speed=math.abs(v.verticalSpeed)
                local stoppingRange=speed*holdAccelerationHorizon+
                    speed*speed/(2*math.max(responseAcceleration,0.01))
                local authorityRange=math.max(brakingClearance,stoppingRange,maxVs*responseSeconds,1)
                local altitudeAuthority=clamp((direction*holdError-brakingClearance)/authorityRange,0,1)
                local speedAuthority=direction<0 and clamp(-speedError/math.max(maxVs,0.01),0,1) or 0
                local authority=math.max(altitudeAuthority,speedAuthority)
                accelerationLimit=normalHoldAcceleration+
                    (responseAcceleration-normalHoldAcceleration)*authority
            end
        end
        local requestedAcceleration=speedError/math.max(horizon,0.5)
        if startupDemand and speedError<0 then
            -- Braking follows the measured actuator response, not the slower
            -- positive speed ramp. This matches the acceleration bound used
            -- by the stopping-distance governor while keeping deceleration
            -- proportional for small speed errors.
            local brakingHorizon=math.max(state.sampleSeconds or 0.5,
                finite(lag) and lag or 0.5)
            requestedAcceleration=speedError/brakingHorizon
        elseif startupDemand and not s.acquisitionMotionReadyAt and speedError>0 then
            -- A grounded vessel cannot earn its measured-motion proof when
            -- the speed-loop cap asks for less acceleration than unknown drag
            -- consumes. Use the bounded startup acceleration once to establish
            -- gentle motion; afterward the measured drag feed-forward and
            -- slower feedback horizon govern the ramp.
            requestedAcceleration=accelerationLimit
        end
        requestedAcceleration=clamp(requestedAcceleration,-accelerationLimit,accelerationLimit)
        s.lastRequestedAcceleration=requestedAcceleration
        local lowerEffort=math.min(0,requestedAcceleration)/gravity
        local upperEffort=math.max(0,requestedAcceleration)/gravity
        -- In HOLD, centre the acceleration band on the hover support the
        -- integral has learned, not on the model's 1.00. The model can be ~5%
        -- off at altitude; a band around 1.00 (with back-calculation) kept the
        -- integral from ever reaching the real hover point, so she could not
        -- descend (logged 2026-10-20: 30 blocks above target, -2 b/s asked).
        local learnedCentre=supportBaseline
        if not startupDemand then
            local g=self.inner.g
            local learned=finite(g.ki) and finite(self.inner.i) and g.ki*self.inner.i or 0
            learnedCentre=supportBaseline+clamp(learned,-(c.max_feed_fraction or 0.15),c.max_feed_fraction or 0.15)
        end
        desiredRatio=clamp(uncappedSupportRequest,
            clamp(learnedCentre+lowerEffort,minimumSupport,maximumSupport),
            clamp(learnedCentre+upperEffort,minimumSupport,maximumSupport))
        if (holdApproachActive or holdBraking) and v.verticalSpeed*speedError<0 and
            (uncappedSupportRequest-learnedCentre)*requestedAcceleration<=0 then
            -- Retain learned hover support. Only replace an integral that is
            -- opposing braking, using the existing gentle acceleration bound;
            -- the back-calculation below transfers it to that bounded effort.
            desiredRatio=clamp(learnedCentre+requestedAcceleration/gravity,minimumSupport,maximumSupport)
        end
        if math.abs(desiredRatio-uncappedSupportRequest)>1e-9 then
            local gains=self.inner.g
            if finite(gains.ki) and gains.ki>0 and finite(gains.kp) and finite(gains.kd) then
                local allowedEffort=desiredRatio-supportBaseline
                local limit=finite(gains.integral_limit) and math.max(0,gains.integral_limit) or 0
                local allowedIntegral=(allowedEffort-gains.kp*speedError-gains.kd*self.inner.d)/gains.ki
                self.inner.i=clamp(allowedIntegral,-limit,limit)
                effort=clamp(gains.kp*speedError+gains.ki*self.inner.i+gains.kd*self.inner.d,
                    -(c.max_feed_fraction or 0.15),c.max_feed_fraction or 0.15)
                self.effort=effort;self.feedLimited=true
            else self.inner.i=oldInnerI end
        end
    end
    -- A settled envelope can be numerically at neutral support while the
    -- extremely small startup speed-loop margin never produces actual motion.
    -- Require sustained quiet motion and output caught up to every bulk target
    -- before renewing bounded acceleration. Never boost a still-filling plant.
    local outputSettled=state.complete==true and state.outputsValid==true
    for _,q in ipairs(QUADS) do
        for name,provider in pairs(io.nodes[q].providers or {}) do
            if provider.controlRole=="bulk" then
                local target=s.currentTargets and s.currentTargets[q] and s.currentTargets[q][name]
                if not finite(target) or provider.gasOutputValid~=true or not finite(provider.gasOutput) or
                    math.abs(provider.gasOutput-target)>math.max(1,target*.0001) then outputSettled=false end
            end
        end
    end
    local quietShortfall=captureApproach and remainingTarget>SYSTEMS_TARGET_TOLERANCE_BLOCKS and
        self.verticalTarget>0 and math.abs(v.verticalSpeed)<=.02 and
        finite(state.verticalAccelerationRaw) and math.abs(state.verticalAccelerationRaw)<=.005 and
        outputSettled and state.supplyStep~=true
    s.acquisitionStallRecovery=false
    if quietShortfall then
        s.acquisitionStallSince=s.acquisitionStallSince or now
        local dwell=math.max(10,finite(lag) and lag or SYSTEMS_STARTUP_CONTROL_HORIZON_SECONDS)
        if now-s.acquisitionStallSince>=dwell then
            local acceleration=math.min(systemsStartupAcceleration(c,lag,state.sampleSeconds,s.lastAckWaitSeconds),
                hoverSpeed/responseSeconds)
            local recoveryDemand=clamp(actualRatio+acceleration/gravity,minimumSupport,maximumSupport)
            if recoveryDemand>desiredRatio then
                desiredRatio=recoveryDemand;s.acquisitionStallRecovery=true
                self.effort=desiredRatio-supportBaseline
            end
        end
    else s.acquisitionStallSince=nil end
    -- Climb stall recovery: lift estimates carry about 1% error, so a small
    -- commanded margin can leave the ship hovering far below its target.
    -- While well below target, commanded upward and not moving, raise the
    -- support request slowly until she climbs; release it once she does.
    local stallBoost=s.climbStallBoost or 0
    if startupDemand and remainingTarget>8 and self.verticalTarget>0 and finite(v.verticalSpeed) then
        if v.verticalSpeed<math.min(0.15,0.5*self.verticalTarget) and outputSettled and state.supplyStep~=true then
            -- Stalled or sinking while commanded up: the hover estimate is
            -- short. The measured shortfall at about Y 95 was ~0.6% of weight,
            -- so build the margin within seconds rather than minutes.
            s.climbStallSince=s.climbStallSince or now
            if now-s.climbStallSince>=4 then stallBoost=math.min(0.05,stallBoost+0.003*math.max(0,dt)) end
        elseif v.verticalSpeed>1.2*self.verticalTarget then
            -- Climbing faster than commanded: hand the margin back gradually.
            s.climbStallSince=nil
            stallBoost=math.max(0,stallBoost-0.002*math.max(0,dt))
        else
            -- Climbing slower than commanded. The support actually delivered
            -- trails the request by the ACK wait plus balloon fill (~0.6% of
            -- weight in logged climbs), as large as the whole startup
            -- acceleration budget, so she crept up at ~0.2 b/s with near-zero
            -- measured acceleration. Learn that shortfall: while measured
            -- acceleration stays below the requested acceleration, add the
            -- missing fraction of weight over an 8 s time constant.
            s.climbStallSince=nil
            local requested=s.lastRequestedAcceleration
            local measured=finite(state.verticalAcceleration) and state.verticalAcceleration or state.verticalAccelerationRaw
            if finite(requested) and requested>0 and finite(measured) and finite(gravity) and gravity>0 and
                outputSettled and state.supplyStep~=true and measured<requested then
                local missing=clamp((requested-measured)/gravity,0,0.01)
                stallBoost=math.min(0.05,stallBoost+missing/8*math.max(0,dt))
            end
        end
    elseif s.phase=="READY" and finite(v.verticalSpeed) and finite(remainingTarget) then
        -- HOLD support bias. HOLD may only request ~0.2% of weight beyond the
        -- estimated hover support, smaller than that estimate's own error, so
        -- she could sink (or rise) slowly away from the target while the
        -- controller believed it was holding. While more than a block off
        -- target and drifting slowly (not moving toward it), learn a slow offset in the
        -- target's direction; keep it once she holds (it is the estimate's
        -- error), and unlearn it the same way after an overshoot.
        s.climbStallSince=nil
        -- Near-target braking takes precedence over a historical drift boost.
        -- The allocator still limits actual ceiling travel; retaining this
        -- offset here can reverse the requested braking acceleration's sign.
        if (holdApproachActive or holdBraking) and v.verticalSpeed*speedError<0 and stallBoost*speedError<0 then
            stallBoost=0;s.holdDriftSince=nil
        end
        local towardTarget=remainingTarget>0 and v.verticalSpeed or -v.verticalSpeed
        if math.abs(remainingTarget)>1 and towardTarget<0.05 and math.abs(v.verticalSpeed)<0.15 then
            s.holdDriftSince=s.holdDriftSince or now
            if now-s.holdDriftSince>=20 then
                local direction=remainingTarget>0 and 1 or -1
                -- Five times faster once the progress watchdog has declared an
                -- altitude stall: whatever is holding her, lean on it.
                local rate=self.altitudeProgressStalled and 0.001 or 0.0002
                stallBoost=clamp(stallBoost+direction*rate*math.max(0,dt),-0.03,0.05)
            end
        else
            s.holdDriftSince=nil
        end
    else
        -- Near the target or outside the climb: fade any margin out smoothly.
        s.climbStallSince=nil;stallBoost=math.max(0,stallBoost-0.004*math.max(0,dt))
    end
    s.climbStallBoost=stallBoost
    if stallBoost~=0 then
        desiredRatio=clamp(desiredRatio+stallBoost,minimumSupport,maximumSupport)
        if math.abs(stallBoost)>0.002 then
            s.speedLimiter=s.phase=="READY" and "HOLD SUPPORT BIAS" or "CLIMB STALL BOOST"
        end
    end
    if innerLimited and ((effort>=c.max_feed_fraction and speedError>0) or
        (effort<=-c.max_feed_fraction and speedError<0)) then self.inner.i=oldInnerI end
    s.lastDesiredRatio=desiredRatio
    return desiredRatio
end
-- @ama-summary: Send the next pending chamber target and record its acknowledgement deadline.
function Flight:sendSystemsNext(io,now)
    local s=self.systemsRun;if not s then return false end
    if s.batchStage=="control" then s.lastTargetCommandAt=now end
    s.pending={}
    for _,q in ipairs(QUADS) do
        local targets=s.batchTargets[q]
        local commandStage=s.telemetryRecovery and s.recoveryStages and s.recoveryStages[q] or s.batchStage
        local ok,seq=io:sendSystemsCommand(q,targets,commandStage)
        if not ok then
            if s.telemetryRecovery then
                s.telemetryRecovery.sendFailure=q.." SYSTEMS SEND FAILED: "..tostring(seq)
                s.telemetryRecovery.lastRetryAt=now
                s.telemetryRecovery.hasAttempted=true
                s.telemetryRecovery.retryCount=(s.telemetryRecovery.retryCount or 0)+1
                s.pending[q]=nil
                return false
            end
            TelemetryRecovery.suspend(self,s,now,q.." SYSTEMS SEND FAILED: "..tostring(seq))
            return false
        end
        s.pending[q]={q=q,seq=seq,targets=targets,stage=commandStage,sentAt=now,boot=s.boots[q]}
    end
    if s.telemetryRecovery then
        s.telemetryRecovery.lastRetryAt=now
        s.telemetryRecovery.hasAttempted=true
        s.telemetryRecovery.retryCount=(s.telemetryRecovery.retryCount or 0)+1
        s.telemetryRecovery.sendFailure=nil
    end
    if s.balancedReason then
        s.reason=s.balancedReason
    elseif s.batchStage=="probe" then
        s.reason=s.phase=="VERIFYING" and "KEEPING PROBE BURNERS ACTIVE" or "ACTIVATING PROBE BURNERS"
    elseif s.phase=="CONTROL_START" then s.reason="ACTIVATING BULK VENTS"
    elseif s.phase=="READY" then s.reason=self.trimStatus and self.trimStatus.authorityLimited and
        "HOLDING ALTITUDE / TRIM AUTHORITY EXHAUSTED" or "HOLDING SELECTED ALTITUDE"
    else s.reason="BUILDING LIFT TO TARGET" end
    return true
end
-- @ama-summary: Stage a complete chamber target batch with its command stage and trim allocation.
function Flight:beginSystemsBatch(io,stage,maps,now,coarseTrimApplied)
    local s=self.systemsRun;if not s then return false end
    if not s.telemetryRecovery and stage=="control" and s.phase=="BUILDING_LIFT" and not s.responseProbe and not s.responseLagSeconds and
        systemsBulkCeilingSum(maps,io.nodes)>systemsBulkCeilingSum(s.currentTargets,io.nodes) then
        local dynamics=s.dynamics or {}
        s.responseProbe={excitation=true,at=now,actualRatio=dynamics.actualRatio or 0,
            quadrants=clone(dynamics.quadrants or {})}
    end
    s.batchStage=stage;s.batchTargets=copyMaps(maps);s.appliedMaps={}
    if stage=="control" then
        s.batchCoarseTrimApplied=clone(coarseTrimApplied~=nil and coarseTrimApplied or s.coarseTrimApplied or {})
    else s.batchCoarseTrimApplied=nil end
    return self:sendSystemsNext(io,now)
end
-- Never lower an active vent below the ceiling it held when START SYSTEMS
-- began (preflight records them). Floors from the takeoff seed or balance
-- caps must not take lift away from a vessel that is already flying.
-- @ama-summary: Retain observed bulk-vent targets while constructing a probe-stage recovery map.
local function retainActiveBulk(maps,retained)
    if type(maps)~="table" or type(retained)~="table" then return maps end
    for q,entries in pairs(retained) do
        for name,amount in pairs(entries) do
            if type(maps[q])=="table" and finite(maps[q][name]) and finite(amount) and amount>maps[q][name] then
                maps[q][name]=amount
            end
        end
    end
    return maps
end
-- Current balloon lift carrying at least 90% of the weight means the ship is
-- flying (or effectively floating): there is nothing to take off or build.
-- @ama-summary: Current balloon lift carrying at least 90% of the weight means the ship is flying (or effectively floating): there is nothing to take off or build.
function Flight:systemsAirborneAtStart(io)
    local v=io.vessel or {}
    local pressure=airPressure(v)
    if not pressure or not finite(v.mass) or v.mass<=0 then return false end
    local sum=0
    for _,q in ipairs(QUADS) do
        local balloon=io.nodes and io.nodes[q] and io.nodes[q].balloon
        if type(balloon)~="table" or balloon.liftValid~=true or not finite(balloon.lift) then return false end
        sum=sum+balloon.lift
    end
    local ratio=sum*pressure/v.mass
    return ratio>=0.9,ratio
end
-- Airborne START SYSTEMS adopts the exact ceilings the chambers hold now,
-- like a core restart restore: probe, re-arm control at those same maps,
-- then normal READY/HOLD control toward the selected altitude. No takeoff
-- seed, launch settle or lift build is run.
-- @ama-summary: Adopt verified existing lift into an airborne altitude-control run.
function Flight:startSystemsAirborne(io,now,prepared)
    local v=io.vessel
    local maps={}
    for _,q in ipairs(QUADS) do
        maps[q]={}
        for name,provider in pairs(io.nodes[q].providers or {}) do
            local amount=provider.targetAmount
            local limit=prepared.limits[q] and prepared.limits[q][name]
            if not limit or not finite(amount) then return false,q.." EXISTING GAS TARGET UNAVAILABLE" end
            if amount<limit.minimum then
                if provider.controlRole=="fine" and provider.signalStrength==0 then amount=0
                else return false,q.." EXISTING GAS TARGET BELOW CONTROL FLOOR" end
            end
            maps[q][name]=amount
        end
    end
    local s={phase="READY",providerRoles=prepared.roles,providerLimits=prepared.limits,boots=prepared.boots,
        bindingFingerprints=prepared.bindingFingerprints,bindingGenerations=prepared.bindingGenerations,
        acceptedBootGenerations=prepared.acceptedBootGenerations,nodeIDs=prepared.nodeIDs,
        coreID=prepared.coreID,coreSession=prepared.coreSession,uuid=prepared.uuid,fingerprint=prepared.fingerprint,
        target=prepared.target,targetReason=prepared.targetReason,
        currentTargets=copyMaps(maps),baseline=copyMaps(maps),appliedMaps=copyMaps(maps),
        coarseTrimApplied={},batchCoarseTrimApplied={},startAltitude=v.altitude,index=1,
        startedAt=now,phaseStartedAt=now,lastSystemsUpdateAt=now,lastControlAt=now,lastPidAt=now,
        lastTargetCommandAt=now,lastTargetAppliedAt=now,lastLiftProgressAt=now,lastAckWaitSeconds=0,
        acquisitionTimeout=86400,launchComplete=true,launchDurationSeconds=0,acquisitionPidActive=false,
        airborne=true,airborneStart=true}
    TelemetryRecovery.suspend(self,s,now,"AIRBORNE START: ADOPTING CURRENT LIFT")
    s.telemetryRecovery.targetMaps=copyMaps(maps)
    s.telemetryRecovery.coarseTrimApplied={}
    local good,reason=self:systemsGuard(io,now,s,true,true)
    if not good and not TelemetryRecovery.isTransientGuardFault(io,s,now,reason,self) then
        return false,reason
    end
    self.systemsRun=s;self.systemsLastOutcome=nil;self.systemsRetainedRun=nil
    self.enabled=true;self.available=false;self.target=s.target;self.baseline=copyMaps(maps)
    if self.controls then self.controls.targets.altitude=s.target end
    self:resetTrim();self:seedLevelBias()
    self.outer:reset(v.altitude);self.inner:reset(v.verticalSpeed)
    self:seedHoverOffset(v.altitude)
    self.verticalTarget=v.verticalSpeed;self.effort=0
    self.reason="AIRBORNE START: ADOPTING CURRENT LIFT"
    self.systemsSnapshot={active=true,available=false,phase="READY",pending=true,complete=false,
        target=s.target,reason=self.reason}
    return true,"AIRBORNE START: CURRENT LIFT ADOPTED; NO TAKEOFF OR BUILD"
end
-- @ama-summary: Validate startup and initialize its probe, target and retained-identity state.
function Flight:startSystems(io,now,prepared)
    if self.systemsRun then return false,"START SYSTEMS ALREADY ACTIVE" end
    local reason
    if not prepared then prepared,reason=self:systemsPreflight(io,now) end
    if not prepared then
        self.systemsAvailable=false;self.systemsBlockedReason=reason
        logOperationIssue(self,"flight","systems","START SYSTEMS FAILED: "..tostring(reason))
        return false,reason
    end
    self.coreLogIssues=self.coreLogIssues or {};self.coreLogIssues[issueScope("flight","systems")]=nil
    -- Already flying: skip takeoff and lift build entirely.
    local airborne=self:systemsAirborneAtStart(io)
    if airborne then return self:startSystemsAirborne(io,now,prepared) end
    local initialGasRequested=self.config.startup_gas_target_m3_per_chamber
    if not finite(initialGasRequested) or initialGasRequested<0 then initialGasRequested=0 end
    -- Airborne start: current balloon lift already carries the vessel. Then
    -- the takeoff seed, launch settle and lift build are skipped: control is
    -- taken over at the current ceilings and goes straight to READY.
    local airborneStart,airborneRatio=false,nil
    do
        local v=io.vessel or {}
        local pressure=airPressure(v)
        if next(prepared.retainedBulk or {})~=nil and pressure and finite(v.mass) and v.mass>0 then
            local liftSum,complete=0,true
            for _,q in ipairs(QUADS) do
                local balloon=io.nodes[q] and io.nodes[q].balloon
                if type(balloon)~="table" or balloon.liftValid~=true or not finite(balloon.lift) then complete=false;break end
                liftSum=liftSum+balloon.lift
            end
            if complete then
                airborneRatio=liftSum*pressure/v.mass
                airborneStart=airborneRatio>=0.9
            end
        end
    end
    if airborneStart then initialGasRequested=0 end
    local initialGasTarget={requestedM3PerChamber=initialGasRequested,unit="m3/chamber",
        targetBasis="sum of provider target ceilings; not measured gas volume",
        limited=false,seeded=false,status=airborneStart and "SKIPPED_AIRBORNE" or
            (initialGasRequested>0 and "WAITING_FOR_VERIFIED_CAPACITY" or "DISABLED")}
    self.initialAcquisitionEnded=false
    self.initialAcquisitionTarget=prepared.target
    self.systemsRun={phase="PROBING",launchDurationSeconds=self.config.launch_settle_seconds,
        probeTargets=prepared.probeTargets,controlStartTargets=prepared.controlTargets,
        retainedBulk=prepared.retainedBulk or {},airborneStart=airborneStart,airborneStartRatio=airborneRatio,
        initialGasTarget=initialGasTarget,seedBatchPendingAck=false,
        providerRoles=prepared.roles,
        providerLimits=prepared.limits,boots=prepared.boots,
        bindingFingerprints=prepared.bindingFingerprints,bindingGenerations=prepared.bindingGenerations,
        acceptedBootGenerations=prepared.acceptedBootGenerations,nodeIDs=prepared.nodeIDs,
        coreSession=prepared.coreSession,coreID=prepared.coreID,
        uuid=prepared.uuid,fingerprint=prepared.fingerprint,target=prepared.target,targetReason=prepared.targetReason,
        startedAt=now,phaseStartedAt=now,index=1,hoverSince=nil,lastControlAt=now,lastPidAt=now,
        coarseTrimApplied={},batchCoarseTrimApplied={},
        lastSystemsUpdateAt=now,lastTargetCommandAt=now,lastTargetAppliedAt=now,lastAckWaitSeconds=0,lastLiftRatio=nil,
        lastLiftProgressAt=now,startAltitude=io.vessel.altitude,
        acquisitionTimeout=math.min(86400,math.max(900,
            math.abs(prepared.target-io.vessel.altitude)/math.max(self.config.max_vertical_speed or 1,0.01)*4+300))}
    self.systemsLastOutcome=nil;self.enabled=true;self.available=false;self.hoverSince=nil
    self.target=prepared.target
    if self.controls then self.controls.targets.altitude=prepared.target end
    self.outer:reset(io.vessel.altitude);self.inner:reset(io.vessel.verticalSpeed)
    self:resetTrim();self.effort=0;self.verticalTarget=0
    self.reason="START SYSTEMS IN PROGRESS"
    self:beginSystemsBatch(io,"probe",prepared.probeTargets,now)
    if not self.systemsRun then return false,self.systemsSnapshot and self.systemsSnapshot.reason or "SYSTEMS START FAILED" end
    self.systemsRun.groundAltitude=io.vessel and finite(io.vessel.altitude) and io.vessel.altitude or nil
    self.systemsSnapshot={active=true,available=false,phase="PROBING",pending=true,complete=false,
        target=prepared.target,reason=airborneStart and "AIRBORNE START: TAKING OVER CURRENT LIFT" or "ACTIVATING PROBE BURNERS"}
    if airborneStart and os and type(os.__amaryllisLog)=="function" then
        pcall(os.__amaryllisLog,string.format("Core systems: airborne start, current lift %.2f of weight; takeoff and build skipped",
            airborneRatio),"core.systems")
    end
    return true,airborneStart and "AIRBORNE START: TAKING OVER CURRENT LIFT" or "START SYSTEMS SEQUENCE STARTED"
end
-- An explicit airborne recovery reuses verified retained gas, not the takeoff
-- seed. Validation is read-only and also supplies the bridge's availability.
-- @ama-section: Recovery | Physical target reconciliation and retained-run resumption.
-- @ama-summary: Record a terminal recovery guard result while retaining applied lift intent.
function Flight:abortRecoveryState(io,now)
    if self.systemsRun or self.shutdownJob or self.stopReview or self.emergencyLiftLatched or
        self.tuningRun or self.startupPending or self.maintenanceJob or
        (self.restart and (self.restart.job or self.restart.saved)) then
        return nil,"FINISH CURRENT SYSTEMS OPERATION FIRST"
    end
    if not self.systemsLastOutcome or self.systemsLastOutcome.phase~="ABORTED" or
        type(self.systemsRetainedRun)~="table" then return nil,"NO RETAINED ABORT TO RECOVER" end
    local s=clone(self.systemsRetainedRun)
    if s.phase~="READY" and s.phase~="BUILDING_LIFT" then return nil,"NO RETAINED AIRBORNE CONTROL STATE" end
    local assembled,why=Flight.assemblyGate(io,now)
    if not assembled then return nil,why or "VESSEL ASSEMBLY UNAVAILABLE" end
    if type(io.routeAllowed)=="function" then
        local allowed,reason=io:routeAllowed();if not allowed then return nil,reason end
    elseif io.identityReady==false then return nil,"CORE IDENTITY UNVERIFIED" end
    -- Validate a restarted chamber using the same trusted Hello, vessel and
    -- exact provider signature checks as live telemetry recovery. Only the
    -- cloned candidate is rebound; availability checks never change authority.
    local trustedRebinds={}
    for _,q in ipairs(QUADS) do
        local node=io.nodes and io.nodes[q]
        if node and node.boot~=s.boots[q] then
            local state,bootReason=TelemetryRecovery.nodeBootState(io,s,q,now,self)
            if state~="trusted" then return nil,q.." "..tostring(bootReason or "LIFT BOOT CHANGE NOT TRUSTED") end
            trustedRebinds[q]=true
            s.boots[q]=node.boot
            s.bindingGenerations=s.bindingGenerations or {}
            s.bindingGenerations[q]=node.bindingGeneration
            s.acceptedBootGenerations=s.acceptedBootGenerations or {}
            s.acceptedBootGenerations[q]=node.acceptedBootGeneration
        end
    end
    -- Normal flight guards remain in force, including current speed limits.
    -- A historical abort can be cleared only after its blocking cause clears.
    s.phase="READY"
    local valid,reason=self:systemsGuard(io,now,s,true,true)
    if not valid then return nil,reason end
    if not finite(s.target) or s.target<self.config.minimum_world_y or s.target>self.config.maximum_world_y then
        return nil,"RETAINED ALTITUDE TARGET OUT OF RANGE"
    end
    -- A command may have applied to only some providers before the
    -- abort. Recover core's retained intent, not an unexplained observed map.
    -- The guards above verify identity/bindings; this helper checks the exact
    -- provider allowlist and target bounds before recovery re-applies it.
    local maps,mapReason,coarse=TelemetryRecovery.authoritativeTargetMaps(s,io.nodes)
    if not maps then return nil,mapReason end
    s.currentTargets=copyMaps(maps);s.coarseTrimApplied=copyMaps(coarse)
    s.appliedMaps=copyMaps(maps);s.pending=nil;s.batchTargets=nil;s.batchStage=nil;s.batchCoarseTrimApplied={}
    s.telemetryRecovery=nil;s.launchComplete=true;s.launchDurationSeconds=0;s.airborne=true
    s.climbStallBoost=0;s.climbStallSince=nil;s.holdDriftSince=nil
    return s
end
-- @ama-summary: Reconstruct altitude control from retained target maps and fresh provider observations.
function Flight:recoverSystems(io,now)
    local s,reason=self:abortRecoveryState(io,now)
    if not s then return false,reason end
    s.recoveredAbortReason=self.systemsLastOutcome.reason
    self.systemsRun=s;self.systemsLastOutcome=nil;self.systemsRetainedRun=nil
    self.enabled=true;self.available=false;self.target=s.target
    if self.controls then self.controls.targets.altitude=s.target end
    self.outer:reset(io.vessel.altitude);self.inner:reset(io.vessel.verticalSpeed)
    self:seedHoverOffset(io.vessel.altitude)
    self.verticalTarget=io.vessel.verticalSpeed;self.effort=0
    -- The existing recovery coordinator renews activation/leases at these
    -- exact maps and waits for ACK/readback before normal PID writes resume.
    TelemetryRecovery.suspend(self,s,now,"AIRBORNE ABORT RECOVERY REQUESTED")
    return true,"RECOVERING RETAINED LIFT; NO TAKEOFF SEED"
end
-- @ama-section: Systems control | Startup, measured dynamics and bounded provider demand.
-- @ama-summary: Release the renewable systems lease and retain the applied provider ceilings.
function Flight:stopSystems(io,reason,now,abortDetails)
    local s=self.systemsRun
    if not s then return false,"NO ACTIVE SYSTEMS SEQUENCE" end
    self.systemsRetainedRun=clone(s)
    now=now or (io.nowSeconds and io:nowSeconds()) or 0
    -- Stop cancels the renewable command lease while retaining every provider
    -- ceiling already applied. Never restore output against stale hardware.
    for _,q in ipairs(QUADS) do
        local n=io.nodes and io.nodes[q]
        if n and n.boot==s.boots[q] and io.nodeFresh and io:nodeFresh(q,now) then
            pcall(io.sendSystemsStop,io,q)
        end
    end
    local outcome=reason or "STOPPED BY OPERATOR"
    local phase=outcome=="STOPPED BY OPERATOR" and "STOPPED" or "ABORTED"
    self.systemsRun=nil;self.enabled=false;self.available=false;self.pending=nil;self.hoverSince=nil
    self.reason=outcome
    local savedDetails=type(abortDetails)=="table" and clone(abortDetails) or nil
    self.systemsLastOutcome={phase=phase,target=s.target,reason=outcome,abortDetails=savedDetails,
        initialGasTarget=clone(s.initialGasTarget)}
    self.systemsSnapshot={active=false,available=false,phase=phase,pending=false,complete=false,
        target=s.target,reason=outcome,warning=s.warning,curve=s.curve,
        demandProgress=s.demandProgress,capacityProgress=s.capacityProgress,
        abortReason=phase=="ABORTED" and outcome or nil,abortDetails=savedDetails,
        initialGasTarget=clone(s.initialGasTarget)}
    if phase=="ABORTED" then
        logOperationIssue(self,"flight","systems",outcome,systemsAbortText(savedDetails))
    end
    return true,outcome
end
-- @ama-summary: Update altitude and attitude PID measurements after target acknowledgement.
function Flight:observeSystemsPidAfterAck(io,s,now)
    local elapsed=now-(s.lastPidAt or now)
    observePidMeasurement(self.outer,io.vessel.altitude,elapsed)
    observePidMeasurement(self.inner,io.vessel.verticalSpeed,elapsed)
    local y={}
    for _,q in ipairs(QUADS) do
        y[q]=io.nodes[q].altitude and io.nodes[q].altitude.sensorWorldY
        if not finite(y[q]) then s.lastPidAt=now;return end
    end
    local roll=(y.FL+y.RL-y.FR-y.RR)/4
    local measuredPitch=(y.FL+y.FR-y.RL-y.RR)/4
    local config=self.config
    if math.abs(roll)<config.trim_deadband_blocks then roll=0 end
    local manualBias=finite(config.manual_fore_aft_trim_blocks) and
        clamp(config.manual_fore_aft_trim_blocks,MANUAL_TRIM_MIN,MANUAL_TRIM_MAX) or 0
    local pitchTarget=manualBias/2
    local pitchControlMeasurement=measuredPitch
    local pitchDeadband=config.trim_deadband_blocks
    if manualBias~=0 then pitchDeadband=math.min(pitchDeadband,math.abs(pitchTarget)*0.5) end
    if math.abs(pitchTarget-measuredPitch)<pitchDeadband then pitchControlMeasurement=pitchTarget end
    observePidMeasurement(self.rollTrim,roll,elapsed)
    observePidMeasurement(self.pitchTrim,pitchControlMeasurement,elapsed)
    s.lastPidAt=now
end
-- @ama-section: Recovery | Physical target reconciliation and retained-run resumption.
-- @ama-summary: Classify the chambers' current probe/control lease stages.
local function recoveryStageMode(io)
    local mode=nil
    for _,q in ipairs(QUADS) do
        local node=io.nodes and io.nodes[q]
        local current
        if node and node.systemsStage=="control" and node.systemsProbeReady==true then current="control"
        elseif node and node.systemsStage=="probe" and node.systemsProbeReady==true then current="probe"
        elseif node and node.systemsStage==nil and node.systemsProbeReady~=true then current="expired"
        else current="transition" end
        if mode==nil then mode=current elseif mode~=current then return "mixed" end
    end
    return mode or "mixed"
end
-- @ama-summary: Construct probe recovery maps from the retained chamber targets.
local function recoveryProbeMaps(io,maps)
    local result=copyMaps(maps)
    for _,q in ipairs(QUADS) do
        for name,provider in pairs(io.nodes[q].providers or {}) do
            if provider.controlRole=="bulk" then
                -- Probe renews telemetry without changing existing steam.
                -- Core's authoritative map is restored by the control stage.
                result[q][name]=provider.targetAmount
            elseif provider.controlRole=="fine" and result[q][name]==0 then
                result[q][name]=provider.minimumNonzeroTarget or 5
            end
        end
    end
    return result
end
-- @ama-summary: Reconcile physical targets, renew authority and resume the retained systems run.
function Flight:updateSystemsRecovery(io,now,s)
    local recovery=s.telemetryRecovery
    local function wait(reason,pending)
        TelemetryRecovery.suspend(self,s,now,reason)
        logSystemsTelemetryRecovery(self,recovery.failed and
            ("RECOVERY FAILED AFTER 120 SECONDS: "..tostring(reason).."; CONTINUING RETRIES") or reason,false)
        self.systemsSnapshot.pending=pending==true
        return false
    end
    local assembled,assemblyReason,assembly=Flight.assemblyGate(io,now)
    if not assembled then
        if assembly and assembly.state=="DISASSEMBLED" then
            self:stopSystems(io,assemblyReason or "VESSEL DISASSEMBLED",now);return false
        end
        self.assembly=assembly
        return wait(assemblyReason or "ASSEMBLY STATE UNKNOWN",s.pending~=nil)
    end
    local mode=recoveryStageMode(io)
    local allowInactive=true -- Recovery reapplies activation as well as ceilings.
    local good,fault,abortDetails=self:systemsGuard(io,now,s,allowInactive,true)
    if not good then
        if TelemetryRecovery.isTransientGuardFault(io,s,now,fault,self) then
            return wait(fault,s.pending~=nil)
        end
        self:stopSystems(io,fault,now,abortDetails);return false
    end
    for _,q in ipairs(QUADS) do
        local node=io.nodes[q]
        if node.systemsSupported~=true then
            self:stopSystems(io,q.." SYSTEMS CAPABILITY CHANGED",now);return false
        end
        if node.systemsStartReady~=true then
            return wait(q.." WAITING FOR START SYSTEMS HARDWARE READINESS",s.pending~=nil)
        end
    end

    -- @ama-summary: Complete the active recovery stage using verified physical target maps.
    local function finishActive(actualMaps,actualCoarse)
        local priorPhase=recovery.resumePhase or s.phase
        TelemetryRecovery.complete(self,io,s,now,actualMaps,actualCoarse)
        logSystemsTelemetryRecovery(self,nil,true)
        if priorPhase=="CONTROL_START" and s.initialGasTarget and s.initialGasTarget.waitingForCapacity and
            not s.seedBatchPendingAck then
            local gasInfo=s.initialGasTarget
            gasInfo.bootstrapAppliedM3PerChamberByQuadrant=systemsProviderTargetTotals(io,s.currentTargets)
            gasInfo.controlMapPendingAck=false
            s.phase="VERIFYING";s.phaseStartedAt=now
            s.acquisitionPidActive=false;s.lastPidAt=now;s.lastTargetCommandAt=now;s.lastTargetAppliedAt=now
        elseif priorPhase=="CONTROL_START" then
            local gasInfo=s.initialGasTarget
            if gasInfo then
                local actual=systemsProviderTargetTotals(io,s.currentTargets)
                if actual then gasInfo.appliedM3PerChamberByQuadrant=actual end
                local seedWasIssued=s.seedBatchPendingAck==true
                local fullyApplied=gasInfo.requestedM3PerChamber<=0 or seedWasIssued
                local planned=gasInfo.plannedM3PerChamberByQuadrant
                if planned and actual and fullyApplied then
                    fullyApplied=true
                    for _,q in ipairs(QUADS) do
                        if planned[q]~=actual[q] then fullyApplied=false;break end
                    end
                end
                gasInfo.seeded=fullyApplied and gasInfo.requestedM3PerChamber>0
                gasInfo.waitingForCapacity=false;gasInfo.controlMapPendingAck=false
                if gasInfo.requestedM3PerChamber>0 and not seedWasIssued then
                    gasInfo.status="RECOVERED_LIMITED_NO_SEED"
                elseif gasInfo.requestedM3PerChamber>0 then
                    gasInfo.status=fullyApplied and (gasInfo.limited and "RECOVERED_APPLIED_LIMITED" or "RECOVERED_APPLIED") or
                        "RECOVERED_WITH_RETAINED_MAP"
                    if not fullyApplied then gasInfo.reason="TELEMETRY RECOVERY RETAINED THE VERIFIED PARTIAL STARTUP MAP; SEED WAS NOT REAPPLIED" end
                end
            end
            s.seedBatchPendingAck=false
            s.phase="BUILDING_LIFT";s.phaseStartedAt=now
            if not s.launchStartedAt and (s.launchDurationSeconds or 0)>0 then s.launchStartedAt=now end
            s.baseline=copyMaps(s.currentTargets);self.baseline=copyMaps(s.currentTargets)
            self.outer:reset(io.vessel.altitude);self.inner:reset(io.vessel.verticalSpeed)
            self:resetTrim();self:seedLevelBias();self.effort=0;self.verticalTarget=0
            s.acquisitionPidActive=false;s.lastPidAt=now;s.lastTargetCommandAt=now;s.lastTargetAppliedAt=now
            s.lastLiftProgressAt=now;s.lastLiftRatio=nil
        elseif priorPhase=="PROBING" then
            s.phase="VERIFYING";s.phaseStartedAt=now;s.reason="WAITING FOR PROBE BALLOON DATA"
            s.renewAt=now+SYSTEMS_PROBE_RENEW_SECONDS;s.renewing=false
        end
        s.reason="LIFT TELEMETRY RESTORED; RESUMING "..tostring(s.phase)
        self.reason=s.reason;self.enabled=true;self.available=false
        self.systemsSnapshot={active=true,available=false,phase=s.phase,pending=false,
            complete=s.phase=="READY",target=s.target,reason=s.reason,warning=s.warning,
            curve=s.curve,demandProgress=s.demandProgress,capacityProgress=s.capacityProgress}
        return true
    end
    -- @ama-summary: Compare a chamber's physical provider readback with the retained target map.
    local function verifyMap(node,q,expected)
        local actual,reason=TelemetryRecovery.readTargetMap(node,expected,s.providerRoles[q])
        if not actual then return false,q.." "..tostring(reason) end
        if not TelemetryRecovery.mapsEqual(actual,expected) then
            return false,q.." PROVIDER CEILING CHANGED DURING TELEMETRY RECOVERY"
        end
        return true
    end
    -- @ama-summary: Check recovery acknowledgements and readbacks for the active command stage.
    local function verifyCommand(stage)
        local all=true
        local leaseExpired=false
        for _,q in ipairs(QUADS) do
            local pending=s.pending and s.pending[q]
            local node=io.nodes[q]
            -- The local sender can reject control before assigning a pending
            -- sequence when the node's probe lease has expired. Detect that
            -- live state independently of ACKs, or retries remain stuck on
            -- control forever. Identity and hardware guards run above; the
            -- lease-expired branch reconciles retained maps before probing.
            if node.systemsStage==nil and node.systemsProbeReady~=true and
                (stage=="control" or (pending and now-pending.sentAt>=SYSTEMS_ACK_TIMEOUT_SECONDS)) then
                all=false;leaseExpired=true
            end
            if not pending then all=false
            elseif node.lastAppliedSeq==pending.seq then
                if not io:commandWasApplied(q,pending.seq,pending.targets) then
                    recovery.sendFailure=q.." RECOVERY TARGET READBACK MISMATCH"
                    return false,"retry"
                end
                local expectedStage=pending.stage or stage
                if node.systemsStage~=expectedStage or node.systemsProbeReady~=true then
                    -- A node can keep the pending sequence and exact target
                    -- readback after its renewable lease expires. That is a
                    -- lease lapse, not evidence that the accepted command was
                    -- rejected or altered; rearm the retained map below.
                    if node.systemsStage==nil and node.systemsProbeReady~=true then
                        all=false;leaseExpired=true
                    else
                        recovery.sendFailure=q.." RECOVERY STAGE READBACK MISMATCH"
                        return false,"retry"
                    end
                end
                if expectedStage=="probe" and not leaseExpired then
                    for name,provider in pairs(node.providers or {}) do
                        if provider.controlRole=="fine" and provider.signalStrength~=15 then
                            recovery.sendFailure=q.." RECOVERY PROBE ACTIVATION MISMATCH"
                            return false,"retry"
                        end
                    end
                end
            else
                all=false
                if node.lastReceivedSeq==pending.seq then
                    for _,nodeFault in ipairs(node.faults or {}) do
                        if type(nodeFault)=="string" and stage=="control" and
                            nodeFault:find("SYSTEMS_PROBE_REQUIRED",1,true) then
                            -- The node's probe lease lapsed before control
                            -- arrived. Resending control can never succeed;
                            -- re-probe (keeping retained outputs), then restore.
                            leaseExpired=true
                        elseif type(nodeFault)=="string" and nodeFault:match("^SYSTEMS") then
                            recovery.sendFailure=q.." "..nodeFault
                            return false,"retry"
                        end
                    end
                end
            end
        end
        if leaseExpired then return false,"lease-expired" end
        return all
    end
    -- @ama-summary: Stage the next verified probe/control recovery batch.
    local function sendRecoveryBatch(stage,maps,coarse)
        s.recoveryStages=nil
        if stage=="probe" then
            maps=recoveryProbeMaps(io,maps)
            s.recoveryStages={}
            for _,q in ipairs(QUADS) do
                local node=io.nodes[q]
                -- A valid control owner cannot accept a probe. Keep its exact
                -- observed map and renew control while expired peers re-probe.
                if node.systemsStage=="control" and node.systemsProbeReady==true then
                    local actual,reason=TelemetryRecovery.readTargetMap(node,
                        recovery.targetMaps and recovery.targetMaps[q],s.providerRoles[q])
                    if not actual then return wait(q.." "..tostring(reason),false) end
                    maps[q]=actual;s.recoveryStages[q]="control"
                end
            end
            recovery.probeTargets=copyMaps(maps)
        end
        recovery.commandStage=stage
        recovery.lastRetryAt=now
        recovery.hasAttempted=true
        recovery.attemptCount=(recovery.attemptCount or 0)+1
        self:beginSystemsBatch(io,stage,maps,now,stage=="control" and coarse or nil)
        if not self.systemsRun then return false end
        return wait(recovery.mismatchReason or (stage=="probe" and
            "REVALIDATING LIFT PROBE; RETAINING APPLIED OUTPUTS" or
            "REAPPLYING CORE LIFT TARGETS AND CONTROL LEASE"),true)
    end

    -- Rebinding starts a new node command sequence, so the old boot's ACK is
    -- never used to complete a pending batch. Verify the exact live provider
    -- signature first, reconcile the physical maps, then renew a probe lease
    -- under the newly accepted boot before restoring the retained control map.
    local trustedRebinds={}
    for _,q in ipairs(QUADS) do
        if io.nodes[q].boot~=s.boots[q] then
            local state,reason=TelemetryRecovery.nodeBootState(io,s,q,now,self)
            if state=="wait" then return wait(q.." "..tostring(reason),s.pending~=nil) end
            if state~="trusted" then
                self:stopSystems(io,reason or q.." LIFT BOOT CHANGE NOT TRUSTED",now)
                return false
            end
            trustedRebinds[q]=true
        end
    end
    if next(trustedRebinds) then
        if recovery.hasAttempted and recovery.lastRetryAt and
            now-recovery.lastRetryAt<SYSTEMS_RECOVERY_RETRY_SECONDS then
            return wait("WAITING TO RECONCILE THE REBOUND LIFT NODE",s.pending~=nil)
        end
        local actualMaps,mapReason,actualCoarse=TelemetryRecovery.authoritativeTargetMaps(s,io.nodes)
        if not actualMaps then
            if mapReason and (mapReason:find("READBACK UNAVAILABLE",1,true) or
                mapReason:find("READBACK INVALID",1,true)) then return wait(mapReason,s.pending~=nil) end
            self:stopSystems(io,mapReason or "RETAINED SYSTEMS MAP COULD NOT BE VERIFIED",now)
            return false
        end
        if not recovery.targetMaps then recovery.targetMaps=copyMaps(actualMaps) end
        recovery.currentMaps=copyMaps(actualMaps)
        recovery.coarseTrimApplied=copyMaps(actualCoarse or s.coarseTrimApplied or {})
        recovery.probeTargets=recoveryProbeMaps(io,actualMaps)
        s.currentTargets=copyMaps(actualMaps);s.appliedMaps=copyMaps(actualMaps)
        s.coarseTrimApplied=copyMaps(recovery.coarseTrimApplied)
        s.pending=nil;s.batchTargets=nil;s.batchStage=nil;s.batchCoarseTrimApplied={}
        for q in pairs(trustedRebinds) do
            local node=io.nodes[q]
            s.boots[q]=node.boot
            s.bindingFingerprints[q]=node.bindingFingerprint
            s.bindingGenerations=s.bindingGenerations or {};s.bindingGenerations[q]=node.bindingGeneration
            s.acceptedBootGenerations=s.acceptedBootGenerations or {}
            s.acceptedBootGenerations[q]=node.acceptedBootGeneration
        end
        recovery.commandStage=nil
        return sendRecoveryBatch("probe",recovery.probeTargets,recovery.coarseTrimApplied)
    end

    if recovery.commandStage then
        local stage=recovery.commandStage
        local applied,terminal=verifyCommand(stage)
        if terminal=="terminal" or self.systemsRun~=s then return false end
        if terminal=="lease-expired" then
            if recovery.lastRetryAt and now-recovery.lastRetryAt<SYSTEMS_RECOVERY_RETRY_SECONDS then
                return wait("LIFT CONTROL LEASE EXPIRED; REARMING RETAINED OUTPUTS",true)
            end
            local actualMaps,mapReason,actualCoarse=TelemetryRecovery.authoritativeTargetMaps(s,io.nodes)
            if not actualMaps then
                if mapReason and mapReason:find("READBACK UNAVAILABLE",1,true) then
                    return wait(mapReason,true)
                end
                self:stopSystems(io,mapReason or "RETAINED SYSTEMS MAP COULD NOT BE VERIFIED",now);return false
            end
            -- Preserve the desired control map and reconcile every live
            -- quadrant, including any already-applied part of a pending
            -- batch. The probe refreshes expired leases before restoring it.
            recovery.currentMaps=copyMaps(actualMaps)
            recovery.coarseTrimApplied=copyMaps(actualCoarse or s.coarseTrimApplied or {})
            recovery.probeTargets=recoveryProbeMaps(io,actualMaps)
            s.currentTargets=copyMaps(actualMaps);s.appliedMaps=copyMaps(actualMaps)
            s.coarseTrimApplied=copyMaps(recovery.coarseTrimApplied)
            s.pending=nil;s.batchTargets=nil;s.batchStage=nil;s.batchCoarseTrimApplied={}
            recovery.commandStage=nil
            return sendRecoveryBatch("probe",recovery.probeTargets,recovery.coarseTrimApplied)
        end
        if not applied then
            local timedOut=false
            for _,q in ipairs(QUADS) do
                local pending=s.pending and s.pending[q]
                if not pending or now-pending.sentAt>=SYSTEMS_ACK_TIMEOUT_SECONDS then timedOut=true end
            end
            if timedOut and (not recovery.lastRetryAt or now-recovery.lastRetryAt>=SYSTEMS_RECOVERY_RETRY_SECONDS) then
                return sendRecoveryBatch(stage,s.batchTargets,recovery.coarseTrimApplied)
            end
            return wait(recovery.sendFailure or "WAITING FOR FRESH LIFT RECOVERY ACKNOWLEDGEMENTS",true)
        end
        if stage=="probe" then
            local probeMaps=recovery.probeTargets
            for _,q in ipairs(QUADS) do
                local ok,why=verifyMap(io.nodes[q],q,probeMaps[q])
                if not ok then self:stopSystems(io,why,now);return false end
            end
            local envelope,envelopeReason=self:systemsEnvelopeReady(io,false,false,true)
            if not envelope then
                if TelemetryRecovery.isTransientGuardFault(io,s,now,envelopeReason,self) then
                    return wait(envelopeReason,true)
                end
                self:stopSystems(io,envelopeReason or "RECOVERY PROBE ENVELOPE INVALID",now);return false
            end
            local resumePhase=recovery.resumePhase or s.phase
            if resumePhase=="PROBING" or resumePhase=="VERIFYING" then
                local actualMaps=recovery.targetMaps or s.probeTargets
                local coarse=recovery.coarseTrimApplied or s.coarseTrimApplied or {}
                return finishActive(actualMaps,coarse)
            end
            return sendRecoveryBatch("control",recovery.targetMaps,recovery.coarseTrimApplied)
        end
        local strict,strictReason=self:systemsGuard(io,now,s,false,true)
        if not strict then
            if TelemetryRecovery.isTransientGuardFault(io,s,now,strictReason,self) then
                return wait(strictReason,true)
            end
            self:stopSystems(io,strictReason,now);return false
        end
        for _,q in ipairs(QUADS) do
            local ok,why=verifyMap(io.nodes[q],q,recovery.targetMaps[q])
            if not ok then self:stopSystems(io,why,now);return false end
        end
        return finishActive(recovery.targetMaps,recovery.coarseTrimApplied)
    end

    local actualMaps,mapReason,actualCoarse,mismatch,mismatchReason=TelemetryRecovery.authoritativeTargetMaps(s,io.nodes)
    if not actualMaps then
        if mapReason and mapReason:find("READBACK UNAVAILABLE",1,true) then return wait(mapReason,s.pending~=nil) end
        self:stopSystems(io,mapReason or "RETAINED SYSTEMS MAP COULD NOT BE VERIFIED",now);return false
    end
    recovery.targetMaps=copyMaps(actualMaps)
    recovery.mismatchReason=mismatchReason
    recovery.coarseTrimApplied=copyMaps(actualCoarse or s.coarseTrimApplied or {})
    s.currentTargets=copyMaps(actualMaps);s.coarseTrimApplied=copyMaps(recovery.coarseTrimApplied)
    s.pending=nil;s.batchTargets=nil;s.batchStage=nil;s.batchCoarseTrimApplied={};s.appliedMaps=copyMaps(actualMaps)

    if mode=="control" then
        if mismatch then
            return sendRecoveryBatch("control",actualMaps,actualCoarse)
        end
        return finishActive(actualMaps,actualCoarse)
    elseif mode=="probe" then
        if s.phase=="PROBING" or s.phase=="VERIFYING" then
            return finishActive(actualMaps,actualCoarse)
        end
        local envelope,envelopeReason=self:systemsEnvelopeReady(io,false,false,true)
        if not envelope then
            if TelemetryRecovery.isTransientGuardFault(io,s,now,envelopeReason,self) then return wait(envelopeReason,false) end
            self:stopSystems(io,envelopeReason or "RECOVERY PROBE ENVELOPE INVALID",now);return false
        end
        return sendRecoveryBatch("control",actualMaps,actualCoarse)
    elseif mode=="expired" or mode=="mixed" then
        local probeMaps=recoveryProbeMaps(io,actualMaps)
        recovery.probeTargets=copyMaps(probeMaps)
        return sendRecoveryBatch("probe",probeMaps,actualCoarse)
    end
    return wait("WAITING FOR ALL LIFT NODES TO REACH A CONSISTENT LEASE STATE",false)
end
-- @ama-section: Systems control | Startup, measured dynamics and bounded provider demand.
-- @ama-summary: Measure stable hover duration near the selected altitude and report capture readiness.
function Flight:systemsCaptureReady(s,v,now,supportSettled,actualRatio)
    local liftReady=supportSettled and math.abs(actualRatio-1)<=self.config.lift_balance_tolerance_fraction
    local distance=math.abs(s.target-v.altitude)
    local normal=liftReady and distance<=5 and math.abs(v.verticalSpeed)<=self.config.hover_max_vertical_speed
    local wide=liftReady and distance<=10 and v.verticalSpeed>-.5 and v.verticalSpeed<.5
    if normal then s.hoverSince=s.hoverSince or now else s.hoverSince=nil end
    if wide then s.wideHoverSince=s.wideHoverSince or now else s.wideHoverSince=nil end
    if normal or wide then s.reason="CAPTURING STABLE HOVER" end
    return (s.hoverSince~=nil and now-s.hoverSince>=self.config.hover_capture_seconds) or
        (s.wideHoverSince~=nil and now-s.wideHoverSince>10)
end
-- @ama-summary: Advance startup, acquisition, recovery and altitude-hold target batches.
function Flight:updateSystems(io,now)
    local s=self.systemsRun
    if not s then
        local prepared,reason=self:systemsPreflight(io,now)
        self.systemsAvailable=prepared~=nil;self.systemsBlockedReason=reason
        local previous=self.systemsLastOutcome
        self.systemsSnapshot={active=false,available=self.systemsAvailable==true,
            phase=previous and previous.phase or (self.systemsAvailable and "READY" or "IDLE"),pending=false,
            complete=false,target=previous and previous.target or nil,
            reason=reason or (previous and previous.reason or nil),
            abortReason=previous and previous.phase=="ABORTED" and previous.reason or nil,
            abortDetails=previous and previous.abortDetails or nil}
        return
    end
    if s.telemetryRecovery then
        self:updateSystemsRecovery(io,now,s)
        return
    end
    local good,fault,abortDetails=self:systemsGuard(io,now,s)
    if not good then
        if TelemetryRecovery.isTransientGuardFault(io,s,now,fault,self) then
            TelemetryRecovery.suspend(self,s,now,fault)
            self:updateSystemsRecovery(io,now,s)
        else self:stopSystems(io,fault,now,abortDetails) end
        return
    end
    local previousUpdateAt=s.lastSystemsUpdateAt
    if finite(previousUpdateAt) and now-previousUpdateAt>SYSTEMS_SAMPLE_GAP_SECONDS then
        local pending=s.pending and s.pending[QUADS[1]]
        local pendingAckSeconds=pending and finite(pending.sentAt) and now-pending.sentAt or nil
        -- Scheduling gaps suspend integration and retain lift; recovery must
        -- revalidate live identity, providers, targets and ACKs before resuming.
        TelemetryRecovery.suspend(self,s,now,"SYSTEMS RUNTIME SAMPLE GAP")
        s.telemetryRecovery.sampleGapDetails={phase=s.phase,lastUpdateAt=previousUpdateAt,
            elapsedSeconds=now-previousUpdateAt,sampleGapLimitSeconds=SYSTEMS_SAMPLE_GAP_SECONDS,
            pendingAckSeconds=pendingAckSeconds}
        return
    elseif finite(previousUpdateAt) and now<previousUpdateAt then
        self:stopSystems(io,"SYSTEMS RUNTIME CLOCK MOVED BACKWARD",now,{phase=s.phase,
            lastUpdateAt=previousUpdateAt,elapsedSeconds=now-previousUpdateAt,
            sampleGapLimitSeconds=SYSTEMS_SAMPLE_GAP_SECONDS})
        return
    end
    s.lastSystemsUpdateAt=now
    -- A fresh node may have lost its renewable lease before the command's
    -- rejection arrives. Re-probe using the retained run instead of waiting
    -- for a matching rejected sequence or letting an ACK timeout abort it.
    if s.batchStage=="control" or s.phase=="READY" or s.phase=="BUILDING_LIFT" then
        for _,q in ipairs(QUADS) do
            local node=io.nodes[q]
            if node.systemsStage==nil and node.systemsProbeReady~=true then
                TelemetryRecovery.suspend(self,s,now,q.." LIFT CONTROL LEASE LOST")
                self:updateSystemsRecovery(io,now,s);return
            end
        end
    end
    self:observeSystemsDynamics(io,s,now)
    s.warning=systemsWarning(io,s)
    self.reason=s.reason or self.reason
    if (s.phase=="BUILDING_LIFT" or s.phase=="READY") and self.controls and
        finite(self.controls.targets.altitude) and self.controls.targets.altitude>=self.config.minimum_world_y and
        self.controls.targets.altitude<=self.config.maximum_world_y then
        -- START SYSTEMS seeds this target from the selected cockpit value.
        -- Later valid cockpit edits remain live even while an ACK is pending.
        if s.target~=self.controls.targets.altitude then s.supportCorrectionRemainders={} end
        s.target=self.controls.targets.altitude
    end
    local balanced,balancedReason=self:balancedLiftModel(io,s.target,now)
    self.balancedLift=balanced;s.balancedLift=balanced
    if balanced.phase=="UNAVAILABLE" or balanced.phase=="INFEASIBLE" then
        s.balancedReason=balancedReason or balanced.reason or "BALANCED LIFT CAPACITY UNAVAILABLE"
    elseif balanced.targetUnreachable then
        s.balancedReason=balanced.reason
    else
        s.balancedReason=nil
    end
    if s.pending then
        local allApplied=true
        for _,q in ipairs(QUADS) do
            local pending=s.pending[q]
            local node=io.nodes[q]
            -- A fresh response for this sequence can explicitly reject the
            -- command. Surface that reason instead of waiting for an ACK that
            -- will never arrive. Historical faults cannot reject a new packet.
            if node.lastReceivedSeq==pending.seq and node.lastAppliedSeq~=pending.seq then
                for _,fault in ipairs(node.faults or {}) do
                    if type(fault)=="string" and fault:match("^SYSTEMS") then
                        TelemetryRecovery.suspend(self,s,now,q.." "..fault)
                        self:updateSystemsRecovery(io,now,s);return
                    end
                end
            end
            if io:commandWasApplied(q,pending.seq,pending.targets) then
                s.appliedMaps[q]=clone(pending.targets)
            else
                allApplied=false
                if now-pending.sentAt>SYSTEMS_ACK_TIMEOUT_SECONDS then
                    TelemetryRecovery.suspend(self,s,now,q.." SYSTEMS COMMAND ACK TIMEOUT")
                    self:updateSystemsRecovery(io,now,s);return
                end
            end
        end
        if not allApplied then
            self.systemsSnapshot={active=true,available=false,phase=s.phase,pending=true,complete=false,
                target=s.target,reason=s.reason,warning=s.warning,curve=s.curve,
                demandProgress=s.demandProgress,capacityProgress=s.capacityProgress,
                desiredLiftRatio=s.lastDesiredRatio}
            return
        end
        local stage=s.batchStage
        if stage=="control" then
            local ackWait=0
            for _,q in ipairs(QUADS) do
                local pending=s.pending[q]
                if pending and finite(pending.sentAt) then ackWait=math.max(ackWait,now-pending.sentAt) end
            end
            s.lastAckWaitSeconds=ackWait
        end
        s.pending=nil
        if stage=="control" and (s.phase=="BUILDING_LIFT" or s.phase=="READY") then
            self:observeSystemsPidAfterAck(io,s,now)
        end
        if stage=="probe" then
            if s.phase=="PROBING" then
                s.phase="VERIFYING";s.phaseStartedAt=now;s.reason="WAITING FOR PROBE BALLOON DATA"
                s.renewAt=now+SYSTEMS_PROBE_RENEW_SECONDS;s.renewing=false
            else
                s.renewing=false;s.renewAt=now+SYSTEMS_PROBE_RENEW_SECONDS
            end
            return
        end
        local controlTargetsChanged=stage=="control" and
            systemsBulkTargetsChanged(s.batchTargets,s.currentTargets,io.nodes)
        s.currentTargets=copyMaps(s.batchTargets);s.lastControlAt=now
        if stage=="control" then s.coarseTrimApplied=clone(s.batchCoarseTrimApplied or {}) end
        if controlTargetsChanged then s.lastTargetAppliedAt=now end
        if s.phase=="CONTROL_START" then
            local gasInfo=s.initialGasTarget
            if gasInfo and gasInfo.waitingForCapacity and not s.seedBatchPendingAck then
                gasInfo.bootstrapAppliedM3PerChamberByQuadrant=systemsProviderTargetTotals(io,s.currentTargets)
                gasInfo.status="WAITING_FOR_VERIFIED_CAPACITY"
                gasInfo.controlMapPendingAck=false
                s.phase="VERIFYING";s.phaseStartedAt=now;s.reason="WAITING FOR VERIFIED BALANCED CAPACITY FOR INITIAL GAS TARGET"
                s.acquisitionPidActive=false;s.lastPidAt=now;s.lastTargetCommandAt=now;s.lastTargetAppliedAt=now
                self.systemsSnapshot={active=true,available=false,phase=s.phase,pending=false,complete=false,
                    target=s.target,reason=s.reason,initialGasTarget=clone(gasInfo)}
                return
            end
            if gasInfo then
                local actualTotals,actualReason=systemsProviderTargetTotals(io,s.currentTargets)
                if actualTotals then gasInfo.appliedM3PerChamberByQuadrant=actualTotals end
                gasInfo.controlMapPendingAck=false;gasInfo.waitingForCapacity=false
                if gasInfo.requestedM3PerChamber>0 and s.seedBatchPendingAck then
                    gasInfo.seeded=true
                    gasInfo.status=gasInfo.limited and "APPLIED_LIMITED" or "APPLIED"
                elseif gasInfo.requestedM3PerChamber>0 then
                    gasInfo.seeded=false;gasInfo.status="LIMITED_NOT_APPLIED"
                    gasInfo.reason=gasInfo.limitReason or actualReason or "INITIAL GAS TARGET WAS NOT APPLIED"
                    gasInfo.limited=true
                else
                    gasInfo.seeded=false;gasInfo.status="DISABLED"
                end
                s.seedBatchPendingAck=false
            end
            if s.airborneStart then
                -- Already flying: no launch settle and no lift build. Hold
                -- from the acknowledged current ceilings in READY.
                s.launchComplete=true;s.launchDurationSeconds=0;s.airborne=true
                self:captureSystemsBaseline(io,s,now)
                s.reason="AIRBORNE START COMPLETE; HOLDING SELECTED ALTITUDE"
                self.reason=s.reason
                return
            end
            s.phase="BUILDING_LIFT";s.phaseStartedAt=now
            if not s.launchStartedAt and (s.launchDurationSeconds or 0)>0 then s.launchStartedAt=now end
            s.lastLiftRatio=nil;s.lastLiftProgressAt=now;s.reason="BUILDING LIFT TO TARGET"
            -- The acknowledged control-start map is the acquisition baseline.
            -- Reset derivative history here so probe activation time cannot
            -- enter either PID, and give trim symmetric authority immediately.
            s.baseline=copyMaps(s.currentTargets);self.baseline=copyMaps(s.currentTargets)
            self.outer:reset(io.vessel.altitude);self.inner:reset(io.vessel.verticalSpeed)
            self:resetTrim();self:seedLevelBias();self.effort=0;self.verticalTarget=0
            s.coarseTrimApplied={};s.batchCoarseTrimApplied={}
            s.acquisitionPidActive=false;s.lastPidAt=now;s.lastTargetCommandAt=now;s.lastTargetAppliedAt=now
        end
        return
    end
    if s.phase=="PROBING" then return end
    if s.phase=="VERIFYING" then
        local envelopeReady,envelopeReason=self:systemsEnvelopeReady(io)
        if s.initialGasTarget and s.initialGasTarget.waitingForCapacity and
            (not envelopeReady or balanced.phase=="UNAVAILABLE" or balanced.phase=="INFEASIBLE") then
            s.reason=not envelopeReady and (envelopeReason or "WAITING FOR VERIFIED STARTUP GAS CAPACITY") or
                (balancedReason or balanced.reason or "WAITING FOR VERIFIED STARTUP GAS CAPACITY")
            self.systemsSnapshot={active=true,available=false,phase=s.phase,pending=false,complete=false,
                target=s.target,reason=s.reason,warning=s.warning,curve=s.curve,
                demandProgress=s.demandProgress,capacityProgress=s.capacityProgress,
                initialGasTarget=clone(s.initialGasTarget)}
            return
        end
        if envelopeReady then
            local maps=s.controlStartTargets
            if type(maps)~="table" then self:stopSystems(io,"CONTROL START TARGETS UNAVAILABLE",now);return end
            if balanced.phase=="UNAVAILABLE" or balanced.phase=="INFEASIBLE" then
                local why=balancedReason or balanced.reason or "BALANCED LIFT CAPACITY UNAVAILABLE"
                local canStartAtFloor=balanced.phase=="UNAVAILABLE" and
                    (why:find("WAITING FOR BULK ENVELOPE CAPACITY",1,true) or
                     why:find("BALLOON CAPACITY UNAVAILABLE",1,true)) and
                    self:isFloorOnlyTargets(io,maps,true,false,true)
                if canStartAtFloor then
                    s.balancedReason=why
                    if s.initialGasTarget and s.initialGasTarget.requestedM3PerChamber>0 then
                        s.initialGasTarget.waitingForCapacity=true
                        s.initialGasTarget.status="WAITING_FOR_VERIFIED_CAPACITY"
                        s.initialGasTarget.reason=why
                        s.initialGasTarget.bootstrapM3PerChamberByQuadrant=systemsProviderTargetTotals(io,maps)
                    end
                    s.phase="CONTROL_START"
                    self:beginSystemsBatch(io,"control",maps,now);return
                end
                envelopeReady=false;envelopeReason=why
            else
                local capped,capReason,limited=self:capBalancedTargets(io,maps,balanced)
                if not capped then
                    envelopeReady=false;envelopeReason=capReason or "BALANCED PROVIDER FLOOR LIMIT UNAVAILABLE"
                    s.balancedReason=envelopeReason
                    balanced.phase="INFEASIBLE";balanced.reason=envelopeReason
                else
                    maps=capped
                    local seedInfo
                    local seedMaps,info,seedReason=self:systemsStartupGasSeedTargets(io,maps,balanced,s)
                    seedInfo=info
                    local seedWillApply=seedMaps~=nil and info.requestedM3PerChamber>0
                    if not seedMaps then
                        seedMaps=maps
                        seedInfo=s.initialGasTarget or info
                        seedInfo.waitingForCapacity=false
                        if seedInfo.requestedM3PerChamber>0 then
                            seedInfo.limited=true
                            seedInfo.limitReason=seedReason or "INITIAL GAS TARGET COULD NOT BE SAFELY ALLOCATED"
                        end
                    end
                    local seedCapped,seedCapReason,seedLimited=self:capBalancedTargets(io,seedMaps,balanced)
                    if not seedCapped then
                        envelopeReady=false;envelopeReason=seedCapReason or "INITIAL GAS TARGET CAPACITY UNAVAILABLE"
                        s.balancedReason=envelopeReason
                        return
                    end
                    local planned,plannedReason=systemsProviderTargetTotals(io,seedCapped)
                    if not planned then
                        self:stopSystems(io,plannedReason or "INITIAL GAS TARGET MAP INVALID",now);return
                    end
                    seedInfo.plannedM3PerChamberByQuadrant=planned
                    seedInfo.waitingForCapacity=false
                    seedInfo.controlMapPendingAck=true
                    if seedLimited then
                        seedInfo.limited=true
                        seedInfo.limitReason=seedInfo.limitReason or seedCapReason or
                            "WEAKEST BALANCED CAPACITY REDUCED THE INITIAL GAS TARGET"
                        balanced.capApplied=true;balanced.demandLimited=true
                    end
                    seedInfo.status=seedInfo.requestedM3PerChamber>0 and "ACKNOWLEDGMENT_PENDING" or "DISABLED"
                    s.initialGasTarget=seedInfo
                    s.seedBatchPendingAck=seedWillApply
                    seedCapped=retainActiveBulk(seedCapped,s.retainedBulk)
                    maps=seedCapped
                    s.controlStartTargets=copyMaps(seedCapped)
                    s.phase="CONTROL_START"
                    self:beginSystemsBatch(io,"control",maps,now);return
                end
            end
        end
        s.reason=envelopeReason or "WAITING FOR PROBE BALLOON DATA"
        if now-s.phaseStartedAt>SYSTEMS_ENVELOPE_TIMEOUT_SECONDS then
            self:stopSystems(io,(envelopeReason or "BALLOON DATA UNAVAILABLE").."; PROBE TIMED OUT",now);return
        end
        if now>=s.renewAt then
            s.renewing=true;s.phase="VERIFYING"
            self:beginSystemsBatch(io,"probe",s.probeTargets,now);return
        end
        self.systemsSnapshot={active=true,available=false,phase=s.phase,pending=false,complete=false,
            target=s.target,reason=s.reason,warning=s.warning,curve=s.curve,
            demandProgress=s.demandProgress,capacityProgress=s.capacityProgress}
        return
    end
    if s.phase=="CONTROL_START" then return end
    if s.phase~="BUILDING_LIFT" and s.phase~="READY" then
        self:stopSystems(io,"INVALID SYSTEMS PHASE",now);return
    end
    if s.phase=="BUILDING_LIFT" and s.launchStartedAt and not s.launchComplete then
        local remaining=math.max(0,(s.launchDurationSeconds or 0)-(now-s.launchStartedAt))
        if remaining>0 then
            s.acquisitionPidActive=false;self.effort=0;self.verticalTarget=0
            s.lastPidAt=now;s.lastLiftProgressAt=now
            if now-s.lastControlAt>=io.config.network.sample_interval_seconds then
                local launchDt=clamp(now-(s.lastControlAt or now),0.05,3)
                s.lastControlAt=now
                -- Keep leveling while the altitude PID is paused: an uneven
                -- fill pitches the ship hardest during these first seconds.
                local launchMaps,launchApplied=s.currentTargets,s.coarseTrimApplied
                local trimmedOk=s.baseline and self:updateTrim(io,s.baseline,launchDt,launchDt,now)
                if trimmedOk then
                    local base={}
                    for _,q in ipairs(QUADS) do
                        base[q]={}
                        for name,value in pairs(s.currentTargets[q] or {}) do
                            local applied=s.coarseTrimApplied and s.coarseTrimApplied[q] and s.coarseTrimApplied[q][name]
                            base[q][name]=finite(applied) and value-applied or value
                        end
                    end
                    local trimmed=self:applyCoarseSteamTrim(io,base,balanced,now)
                    local capped=trimmed and self:capBalancedTargets(io,trimmed,balanced)
                    if capped then
                        launchMaps,launchApplied=capped,{}
                        for _,q in ipairs(QUADS) do
                            launchApplied[q]={}
                            for name,p in pairs(io.nodes[q].providers or {}) do
                                if p.controlRole=="bulk" and finite(capped[q][name]) and finite(base[q][name]) then
                                    launchApplied[q][name]=capped[q][name]-base[q][name]
                                end
                            end
                        end
                    end
                end
                self:beginSystemsBatch(io,"control",launchMaps,now,launchApplied)
                if not self.systemsRun or s.telemetryRecovery then return end
            end
            s.reason="LAUNCH SETTLING / PID PAUSED: "..string.format("%.1f",remaining).."s"
            self.reason=s.reason
            self.systemsSnapshot={active=true,available=false,phase="LAUNCH",pending=s.pending~=nil,
                complete=false,target=s.target,reason=s.reason,pidActive=false,launchRemainingSeconds=remaining}
            return
        end
        s.launchComplete=true
        self.outer:reset(io.vessel.altitude);self.inner:reset(io.vessel.verticalSpeed)
        s.dynamics=nil;s.acquisitionMotionSamples=0;s.acquisitionMotionReadyAt=nil
        s.lastPidAt=now;s.lastControlAt=now;s.lastSystemsUpdateAt=now
        s.reason="LAUNCH SETTLED; BUILDING LIFT TO TARGET"
        return
    end
    if balanced.phase=="UNAVAILABLE" or balanced.phase=="INFEASIBLE" then
        s.reason=s.balancedReason or balanced.reason or "BALANCED LIFT CAPACITY UNAVAILABLE"
        if s.currentTargets and now-s.lastControlAt>=io.config.network.sample_interval_seconds then
            s.lastControlAt=now
            self:beginSystemsBatch(io,"control",s.currentTargets,now)
        end
        self.systemsSnapshot={active=true,available=false,phase=s.phase,pending=s.pending~=nil,
            complete=s.phase=="READY",target=s.target,reason=s.reason,warning=s.warning,
            liftRatio=s.dynamics and s.dynamics.actualRatio,balancedLift=balanced}
        return
    end
    local c=self.config;local v=io.vessel
    local lift=0;for _,q in ipairs(QUADS) do lift=lift+io.nodes[q].balloon.lift end
    -- The raw getter excludes both gravity and the local pressure multiplier.
    local actualRatio=lift*airPressure(v)/v.mass
    local responseSeconds=math.max(c.hover_capture_seconds or 5,1)
    local maxVs=c.max_vertical_speed or 1
    local desiredVs=self.verticalTarget or clamp((s.target-v.altitude)/responseSeconds,-maxVs,maxVs)
    local dynamics=s.dynamics or {}
    local measuredLiftRate=finite(dynamics.projectedLiftRate) and dynamics.projectedLiftRate or dynamics.liftRate
    local supportTarget=finite(s.lastDesiredRatio) and s.lastDesiredRatio or 1
    local supportTolerance=math.min(c.lift_balance_tolerance_fraction,
        math.max(0.005,(c.hover_max_vertical_speed or 0.2)/
            (math.abs(v.environment.gravity.y)*math.max(responseSeconds,1))))
    local supportSettled=math.abs(actualRatio-supportTarget)<=supportTolerance and
        not (actualRatio<supportTarget and finite(measuredLiftRate) and
            measuredLiftRate< -supportTolerance/math.max(responseSeconds,1))
    if s.phase=="BUILDING_LIFT" then
        if self:systemsCaptureReady(s,v,now,supportSettled,actualRatio) then
            self:captureSystemsBaseline(io,s,now)
        end
    end
    if now-s.lastControlAt<io.config.network.sample_interval_seconds then
        self.systemsSnapshot={active=true,available=false,phase=s.phase,pending=false,complete=s.phase=="READY",
            target=s.target,reason=s.reason,warning=s.warning,curve=s.curve,
            demandProgress=s.demandProgress,capacityProgress=s.capacityProgress,
            desiredLiftRatio=s.lastDesiredRatio,
            liftRatio=actualRatio,verticalSpeedTarget=desiredVs}
        return
    end
    local dt=now-s.lastControlAt
    if dt<=0 or dt>SYSTEMS_SAMPLE_GAP_SECONDS then
        self:stopSystems(io,"SYSTEMS CONTROL SAMPLE GAP",now,{phase=s.phase,
            elapsedSeconds=dt,sampleGapLimitSeconds=SYSTEMS_SAMPLE_GAP_SECONDS,
            lastControlAt=s.lastControlAt,lastTargetCommandAt=s.lastTargetCommandAt})
        return
    end
    local pidDt=now-(s.lastPidAt or s.lastControlAt)
    if pidDt<=0 or pidDt>SYSTEMS_SAMPLE_GAP_SECONDS then
        self:stopSystems(io,"SYSTEMS PID SAMPLE GAP",now,{phase=s.phase,
            elapsedSeconds=pidDt,sampleGapLimitSeconds=SYSTEMS_SAMPLE_GAP_SECONDS,
            lastPidAt=s.lastPidAt,lastTargetCommandAt=s.lastTargetCommandAt})
        return
    end
    local actuatorElapsed=now-(s.lastTargetCommandAt or s.lastControlAt)
    local slewDt=finite(actuatorElapsed) and actuatorElapsed>0 and
        math.min(actuatorElapsed,SYSTEMS_MAX_SLEW_CATCHUP_SECONDS) or dt
    s.lastControlAt=now
    -- Calculate acquisition demand only after the previous four-quadrant
    -- batch was acknowledged. The feed-forward comes from validated mass,
    -- local pressure, gravity, gas composition and current bulk output; the
    -- existing slew/taper/balanced-cap path remains the only actuator route.
    local outerIBefore,innerIBefore=self.outer.i,self.inner.i
    s.lastLiftCalculationAt=now
    local desiredRatio=1
    if s.phase=="BUILDING_LIFT" then
        desiredRatio=self:systemsAcquisitionControl(io,s,pidDt,actualRatio,now,slewDt)
        desiredVs=self.verticalTarget or 0
        if s.acquisitionPidActive then
            local trimOk,trimReason=self:updateTrim(io,s.baseline,pidDt,slewDt,now)
            if not trimOk then self:stopSystems(io,trimReason or "SYSTEMS TRIM DATA UNAVAILABLE",now);return end
            if s.airborne and self.trimStatus and self.trimStatus.levelIndicated then self:rememberLevelBias(now) end
        end
    end
    local maps,direction,allAtMaximum,curveTelemetry
    if s.phase=="READY" then
        self.target=s.target
        local mapReason
        maps,mapReason=self:systemsHoldTargets(io,s,pidDt,actualRatio,now,slewDt)
        if not maps then self:stopSystems(io,mapReason or "SYSTEMS HOLD DATA UNAVAILABLE",now);return end
        pcall(self.rememberHoverOffset,self,io.vessel,s,actualRatio,now)
        desiredRatio=finite(s.lastDesiredRatio) and s.lastDesiredRatio or desiredRatio
    else
        maps,direction,allAtMaximum,curveTelemetry=self:systemsControlTargets(io,s,dt,desiredRatio,actualRatio,now,slewDt)
        s.curve=curveTelemetry.curve
        s.demandProgress=curveTelemetry.demandProgress
        s.capacityProgress=curveTelemetry.capacityProgress
        s.capacityLimited=curveTelemetry.capacityLimited
        s.fastBoost=curveTelemetry.fastBoost
        s.warning=systemsWarning(io,s)
        if direction>0 and allAtMaximum then
            self.outer.i=outerIBefore;self.inner.i=innerIBefore
        end
    end
    if s.phase=="BUILDING_LIFT" and s.acquisitionPidActive and s.initialGasTarget and
        s.initialGasTarget.seeded==true and finite(s.initialGasTarget.requestedM3PerChamber) and
        s.initialGasTarget.requestedM3PerChamber>0 then
        local demandCapped,capReason,capInfo=capSeededStartupSupportTargets(io,maps,desiredRatio,self.config)
        if not demandCapped then self:stopSystems(io,capReason or "STARTUP SEED SUPPORT CAP FAILED",now);return end
        maps=demandCapped
        s.initialGasTarget.dynamicDemandMaximumM3PerChamber=capInfo and capInfo.maximumM3PerChamber
        s.initialGasTarget.dynamicDemandCapApplied=capInfo and capInfo.limited==true or false
        s.initialGasTarget.dynamicDemandFloorLimited=capInfo and capInfo.floorLimited==true or false
        if capInfo and capInfo.limited then
            self.outer.i=outerIBefore;self.inner.i=innerIBefore
        end
    end
    s.lastPidAt=now
    local baseMaps=copyMaps(maps)
    maps=self:applyCoarseSteamTrim(io,baseMaps,balanced,now)
    local capped,capReason,capacityLimited=self:capBalancedTargets(io,maps,balanced)
    if not capped then
        balanced.phase="INFEASIBLE";balanced.reason=capReason or "BALANCED PROVIDER FLOOR LIMIT UNAVAILABLE"
        s.balancedReason=balanced.reason;s.reason=balanced.reason
        if s.currentTargets then
            self:beginSystemsBatch(io,"control",s.currentTargets,now)
        end
        self.systemsSnapshot={active=true,available=false,phase=s.phase,pending=s.pending~=nil,
            complete=s.phase=="READY",target=s.target,reason=s.reason,warning=s.warning,
            liftRatio=actualRatio,balancedLift=balanced}
        return
    end
    maps=capped
    if capacityLimited then
        self.saturated=true
        self.outer.i=outerIBefore;self.inner.i=innerIBefore
    end
    if balanced.targetUnreachable then s.balancedReason=balanced.reason end
    if s.phase~="READY" and direction>0 and allAtMaximum and
        not capacityLimited and not balanced.targetUnreachable then
        if not s.lastLiftRatio or actualRatio>s.lastLiftRatio+SYSTEMS_LIFT_PROGRESS_EPSILON then
            s.lastLiftProgressAt=now
        elseif now-s.lastLiftProgressAt>=math.max(60,(c.hover_capture_seconds or 5)*4) then
            self:stopSystems(io,"MAXIMUM VENT CEILINGS; LIFT NOT INCREASING",now);return
        end
    elseif s.phase~="READY" then s.lastLiftProgressAt=now end
    s.lastLiftRatio=actualRatio
    local appliedCoarse={}
    for _,q in ipairs(QUADS) do
        appliedCoarse[q]={}
        for name,p in pairs(io.nodes[q].providers or {}) do
            if p.controlRole=="bulk" then
                appliedCoarse[q][name]=maps[q][name]-baseMaps[q][name]
            end
        end
    end
    self:beginSystemsBatch(io,"control",maps,now,appliedCoarse)
    self.systemsSnapshot={active=true,available=false,phase=s.phase,pending=true,complete=s.phase=="READY",
        target=s.target,reason=s.reason,liftRatio=actualRatio,desiredLiftRatio=desiredRatio,
        verticalSpeedTarget=self.verticalTarget or desiredVs,effort=self.effort,saturated=self.saturated==true,
        warning=s.warning,curve=s.curve,demandProgress=s.demandProgress,capacityProgress=s.capacityProgress,
        fastBoost=s.fastBoost,balancedLift=balanced}
end
-- @ama-summary: Track vent-start acknowledgements and report the completed startup operation.
function Flight:updateStartup(io,now)
    self.startupComplete=io.config.vent_startup_enabled==true
    for _,q in ipairs(QUADS) do
        local n=io.nodes[q];local bulk=0
        if not n or not io:nodeFresh(q,now) then self.startupComplete=false
        else
            for _,p in pairs(n.providers or {}) do
                if p.controlRole=="bulk" then
                    bulk=bulk+1
                    if not p.signalValid or p.signalStrength~=15 or not p.attachedValid or not p.attached or
                        not p.gasOutputValid or not finite(p.gasOutput) or p.gasOutput<0 or
                        (p.activeSupported and (not p.activeValid or not p.active)) then self.startupComplete=false end
                end
            end
            if bulk~=steamCount(n) then self.startupComplete=false end
        end
    end
    if self.startupPending then
        local applied=true
        for _,q in ipairs(QUADS) do
            local command=self.startupPending[q]
            if io.nodes[q].boot~=command.boot then
                self.startupPending=nil;self.startupReason=q.." STARTUP BOOT CHANGED";break
            end
            if not io:commandWasApplied(q,command.seq,command.targets) then applied=false end
        end
        if self.startupPending and applied then self.startupPending=nil;self.startupReason="VENTS STARTED"
        elseif self.startupPending and now-self.startupSentAt>(io.config.vent_startup_ack_seconds or 18) then
            self.startupPending=nil;self.startupReason="VENT STARTUP NOT ACKNOWLEDGED; CHECK LIFT LOGS"
        end
    end
    local maps,blocked=self:startupTargets(io,now)
    self.startupBlockedReason=blocked
    self.startupAvailable=not self.startupComplete and self.startupPending==nil and maps~=nil
end
-- @ama-section: Flight lifecycle | Operator actions, runtime gates and cached presentation.
-- @ama-summary: Copy a permitted navigator action into a bounded core request.
local function copyBridgeAction(value,depth,budget)
    local kind=type(value)
    if kind=="number" then if not finite(value) then error("nonfinite action",0) end;return value end
    if kind=="string" then if #value>2048 then error("action string too long",0) end;return value end
    if kind=="boolean" or kind=="nil" then return value end
    if kind~="table" or depth>4 then error("invalid action nesting",0) end
    local out={}
    for key,item in pairs(value) do
        budget.n=budget.n+1
        if budget.n>128 or type(key)~="string" and type(key)~="number" or
            type(key)=="string" and #key>128 or type(key)=="number" and not finite(key) then error("action size/key limit",0) end
        out[key]=copyBridgeAction(item,depth+1,budget)
    end
    return out
end
local function sameBridgeAction(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not sameBridgeAction(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
-- @ama-summary: Correlate navigator requests with the current core session and dispatch accepted actions.
function Flight:bridgeRequest(io,message,now)
    local boot,seq=message.boot,message.seq
    if type(boot)~="string" or #boot==0 or #boot>128 or not boot:match("^[%w_%.%-:]+$") or
        not finite(seq) or seq%1~=0 or seq<1 or seq>io.config.network.max_sequence then
        return false,"INVALID BRIDGE REQUEST IDENTITY"
    end
    self.retiredBridgeBoots=self.retiredBridgeBoots or {}; self.bridgeBootOrder=self.bridgeBootOrder or {}
    if self.retiredBridgeBoots[boot] then return false,"RETIRED BRIDGE BOOT" end
    if self.bridgeBoot~=boot then
        if self.bridgeBoot then
            self.retiredBridgeBoots[self.bridgeBoot]=true
            self.bridgeBootOrder[#self.bridgeBootOrder+1]=self.bridgeBoot
            if #self.bridgeBootOrder>32 then self.retiredBridgeBoots[table.remove(self.bridgeBootOrder,1)]=nil end
        end
        -- Navigator owns presentation, not altitude authority. Its reboot
        -- changes request identity without stopping the core's running hold.
        self.maintenanceReview=nil;self.tuningReview=nil;self.stopReview=nil
        if self.tuningRun then self:abortTuning(io,"BRIDGE RESTARTED") end
        self.bridgeBoot=boot; self.lastRequestSeq=0
        self.bridgeRequestResults={};self.bridgeRequestOrder={}
    end
    self.bridgeRequestResults=self.bridgeRequestResults or {};self.bridgeRequestOrder=self.bridgeRequestOrder or {}
    local copied,action=pcall(copyBridgeAction,message.action,0,{n=0})
    if not copied or type(action)~="table" or type(action.type)~="string" then return false,"INVALID BRIDGE ACTION" end
    local prior=self.bridgeRequestResults[seq]
    if prior then
        if not sameBridgeAction(prior.action,action) or prior.expiresAt~=message.expiresAt then return false,"BRIDGE REQUEST ID REUSED" end
        if prior.accepted==nil then return false,"COMMAND RESULT PENDING" end
        return prior.accepted,prior.reason
    end
    if seq<=self.lastRequestSeq then return false,"BRIDGE REQUEST REPLAY" end
    self.lastRequestSeq=seq
    local record={action=copyBridgeAction(action,0,{n=0}),expiresAt=message.expiresAt}
    self.bridgeRequestResults[seq]=record;self.bridgeRequestOrder[#self.bridgeRequestOrder+1]=seq
    if #self.bridgeRequestOrder>32 then self.bridgeRequestResults[table.remove(self.bridgeRequestOrder,1)]=nil end
    -- The navigator's wall-clock deadline prevents a queued command from
    -- becoming a surprise action after a long game/event-queue stall.
    if message.expiresAt~=nil and (not finite(message.expiresAt) or message.expiresAt<=now or message.expiresAt>now+60) then
        record.accepted=false;record.reason="COMMAND EXPIRED OR DEADLINE INVALID";return false,record.reason
    end
    local called,accepted,reason=pcall(function()
        if io.remoteAP then io.remoteAP:pilotAction(action) end
        return self:request(io,action,now)
    end)
    if not called then accepted,reason=false,"COMMAND ERROR; CHECK CORE: "..tostring(accepted):sub(1,160) end
    record.accepted,record.reason=accepted==true,reason
    return record.accepted,record.reason
end
-- ===================== ASSEMBLY GATE =====================
-- A disassembled (or not yet confirmed) vessel has no meaningful CoM, balloon
-- lift or attitude, so every lift calculation stops here: START SYSTEMS,
-- altitude hold, trim and PID tuning are cancelled and their integrators are
-- discarded. Like other faults, this cancels authority and RETAINS the lift
-- ceilings already applied; it never writes lift outputs itself. Propulsion
-- is stopped separately by Thrust (nodes ramp to zero). Nothing resumes on
-- reassembly: START SYSTEMS must be requested again.
-- @ama-summary: Suspend assembly-gated flight operations and retain their last applied lift settings.
function Flight:assemblyBlocked(io,now,reason)
    reason=reason or "VESSEL DISASSEMBLED"
    if self.tuningRun then self:abortTuning(io,reason) end
    if self.systemsRun then self:stopSystems(io,reason,now) end
    if self.enabled then self:stop(reason) end
    self.tuningReview=nil;self.startupPending=nil
    self.hoverSince=nil;self.tuningHoverSince=nil
    self.available=false;self.reason=reason
    self.systemsAvailable=false;self.systemsBlockedReason=reason
    local last=self.systemsLastOutcome
    self.systemsSnapshot={active=false,available=false,phase="BLOCKED",pending=false,complete=false,
        target=last and last.target or nil,reason=reason,
        abortReason=last and last.phase=="ABORTED" and last.reason or nil,
        abortDetails=last and last.abortDetails or nil}
    self.tuningSnapshot={available=false,active=false,reason=reason,result=self.tuningResult}
    self.startupAvailable=false;self.startupBlockedReason=reason
    self.trimStatus=nil
end
-- @ama-summary: Publish the validated altitude/input authority context to chamber controllers.
function Flight:renewLiftControlContext(io,now)
    local controls=self.controls
    local assembled,_,assembly=Flight.assemblyGate(io,now)
    local assemblyUnknown=not assembled and (not assembly or assembly.state~="DISASSEMBLED")
    if self.systemsRun and assemblyUnknown and not self.systemsRun.telemetryRecovery then
        TelemetryRecovery.suspend(self,self.systemsRun,now,"ASSEMBLY STATE UNKNOWN")
    end
    if self.systemsRun and assembled and not self.systemsRun.telemetryRecovery then
        local guarded,guardReason=self:systemsGuard(io,now,self.systemsRun)
        if not guarded and TelemetryRecovery.isTransientGuardFault(io,self.systemsRun,now,guardReason,self) then
            TelemetryRecovery.suspend(self,self.systemsRun,now,guardReason)
        end
    end
    local telemetrySuspended=self.systemsRun and self.systemsRun.telemetryRecovery~=nil
    local assemblySuppressed=not assembled
    local selected=controls and controls.targets and controls.targets.altitude or nil
    local inputsActive=false
    if controls and type(controls.fresh)=="function" then
        local fresh=controls:fresh(io,now)
        inputsActive=fresh==true and controls.available==true
    end
    if telemetrySuspended or assemblySuppressed then inputsActive=false end
    local limits=self.config or {}
    local altitudeValid=not telemetrySuspended and not assemblySuppressed and finite(selected) and finite(limits.minimum_world_y) and
        finite(limits.maximum_world_y) and selected>=limits.minimum_world_y and selected<=limits.maximum_world_y
    local activeSystemsPhase=not self.systemsRun or self.systemsRun.phase=="READY" or
        (self.systemsRun.phase=="BUILDING_LIFT" and self.systemsRun.acquisitionPidActive==true)
    local pidCandidate=self.enabled==true and not self.shutdownJob and not self.emergencyLiftLatched and
        not self.tuningRun and not self.startupPending and not self.maintenanceJob and activeSystemsPhase and
        not telemetrySuspended and not assemblySuppressed
    local pidActive=false
    if pidCandidate and altitudeValid and inputsActive then
        if self.systemsRun then
            local guarded=self:systemsGuard(io,now,self.systemsRun)==true
            if self.systemsRun.phase=="BUILDING_LIFT" then
                local feedForward=self:systemsHoverFeedForward(io,self.systemsRun,now)
                pidActive=guarded and feedForward~=nil
                if not pidActive then self.systemsRun.acquisitionPidActive=false end
            else
                local feedForward,feedReason=self:systemsHoverFeedForward(io,self.systemsRun,now)
                pidActive=guarded and feedForward~=nil
                self.systemsRun.acquisitionPidActive=pidActive
                self.systemsRun.feedForwardReason=feedReason
            end
        else
            pidActive=self:check(io,now)==true
        end
    end
    local context={selectedAltitude=altitudeValid and selected or nil,
        pidActive=pidActive,inputsActive=inputsActive}
    self.liftControlContext=context
    if type(io.sendLiftControlContext)=="function" then
        for _,q in ipairs(QUADS) do pcall(io.sendLiftControlContext,io,q,context) end
    end
    return context
end
-- Rebind a fresh Sable association across retained control references.
-- @ama-summary: Adopt a fresh Sable UUID across retained control references and persistent selections.
function Flight:adoptVesselIdentity(io,now)
    local v=io.vessel or {}
    local observed=(io.primaryReadings or {}).uuid
    local stale=(io.config.network or {}).sensor_stale_seconds or 18
    if v.valid~=true or not observed or observed.value~=v.uuid or not finite(observed.at) or
        now<observed.at or now-observed.at>stale or
        (self.vesselAdoptedAt and observed.at<=self.vesselAdoptedAt) then return end
    local old=self.uuid or (self.systemsRun or {}).uuid or (self.controls or {}).uuid
    if not old or old==v.uuid then return end
    local track=io.assemblyTrack
    local uncertain=not track or track.error~=nil or not finite(track.definiteAt) or
        now-track.definiteAt>stale
    if not uncertain then return end
    self.vesselAdoptedAt=observed.at
    -- @ama-summary: Update matching retained vessel UUID references through the operation's nested records.
    local function rebind(value,depth,seen)
        if type(value)~="table" or depth>8 or seen[value] then return end
        seen[value]=true
        for key,item in pairs(value) do
            if (key=="uuid" or key=="headingTargetUuid" or key=="speedTargetUuid") and item==old then
                value[key]=v.uuid
            elseif type(item)=="table" then rebind(item,depth+1,seen) end
        end
    end
    for _,value in ipairs({self,self.controls,io.autopilot or {},io.positionAnchor or {},
        io.controlPresets or {}}) do rebind(value,0,{}) end
    if self.restart and self.restart.saved then self.restart:write(self.restart.saved) end
    if io.controlPresets then io.controlPresets:update(io,self,now) end
    if type(os.__amaryllisLog)=="function" then os.__amaryllisLog("Vessel association updated: "..old.." -> "..v.uuid,"core.identity") end
end

-- @ama-summary: Update cockpit state, retained intent and the current altitude-control lifecycle.
function Flight:update(io,now)
    self:adoptVesselIdentity(io,now)
    NavigationSettings.ensure(io.config)
    if self.controls then self.controls:update(io,now) end
    self.settingsEntries={}
    for _,f in ipairs(FIELDS) do local entry=clone(f);entry.path=nil;entry.value=readPath(io.config,f.path);self.settingsEntries[#self.settingsEntries+1]=entry end
    if self.systemsRun then self:setSystemsIntent(true)
    elseif not self.emergencyLiftLatched then pcall(self.autoResumeSystems,self,io,now) end
    if self.emergencyLiftLatched then
        if self.emergencyLiftDisarmJob then self:updateLiftDisarm(io,now)
        else self:updateEmergencyLiftKill(io,now) end
        self.available=false;self.startupAvailable=false;self.systemsAvailable=false
        if self.emergencyLiftLatched then
            self.reason=self.emergencyLiftDisarmJob and self.emergencyLiftDisarmJob.reason or "EMERGENCY LIFT KILL LATCHED; DISARM KILL FIRST"
            self.systemsBlockedReason=self.reason
            self.systemsSnapshot={active=false,available=false,phase="BLOCKED",pending=false,complete=false,reason=self.reason}
        end
        return
    end
    self:renewLiftControlContext(io,now)
    -- Sending four control-context messages may yield while the input worker
    -- publishes a newer completion timestamp. Evaluate subsequent gates using
    -- the shared live clock, matching the snapshot and assembly-gate behavior.
    if io and type(io.nowSeconds)=="function" then
        local ok,current=pcall(io.nowSeconds,io)
        if ok and finite(current) and (not finite(now) or current>now) then now=current end
    end
    if self.stopReview and now>self.stopReview.expires then self.stopReview=nil end
    if self.shutdownJob then self:updateShutdown(io,now);self.available=false;return end
    self.maintenanceSnapshot=self:maintenanceState(io,now)
    local assembled,assemblyReason,assembly=Flight.assemblyGate(io,now)
    self.assembly=assembly
    self:updateMaintenance(io,now)
    if not assembled then
        if self.systemsRun and assembly and assembly.state~="DISASSEMBLED" then
            TelemetryRecovery.suspend(self,self.systemsRun,now,assemblyReason or "ASSEMBLY STATE UNKNOWN")
            self:updateSystemsRecovery(io,now,self.systemsRun)
            self.available=false
            return
        end
        self:assemblyBlocked(io,now,assemblyReason); return
    end
    local targetY=self.controls and self.controls.targets and self.controls.targets.altitude or
        (io.vessel and io.vessel.altitude)
    self.balancedLift=self:balancedLiftModel(io,targetY,now)
    self:updateTuning(io,now)
    if self.tuningRun then self.available=false;return end
    self:updateStartup(io,now)
    if self.systemsRun then
        self:updateSystems(io,now);self.available=false
        return
    end
    self:updateSystems(io,now)
    local ok,reason=self:check(io,now)
    if not self.enabled then
        self.reason=reason or self.reason or "NOT ENGAGED"
        if ok and math.abs(io.vessel.verticalSpeed)<=self.config.hover_max_vertical_speed then
            self.hoverSince=self.hoverSince or now
        else self.hoverSince=nil end
        self.available=ok and self.hoverSince~=nil and now-self.hoverSince>=self.config.hover_capture_seconds
        return
    end
    if not ok then self:stop(reason); return end
    if self.pending then
        local acknowledged=true
        for _,q in ipairs(QUADS) do
            if not io:commandWasApplied(q,self.pending[q].seq,self.pending[q].targets) then acknowledged=false end
        end
        if not acknowledged then
            if now-self.sentAt>io.config.network.commission_ack_seconds then self:stop("LIFT COMMAND ACK TIMEOUT") end
            return -- Do not integrate while a previous write is still pending.
        end
        self.pending=nil
    end
    local dt=now-self.lastUpdate
    if dt<io.config.network.sample_interval_seconds then return end
    if dt>3 or dt<=0 then self:stop("CONTROL SAMPLE GAP"); return end
    self.lastUpdate=now
    if self.controls then self.target=self.controls.targets.altitude
    else
        -- Legacy fixtures/configurations retain the original constant-rate input.
        local raw=io.inputs.raw
        local direction=((raw.altitude_up or 0)>0 and 1 or 0)-((raw.altitude_down or 0)>0 and 1 or 0)
        self.target=clamp(self.target+direction*self.config.target_rate_blocks_per_second*dt,
            self.config.minimum_world_y,self.config.maximum_world_y)
    end
    local oldOuterI,oldInnerI=self.outer.i,self.inner.i
    self.verticalTarget,self.speedLimited=self.outer:step(self.target,io.vessel.altitude,dt,
        -self.config.max_vertical_speed,self.config.max_vertical_speed)
    self.effort,self.feedLimited=self.inner:step(self.verticalTarget,io.vessel.verticalSpeed,dt,
        -self.config.max_feed_fraction,self.config.max_feed_fraction)
    local trimOk,trimReason=self:updateTrim(io,self.baseline,dt,dt,now)
    if not trimOk then self:stop(trimReason);return end
    local allTargets={}; self.saturated=false; local bulkSaturated=false
    for _,q in ipairs(QUADS) do
        allTargets[q]={}
        for name,p in pairs(io.nodes[q].providers) do
            local value=self.baseline[q][name]
            if p.controlRole=="bulk" then value=value*(1+self.effort)
            else value=value+self.trim[q] end
            -- Continuous control never requests zero: the burner must stay on
            -- for envelope calculation, and provider zero clamping is untested.
            local bounded=clamp(math.floor(value+0.5),p.controlRole=="fine" and 0 or p.minimumNonzeroTarget,p.maxTarget)
            if bounded>0 and bounded<p.minimumNonzeroTarget then bounded=p.minimumNonzeroTarget end
            if bounded~=math.floor(value+0.5) then
                self.saturated=true
                if p.controlRole=="bulk" then bulkSaturated=true end
            end
            allTargets[q][name]=bounded
        end
    end
    local model,modelReason=self:balancedLiftModel(io,self.target,now)
    self.balancedLift=model
    if model.phase=="UNAVAILABLE" or model.phase=="INFEASIBLE" then
        self.outer.i=oldOuterI;self.inner.i=oldInnerI
        self:stop(modelReason or model.reason or "BALANCED LIFT CAPACITY UNAVAILABLE");return
    end
    local baseTargets=copyMaps(allTargets)
    allTargets=self:applyCoarseSteamTrim(io,baseTargets,model,now)
    local capped,capReason,capacityLimited=self:capBalancedTargets(io,allTargets,model)
    if not capped then
        self.outer.i=oldOuterI;self.inner.i=oldInnerI
        self:stop(capReason or "BALANCED LIFT TARGET LIMIT UNAVAILABLE");return
    end
    allTargets=capped
    if capacityLimited then
        self.saturated=true;bulkSaturated=true
        self.outer.i=oldOuterI;self.inner.i=oldInnerI
    end
    if model.phase=="LIMITED" then
        self.balancedLift=model
    end
    -- Provider ceilings add another saturation boundary after the PID. Freeze
    -- both integrals there as well, so maximum vent caps cannot wind them up.
    if bulkSaturated then self.outer.i=oldOuterI; self.inner.i=oldInnerI end
    -- Snapshot validation above covers all four nodes before the first send.
    -- Each node still repeats identity, bounds and commissioning checks itself.
    self.pending={}; self.sentAt=now
    for _,q in ipairs(QUADS) do
        local sent,seq=io:sendAltitudeCommand(q,allTargets[q])
        if not sent then self:stop("LIFT SEND FAILED: "..tostring(seq)); return end
        self.pending[q]={seq=seq,targets=allTargets[q]}
    end
end
-- @ama-summary: Add flight, maintenance, recovery and systems information to a cached display snapshot.
function Flight:decorate(snapshot,io,now)
    io=io or {}
    if io.config and io.thrust and self.controls then
        local ap=self:ensureAutopilot(io)
        snapshot.autopilot=ap:snapshot(io,self.controls,now or snapshot.updatedAt or 0)
        if not self.enabled or self.emergencyLiftLatched or self.shutdownJob or self.tuningRun or self.maintenanceJob or
            (self.systemsRun and self.systemsRun.phase~="READY") or (self.restart and (self.restart.job or self.restart.saved)) then
            snapshot.autopilot.available=false;snapshot.autopilot.engageReason="ESTABLISH ALTITUDE HOLD / FINISH SYSTEMS OPERATION"
        end
        snapshot.ap=ap.active and "ACTIVE" or ap.state
    end
    -- The old io.anchor guard represents a total cockpit lockout. Horizontal
    -- anchor authority lives separately so steering and lift remain available.
    snapshot.anchorControl=io.positionAnchor and io.positionAnchor:snapshot() or {active=false,state="OFF"}
    if type(io.assemblyGate)=="function" then
        local _,_,assembly=io:assemblyGate(now);snapshot.assembly=assembly
    end

    snapshot.anchor=snapshot.anchorControl.state
    local anchorReady,anchorReason=false,"ENABLE PROPULSION FIRST"
    if io.thrust and io.config and (io.config.thrust or {}).enabled==true and not self.emergencyLiftLatched and not self.shutdownJob then
        anchorReady,anchorReason=io.thrust:activationReady(io,now,self.controls)
        if anchorReady then
            local v,why=(io.positionAnchor or Anchor.new(io.config)):telemetry(io,now)
            anchorReady=v~=nil;anchorReason=not v and why or nil
        end
    end
    if self.restart and (self.restart.job or self.restart.saved) then anchorReady=false;anchorReason="SYSTEMS RESTART IN PROGRESS" end
    snapshot.anchorControl.available=anchorReady and not snapshot.anchorControl.active
    if io.autopilot and io.autopilot.active then snapshot.anchorControl.available=false;anchorReason="DISENGAGE AUTOPILOT FIRST" end
    snapshot.anchorControl.engageReason=anchorReason
    local restart=self.restart
    snapshot.systemsRestart={available=restart~=nil and not restart.job and not restart.saved and
        not self.emergencyLiftDisarmJob and not self.shutdownJob and not self.tuningRun and not self.maintenanceJob,
        active=restart~=nil and (restart.job~=nil or restart.saved~=nil),reason=restart and restart.reason}
    snapshot.systemsStopReview=self.stopReview
    local trimPidActive=not self.systemsRun or
        ((self.systemsRun.phase=="READY" or self.systemsRun.phase=="BUILDING_LIFT") and
            self.systemsRun.acquisitionPidActive==true)
    local trimControl=self.enabled and trimPidActive and
        self.trimStatus and clone(self.trimStatus) or {active=false}
    local bias=self.config and self.config.manual_fore_aft_trim_blocks
    if not finite(bias) then bias=0 end
    trimControl.manualForeAftBias=bias
    trimControl.manualTargetForeAftHeightDifferenceBlocks=bias
    trimControl.manualTrimMinimum=MANUAL_TRIM_MIN
    trimControl.manualTrimMaximum=MANUAL_TRIM_MAX
    trimControl.manualTrimSteps={MANUAL_TRIM_STEPS[1],MANUAL_TRIM_STEPS[2]}
    trimControl.manualTrimAvailable,trimControl.manualTrimReason=
        self:manualTrimAvailability(io,finite(now) and now or snapshot.updatedAt)
    if not finite(trimControl.foreAftHeightDifferenceBlocks) then
        local nodes=snapshot.nodes or {};local heights={}
        for _,q in ipairs(QUADS) do
            local node=nodes[q];local altitude=node and node.altitude
            if not node or node.online~=true or not altitude or altitude.valid~=true or
                not finite(altitude.sensorWorldY) then heights=nil;break end
            heights[q]=altitude.sensorWorldY
        end
        if heights then
            trimControl.foreAftHeightDifferenceBlocks=(heights.FL+heights.FR)/2-(heights.RL+heights.RR)/2
        end
    end
    snapshot.trimControl=trimControl
    snapshot.maintenance=self.maintenanceSnapshot
    snapshot.tuning=self.tuningSnapshot
    snapshot.emergencyLift=self:emergencyLiftState()
    local balanced=self.balancedLift or {phase="UNAVAILABLE",targetSupportKnown=false,
        reason="BALANCED LIFT CAPACITY NOT SAMPLED"}
    snapshot.balancedLift={phase=balanced.phase,reason=balanced.reason,
        limitingQuadrant=balanced.limitingQuadrant,
        rawPerQuadrantMaximum=balanced.rawPerQuadrantMaximum,rawVesselMaximum=balanced.rawVesselMaximum,
        currentSupportRatio=balanced.currentSupportRatio,actualSupportRatio=balanced.actualSupportRatio,
        targetSupportRatio=balanced.targetSupportRatio,targetSupportKnown=balanced.targetSupportKnown==true,
        targetUnreachable=balanced.targetUnreachable==true,capApplied=balanced.capApplied==true,
        demandLimited=balanced.demandLimited==true}
    if self.controls then self.controls:decorate(snapshot) end
    if io.autopilot and io.autopilot.active then
        snapshot.modes=clone(snapshot.modes or {})
        snapshot.modes.heading="SEL";snapshot.modes.throttle="SEL"
        snapshot.targets=clone(snapshot.targets or {})
        snapshot.targets.speed=io.autopilot.arrivalAnchor and 0 or io.autopilot.speedTarget
        snapshot.targets.heading=io.autopilot.headingTarget or (io.vessel or {}).heading
    end
    if restart and restart.saved then
        snapshot.modes=clone(restart.saved.controls.modes)
        snapshot.targets=clone(restart.saved.controls.targets)
    end
    snapshot.settings=snapshot.settings or {};snapshot.settings.entries=self.settingsEntries
    local recoverRun,recoverReason=self:abortRecoveryState(io,now or snapshot.updatedAt)
    snapshot.systemsRecovery={available=recoverRun~=nil,reason=recoverReason,
        target=self.systemsLastOutcome and self.systemsLastOutcome.target or nil}
    snapshot.altitudeControl={enabled=self.enabled,available=self.available==true,reason=self.reason,
        target=self.systemsRun and self.systemsRun.target or self.target,
        effort=self.effort,verticalSpeedTarget=self.verticalTarget,saturated=self.saturated==true,
        baselineGasMix=self.enabled and self.mixBaseline or nil}
    snapshot.systemsStartup=clone(self.systemsSnapshot or {active=false,available=self.systemsAvailable==true,
        phase=self.systemsAvailable and "READY" or "IDLE",reason=self.systemsBlockedReason}
    )
    -- An accepted restart is explicit intent to run systems, including while
    -- the rebooted core is waiting to restore its checkpoint. Derive the
    -- START/STOP state from that lifecycle rather than an old idle snapshot.
    local restarting=snapshot.systemsRestart.active and not self.emergencyLiftLatched and not self.shutdownJob
    snapshot.systemsStartup.active=self.systemsRun~=nil or restarting
    if snapshot.systemsStartup.active then snapshot.systemsStartup.available=false end
    if not self.systemsRun and restarting then
        snapshot.systemsStartup.phase="RESTARTING"
        snapshot.systemsStartup.pending=true;snapshot.systemsStartup.complete=false
        snapshot.systemsStartup.reason=restart.reason
        snapshot.systemsStartup.abortReason=nil;snapshot.systemsStartup.abortDetails=nil
    end
    if self.systemsRun then
        local s=self.systemsRun
        local selected=self.controls and self.controls.targets and self.controls.targets.altitude
        local presentationTarget=self.initialAcquisitionTarget or s.target
        if finite(selected) and selected~=presentationTarget then self.initialAcquisitionEnded=true end
        local displayPhase=s.phase
        if s.phase=="READY" then displayPhase="READY"
        elseif s.phase=="CONTROL_START" then displayPhase="OPENING STEAM VENTS"
        elseif s.phase=="BUILDING_LIFT" then
            if self.initialAcquisitionEnded or s.airborneStart then displayPhase="READY"
            else displayPhase=s.launchMotionVerified and "ACQUIRING SEL ALT" or "STATIC INFLATION" end
        end
        snapshot.systemsStartup.displayPhase=displayPhase
        snapshot.systemsStartup.target=self.systemsRun.target
        snapshot.systemsStartup.pidActive=(self.systemsRun.phase=="BUILDING_LIFT" or
            self.systemsRun.phase=="READY") and self.systemsRun.acquisitionPidActive==true
        snapshot.systemsStartup.initialGasTarget=clone(self.systemsRun.initialGasTarget)
        local s=self.systemsRun
        snapshot.systemsStartup.acquisitionStallRecovery=s.acquisitionStallRecovery==true
        snapshot.systemsStartup.supportCorrectionDirection=s.lastSupportCorrectionDirection
        snapshot.systemsStartup.holdFeedForwardLimited=s.holdFeedForwardLimited
        snapshot.systemsStartup.dragSupportCompensation=s.dragSupportCompensation
        snapshot.systemsStartup.appliedDragSupportCompensation=s.appliedDragSupportCompensation
        snapshot.systemsStartup.feedForwardReason=s.feedForwardReason
        snapshot.systemsStartup.speedLimiter=s.speedLimiter
        snapshot.systemsStartup.ackWaitSeconds=s.lastAckWaitSeconds
        if s.launchStartedAt and not s.launchComplete and not s.telemetryRecovery then
            local launchNow=finite(now) and now or (finite(snapshot.updatedAt) and snapshot.updatedAt or s.launchStartedAt)
            snapshot.systemsStartup.phase="LAUNCH"
            snapshot.systemsStartup.displayPhase="CAPTURING PITCH ZERO"
            snapshot.systemsStartup.launchRemainingSeconds=math.max(0,
                (s.launchDurationSeconds or 0)-(launchNow-s.launchStartedAt))
            snapshot.systemsStartup.reason="LAUNCH SETTLING / PID PAUSED"
            snapshot.systemsStartup.pidActive=false
        end
    else
        snapshot.systemsStartup.pidActive=false
        snapshot.systemsStartup.initialGasTarget=clone(self.systemsLastOutcome and self.systemsLastOutcome.initialGasTarget)
    end
    snapshot.ventStartup={available=self.startupAvailable==true,pending=self.startupPending~=nil,
        complete=self.startupComplete==true,reason=self.startupReason or self.startupBlockedReason,ceilingPerVent=50}
    if self.enabled and not self.controls then snapshot.targets.altitude=self.target end
    return snapshot
end
return Flight
