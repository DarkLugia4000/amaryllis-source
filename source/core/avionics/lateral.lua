-- @ama-section: Sideways guidance | Selected displacement, braking and pilot handover.
-- Lateral input and guidance only. Actuator authority remains in Thrust.
local Lateral={};Lateral.__index=Lateral
local function finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function delta(a,b) return (a-b+180)%360-180 end
function Lateral.new(config)
 return setmetatable({config=config,mode="MANUAL",state="MANUAL",waitNeutral=true,offset=0,output=0},Lateral)
end
function Lateral:cancel()
 self.mode="MANUAL";self.state="MANUAL";self.offset=0;self.origin=nil;self.pending=false
 self.braking=false;self.output=0;self.integral=0;self.manual=0;self.hold=nil;self.waitNeutral=true
 self.settledAt=nil;self.lastAt=nil;self.turnQuietUntil=nil;self.completedHeading=nil
end
-- @ama-section: Sideways guidance | Selected displacement, braking and pilot handover.
-- @ama-summary: Validate the vessel observations used for sideways position guidance.
function Lateral:telemetry(io,now)
 local v=io.vessel or {};local p=v.position;local vel=v.linearVelocity
 if v.valid~=true or v.geometryVerified~=true or v.velocityFrameVerified~=true or
  not finite(v.at) or now<v.at or now-v.at>((self.config.network or {}).sensor_stale_seconds or 3) or
  not finite(v.heading) or type(v.uuid)~="string" or type(p)~="table" or
  not finite(p.x) or not finite(p.z) or type(vel)~="table" or not finite(vel.x) or not finite(vel.z) then
  return nil,"FRESH LATERAL POSITION / VELOCITY REQUIRED"
 end
 return v
end
-- @ama-summary: Capture the lateral origin for selected sideways travel.
function Lateral:select(mode,io,controls,now)
 if mode~="MANUAL" and mode~="SEL" then return false,"INVALID LATERAL MODE" end
 if io.autopilot and io.autopilot.active or io.positionAnchor and io.positionAnchor.active then
  return false,"AP / ANCHOR OWNS LATERAL CONTROL"
 end
 if mode=="MANUAL" then self:cancel();return true end
 local v,reason=self:telemetry(io,now);if not v then return false,reason end
 self:cancel();self.mode="SEL";self.state="IDLE";self.origin={x=v.position.x,z=v.position.z};self.uuid=v.uuid
 self.completedHeading=(controls.modes.heading=="SEL" and controls.targets.heading or v.heading)
 return true
end
-- @ama-summary: Interpret lateral pilot input into bounded displacement and braking intent.
function Lateral:input(raw,at,dt,blocked)
 if blocked then self:cancel();return end
 local left,right=raw.left_lift>0,raw.right_lift>0
 if not left and not right then self.waitNeutral=false end
 if self.mode=="SEL" and left and right and not self.waitNeutral then
  self.mode="MANUAL";self.offset=0;self.origin=nil;self.pending=false;self.braking=true
  self.state="BRAKING";self.output=0;self.integral=0;self.manual=0;self.waitNeutral=true;self.hold=nil;self.settledAt=nil
  return
 end
 if self.waitNeutral or self.braking then self.manual=0;self.hold=nil;return end
 local direction=left==right and 0 or (right and 1 or -1)
 local c=self.config.cockpit or {}
 if self.mode=="MANUAL" then
  self.manual=direction==0 and 0 or (raw.right_lift-raw.left_lift)/15*(c.lateral_strength_percent or 50)/100
  self.state="MANUAL";return
 end
 if direction==0 then self.hold=nil;return end
 local change=0
 if not self.hold or self.hold.direction~=direction then
  self.hold={direction=direction,start=at};change=direction*(c.lateral_offset_step_blocks or .5)
 else
  local delay=c.lateral_hold_delay_seconds or .5
  local elapsed=math.max(0,at-self.hold.start-delay)-math.max(0,at-math.min(dt,.25)-self.hold.start-delay)
  change=direction*elapsed*(c.lateral_adjustment_blocks_per_second or 1)
 end
 if change~=0 then self.offset=clamp(self.offset+change,-100,100);self.pending=true;self.settledAt=nil end
