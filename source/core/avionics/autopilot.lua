local Mathx = require("avionics.mathx")
-- Section: Route guidance | Destination acquisition, cruise and arrival control.
-- Navigator information AP retry revision v1
-- Single-entry route execution; storage, guidance and arrival action are
-- separate so ordered waypoint routes can extend this without changing I/O.
local Anchor=require("avionics.anchor")
local Library=require("avionics.destinations")
local AP={}
local NavigationSettings=require("avionics.navigation_settings")
local Controls=require("avionics.controls")
local finite = Mathx.finite
local function copy(v) if type(v)~="table" then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local clamp = Mathx.clamp
-- Section: Route guidance | Destination acquisition, cruise and arrival control.
-- Summary: Calculate a normalized compass bearing from horizontal displacement.
local function bearing(x,z)
    local a
    if math.atan2 then a=math.atan2(x,-z)
    elseif -z>0 then a=math.atan(x/-z)
    elseif -z<0 then a=math.atan(x/-z)+(x>=0 and math.pi or -math.pi)
    else a=x>=0 and math.pi/2 or -math.pi/2 end
    return math.deg(a)%360
end
local function log(self,reason)
    if self.logged==reason then return end;self.logged=reason
    if os and type(os.__amaryllisLog)=="function" then os.__amaryllisLog("Core autopilot: "..reason,"core.autopilot")
    else print("Core autopilot: "..reason) end
end
-- Summary: Construct route guidance with its saved draft and destination-library access.
function AP.new(config,storage,deps)
    deps=deps or {}
    local self=setmetatable({config=config,storage=storage,deps=deps,library=Library.new(deps),
        active=false,state="OFF",draft={cruiseSpeed=3},route=nil},{__index=AP})
    if storage then
        local ok,value,_,status=pcall(storage.readJson,"/avionics/data/navigation.json",deps)
        if ok and type(value)=="table" and value.schemaVersion==1 and self:validDraft(value.destination,false) then
            self.draft=copy(value.destination)
            -- "Destination" was the earlier default name; such drafts are unnamed and use their coordinates.
            if self.draft.name=="Destination" then self.draft.name=nil end
        elseif status~="missing" then self.reason="SAVED NAVIGATION SETTINGS INVALID";log(self,self.reason) end
    end
    return self
end
-- Summary: Validate destination text, coordinates, cruise speed and altitude bounds.
function AP:validDraft(d,complete)
    local c=self.config.cockpit or {};local alt=self.config.altitude_control or {}
    if type(d)~="table" or (d.name~=nil and (type(d.name)~="string" or #d.name<1 or #d.name>40 or
        not d.name:match("%S") or d.name:find("[%c]"))) or not finite(d.cruiseSpeed) or d.cruiseSpeed<.1 or
        d.cruiseSpeed>math.min(30,c.maximum_selected_speed or 30) then return false end
    for _,key in ipairs({"x","z"}) do
        if d[key]==nil and complete~=false then return false end
        if d[key]~=nil and (not finite(d[key]) or math.abs(d[key])>30000000) then return false end
    end
    if d.altitude==nil then return complete==false end
    return finite(d.altitude) and d.altitude>=(alt.minimum_world_y or -64) and d.altitude<=2048
end
-- Name a destination: its entered name, or "X, Z" from its whole-block coordinates when no name is entered.
function AP.label(d)
    if type(d)~="table" then return nil end
    if type(d.name)=="string" and d.name:match("%S") then return d.name end
    if finite(d.x) and finite(d.z) then
        return string.format("%d, %d",math.floor(d.x+.5),math.floor(d.z+.5))
    end
end
-- Summary: Persist a validated navigator destination draft.
function AP:saveDraft(candidate)
    if not self:validDraft(candidate,false) then return false,"DESTINATION / SPEED / ALTITUDE INVALID" end
    if self.storage then
        local ok,why=self.storage.writeJson("/avionics/data/navigation.json",{schemaVersion=1,destination=candidate},self.deps)
        if not ok then return false,"NAVIGATION SETTINGS NOT SAVED: "..tostring(why) end
    end
    self.draft=copy(candidate);return true,"DESTINATION UPDATED"
