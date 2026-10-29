
local Ops=require("avionics.remote_ap")
local Flight=require("avionics.flight")
local Anchor=require("avionics.anchor")
local AP=require("avionics.autopilot")
fs={exists=function() return false end}
os.__amaryllisLog=function() end
local checks=0
local function check(ok,why) assert(ok,why);checks=checks+1 end
local function clone(v) if type(v)~="table" then return v end;local r={};for k,x in pairs(v) do r[k]=clone(x) end;return r end
local function fixture()
 local c=clone(CONFIG)
 c.thrust.enabled=true;c.thrust.speed_control_enabled=true;c.thrust.heading_control_enabled=true
 local clock={now=10,epoch=100000}
 local inputs={};for _,k in ipairs({"left_press","left_lift","right_press","right_lift","prop_forward","prop_reverse","ap_disconnect","altitude_up","altitude_down"}) do inputs[k]=0 end
 local io={config=c,session="core-session",identityReady=true,propulsionHeartbeat=10,
  nowSeconds=function() return clock.now end,
  assemblyGate=function() return true end,routeAllowed=function() return true end,
  inputs={valid=true,at=10,raw=inputs},
  vessel={valid=true,at=10,uuid="vessel",position={x=0,y=120,z=0},linearVelocity={x=0,y=0,z=0},
   forwardDirection={x=0,z=-1},heading=0,forwardSpeed=0,altitude=120,velocityFrameVerified=true,geometryVerified=true},
  thrust={activationReady=function() return true end,resetSpeedLoop=function() end,
   resetHeadingLoop=function() end,resetManualAccelerationLoop=function() end}}
 local f=Flight.new(c);f.enabled=true;f.systemsRun={phase="READY"};f.restart={}
 f.controls.available=true;f.controls.updatedAt=10;f.controls.leversAvailable=true;f.controls.requireNeutral=false
 f.controls.targets.altitude=120
 local permissions={one=true,two=true}
 local ops=Ops.new(io,f,{epoch=function() return clock.epoch end,permission=function(pair) return permissions[pair]==true end})
 io.remoteAP=ops
 local count=0
 local function packet(action,extra)
  count=count+1
  local p={action=action or "ap_send",commandID="command-"..count,coreSession=io.session,
   generation=ops.generation,sentAt=clock.epoch,destination={name="Remote test",x=100,z=-200,altitude=150,cruiseSpeed=3}}
  for k,v in pairs(extra or {}) do p[k]=v end
  return p
 end
 local function execute(p,pair,sender)
  pair=pair or "one";sender=sender or 63
  local ack=ops:request(sender,pair,p);ops:step(clock.now)
  return ops:request(sender,pair,{action="ap_result",commandID=p.commandID}),ack
 end
 return io,f,ops,packet,execute,clock,permissions
end
local Presets=require("avionics.control_presets")
local store={};local writes=0;local fail=false
local storage={
 readJson=function(path)return clone(store[path])end,
 writeJson=function(path,value)
  writes=writes+1;if fail then return false,"injected disk failure"end
  store[path]=clone(value);return true
 end}
local function setup(disk)
 store=disk or{};writes=0;fail=false
 local io,f,o,packet,execute,clock=fixture()
 io.localID=35
 f.controls.uuid="vessel";f.controls.targets={heading=120,speed=4,altitude=160}
 local p=Presets.new(io.config,storage);io.controlPresets=p
 return io,f,p,clock,o,packet,execute
end
local function sample(io,clock,now,raw)
 clock.now=now;io.inputs.at=now;io.vessel.at=now
 if raw then io.inputs.raw[raw[1]]=raw[2]end
end
local function selected(io,f,p,clock)
 sample(io,clock,10)
 assert(f.controls:mode(io,{axis="heading",mode="SEL"},10))
 assert(f.controls:mode(io,{axis="throttle",mode="SEL"},10))
 f.controls.targets={heading=120,speed=4,altitude=160}
 p:update(io,f,10)
end