end
-- @ama-summary: Compute sideways demand and braking from the current offset and velocity.
function Lateral:evaluate(io,now,controls,yaw)
 if controls.lateralStopLock or controls.available~=true or io.autopilot and io.autopilot.active or io.positionAnchor and io.positionAnchor.active then
  self:cancel();return 0
 end
 if self.mode=="MANUAL" and not self.braking then self.output=self.manual or 0;return self.output end
 local v,reason=self:telemetry(io,now)
 if not v or self.uuid and v.uuid~=self.uuid then
  self:cancel();self.state="UNAVAILABLE";self.reason=reason or "VESSEL IDENTITY CHANGED";return 0
 end
 self.reason=nil
 local heading=controls.modes.heading=="SEL" and controls.targets.heading or v.heading
 if not finite(heading) then self:cancel();return 0 end
 local angle=math.rad(heading);local nx,nz=math.cos(angle),math.sin(angle)
 local speed=v.linearVelocity.x*nx+v.linearVelocity.z*nz
 local error=0
 if self.origin then error=self.offset-((v.position.x-self.origin.x)*nx+(v.position.z-self.origin.z)*nz) end
 self.remaining=error;self.speed=speed;self.referenceHeading=heading
 if self.mode=="SEL" and self.completedHeading and math.abs(delta(heading,self.completedHeading))>.1 then self.pending=true end
 local dt=self.lastAt and v.at-self.lastAt or 0
 local rate=self.lastHeading and dt>0 and math.abs(delta(v.heading,self.lastHeading))/dt or 0
 if dt>0 or not self.lastAt then self.lastAt=v.at;self.lastHeading=v.heading end
 dt=clamp(dt,0,.5)
 if self.mode=="SEL" then
  local turning=math.abs(yaw or 0)>.02 or math.abs(controls.yaw or 0)>.02 or rate>.5 or math.abs(delta(heading,v.heading))>3
  if turning then self.turnQuietUntil=now+1 end
  if self.turnQuietUntil and now<self.turnQuietUntil then
   self.output=0;self.integral=0;self.settledAt=nil;self.state="TURNING";return 0
  end
  if not self.pending then self.output=0;self.integral=0;self.state="IDLE";return 0 end
 end
 local settled=math.abs(speed)<=.05 and (self.braking or math.abs(error)<=.2)
 if settled then self.settledAt=self.settledAt or now else self.settledAt=nil end
 if self.settledAt and now-self.settledAt>=1 then
  self.output=0;self.integral=0;self.pending=false;self.completedHeading=heading
  if self.braking then self.braking=false;self.waitNeutral=true;self.state="MANUAL"
  else self.state="IDLE" end
  return 0
 end
 local desired=self.braking and 0 or clamp((error-speed*3)*.25,-.5,.5)
 local velocityError=desired-speed
 local integral=self.integral or 0
 -- Accumulate only during a selected approach. Shed drive bias as soon as
 -- motion requires braking; keep stopping and handover free of stored thrust.
 if self.braking or speed*velocityError<0 or integral*velocityError<0 then integral=0 end
 if not self.braking and not settled then integral=clamp(integral+.08*velocityError*dt,-.15,.15) end
 self.integral=integral
 local wanted=clamp(.4*velocityError+integral,-1,1)
 self.output=clamp(wanted,(self.output or 0)-.5*dt,(self.output or 0)+.5*dt)
 self.state=self.braking and "BRAKING" or (speed*(desired-speed)<0 and "BRAKING" or "MOVING")
 -- Guidance normal follows current/selected heading; actuators follow the bow.
 return self.output*math.cos(math.rad(delta(heading,v.heading)))
end
function Lateral:snapshot()
 return {mode=self.mode,state=self.state,offset=self.offset,remaining=self.remaining,
  sidewaysSpeed=self.speed,referenceHeading=self.referenceHeading,active=self.pending or self.braking or false,
  waitingForNeutral=self.waitNeutral,reason=self.reason}
end
return Lateral