end
-- Summary: Apply a permitted destination edit or saved-destination selection.
function AP:edit(io,controls,action,now)
    if self.active then return false,"DISENGAGE AUTOPILOT BEFORE EDITING DESTINATION" end
    local candidate=copy(self.draft)
    candidate.altitude=candidate.altitude or controls.targets.altitude
    local v=io.vessel or {};local p=v.position or {}
    if candidate.x==nil then candidate.x=p.x end;if candidate.z==nil then candidate.z=p.z end
    if action.type=="ap_current" then
        local sample,why=Anchor.new(self.config):telemetry(io,now)
        if not sample then return false,why end
        candidate.x=sample.position.x;candidate.z=sample.position.z
    elseif action.type=="ap_edit" then
        if action.key~="x" and action.key~="z" and action.key~="name" and action.key~="cruiseSpeed" and action.key~="altitude" then return false,"UNKNOWN DESTINATION FIELD" end
        candidate[action.key]=action.value
        -- A blank name removes it; the destination is then named by its coordinates.
        if action.key=="name" and (type(action.value)~="string" or not action.value:match("%S")) then candidate.name=nil end
    elseif action.type=="destination_select" then
        self.library:refresh();local selected=self.library.entries[action.index]
        if not selected then return false,self.library.reason or "SELECT A SAVED DESTINATION" end
        candidate.name=selected.name;candidate.x=selected.x;candidate.z=selected.z
    else return false,"UNKNOWN NAVIGATION ACTION" end
    -- A destination altitude above the altitude ceiling is set to the ceiling.
    local ceiling=Controls.altitudeCeiling(self.config.altitude_control)
    if finite(candidate.altitude) and finite(ceiling) and candidate.altitude>ceiling then candidate.altitude=ceiling end
    return self:saveDraft(candidate)
end
-- Summary: Check destination, vessel and propulsion readiness for route engagement.
function AP:ready(io,controls,now,destination,allowAnchorRelease)
    if not self:validDraft(destination or self.draft) then return false,"SET DESTINATION X/Z, CRUISE SPEED AND ALTITUDE" end
    if io.positionAnchor and io.positionAnchor.active and not allowAnchorRelease then return false,"RELEASE ANCHOR BEFORE ENGAGING AUTOPILOT" end
    if not io.thrust or (self.config.thrust or {}).enabled~=true then return false,"ENABLE PROPULSION FIRST" end
    local ready,why=io.thrust:activationReady(io,now,controls);if not ready then return false,why end
    local v,reason=Anchor.new(self.config):telemetry(io,now);if not v then return false,reason end
    local c=self.config.thrust
    if not (c.speed_control_enabled or c.speed_control_verified) or not (c.heading_control_enabled or c.heading_control_verified) then return false,"ENABLE SPEED AND HEADING CONTROL" end
    if not finite(v.heading) or not finite(v.forwardSpeed) then return false,"HEADING / SIGNED SPEED UNAVAILABLE" end
    return true
end
-- Summary: Capture route-start observations and initialize heading/speed acquisition.
function AP:engage(io,controls,now)
    if self.active then return false,"AUTOPILOT ALREADY ACTIVE" end
    local ready,why=self:ready(io,controls,now);if not ready then return false,why end
    if io.positionAnchor and io.positionAnchor.active then return false,"RELEASE ANCHOR BEFORE ENGAGING AUTOPILOT" end
    self.route={entries={{name=AP.label(self.draft),x=self.draft.x,z=self.draft.z,arrival="anchor"}},index=1}
    self.remoteOwner=nil
    self.cruiseSpeed=self.draft.cruiseSpeed;self.uuid=io.vessel.uuid
    self.start={x=io.vessel.position.x,z=io.vessel.position.z};self.active=true;self.state="ACQ"
    self.engagedAt=now;self.updatedAt=nil
    -- Impacts measured before engagement do not stop this route.
    self.impactSeqAtEngage=AP.impactSeq(io)
    do
        local tx,tz=self.draft.x-self.start.x,self.draft.z-self.start.z
        self.distance=math.sqrt(tx*tx+tz*tz);self.crossTrack=0
        self.headingTarget=self.distance>.01 and bearing(tx,tz) or io.vessel.heading
    end
    self.reason=nil;self.since=nil;self.recoveryAttempts=0;self.nextRecoveryAttemptAt=nil
    self.routeHeading=self.headingTarget
    self.headingBias=0
    self.acqSince=now
    self.acqDetail=nil
    self:resetGuidance("ACQ")
    local ceiling=Controls.altitudeCeiling(self.config.altitude_control)
    controls.targets.altitude=finite(ceiling) and math.min(self.draft.altitude,ceiling) or self.draft.altitude
    io.thrust:resetSpeedLoop();io.thrust:resetHeadingLoop()
    log(self,"ENGAGED: "..AP.label(self.draft));return true,"AUTOPILOT ENGAGED"
