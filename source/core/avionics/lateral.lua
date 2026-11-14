local Mathx = require("avionics.mathx")
-- Section: Sideways guidance | Selected displacement, braking and pilot handover.
-- Lateral input and guidance only. Actuator authority remains in Thrust.
local Lateral={};Lateral.__index=Lateral
local finite = Mathx.finite
local clamp = Mathx.clamp
local function delta(a,b) return (a-b+180)%360-180 end
function Lateral.new(config)
 return setmetatable({config=config,mode="MANUAL",state="MANUAL",waitNeutral=false,offset=0,output=0},Lateral)
end
-- Summary: Clear lateral demand and guidance history; strafe input acts from the next sample.
function Lateral:cancel()
 self.mode="MANUAL";self.state="MANUAL";self.offset=0;self.track=nil;self.pending=false
 self.braking=false;self.output=0;self.integral=0;self.manual=0;self.hold=nil;self.waitNeutral=false
 self.settledAt=nil;self.lastAt=nil;self.turnQuietUntil=nil
 self.positionTrace=nil
end
-- Section: Sideways guidance | Selected displacement, braking and pilot handover.
-- Summary: Validate the vessel observations used for sideways position guidance.
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
-- Summary: Start selected sideways travel at zero offset from the current position.
function Lateral:select(mode,io,controls,now)
 if mode~="MANUAL" and mode~="SEL" then return false,"INVALID LATERAL MODE" end
 if io.autopilot and io.autopilot.active or io.positionAnchor and io.positionAnchor.active then
  return false,"AP / ANCHOR OWNS LATERAL CONTROL"
 end
 if mode=="MANUAL" then self:cancel();return true end
 local v,reason=self:telemetry(io,now);if not v then return false,reason end
 self:cancel();self.mode="SEL";self.state="IDLE";self.track={x=v.position.x,z=v.position.z,travelled=0};self.uuid=v.uuid
 return true
end
-- Summary: Interpret lateral pilot input into bounded displacement and braking intent.
function Lateral:input(raw,at,dt,blocked)
 if blocked then self:cancel();return end
 local left,right=raw.left_lift>0,raw.right_lift>0
 if not left and not right then self.waitNeutral=false end
 if self.mode=="SEL" and left and right and not self.waitNeutral then
  self.mode="MANUAL";self.offset=0;self.track=nil;self.pending=false;self.braking=true
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
-- Summary: Compute sideways demand and braking from the current offset and velocity.
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
 local dt=self.lastAt and v.at-self.lastAt or 0
 local rate=self.lastHeading and dt>0 and math.abs(delta(v.heading,self.lastHeading))/dt or 0
 if dt>0 or not self.lastAt then self.lastAt=v.at;self.lastHeading=v.heading end
 dt=clamp(dt,0,.5)
 -- Heading-hold torque can persist at a settled heading. Pause translation
 -- for pilot turn input, measured rotation or a heading still being acquired.
 local turning=self.mode=="SEL" and (math.abs(controls.yaw or 0)>.02 or rate>.5 or math.abs(delta(heading,v.heading))>3)
 -- Sideways travel is summed one sample at a time along the current reference
 -- axis, so forward flight adds nothing and the offset stays relative to her
 -- present track after a heading change. Movement during a turn is skipped.
 local track=self.track
 self.positionTrace=nil
 if track then
  local credited=0
  if not turning then
   credited=(v.position.x-track.x)*nx+(v.position.z-track.z)*nz
   track.travelled=track.travelled+credited
  end
  local observation=v.positionObservation or {}
  local raw=observation.raw or v.position
  self.positionTrace={rawX=raw.x,rawZ=raw.z,x=v.position.x,z=v.position.z,
   sampleAt=observation.at,projectedAt=observation.projectedAt,velocityAt=observation.projectionVelocityAt,
   evaluatedAt=now,credited=credited,travelled=track.travelled,turning=turning}
  track.x,track.z=v.position.x,v.position.z
 end
 local error=track and self.offset-track.travelled or 0
 self.remaining=error;self.speed=speed;self.referenceHeading=heading
 if self.mode=="SEL" then
  if turning then self.turnQuietUntil=now+1 end
  if self.turnQuietUntil and now<self.turnQuietUntil then
   self.output=0;self.integral=0;self.settledAt=nil;self.state="TURNING";return 0
  end
  if not self.pending then
   -- Idle keeps no target: a new press measures from her position at that moment.
   self.offset=0;self.remaining=0;if track then track.travelled=0 end
   self.output=0;self.integral=0;self.state="IDLE";return 0
  end
 end
 local settled=math.abs(speed)<=.05 and (self.braking or math.abs(error)<=.2)
 if settled then self.settledAt=self.settledAt or now else self.settledAt=nil end
 if self.settledAt and now-self.settledAt>=1 then
  self.output=0;self.integral=0;self.pending=false
  -- A finished strafe keeps nothing: the next press starts a new offset from where she is now.
  if not self.braking then
   self.offset=0;self.remaining=0
   if track then self.track={x=v.position.x,z=v.position.z,travelled=0} end
  end
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
 -- Active braking is thrust against the current motion. Drag stops the vessel quickly
 -- below the configured speed, so that thrust is withheld and the drives stay idle.
 -- A selected approach that has passed its target by more than the settle tolerance
 -- still returns, because that thrust corrects position and does not brake.
 local brakeMinimum=(self.config.cockpit or {}).lateral_brake_minimum_speed
 if not finite(brakeMinimum) then brakeMinimum=2 end
 local passedTarget=not self.braking and error*speed<0 and math.abs(error)>.2
 if wanted*speed<0 and math.abs(speed)<brakeMinimum and not passedTarget then wanted=0 end
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
