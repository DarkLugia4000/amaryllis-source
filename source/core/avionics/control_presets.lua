local Mathx = require("avionics.mathx")
-- Section: Pilot selections | Persistent modes and selected values.
-- Persist selections only. AP, lift authority, integrals and strafe are not saved.
local Presets={};Presets.__index=Presets
local finite = Mathx.finite
-- Section: Pilot selections | Persistent modes and selected values.
-- Summary: Construct the persisted mode/target store and load its saved record.
function Presets.new(config,storage,deps)
 local self=setmetatable({config=config,storage=storage,deps=deps or {},path="/avionics/data/control-presets.json"},Presets)
 for _,path in ipairs({self.path,self.path..".bak"}) do
  local ok,value=pcall(storage.readJson,path,self.deps)
  if ok and self:valid(value) then self.saved=value;self.pending=true;break end
 end
 return self
end
-- Summary: Validate a stored mode/target record against the supported schema and bounds.
function Presets:valid(v)
 if type(v)~="table" or v.schemaVersion~=1 or not finite(v.coreID) or
  type(v.uuid)~="string" or v.uuid=="" or type(v.modes)~="table" or type(v.targets)~="table" then return false end
 if v.modes.heading~="MANUAL" and v.modes.heading~="SEL" then return false end
 if v.modes.throttle~="MANUAL" and v.modes.throttle~="SEL" and v.modes.throttle~="DIRECT" then return false end
 local t=v.targets;local c=self.config.cockpit;local a=self.config.altitude_control
 if t.heading~=nil and (not finite(t.heading) or t.heading<0 or t.heading>=360) then return false end
 -- Stored speed can exceed the current selector ceiling after a limit edit.
 -- Validate against the config schema ceiling and clamp at restoration.
 if t.speed~=nil and (not finite(t.speed) or t.speed<c.minimum_selected_speed or t.speed>100) then return false end
 if t.altitude~=nil and (not finite(t.altitude) or t.altitude<a.minimum_world_y or t.altitude>2048) then return false end
 return (v.modes.heading~="SEL" or t.heading~=nil) and (v.modes.throttle~="SEL" or t.speed~=nil)
end
-- Summary: Cancel pending preset restoration and release its resume gate.
function Presets:cancelRestore()
 self.pending=false;self.saved=nil;self.awaitResume=false
end
-- Summary: Restore or persist pilot selections once the core identity matches and vessel data is fresh, rereading SEL targets for a new vessel ID.
function Presets:update(io,flight,now)
 local controls=flight.controls;local v=io.vessel or {}
 if not controls then return end
 if self.pending then
  controls:update(io,now)
  -- Hold propulsion while waiting to restore a saved selection.
  controls.holdPropulsion=true;controls.holdReason="PRESETS RESTORING";controls.request=0;controls.yaw=0
  if io.identityReady~=true or not controls.available or v.valid~=true or
   v.geometryVerified~=true or v.velocityFrameVerified~=true or not finite(v.at) or
   now<v.at or now-v.at>self.config.network.sensor_stale_seconds then return end
  local saved=self.saved
  if saved.coreID~=io.localID then
   self:cancelRestore();controls.holdPropulsion=false;controls.holdReason=nil
   self.reason="SAVED PRESETS BELONG TO A DIFFERENT CORE";return
  end
  controls.modes.heading=saved.modes.heading;controls.modes.throttle=saved.modes.throttle
  controls.modes.lateral="MANUAL";controls.lateral:cancel()
  -- The modes carry over to any vessel ID, since reassembly gives the ship
  -- a new Sable ID. Selected values carry over only for the same ID; for a
  -- new ID each SEL axis takes the current reading, as pressing SEL does,
  -- and the altitude target is taken from the current height.
  local reread=saved.uuid~=v.uuid
  if reread then
   local c=self.config.cockpit
   local speed=finite(v.forwardSpeed) and math.max(c.minimum_selected_speed,
    math.min(c.maximum_selected_speed,v.forwardSpeed)) or 0
   controls.targets={heading=saved.modes.heading=="SEL" and finite(v.heading) and v.heading%360 or nil,
    speed=saved.modes.throttle=="SEL" and speed or nil,
    altitude=finite(v.altitude) and v.altitude or nil}
   if saved.modes.heading=="SEL" and controls.targets.heading==nil then controls.modes.heading="MANUAL" end
  else
   controls.targets={heading=saved.targets.heading,speed=saved.targets.speed,altitude=saved.targets.altitude}
   if finite(controls.targets.speed) then
    controls.targets.speed=math.min(self.config.cockpit.maximum_selected_speed,controls.targets.speed)
   end
  end
  controls.uuid=v.uuid;controls.headingTargetUuid=v.uuid;controls.speedTargetUuid=v.uuid
  controls.holds={};controls.lastSample=io.inputs and io.inputs.at
  if type(controls.noteHandover)=="function" then controls:noteHandover() end
  -- A restored SEL selection stays held until lift is READY. MANUAL and
  -- DIRECT act at the lever positions from the next sample.
  local selected=saved.modes.heading=="SEL" or saved.modes.throttle=="SEL"
  self.pending=false;self.saved=nil;self.awaitResume=selected
  self.reason=selected and "PRESETS HELD: START SYSTEMS OR PRESS A MODE" or
   (reread and "MODES RESTORED; TARGETS REREAD FOR NEW VESSEL ID" or "PRESETS RESTORED")
 end
 if self.awaitResume then
  local ready=flight.enabled==true and (not flight.systemsRun or flight.systemsRun.phase=="READY")
  if not ready then
   controls.holdPropulsion=true;controls.holdReason="PRESETS HELD UNTIL START SYSTEMS READY"
   controls.request=0;controls.yaw=0
  else self.awaitResume=false;self.reason="PRESETS RESTORED" end
 end
 if not self.pending and not self.awaitResume and controls.holdPropulsion then
  controls.holdPropulsion=false;controls.holdReason=nil
 end
 -- Transient input failures and AP/anchor proxy control must not replace the
 -- last valid pilot selection with a temporary cleared or automatic mode.
 if controls.available~=true or io.identityReady~=true or v.valid~=true or controls.uuid~=v.uuid or
  (io.autopilot and io.autopilot.active) or (io.positionAnchor and io.positionAnchor.active) then return end
 local document={schemaVersion=1,coreID=io.localID,uuid=v.uuid,
  modes={heading=controls.modes.heading,throttle=controls.modes.throttle},
  targets={heading=controls.targets.heading,speed=controls.targets.speed,altitude=controls.targets.altitude}}
 if not self:valid(document) then return end
 local t=document.targets
 local key=table.concat({tostring(document.coreID),document.uuid,document.modes.heading,document.modes.throttle,
  tostring(t.heading),tostring(t.speed),tostring(t.altitude)},"|")
 local modeKey=document.modes.heading.."|"..document.modes.throttle
 if key==self.lastKey or (modeKey==self.lastModes and self.nextSave and now<self.nextSave) then return end
 self.nextSave=now+1
 local called,ok,reason=pcall(self.storage.writeJson,self.path,document,self.deps)
 if called and ok then self.lastKey=key;self.lastModes=modeKey;self.saveError=nil
 else self.saveError="CONTROL PRESETS NOT SAVED: "..tostring(called and reason or ok) end
end
function Presets:snapshot()
 return {pending=self.pending==true,awaitingSystems=self.awaitResume==true,reason=self.saveError or self.reason}
end
return Presets
