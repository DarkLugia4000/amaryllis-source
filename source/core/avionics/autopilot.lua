-- @ama-section: Route guidance | Destination acquisition, cruise and arrival control.
-- Navigator information AP retry revision v1
-- Single-entry route execution; storage, guidance and arrival action are
-- separate so ordered waypoint routes can extend this without changing I/O.
local Anchor=require("avionics.anchor")
local Library=require("avionics.destinations")
local AP={}
local NavigationSettings=require("avionics.navigation_settings")
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function copy(v) if type(v)~="table" then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function clamp(n,a,b) return math.max(a,math.min(b,n)) end
-- @ama-section: Route guidance | Destination acquisition, cruise and arrival control.
-- @ama-summary: Calculate a normalized compass bearing from horizontal displacement.
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
-- @ama-summary: Construct route guidance with its saved draft and destination-library access.
function AP.new(config,storage,deps)
    deps=deps or {}
    local self=setmetatable({config=config,storage=storage,deps=deps,library=Library.new(deps),
        active=false,state="OFF",draft={name="Destination",cruiseSpeed=3},route=nil},{__index=AP})
    local f=deps.fs or fs
    if storage and f and f.exists("/avionics/data/navigation.json") then
        local ok,value=pcall(storage.readJson,"/avionics/data/navigation.json",deps)
        if ok and type(value)=="table" and value.schemaVersion==1 and self:validDraft(value.destination,false) then self.draft=copy(value.destination)
        else self.reason="SAVED NAVIGATION SETTINGS INVALID";log(self,self.reason) end
    end
    return self
end
-- @ama-summary: Validate destination text, coordinates, cruise speed and altitude bounds.
function AP:validDraft(d,complete)
    local c=self.config.cockpit or {};local alt=self.config.altitude_control or {}
    if type(d)~="table" or type(d.name)~="string" or #d.name<1 or #d.name>40 or
        not d.name:match("%S") or d.name:find("[%c]") or not finite(d.cruiseSpeed) or d.cruiseSpeed<.1 or
        d.cruiseSpeed>math.min(30,c.maximum_selected_speed or 30) then return false end
    for _,key in ipairs({"x","z"}) do
        if d[key]==nil and complete~=false then return false end
        if d[key]~=nil and (not finite(d[key]) or math.abs(d[key])>30000000) then return false end
    end
    if d.altitude==nil then return complete==false end
    return finite(d.altitude) and d.altitude>=(alt.minimum_world_y or -64) and d.altitude<=(alt.maximum_world_y or 320)
end
-- @ama-summary: Persist a validated navigator destination draft.
function AP:saveDraft(candidate)
    if not self:validDraft(candidate,false) then return false,"DESTINATION / SPEED / ALTITUDE INVALID" end
    if self.storage then
        local ok,why=self.storage.writeJson("/avionics/data/navigation.json",{schemaVersion=1,destination=candidate},self.deps)
        if not ok then return false,"NAVIGATION SETTINGS NOT SAVED: "..tostring(why) end
    end
    self.draft=copy(candidate);return true,"DESTINATION UPDATED"
end
-- @ama-summary: Apply a permitted destination edit or saved-destination selection.
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
    elseif action.type=="destination_select" then
        self.library:refresh();local selected=self.library.entries[action.index]
        if not selected then return false,self.library.reason or "SELECT A SAVED DESTINATION" end
        candidate.name=selected.name;candidate.x=selected.x;candidate.z=selected.z
    else return false,"UNKNOWN NAVIGATION ACTION" end
    return self:saveDraft(candidate)