end
-- Summary: Set a SEL heading target to the autopilot's heading, so she keeps that heading after the handover.
function AP:handHeadingToPilot(io,controls)
    if not (controls and controls.modes and controls.modes.heading=="SEL" and finite(self.headingTarget)) then return end
    controls.targets.heading=self.headingTarget;controls.headingTargetUuid=self.uuid
    if io.thrust and type(io.thrust.resetHeadingLoop)=="function" then io.thrust:resetHeadingLoop() end
end
-- Summary: End route guidance and hand live demands back to the pilot's levers at their current position.
function AP:cancel(io,controls,reason,brake)
    -- End a one-off remote command without retaining its destination.
    if self.remoteOwner then self.route=nil end
    self.remoteOwner=nil
    local active=self.active;self.active=false;self.state="OFF";self.since=nil;self.reason=reason
    self.primaryIdle=false
    self.captureSettledSeconds=0
    self:resetDriftTrend()
    if controls and brake~=false then
        -- Keep the pilot's selections; only live authority is handed back.
        -- Levers act at their current position from the next sample.
        controls.request=0;controls.yaw=0;controls.holds={}
        if type(controls.noteHandover)=="function" then controls:noteHandover() end
        if controls.lateral then controls.lateral:cancel() end
        controls.modes.lateral="MANUAL"
        if active then self:handHeadingToPilot(io,controls) end
        if io.thrust then
            io.thrust:resetSpeedLoop();io.thrust:resetHeadingLoop()
            io.thrust:resetManualAccelerationLoop()
        end
    end
    if active then log(self,reason or "DISENGAGED; SELECTED MODES RETAINED") end
end
-- Summary: Sequence number of the latest POSSIBLE IMPACT from the motion monitor, 0 when none.
function AP.impactSeq(io)
    local event=io and io.motionWarnings and io.motionWarnings.lastImpactEvent
    return event and finite(event.seq) and event.seq or 0
end
-- Emergency stop after a measured sudden change in speed or rotation (collision or
-- similar): the route is cancelled, propulsion demand drops to zero (a SEL speed
-- target becomes 0) and the pilot takes over once every lever reads neutral.
-- Summary: End the route after a POSSIBLE IMPACT and hand a stopped ship to the pilot.
function AP:emergencyStop(io,controls,event)
    local reason="EMERGENCY STOP: POSSIBLE IMPACT ("..tostring(event.axis or "MOTION")..")"
    self:cancel(io,controls,reason)
    self.route=nil
    if controls then
        if controls.modes and controls.modes.throttle=="SEL" and controls.targets then controls.targets.speed=0 end
        controls.requireNeutral=true;controls.neutralCause="EMERGENCY STOP"
    end
    log(self,"ROUTE CANCELLED; "..tostring(event.detail or ""))
end
-- Summary: Retain the route and schedule the next counted recovery attempt.
function AP:suspend(now,reason)
    self.since=self.since or now;self.lastAt=nil;self.crossDemand=0;self.reason=reason
    self.primaryIdle=false
    self:resetDriftTrend()
    self.recoveryAttempts=(self.recoveryAttempts or 0)+1
    self.nextRecoveryAttemptAt=now+2
    self.state="RETRYING ("..self.recoveryAttempts..")"
    log(self,self.state..": "..reason)
    return nil,reason
end
-- Section: Acquisition and capture | Fresh-sample settling with primary engines idle.
-- Summary: Clear drift qualification while retaining the route's learned heading bias.
function AP:resetDriftTrend()
    self.driftFiltered=0
    self.driftSign=nil
    self.driftSince=nil
end
-- Summary: Restart heading acquisition and route capture from fresh observations.
function AP:resetGuidance(state)
    self.state=state or "ACQ"
    self.primaryIdle=true
    self.speedTarget=0
    self.crossDemand=0
    self.sideways=0
    self.lastAt=nil
    self.guidanceAt=nil
    self.turnSampleAt=nil
    self.turnHeading=nil
    self.yawRate=nil
    self.turnSettledAt=nil
    self.turnLooseAt=nil
    self.captureSince=nil
    self.captureSettledSeconds=0
    self:resetDriftTrend()
