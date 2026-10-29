-- @ama-section: Motion advisories | Measured impact and sustained-obstruction evidence.
-- Advisory motion monitoring. Cached measurements/readbacks only: no actuator,
-- peripheral, filesystem, route, mode, or flight-authority writes.
local M={};M.__index=M
local RULES={
    sample_age_seconds={1.5,.1,5},sample_gap_seconds={1.25,.1,3},warmup_seconds={2,0,10},
    impact_delta_speed={4,.5,100},impact_acceleration={8,1,200},
    impact_heading_degrees={15,1,180},impact_yaw_rate={30,5,360},
    impact_delta_yaw_rate={12,1,360},impact_angular_acceleration={25,1,1000},
    impact_hold_seconds={10,1,60},impact_cooldown_seconds={15,1,120},
    obstruction_seconds={10,3,120},applied_fraction={.5,.1,1},
    stationary_speed={.15,.01,1},stationary_acceleration={.05,.001,1},
    stationary_yaw_rate={.1,.01,2},stationary_yaw_acceleration={.1,.01,5},
}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function sign(n) return n>0 and 1 or (n<0 and -1 or 0) end
local function vector(v) return type(v)=="table" and finite(v.x) and finite(v.y) and finite(v.z) end
local function norm(v) return math.sqrt(v.x*v.x+v.y*v.y+v.z*v.z) end
local function copy(t) local r={};for k,v in pairs(t or {}) do r[k]=v end;return r end
local function stamp(v,key)
    local field=(((v.sources or {}).fields or {})[key])
    if type(field)=="table" then
        return field.at,field.source,field.source~="UNAVAILABLE" and (v.validFields or {})[key]~=false
    end
    return v.at,"LEGACY",true
end
-- @ama-section: Motion advisories | Measured impact and sustained-obstruction evidence.
-- @ama-summary: Validate motion-advisory settings and initialize measurement history.
function M.new(options)
    options=options or {};local config=options.config or {}
    local self=setmetatable({config={},valid=true,tracks={},events=0,logger=options.logger},M)
    if type(config)~="table" then config={};self.valid=false end
    if config.enabled~=nil and type(config.enabled)~="boolean" then self.valid=false end
    self.enabled=config.enabled~=false
    for key,r in pairs(RULES) do
        local value=config[key];if value==nil then value=r[1] end
        if not finite(value) or value<r[2] or value>r[3] then self.valid=false;value=r[1] end
        self.config[key]=value
    end
    return self
end
function M:settings() local r=copy(self.config);r.enabled=self.enabled;r.valid=self.valid;return r end
-- @ama-summary: Record a changed motion advisory with its measured axis and event time.
function M:emit(kind,axis,now,detail)
    self.events=self.events+1
    self.lastEvent={seq=self.events,kind=kind,axis=axis,at=now,detail=detail}
    local logger=self.logger or (os and os.__amaryllisLog)
    if type(logger)=="function" then
        pcall(logger,"Motion warning "..kind.." ["..axis.."] "..detail,"core.motion-warning")
    end
end
function M:reset(gate)
    if self.obstruction then self:emit("CLEARED",self.obstruction.axis,self.now,"CHECK RESET: "..gate) end
    self.obstruction=nil;self.tracks={};self.previousVelocity=nil;self.previousHeading=nil
    self.warmSince=nil;self.measurements={};self.gate=gate
end
local function freshRole(role,limit)
    return type(role)=="table" and role.available==true and role.statusFresh==true and role.readbackFresh==true
        and role.enabled==true and role.writerEnabled==true and role.ackAccepted~=false
        and finite(role.statusAgeSeconds) and role.statusAgeSeconds<=limit
        and finite(role.readbackAgeSeconds) and role.readbackAgeSeconds+role.statusAgeSeconds<=limit
end
local function applied(role,drive)
    local rb=role.readbacks and role.readbacks[drive]
    local value=role.applied and role.applied[drive]
    if rb and rb.valid==true and finite(value) then return value end
