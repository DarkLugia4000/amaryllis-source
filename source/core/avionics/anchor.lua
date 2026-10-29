-- @ama-section: Position guidance | Captured world point, braking and return demand.
-- Navigator information anchor retry revision v1
-- Horizontal position authority. Integrals live in world coordinates so
-- changing heading never rotates accumulated correction into the wrong axis.
local Anchor={}
local NavigationSettings=require("avionics.navigation_settings")
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function clamp(n,a,b) return math.max(a,math.min(b,n)) end
local function copy(v)
    if type(v)~="table" then return v end
    local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r
end
local function log(self,message)
    if self.logged==message then return end
    self.logged=message
    local logger=os and os.__amaryllisLog
    if type(logger)=="function" then logger("Core anchor: "..message,"core.anchor")
    else print("Core anchor: "..message) end
end
function Anchor.new(config)
    return setmetatable({config=config,active=false,state="OFF",integral={x=0,z=0},
        output={x=0,z=0}},{__index=Anchor})
end
-- @ama-section: Position guidance | Captured world point, braking and return demand.
-- @ama-summary: Validate current world position, velocity and vessel orientation for position guidance.
function Anchor:telemetry(io,now)
    local v=io.vessel or {};local p=v.position;local velocity=v.linearVelocity;local f=v.forwardDirection
    local stale=(self.config.network or {}).sensor_stale_seconds or 3
    if v.valid~=true or not finite(v.at) or now<v.at or now-v.at>stale then return nil,"VESSEL TELEMETRY STALE" end
    if type(v.uuid)~="string" or v.uuid=="" then return nil,"VESSEL IDENTITY UNVERIFIED" end
    if v.positionUnavailable==true then return nil,"ABSOLUTE POSITION UNAVAILABLE; SENSOR FALLBACK" end
    if type(p)~="table" or not finite(p.x) or not finite(p.z) then return nil,"WORLD POSITION UNAVAILABLE" end
    if v.velocityFrameVerified~=true or type(velocity)~="table" or
        not finite(velocity.x) or not finite(velocity.z) then return nil,"WORLD VELOCITY UNAVAILABLE" end
    if v.geometryVerified~=true or type(f)~="table" or not finite(f.x) or not finite(f.z) then
        return nil,"VESSEL ORIENTATION UNAVAILABLE"
    end
    local length=math.sqrt(f.x*f.x+f.z*f.z)
    if length<.1 then return nil,"VESSEL BOW NEAR VERTICAL" end
    local fields=(v.sources or {}).fields
    if fields then
        local at=v.at
        for _,key in ipairs({"position","linearVelocity","heading"}) do
            local measured=(fields[key] or {}).at
            if finite(measured) then
                if now<measured or now-measured>stale then return nil,"POSITION GUIDANCE MEASUREMENT STALE" end
                at=math.min(at,measured)
            end
        end
        local coherent={};for key,value in pairs(v) do coherent[key]=value end
        coherent.at=at;v=coherent
    end
    return v,{x=f.x/length,z=f.z/length}
end
-- @ama-summary: Capture the current world position and initialize anchor braking.
function Anchor:engage(io,now,point)
    if self.active then return false,"ANCHOR ALREADY ENGAGED; RELEASE BEFORE RECAPTURING" end
    local v,why=self:telemetry(io,now);if not v then return false,why end
    if point and (type(point)~="table" or not finite(point.x) or not finite(point.z) or
        math.abs(point.x)>30000000 or math.abs(point.z)>30000000) then return false,"ANCHOR POINT INVALID" end
    self.active=true;self.point={x=point and point.x or v.position.x,z=point and point.z or v.position.z};self.uuid=v.uuid
    self.integral={x=0,z=0};self.output={x=0,z=0};self.lastAt=nil;self.lastVelocity=nil;self.acceleration=nil
    self.state="BRAKING";self.reason=nil;self.since=nil;self.recoveryAttempts=0;self.nextRecoveryAttemptAt=nil;self.settledAt=nil;self.captureThrustCleared=nil;self.captured=nil
    log(self,"ENGAGED AT X "..self.point.x.." Z "..self.point.z)
    return true,"ANCHOR ENGAGED"
end
-- @ama-summary: Release position guidance through the pilot's neutral-input handover.
function Anchor:cancel(controls,reason)
    local wasActive=self.active
    self.active=false;self.state="OFF";self.reason=reason
    self.point=nil;self.uuid=nil;self.lastAt=nil;self.since=nil;self.settledAt=nil;self.captured=nil
    self.integral={x=0,z=0};self.output={x=0,z=0}
    if wasActive and controls then
        -- Release preserves selection and requires a neutral-input handover.
        -- Preserve the pilot's selected throttle mode and target.
        controls.request=0;controls.yaw=0;controls.requireNeutral=true;controls.waitHeading=true
        controls.waitThrottle=true;controls.waitSpeedSelection=true
        controls.holds.speed=nil
    end
    if wasActive then log(self,reason or "RELEASED; SELECTED MODE RETAINED; NEUTRAL REQUIRED") end