end
-- @ama-summary: Check destination, vessel and propulsion readiness for route engagement.
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
-- @ama-summary: Capture route-start observations and initialize heading/speed acquisition.
function AP:engage(io,controls,now)
    if self.active then return false,"AUTOPILOT ALREADY ACTIVE" end
    local ready,why=self:ready(io,controls,now);if not ready then return false,why end
    if io.positionAnchor and io.positionAnchor.active then return false,"RELEASE ANCHOR BEFORE ENGAGING AUTOPILOT" end
    self.route={entries={{name=self.draft.name,x=self.draft.x,z=self.draft.z,arrival="anchor"}},index=1}
    self.remoteOwner=nil
    self.cruiseSpeed=self.draft.cruiseSpeed;self.uuid=io.vessel.uuid
    self.start={x=io.vessel.position.x,z=io.vessel.position.z};self.active=true;self.state="ACQ"
    self.engagedAt=now;self.updatedAt=nil
    do
        local tx,tz=self.draft.x-self.start.x,self.draft.z-self.start.z
        self.distance=math.sqrt(tx*tx+tz*tz);self.crossTrack=0
        self.headingTarget=self.distance>.01 and bearing(tx,tz) or io.vessel.heading
    end
    self.reason=nil;self.since=nil;self.recoveryAttempts=0;self.nextRecoveryAttemptAt=nil;self.lastAt=nil;self.speedTarget=0;self.crossDemand=0;self.turnAnchor=nil;self.turnSettledAt=nil;self.turnSampleAt=nil;self.turnHeading=nil
    -- A previous arrival left arrivalAnchor set; without clearing it a new
    -- route skipped heading acquisition and cancelled as "anchor released".
    self.arrivalAnchor=nil;self.turnLooseAt=nil;self.yawRate=nil;self.acqSince=now;self.acqDetail=nil
    controls.targets.altitude=self.draft.altitude
    io.thrust:resetSpeedLoop();io.thrust:resetHeadingLoop()
    log(self,"ENGAGED: "..self.draft.name);return true,"AUTOPILOT ENGAGED"
end
-- @ama-summary: End route guidance and hand live demands back through the pilot neutral gate.
function AP:cancel(io,controls,reason,brake)
    -- End a one-off remote command without retaining its destination.
    if self.remoteOwner then self.route=nil end
    self.remoteOwner=nil
    local active=self.active;self.active=false;self.state="OFF";self.since=nil;self.reason=reason
    if active and self.arrivalAnchor and io.positionAnchor then io.positionAnchor:cancel(nil,reason) end
    self.arrivalAnchor=nil
    if controls and brake~=false then
        -- Keep the pilot's selections; only live authority is handed back.
        controls.requireNeutral=true;controls.waitThrottle=true;controls.waitHeading=true
        controls.waitThrottle=true;controls.waitHeading=true;controls.waitSpeedSelection=true
        controls.request=0;controls.yaw=0;controls.holds={}
        if controls.lateral then controls.lateral:cancel() end
        controls.modes.lateral="MANUAL"
        if io.thrust then
            io.thrust:resetSpeedLoop();io.thrust:resetHeadingLoop()
            io.thrust:resetManualAccelerationLoop()
        end
    end
    if active then log(self,reason or "DISENGAGED; SELECTED MODES RETAINED") end
end
-- @ama-summary: Retain the route and schedule the next counted recovery attempt.
function AP:suspend(now,reason)
    self.since=self.since or now;self.lastAt=nil;self.crossDemand=0;self.reason=reason
    self.recoveryAttempts=(self.recoveryAttempts or 0)+1
    self.nextRecoveryAttemptAt=now+2
    self.state="RETRYING ("..self.recoveryAttempts..")"
    log(self,self.state..": "..reason)
    return nil,reason