end
-- Summary: Copy pilot selections into the current route's transient propulsion demands.
function AP:guidanceControls(controls)
    local proxy={}
    for key,value in pairs(controls) do proxy[key]=value end
    proxy.modes=copy(controls.modes)
    proxy.targets=copy(controls.targets)
    proxy.modes.heading="SEL"
    proxy.modes.throttle=self.primaryIdle and "DIRECT" or "SEL"
    proxy.targets.heading=self.headingTarget
    proxy.targets.speed=self.speedTarget
    proxy.holdPropulsion=false
    proxy.speedTargetUuid=self.uuid
    proxy.headingTargetUuid=self.uuid
    proxy.request=0
    proxy.yaw=0
    proxy.sideways=clamp(self.sideways or 0,-1,1)
    proxy.routeLateralAuthority=true
    proxy.routeSpeedAuthority=true
    proxy.apPrimaryIdle=self.primaryIdle==true
    proxy.apAcquisition=self.state=="ACQ"
    return proxy
end
-- Summary: Slew route-normal correction and project it onto the vessel's lateral axis.
function AP:updateRouteLateral(v,nx,nz,tuning,dt)
    local wantedSpeed=clamp(-self.crossTrack*tuning.cross_gain,
        -tuning.maximum_cross_speed,tuning.maximum_cross_speed)
    local wanted=clamp(tuning.velocity_gain*(wantedSpeed-self.crossSpeed),-1,1)
    local previous=self.crossDemand or 0
    self.crossDemand=clamp(wanted,previous-tuning.output_slew*dt,previous+tuning.output_slew*dt)
    local forward=v.forwardDirection
    local length=math.sqrt(forward.x^2+forward.z^2)
    self.sideways=self.crossDemand*(nx*(-forward.z)+nz*forward.x)/length
end
-- Section: Cruise compensation | Bounded heading adaptation from sustained lateral demand.
-- The filter time constant is four seconds; its demand deadband is 0.02.
-- Summary: Learn a rate-limited heading bias from a consistent fresh-sample cruise correction.
function AP:updateHeadingBias(v,headingError,yawRate,tuning,dt,newSample)
    if not newSample then return end
    if dt<=0 or self.state~="CRUISE" or v.forwardSpeed<tuning.drift_minimum_speed or
        math.abs(headingError)>3 or not finite(yawRate) or yawRate>.5 or math.abs(self.crossTrack)>4 then
        self:resetDriftTrend()
        return
    end
    local alpha=1-math.exp(-dt/4)
    self.driftFiltered=(self.driftFiltered or 0)+alpha*(self.crossDemand-(self.driftFiltered or 0))
    local signal=self.driftFiltered
    if math.abs(signal)<=.02 then
        self.driftSign=nil
        self.driftSince=nil
        return
    end
    local direction=signal>0 and 1 or -1
    if direction~=self.driftSign then
        self.driftSign=direction
        self.driftSince=v.at
        return
    end
    local qualifiedAt=self.driftSince+tuning.drift_observation_seconds
    local learningSeconds=math.max(0,v.at-math.max(v.at-dt,qualifiedAt))
    self.headingBias=clamp((self.headingBias or 0)+direction*tuning.drift_heading_rate*learningSeconds,
        -tuning.drift_heading_limit,tuning.drift_heading_limit)