end
-- @ama-summary: Resolve verified applied primary-propeller power for the requested direction.
function M:primaryPower(thrust,direction,cap)
    local power=1
    for _,side in ipairs({"left","right"}) do
        local role=(thrust.roles or {})[side=="left" and "thrust-ls" or "thrust-rs"]
        if not freshRole(role,self.config.sample_age_seconds) or role.directionVerified~=true then return end
        local value=applied(role,"primary-"..side)
        if not value or value*direction<cap*self.config.applied_fraction then return end
        power=math.min(power,math.abs(value)/cap)
    end
    return power
end
-- @ama-summary: Resolve verified applied lateral-propeller power for the requested maneuver.
function M:lateralPower(thrust,cap)
    local count,power=0,0
    for _,q in ipairs({"lb","rb","ls","rs"}) do
        local role=(thrust.roles or {})["thrust-"..q]
        if not freshRole(role,self.config.sample_age_seconds) then return end
        for _,side in ipairs({"p","s"}) do
            local drive="lateral-"..q.."-"..side
            local demand=(thrust.requested or {})[drive]
            local value=applied(role,drive)
            if not finite(demand) or not finite(value) then return end
            if math.abs(demand)>=cap*self.config.applied_fraction then
                if value*demand<=0 or math.abs(value)<math.abs(demand)*.9 then return end
                count=count+1;power=math.max(power,math.abs(value)/cap)
            end
        end
    end
    if count>=2 then return power end
end
-- @ama-summary: Track sustained applied demand with insufficient measured motion on one axis.
function M:observe(axis,direction,power,quiet,at,now)
    local track=self.tracks[axis]
    if not direction or direction==0 or not power or not quiet then self.tracks[axis]=nil;return end
    if not track or track.direction~=direction then
        track={direction=direction,since=at,power=power};self.tracks[axis]=track
    end
    track.elapsed=math.max(0,at-track.since);track.power=power
    if track.elapsed>=self.config.obstruction_seconds then
        return {axis=axis,since=now-track.elapsed,elapsed=track.elapsed,power=power}
    end