end
-- @ama-summary: Advance route heading, speed and arrival guidance from fresh vessel observations.
function AP:update(io,now,controls)
    if not self.active then return controls end
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
    if self.since then log(self,"TELEMETRY RECOVERED; RESUMING RETAINED DESTINATION") end
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
    self.headingTarget=bearing(tx,tz)
    local headingError=(self.headingTarget-v.heading+180)%360-180
    -- Yaw rate only changes with a new vessel sample (every 1-2 s). Keep the
    -- last measured value instead of reading 0 between samples, which let
    -- the settle check pass while the bow was still swinging.
    local headingAt=((((v.sources or {}).fields or {}).heading or {}).at) or v.at
    if self.turnSampleAt and headingAt>self.turnSampleAt then
        self.yawRate=math.abs((v.heading-self.turnHeading+180)%360-180)/(headingAt-self.turnSampleAt)
    end
    if not self.turnSampleAt or headingAt>self.turnSampleAt then self.turnSampleAt,self.turnHeading=headingAt,v.heading end
    local yawRate=self.yawRate or 0
    if not self.arrivalAnchor and (self.turnAnchor or math.abs(headingError)>10 or
        (self.state=="ACQ" and math.abs(headingError)>3)) then
        if not self.turnAnchor then
            self.turnAnchor=Anchor.new(self.config)
            self.turnAnchor.velocityOnly=true
            local ok,issue=self.turnAnchor:engage(io,now)
            if not ok then self.turnAnchor=nil;return self:suspend(now,issue) end
            self.turnSettledAt=nil;self.turnLooseAt=nil;self.acqSince=self.acqSince or now
            io.thrust:resetSpeedLoop()
        end
        local horizontalSpeed=math.sqrt(v.linearVelocity.x^2+v.linearVelocity.z^2)
        -- Leave acquisition when tightly settled for 3 s (about two vessel
        -- samples), or when held close enough for 10 s. The tight limits
        -- alone (3 deg, 0.1 b/s drift) could hold a 230-block hull in ACQ
        -- indefinitely while heading control hunted or the hull drifted.
        if math.abs(headingError)<=3 and yawRate<=.5 and horizontalSpeed<=.1 then
            self.turnSettledAt=self.turnSettledAt or now
        else self.turnSettledAt=nil end
        if math.abs(headingError)<=6 and yawRate<=1 and horizontalSpeed<=.3 then
            self.turnLooseAt=self.turnLooseAt or now
        else self.turnLooseAt=nil end
        self.acqDetail=string.format("ACQUIRING HEADING: %.1f DEG OFF, YAW %.2f DEG/S, DRIFT %.2f B/S",
            headingError,yawRate,horizontalSpeed)
        local settled=(self.turnSettledAt and now-self.turnSettledAt>=3) or
            (self.turnLooseAt and now-self.turnLooseAt>=10)
        if not settled then
            self.state="ACQ";self.speedTarget=0;self.crossDemand=0;self.lastAt=nil
            local turnControls=copy(controls)
            turnControls.modes.heading="SEL";turnControls.targets.heading=self.headingTarget
            turnControls.headingTargetUuid=self.uuid;turnControls.waitHeading=false;turnControls.yaw=0
            turnControls.apAcquisition=true
            local proxy,issue=self.turnAnchor:update(io,now,turnControls)
            if not proxy then return self:suspend(now,issue) end
            proxy.targets.speed=0;proxy.routeLateralAuthority=true
            self.sideways=proxy.sideways
            return proxy
        end
        self.turnAnchor=nil;self.turnSettledAt=nil;self.turnLooseAt=nil;self.acqSince=nil;self.acqDetail=nil
        self.lastAt=v.at;self.speedTarget=0
        io.thrust:resetSpeedLoop()
    end
    if self.arrivalAnchor or self.distance<=tuning.arrival_radius+math.max(0,closing)*2 or along<=0 then
        io.positionAnchor=io.positionAnchor or Anchor.new(self.config)
        if not self.arrivalAnchor then
            local ok,issue=io.positionAnchor:engage(io,now,entry)
            if not ok then return self:suspend(now,issue) end
            self.arrivalAnchor=true
            log(self,"APPROACH COMPLETE; ANCHORING AT DESTINATION")
        elseif not io.positionAnchor.active then self:cancel(io,controls,"ARRIVAL ANCHOR RELEASED");return controls end
        self.state=io.positionAnchor.state=="ANCHORED" and "ARRIVED" or "DECEL"
        if self.state=="ARRIVED" then
            -- The position anchor now holds the ship on its own.
            self.active=false;self.arrivalAnchor=nil;log(self,"ARRIVED: "..entry.name);return controls
        end
    else
        -- Keep the bow along the route. Correct cross-track displacement with
        -- translation, damping measured sideways motion before crossing it.
        self.headingTarget=bearing(tx,tz)
        local desiredCrossSpeed=clamp(-self.crossTrack*tuning.cross_gain,-tuning.maximum_cross_speed,tuning.maximum_cross_speed)
        local crossWanted=clamp(tuning.velocity_gain*(desiredCrossSpeed-self.crossSpeed),-1,1)
        -- Plan braking to the destination, rather than to the handover
        -- radius. Extra lead starts braking earlier without creating a
        -- zero-speed target just outside anchor capture.
        local approach=math.sqrt(.16*math.max(0,along-math.max(0,closing)*6))
        local desired=math.min(self.cruiseSpeed,approach)
        -- Vessel samples arrive every 1-2 s. A 0.5 s cap made the cruise ramp
        -- and the lateral slew run 2-4x slower than their settings.
        local stale=(self.config.network or {}).sensor_stale_seconds or 3
        -- Cap at 3 s so a long telemetry gap (now tolerated up to the stale
        -- limit) cannot step the speed ramp or lateral slew in one jump.
        local dt=self.lastAt and clamp(v.at-self.lastAt,0,math.min(stale,3)) or 0
        local previous=self.crossDemand or 0
        self.crossDemand=clamp(crossWanted,previous-tuning.output_slew*dt,previous+tuning.output_slew*dt)
        local forward=v.forwardDirection
        local horizontal=math.sqrt(forward.x^2+forward.z^2)
        -- Positive lateral demand accelerates toward geometric starboard.
        -- Preserve negative feedback in world-route coordinates; yaw is separate.
        self.sideways=self.crossDemand*(nx*(-forward.z)+nz*forward.x)/horizontal
        self.speedTarget=math.min(desired,(self.speedTarget or 0)+tuning.speed_ramp*dt)
        if approach<self.cruiseSpeed then self.state="DECEL"
        elseif self.speedTarget<self.cruiseSpeed-.01 or v.forwardSpeed<self.cruiseSpeed-.1 then self.state="ACCEL"
        else self.state="CRUISE" end
    end
    self.lastAt=v.at
    local proxy={};for k,value in pairs(controls) do proxy[k]=value end
    proxy.modes=copy(controls.modes);proxy.modes.throttle="SEL";proxy.modes.heading="SEL"
    proxy.targets=copy(controls.targets);proxy.targets.speed=self.arrivalAnchor and 0 or self.speedTarget
    proxy.targets.heading=self.headingTarget or v.heading
    proxy.waitThrottle=false;proxy.waitHeading=false;proxy.speedTargetUuid=self.uuid;proxy.headingTargetUuid=self.uuid
    proxy.request=0;proxy.yaw=0
    proxy.sideways=self.arrivalAnchor and 0 or clamp(self.sideways or 0,-1,1)
    proxy.routeLateralAuthority=true;proxy.routeSpeedAuthority=true
    return proxy