end
-- @ama-summary: Retain the anchor point and schedule the next counted recovery attempt.
function Anchor:suspend(now,reason)
    self.since=self.since or now;self.reason=reason
    self.recoveryAttempts=(self.recoveryAttempts or 0)+1
    self.nextRecoveryAttemptAt=now+2
    self.state="RETRYING ("..self.recoveryAttempts..")"
    self.lastAt=nil;self.integral={x=0,z=0};self.output={x=0,z=0};self.settledAt=nil
    log(self,self.state..": "..reason)
    return nil,reason
end
-- @ama-summary: Compute bounded braking and return demand toward the retained anchor point.
function Anchor:update(io,now,controls)
    if not self.active then return nil,"ANCHOR OFF" end
    if self.since and self.nextRecoveryAttemptAt and now<self.nextRecoveryAttemptAt and self.recoveryObservedAt==(io.vessel or {}).at then return nil,self.reason end
    self.recoveryObservedAt=(io.vessel or {}).at
    if (self.config.thrust or {}).enabled~=true then self:cancel(controls,"PROPULSION DISABLED");return nil,self.reason end
    if io.identityReady~=true then return self:suspend(now,"CORE IDENTITY UNVERIFIED") end
    if type(io.assemblyGate)=="function" then
        local ok,why=io:assemblyGate(now)
        if not ok then return self:suspend(now,why or "VESSEL ASSEMBLY UNAVAILABLE") end
    end
    local currentID=(io.vessel or {}).uuid
    if currentID and self.uuid and currentID~=self.uuid then self:cancel(controls,"VESSEL IDENTITY CHANGED");return nil,self.reason end
    local v,forward=self:telemetry(io,now)
    if not v then return self:suspend(now,forward) end
    if v.uuid~=self.uuid then self:cancel(controls,"VESSEL IDENTITY CHANGED");return nil,self.reason end
    if not controls or controls.available~=true then return self:suspend(now,"COCKPIT INPUTS UNAVAILABLE") end
    -- Provider failures pause integration too. The propulsion layer continues
    -- rediscovery and command recovery; there is no retry-count lockout.
    for _,role in ipairs(io.thrust.CONTROLLERS or {}) do
        local ready,why=io.thrust:controllerReady(role,now)
        if not ready then return self:suspend(now,role..": "..tostring(why)) end
    end
    if self.since then log(self,"TELEMETRY RECOVERED; RETURNING TO RETAINED ANCHOR POINT") end
    self.since=nil;self.reason=nil;self.recoveryAttempts=0
    local ex,ez=self.point.x-v.position.x,self.point.z-v.position.z
    local distance=math.sqrt(ex*ex+ez*ez)
    local speed=math.sqrt(v.linearVelocity.x^2+v.linearVelocity.z^2)
    self.distance=distance;self.horizontalSpeed=speed
    local tuning=NavigationSettings.values(self.config,"anchor")
    local thrustConfig=self.config.thrust or {}
    local anchorConfig=((self.config.navigation or {}).anchor) or {}
    -- Her drag (time constant about 5.5 s) holds most of the position by
    -- itself: coasting from v she travels about v*tau and stops. So the hold
    -- works with drag instead of against it:
    --  * Return: a small speed toward the point (position_gain per block,
    --    at most maximum_speed), driven by the cruise thrust for that speed
    --    plus a little velocity feedback. A correction never reverses the
    --    shafts; if one would, she coasts instead.
    --  * Brake: only when she is moving more than brake_margin_bps faster
    --    than the return speed (she is "at speed"), proportional to that
    --    excess like the SEL 0 brake, fading to zero as she slows.
    -- Inside the position tolerance nothing is commanded at all.
    local tau=finite(thrustConfig.drag_time_constant_seconds) and clamp(thrustConfig.drag_time_constant_seconds,1,60) or 5.5
    local margin=finite(anchorConfig.brake_margin_bps) and math.max(0,anchorConfig.brake_margin_bps) or 1
    local brakeGain=finite(anchorConfig.brake_gain) and clamp(anchorConfig.brake_gain,0,1) or
        (finite(thrustConfig.zero_brake_gain) and clamp(thrustConfig.zero_brake_gain,0,1) or 0.06)
    local dt=self.lastAt and v.at-self.lastAt or 0
    local stale=(self.config.network or {}).sensor_stale_seconds or 3
    if dt<0 or dt>stale then dt=0;self.output={x=0,z=0} end
    dt=math.min(dt,3)
    -- Act on her velocity now, not the sample's: decay it by drag over the
    -- sample age (thrust here is small by design).
    local age=clamp(now-v.at,0,10)
    local decay=math.exp(-age/tau)
    local vx,vz=v.linearVelocity.x*decay,v.linearVelocity.z*decay
    local side={x=-forward.z,z=forward.x}
    local vf=vx*forward.x+vz*forward.z
    local vs=vx*side.x+vz*side.z
    local ef=ex*forward.x+ez*forward.z
    local es=ex*side.x+ez*side.z
    -- Once captured inside the position tolerance, drift is left to drag
    -- until it exceeds the hold band (hold_band_blocks, default 2): a
    -- half-block correction would cost a shaft reversal each way.
    local holdBand=finite(anchorConfig.hold_band_blocks) and math.max(tuning.position_tolerance,anchorConfig.hold_band_blocks) or
        math.max(2,tuning.position_tolerance)
    if distance<=tuning.position_tolerance then self.captured=true elseif distance>holdBand then self.captured=nil end
    local inside=distance<=tuning.position_tolerance or self.captured==true
    if not self.captureThrustCleared and inside and speed<=tuning.speed_tolerance then self.captureThrustCleared=true end
    local function returnSpeed(e)
        if self.velocityOnly or inside then return 0 end
        return clamp(e*tuning.position_gain,-tuning.maximum_speed,tuning.maximum_speed)
    end
    -- @ama-summary: Calculate a bounded axis correction from position and velocity error.
    local function axis(e,measured,allowReverse,feedForward)
        local wanted=returnSpeed(e)
        local excess=measured-wanted
        if math.abs(excess)>margin and measured*excess>0 then
            -- At speed: brake against the motion, proportional to the excess.
            return -(excess>0 and 1 or -1)*clamp(brakeGain*(math.abs(excess)-margin),0,1),"BRAKE"
        end
        if wanted==0 then return 0,"COAST" end
        local out=feedForward*wanted+tuning.velocity_kp*(wanted-measured)
        if not allowReverse then
            if wanted>0 then out=clamp(out,0,1) else out=clamp(out,-1,0) end
        end
        return clamp(out,-1,1),"RETURN"
    end
    local ffGain=io.thrust and io.thrust.speedFeedforwardGain and io.thrust:speedFeedforwardGain(returnSpeed(ef)) or 0.031
    -- Primary shafts reverse slowly: no reversal for a return correction.
    local alongDemand,alongMode=axis(ef,vf,false,ffGain)
    -- Lateral pairs need no gearshift; they are fixed-direction units.
    local sideDemand,sideMode=axis(es,vs,true,0)
    self.mode={along=alongMode,side=sideMode}
    local demand={x=alongDemand*forward.x+sideDemand*side.x,z=alongDemand*forward.z+sideDemand*side.z}
    if dt>0 then
        for _,key in ipairs({"x","z"}) do
            self.output[key]=clamp(demand[key],self.output[key]-tuning.output_slew*dt,self.output[key]+tuning.output_slew*dt)
        end
    elseif not self.lastAt then self.output={x=0,z=0} end
    self.lastAt=v.at
    if dt>0 or not self.lastVelocity then self.lastVelocity={x=v.linearVelocity.x,z=v.linearVelocity.z} end
    if self.velocityOnly then
        self.state=speed<=tuning.speed_tolerance and "ANCHORED" or "BRAKING"
    elseif inside and speed<=tuning.speed_tolerance then
        self.settledAt=self.settledAt or now
        self.state=now-self.settledAt>=tuning.settle_seconds and "ANCHORED" or "BRAKING"
    else self.settledAt=nil;self.state=not inside and "RETURNING" or "BRAKING" end
    local proxy={};for k,value in pairs(controls) do proxy[k]=value end
    proxy.modes=copy(controls.modes);proxy.modes.throttle="DIRECT"
    proxy.targets=copy(controls.targets);proxy.waitThrottle=false
    proxy.request=clamp(self.output.x*forward.x+self.output.z*forward.z,-1,1)
    -- Project world correction onto geometric starboard, matching the lateral mixer.
    -- Forward/reverse thrust and yaw retain their existing direction mapping.
    proxy.sideways=clamp(-self.output.x*forward.z+self.output.z*forward.x,-1,1)
    proxy.anchorAuthority=true
    return proxy
end
function Anchor:checkpoint()
    if not self.active then return nil end
    return {point=copy(self.point),uuid=self.uuid}
end
function Anchor:restore(state)
    if type(state)~="table" or type(state.point)~="table" or
        not finite(state.point.x) or not finite(state.point.z) or type(state.uuid)~="string" or state.uuid=="" then return false end
    self.active=true;self.point=copy(state.point);self.uuid=state.uuid
    self.state="RECOVERING";self.lastAt=nil;self.integral={x=0,z=0};self.output={x=0,z=0}
    return true
end
function Anchor:snapshot()
    local tuning=NavigationSettings.values(self.config,"anchor")
    return {active=self.active,state=self.state,point=copy(self.point),reason=self.reason,
        distance=self.distance,horizontalSpeed=self.horizontalSpeed,
        positionTolerance=tuning.position_tolerance,speedTolerance=tuning.speed_tolerance}
end
return Anchor