end
-- @ama-summary: Evaluate fresh motion measurements and update impact/obstruction advisories.
function M:update(snapshot,io,now)
    if not finite(now) then return self:snapshot() end
    self.now=now
    local v=io.vessel or {};local assembly=snapshot.assembly or {}
    if not self.enabled or not self.valid then
        self:reset(not self.valid and "INVALID WARNING CONFIGURATION" or "DISABLED");return self:snapshot()
    end
    if v.valid~=true or type(v.uuid)~="string" or v.uuid=="" or io.identityReady~=true or
        not (assembly.assembled==true or assembly.state=="ASSEMBLED") then
        self:reset("VESSEL / ASSEMBLY UNVERIFIED");return self:snapshot()
    end
    local va,vs,vok=stamp(v,"linearVelocity");local ha,hs,hok=stamp(v,"heading")
    local function current(at) return finite(at) and at<=now and now-at<=self.config.sample_age_seconds end
    if not vector(v.linearVelocity) or not finite(v.heading) or not vok or not hok or not current(va) or not current(ha) then
        self:reset("FRESH VELOCITY / HEADING REQUIRED");return self:snapshot()
    end
    local key=v.uuid.."|"..tostring(vs).."|"..tostring(hs)
    local oldV,oldH=self.previousVelocity,self.previousHeading
    local vdt=oldV and va-oldV.at;local hdt=oldH and ha-oldH.at
    if self.sourceKey~=key or (vdt and (vdt<0 or vdt>self.config.sample_gap_seconds)) or
        (hdt and (hdt<0 or hdt>self.config.sample_gap_seconds)) then
        self:reset("SOURCE / SAMPLE GAP RESET");self.sourceKey=key;oldV=nil;oldH=nil;vdt=nil;hdt=nil
    end
    self.warmSince=self.warmSince or now
    local m=self.measurements or {};self.measurements=m
    local newVelocity=not oldV or va>oldV.at;local newHeading=not oldH or ha>oldH.at
    if not newVelocity and not newHeading then self.gate="WAITING FOR NEW MEASUREMENT";return self:snapshot() end
    if newVelocity then
        m.deltaSpeed=nil;m.acceleration=nil;m.forwardAcceleration=nil
        if oldV and vdt>=.05 then
            m.deltaSpeed=norm({x=v.linearVelocity.x-oldV.value.x,y=v.linearVelocity.y-oldV.value.y,z=v.linearVelocity.z-oldV.value.z})
            m.acceleration=m.deltaSpeed/vdt
            if finite(v.forwardSpeed) and finite(oldV.forward) then m.forwardAcceleration=(v.forwardSpeed-oldV.forward)/vdt end
        end
        self.previousVelocity={at=va,value={x=v.linearVelocity.x,y=v.linearVelocity.y,z=v.linearVelocity.z},forward=v.forwardSpeed}
    end
    if newHeading then
        m.headingDelta=nil;m.angularAcceleration=nil
        if oldH and hdt>=.05 then
            m.headingDelta=(v.heading-oldH.value+180)%360-180
            local yaw=m.headingDelta/hdt
            if finite(oldH.rate) then m.angularAcceleration=(yaw-oldH.rate)/hdt;m.deltaYawRate=yaw-oldH.rate end
            m.yawRate=yaw
        else m.yawRate=nil;m.deltaYawRate=nil end
        self.previousHeading={at=ha,value=v.heading,rate=m.yawRate}
    end
    if now-self.warmSince<self.config.warmup_seconds then self.gate="MEASUREMENT WARMUP";return self:snapshot() end
    self.gate="MONITORING"
    local hardLinear=newVelocity and finite(m.deltaSpeed) and m.deltaSpeed>=self.config.impact_delta_speed and
        m.acceleration>=self.config.impact_acceleration
    local hardRotation=newHeading and ((finite(m.headingDelta) and math.abs(m.headingDelta)>=self.config.impact_heading_degrees and
        math.abs(m.yawRate)>=self.config.impact_yaw_rate) or
        (finite(m.deltaYawRate) and math.abs(m.deltaYawRate)>=self.config.impact_delta_yaw_rate and
         math.abs(m.angularAcceleration)>=self.config.impact_angular_acceleration))
    if (hardLinear or hardRotation) and (not self.lastImpact or now-self.lastImpact>=self.config.impact_cooldown_seconds) then
        self.lastImpact=now;self.impact={axis=hardLinear and "MOTION" or "ROTATION",at=now,untilAt=now+self.config.impact_hold_seconds}
        self:emit("POSSIBLE IMPACT",self.impact.axis,now,string.format("DELTA V %.2f; ACC %.2f; YAW %.2f; ANG ACC %.2f",
            m.deltaSpeed or 0,m.acceleration or 0,m.yawRate or 0,m.angularAcceleration or 0))
    end
    local anchored=io.anchor=="ANCHORED" or io.anchor=="BRAKING" or (io.positionAnchor or {}).active==true
    local thrust=snapshot.thrust or {};local request=thrust.request or {}
    if anchored or thrust.available~=true or (snapshot.emergencyLift or {}).latched==true then
        self.tracks={};self.gate=anchored and "ANCHOR ENGAGED" or "PROPULSION NOT ACTIVE"
        if self.obstruction then self:emit("CLEARED",self.obstruction.axis,now,self.gate) end
        self.obstruction=nil;return self:snapshot()
    end
    local limits=(io.config or {}).thrust or {};local candidate
    local yaw=finite(request.yawDemand) and request.yawDemand or 0
    local side=finite(request.sideDemand) and request.sideDemand or 0
    local mode=thrust.mode or (snapshot.modes or {}).throttle
    local speed=thrust.speedControl or {};local manual=thrust.manualAcceleration or {}
    local intent=0
    if mode=="SEL" and speed.available==true and finite(speed.targetSpeed) and math.abs(speed.targetSpeed)>=1 then intent=sign(speed.targetSpeed)
    elseif mode=="DIRECT" and finite(request.directDriveRequest) then intent=sign(request.directDriveRequest)
    elseif mode=="MANUAL" and manual.available==true and finite(manual.targetAcceleration) and math.abs(manual.targetAcceleration)>=.02 then
        intent=sign(manual.targetAcceleration)
    end
    local forward=finite(v.forwardSpeed) and v.forwardSpeed or nil
    local quietForward=forward and math.abs(forward)<=self.config.stationary_speed and
        finite(m.forwardAcceleration) and math.abs(m.forwardAcceleration)<=self.config.stationary_acceleration and
        forward*intent>=-.02 and math.abs(yaw)<.25 and math.abs(side)<.25 and
        finite(m.yawRate) and math.abs(m.yawRate)<.5
    if newVelocity then
        local cap=finite(limits.primary_max_rpm) and limits.primary_max_rpm/256 or nil
        local power=cap and cap>0 and intent~=0 and self:primaryPower(thrust,intent,cap) or nil
        candidate=self:observe("FORWARD",intent,power,quietForward,va,now)
    end
    local lateralCap=finite(limits.lateral_max_rpm) and limits.lateral_max_rpm/256 or nil
    local lateralPower=lateralCap and lateralCap>0 and self:lateralPower(thrust,lateralCap) or nil
    if newHeading then
        local quietYaw=finite(m.yawRate) and math.abs(m.yawRate)<=self.config.stationary_yaw_rate and
            finite(m.angularAcceleration) and math.abs(m.angularAcceleration)<=self.config.stationary_yaw_acceleration
        local turn=self:observe("TURNING",math.abs(yaw)>=.5 and sign(yaw) or 0,lateralPower,quietYaw,ha,now)
        candidate=candidate or turn
    end
    if newVelocity then
        local f=v.forwardDirection;local sideways
        if vector(f) and v.velocityFrameVerified==true then
            local horizontal=math.sqrt(f.x*f.x+f.z*f.z)
            if horizontal>.1 then sideways=(-f.z*v.linearVelocity.x+f.x*v.linearVelocity.z)/horizontal end
        end
        local quietSide=finite(sideways) and math.abs(sideways)<=self.config.stationary_speed and
            finite(m.acceleration) and m.acceleration<=self.config.stationary_acceleration and
            math.abs(yaw)<.25 and finite(m.yawRate) and math.abs(m.yawRate)<.5
        local lateral=self:observe("SIDEWAYS",math.abs(side)>=.5 and sign(side) or 0,lateralPower,quietSide,va,now)
        candidate=candidate or lateral
    end
    -- A different-rate sensor does not clear a still-valid established warning.
    if not candidate and self.obstruction then
        local track=self.tracks[self.obstruction.axis]
        if track and (not newVelocity and self.obstruction.axis~="TURNING" or not newHeading and self.obstruction.axis=="TURNING") then
            candidate=self.obstruction
        end
    end
    if candidate and (not self.obstruction or self.obstruction.axis~=candidate.axis) then
        self:emit("POSSIBLE OBSTRUCTION",candidate.axis,now,string.format("APPLIED %.0f%%; NO RESPONSE %.1f S",
            candidate.power*100,candidate.elapsed))
    elseif not candidate and self.obstruction then self:emit("CLEARED",self.obstruction.axis,now,"MOTION OR DEMAND CHANGED") end
    self.obstruction=candidate
    return self:snapshot()
end
-- @ama-summary: Return the current bounded operation state and available status details.
function M:snapshot()
    local now=self.now or 0;local impact=self.impact and now<self.impact.untilAt and self.impact or nil
    local obstruction=self.obstruction
    local watched=obstruction
    if not watched then
        for _,track in pairs(self.tracks) do
            if not watched or (track.elapsed or 0)>(watched.elapsed or 0) then watched=track end
        end
    end
    local active=impact or obstruction
    return {available=self.enabled and self.valid,active=active~=nil,
        text=impact and "POSSIBLE IMPACT" or (obstruction and "POSSIBLE OBSTRUCTION" or nil),
        tone=impact and "red" or (obstruction and "yellow" or nil),axis=active and active.axis,
        since=impact and impact.at or (obstruction and obstruction.since),gate=self.gate,
        event=copy(self.lastEvent),eventSeq=self.events,measurements=copy(self.measurements),
        appliedPower=watched and watched.power,obstructionSeconds=watched and watched.elapsed}
end
return M