end
function AP:checkpoint()
    -- Remote CMD has no persistent route checkpoint.
    if not self.active or self.remoteOwner then return nil end
    return {route=copy(self.route),cruiseSpeed=self.cruiseSpeed,uuid=self.uuid,start=copy(self.start),
        arrivalAnchor=self.arrivalAnchor,headingTarget=self.headingTarget,remoteOwner=self.remoteOwner}
end
-- @ama-summary: Validate and restore the retained route into its recovery phase.
function AP:restore(state)
    local entry=type(state)=="table" and type(state.route)=="table" and type(state.route.entries)=="table" and state.route.entries[1]
    if not Library.validEntry(entry) or state.route.index~=1 or entry.arrival~="anchor" or
        not finite(state.cruiseSpeed) or state.cruiseSpeed<.1 or
        state.cruiseSpeed>math.min(30,(self.config.cockpit or {}).maximum_selected_speed or 30) or
        type(state.uuid)~="string" or state.uuid=="" or type(state.start)~="table" or
        not finite(state.start.x) or not finite(state.start.z) or math.abs(state.start.x)>30000000 or math.abs(state.start.z)>30000000 or
        #state.route.entries~=1 or (state.headingTarget~=nil and not finite(state.headingTarget)) then return false end
    self.route=copy(state.route);self.cruiseSpeed=state.cruiseSpeed;self.uuid=state.uuid;self.start=copy(state.start)
    self.arrivalAnchor=state.arrivalAnchor==true;self.headingTarget=state.headingTarget
    self.remoteOwner=type(state.remoteOwner)=="string" and #state.remoteOwner<=80 and state.remoteOwner or nil
    self.active=true;self.state="RECOVERING";self.speedTarget=0;self.crossDemand=0;self.lastAt=nil;return true
end
-- @ama-summary: Build current route progress, destination and engagement availability.
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
    return {active=self.active,state=self.state,reason=reason,available=ready and not self.active,
        engageReason=why,destination=draft,route=copy(self.route),distance=self.distance,
        cruiseSpeed=self.cruiseSpeed,requestedSpeed=self.arrivalAnchor and 0 or self.speedTarget,requestedHeading=self.headingTarget,
        crossTrack=self.crossTrack,crossSpeed=self.crossSpeed,sidewaysDemand=self.sideways,
        library=self.library:snapshot(now)}
end
AP.bearing=bearing
return AP