end
-- Summary: Advance route heading, speed and arrival guidance from fresh vessel observations.
function AP:update(io,now,controls)
    if not self.active then return controls end
    local impact=io.motionWarnings and io.motionWarnings.lastImpactEvent
    if impact and AP.impactSeq(io)>(self.impactSeqAtEngage or 0) then
        self:emergencyStop(io,controls,impact)
        return nil,self.reason
    end
    if self.since and self.nextRecoveryAttemptAt and now<self.nextRecoveryAttemptAt and self.recoveryObservedAt==(io.vessel or {}).at then return nil,self.reason end
    self.recoveryObservedAt=(io.vessel or {}).at
    self.updatedAt=now
    if (self.config.thrust or {}).enabled~=true then self:cancel(io,controls,"PROPULSION DISABLED",false);return nil,self.reason end
    if io.identityReady~=true then return self:suspend(now,"CORE IDENTITY UNVERIFIED") end
    if type(io.routeAllowed)=="function" then local ok,why=io:routeAllowed();if not ok then return self:suspend(now,why) end end
    if type(io.assemblyGate)=="function" then
        local assembled,why,detail=io:assemblyGate(now)
        if not assembled then
            if detail and detail.state=="DISASSEMBLED" then
                self:cancel(io,controls,"VESSEL DISASSEMBLED; RE-ENGAGEMENT REQUIRED",false)
                return nil,self.reason
            end
            return self:suspend(now,why)
        end
    end
    local currentID=(io.vessel or {}).uuid
    if currentID and self.uuid and currentID~=self.uuid then self:cancel(io,controls,"VESSEL IDENTITY CHANGED",false);return nil,self.reason end
    local v,reason=Anchor.new(self.config):telemetry(io,now);if not v then return self:suspend(now,reason) end
    if v.uuid~=self.uuid then self:cancel(io,controls,"VESSEL IDENTITY CHANGED",false);return nil,self.reason end
    if not controls or controls.available~=true then return self:suspend(now,"COCKPIT INPUTS UNAVAILABLE") end
    for _,role in ipairs(io.thrust.CONTROLLERS) do local ok,issue=io.thrust:controllerReady(role,now);if not ok then return self:suspend(now,role..": "..tostring(issue)) end end
    for _,role in ipairs(io.thrust.UNITS) do
        local node=io.thrust.units[role]
        if not io.thrust:fresh(node,now) or not node.status or node.status.available~=true or #node.status.readings==0 then
            return self:suspend(now,role..": SHAFT SPEED TELEMETRY UNAVAILABLE")
        end
        for _,reading in ipairs(node.status.readings) do
            if not reading.validity or reading.validity.speedRaw~=true or not finite(reading.speedRaw) then
                return self:suspend(now,role..": SHAFT SPEED TELEMETRY INVALID")
            end
        end
    end
    if self.since or self.state=="RECOVERING" then
        log(self,"TELEMETRY RECOVERED; REACQUIRING RETAINED ROUTE")
        self:resetGuidance("ACQ")
        self.acqSince=now
        io.thrust:resetSpeedLoop()
    end
    self.since=nil;self.reason=nil;self.recoveryAttempts=0
    local entry=self.route.entries[self.route.index]
    local dx,dz=entry.x-v.position.x,entry.z-v.position.z
    self.distance=math.sqrt(dx*dx+dz*dz)
    local tx,tz=entry.x-self.start.x,entry.z-self.start.z
    local length=math.sqrt(tx*tx+tz*tz)
    if length>.01 then tx=tx/length;tz=tz/length else tx=1;tz=0 end
    local along=dx*tx+dz*tz
    local closing=v.linearVelocity.x*tx+v.linearVelocity.z*tz
    local nx,nz=-tz,tx
    self.crossTrack=(v.position.x-self.start.x)*nx+(v.position.z-self.start.z)*nz
    self.crossSpeed=v.linearVelocity.x*nx+v.linearVelocity.z*nz
    local tuning=NavigationSettings.values(self.config,"autopilot")
    self.routeHeading=bearing(tx,tz)
    self.headingBias=clamp(self.headingBias or 0,-tuning.drift_heading_limit,tuning.drift_heading_limit)
    self.headingTarget=(self.routeHeading+self.headingBias)%360
    local headingError=(self.headingTarget-v.heading+180)%360-180
    local previousAt=self.guidanceAt
    local newSample=previousAt==nil or v.at>previousAt
    local gap=previousAt~=nil and (v.at<previousAt or v.at-previousAt>3)
    local dt=newSample and previousAt and not gap and v.at-previousAt or 0
    if gap then
        self.turnSettledAt=nil;self.turnLooseAt=nil;self.captureSince=nil
        self.captureSettledSeconds=0
        self:resetDriftTrend()
    end
    if newSample or gap then self.guidanceAt=v.at end

    local headingAt=((((v.sources or {}).fields or {}).heading or {}).at) or v.at
    local newHeading=self.turnSampleAt==nil or headingAt>self.turnSampleAt
    if newHeading then
        local elapsed=self.turnSampleAt and headingAt-self.turnSampleAt
        self.yawRate=elapsed and elapsed>0 and elapsed<=3 and
            math.abs((v.heading-self.turnHeading+180)%360-180)/elapsed or nil
        self.turnSampleAt=headingAt
        self.turnHeading=v.heading
    end
    local yawRate=self.yawRate

    -- Arrival is a handover: the autopilot disengages and the digital anchor,
    -- engaged at the destination, takes over braking and positioning.
    if self.distance<=tuning.arrival_radius+math.max(0,closing)*2 or along<=0 then
        io.positionAnchor=io.positionAnchor or Anchor.new(self.config)
        if not io.positionAnchor.active then
            local ok,issue=io.positionAnchor:engage(io,now,entry)
            if not ok then return self:suspend(now,issue) end
        end
        self.active=false;self.state="ARRIVED";self.reason=nil
        self.primaryIdle=false
        self.captureSettledSeconds=0
        self:resetDriftTrend()
        log(self,"ARRIVED: "..entry.name.."; ANCHOR ENGAGED AT DESTINATION")
        self:handHeadingToPilot(io,controls)
        return controls
    end

    if self.state~="ACQ" and math.abs(headingError)>10 then
        self:resetGuidance("ACQ")
        self.acqSince=now
        io.thrust:resetSpeedLoop()
        return self:guidanceControls(controls)
    end
    if self.state=="ACQ" then
        self.primaryIdle=true
        self.speedTarget=0;self.crossDemand=0;self.sideways=0
        if newSample and newHeading then
            if finite(yawRate) and math.abs(headingError)<=3 and yawRate<=.5 then
                self.turnSettledAt=self.turnSettledAt or headingAt
            else self.turnSettledAt=nil end
            if finite(yawRate) and math.abs(headingError)<=6 and yawRate<=1 then
                self.turnLooseAt=self.turnLooseAt or headingAt
            else self.turnLooseAt=nil end
            local settled=(self.turnSettledAt and headingAt-self.turnSettledAt>=3) or
                (self.turnLooseAt and headingAt-self.turnLooseAt>=10)
            if settled then
                self.state="CAPTURE"
                self.captureSince=nil
                self.acqSince=nil;self.acqDetail=nil
            end
        end
        if self.state=="ACQ" then
            self.acqDetail=string.format("ACQUIRING HEADING: %.1f DEG OFF, YAW %s DEG/S",
                headingError,finite(yawRate) and string.format("%.2f",yawRate) or "--")
            return self:guidanceControls(controls)
        end
    end

    self:updateRouteLateral(v,nx,nz,tuning,dt)
    if self.state=="CAPTURE" then
        self.primaryIdle=true
        self.speedTarget=0
        if newSample then
            local settled=math.abs(self.crossTrack)<=tuning.capture_position_tolerance and
                math.abs(self.crossSpeed)<=tuning.capture_speed_tolerance and
                math.abs(headingError)<=6 and finite(yawRate) and yawRate<=1
            if settled then
                self.captureSince=self.captureSince or v.at
                self.captureSettledSeconds=v.at-self.captureSince
            else
                self.captureSince=nil
                self.captureSettledSeconds=0
            end
            if self.captureSettledSeconds>=tuning.capture_settle_seconds then
                self.state="ACCEL"
                self.lastAt=v.at
                io.thrust:resetSpeedLoop()
            end
        end
        -- The first positive ramp step follows the next distinct vessel sample.
        return self:guidanceControls(controls)
    end

    local approach=math.sqrt(.16*math.max(0,along-math.max(0,closing)*6))
    local desired=math.min(self.cruiseSpeed,approach)
    local rampDt=newSample and self.lastAt and not gap and clamp(v.at-self.lastAt,0,3) or 0
    self.speedTarget=math.min(desired,(self.speedTarget or 0)+tuning.speed_ramp*rampDt)
    self.primaryIdle=self.primaryIdle==true and self.speedTarget==0
    if approach<self.cruiseSpeed then self.state="DECEL"
    elseif self.speedTarget<self.cruiseSpeed-.01 then self.state="ACCEL"
    -- ACCEL is the initial run-up to cruise speed. Once CRUISE is reached it holds until DECEL;
    -- the speed loop corrects later speed changes, and heading-bias learning (CRUISE only) continues.
    elseif self.state=="CRUISE" then self.state="CRUISE"
    elseif v.forwardSpeed<self.cruiseSpeed-.1 then self.state="ACCEL"
    else self.state="CRUISE" end
    self:updateHeadingBias(v,headingError,yawRate,tuning,dt,newSample)
    self.headingTarget=(self.routeHeading+self.headingBias)%360
    if newSample then self.lastAt=v.at end
    return self:guidanceControls(controls)
end
function AP:checkpoint()
    -- Remote CMD has no persistent route checkpoint.
    if not self.active or self.remoteOwner then return nil end
    return {route=copy(self.route),cruiseSpeed=self.cruiseSpeed,uuid=self.uuid,start=copy(self.start),
        headingTarget=self.headingTarget,headingBias=self.headingBias,remoteOwner=self.remoteOwner}
end
-- Summary: Validate and restore the retained route into its recovery phase.
function AP:restore(state)
    local entry=type(state)=="table" and type(state.route)=="table" and type(state.route.entries)=="table" and state.route.entries[1]
    if not Library.validEntry(entry) or state.route.index~=1 or entry.arrival~="anchor" or
        not finite(state.cruiseSpeed) or state.cruiseSpeed<.1 or
        state.cruiseSpeed>math.min(30,(self.config.cockpit or {}).maximum_selected_speed or 30) or
        type(state.uuid)~="string" or state.uuid=="" or type(state.start)~="table" or
        not finite(state.start.x) or not finite(state.start.z) or math.abs(state.start.x)>30000000 or math.abs(state.start.z)>30000000 or
        #state.route.entries~=1 or (state.headingTarget~=nil and not finite(state.headingTarget)) then return false end
    local tuning=NavigationSettings.values(self.config,"autopilot")
    local bias=state.headingBias==nil and 0 or state.headingBias
    if not finite(bias) or math.abs(bias)>tuning.drift_heading_limit then return false end
    self.route=copy(state.route);self.cruiseSpeed=state.cruiseSpeed;self.uuid=state.uuid;self.start=copy(state.start)
    self.headingBias=bias
    self.headingTarget=state.headingTarget
    self.remoteOwner=type(state.remoteOwner)=="string" and #state.remoteOwner<=80 and state.remoteOwner or nil
    self.active=true
    self:resetGuidance("RECOVERING")
    return true
end
-- Summary: Build current route progress, destination and engagement availability.
function AP:snapshot(io,controls,now)
    local ready,why=self:ready(io,controls,now)
    local reason=self.reason
    if self.active and finite(now) then
        -- Route guidance runs in the propulsion worker. If it has not run
        -- recently, say so instead of showing a silent, blank ACQ.
        local last=self.updatedAt or self.engagedAt
        if finite(last) and now-last>3 then
            reason="AUTOPILOT NOT UPDATING: "..tostring(io.propulsionWorkerError or "PROPULSION WORKER STALLED")
        elseif not reason and self.state=="ACQ" and finite(self.acqSince) and now-self.acqSince>20 then
            local heading=io.thrust and io.thrust.headingControl
            if heading and heading.available~=true and heading.reason then
                reason="HEADING CONTROL: "..tostring(heading.reason)
            else reason=self.acqDetail end
        end
        local entry=self.route and self.route.entries and self.route.entries[self.route.index or 1]
        local p=io.vessel and io.vessel.position
        if entry and type(p)=="table" and finite(p.x) and finite(p.z) and not finite(self.distance) then
            local dx,dz=entry.x-p.x,entry.z-p.z
            self.distance=math.sqrt(dx*dx+dz*dz)
            if not finite(self.headingTarget) and self.distance>.01 then self.headingTarget=bearing(dx,dz) end
        end
    end
    local draft=copy(self.draft);draft.altitude=draft.altitude or controls.targets.altitude
    draft.label=AP.label(draft)
    return {active=self.active,state=self.state,reason=reason,available=ready and not self.active,
        engageReason=why,destination=draft,route=copy(self.route),distance=self.distance,
        cruiseSpeed=self.cruiseSpeed,requestedSpeed=self.speedTarget,requestedHeading=self.headingTarget,
        crossTrack=self.crossTrack,crossSpeed=self.crossSpeed,sidewaysDemand=self.sideways,
        routeHeading=self.routeHeading,headingBias=self.headingBias or 0,primaryIdle=self.primaryIdle==true,
        captureSettledSeconds=self.captureSettledSeconds or 0,
        captureSettleSeconds=NavigationSettings.values(self.config,"autopilot").capture_settle_seconds,
        library=self.library:snapshot(now)}
end
AP.bearing=bearing
return AP
