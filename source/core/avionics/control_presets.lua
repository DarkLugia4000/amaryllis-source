-- @ama-section: Pilot selections | Persistent modes and selected values.
-- Persist selections only. AP, lift authority, integrals and strafe are not saved.
local Presets={};Presets.__index=Presets
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
-- @ama-section: Pilot selections | Persistent modes and selected values.
-- @ama-summary: Construct the persisted mode/target store and load its saved record.
function Presets.new(config,storage,deps)
 local self=setmetatable({config=config,storage=storage,deps=deps or {},path="/avionics/data/control-presets.json"},Presets)
 for _,path in ipairs({self.path,self.path..".bak"}) do
  local ok,value=pcall(storage.readJson,path,self.deps)
  if ok and self:valid(value) then self.saved=value;self.pending=true;break end
 end
 return self
end
-- @ama-summary: Validate a stored mode/target record against the supported schema and bounds.
function Presets:valid(v)
 if type(v)~="table" or v.schemaVersion~=1 or not finite(v.coreID) or
  type(v.uuid)~="string" or v.uuid=="" or type(v.modes)~="table" or type(v.targets)~="table" then return false end
 if v.modes.heading~="MANUAL" and v.modes.heading~="SEL" then return false end
 if v.modes.throttle~="MANUAL" and v.modes.throttle~="SEL" and v.modes.throttle~="DIRECT" then return false end
 local t=v.targets;local c=self.config.cockpit;local a=self.config.altitude_control
 if t.heading~=nil and (not finite(t.heading) or t.heading<0 or t.heading>=360) then return false end
 if t.speed~=nil and (not finite(t.speed) or t.speed<c.minimum_selected_speed or t.speed>c.maximum_selected_speed) then return false end
 if t.altitude~=nil and (not finite(t.altitude) or t.altitude<a.minimum_world_y or t.altitude>a.maximum_world_y) then return false end
 return (v.modes.heading~="SEL" or t.heading~=nil) and (v.modes.throttle~="SEL" or t.speed~=nil)
end
function Presets:cancelRestore()
 self.pending=false;self.saved=nil;self.awaitResume=false
end
-- @ama-summary: Restore or persist pilot selections using current vessel and neutral-input checks.
function Presets:update(io,flight,now)
 local controls=flight.controls;local v=io.vessel or {}
 if not controls then return end
 if self.pending then
  controls:update(io,now)
  -- Hold all propulsion inputs while waiting to restore a saved selection.
  controls.waitHeading=true;controls.waitThrottle=true;controls.request=0;controls.yaw=0
  if io.identityReady~=true or not controls.available or v.valid~=true or
   v.geometryVerified~=true or v.velocityFrameVerified~=true or not finite(v.at) or
   now<v.at or now-v.at>self.config.network.sensor_stale_seconds then return end
  local saved=self.saved
  if saved.coreID~=io.localID or saved.uuid~=v.uuid then
   self:cancelRestore();self.reason="SAVED PRESETS BELONG TO A DIFFERENT CORE / VESSEL";return
  end
  for _,key in ipairs({"prop_forward","prop_reverse","left_press","right_press","left_lift","right_lift","altitude_up","altitude_down","ap_disconnect"}) do
   if (((io.inputs or {}).raw or {})[key] or 0)~=0 then
    -- Name the input so a stuck lever or link can be found.
    self.reason="PRESETS WAIT: "..string.upper(key).." NOT NEUTRAL";return
   end
  end
  controls.modes.heading=saved.modes.heading;controls.modes.throttle=saved.modes.throttle
  controls.modes.lateral="MANUAL";controls.lateral:cancel()
  controls.targets={heading=saved.targets.heading,speed=saved.targets.speed,altitude=saved.targets.altitude}
  controls.uuid=v.uuid;controls.headingTargetUuid=v.uuid;controls.speedTargetUuid=v.uuid
  controls.holds={};controls.lastSample=io.inputs.at;controls.waitAltitude=true
  -- Only a restored SEL selection needs protecting until lift is READY.
  -- MANUAL and DIRECT already require neutral levers before they act.
  local selected=saved.modes.heading=="SEL" or saved.modes.throttle=="SEL"
  self.pending=false;self.saved=nil;self.awaitResume=selected
  self.reason=selected and "PRESETS HELD: START SYSTEMS OR PRESS A MODE" or "PRESETS RESTORED"
 end
 if self.awaitResume then
  local ready=flight.enabled==true and (not flight.systemsRun or flight.systemsRun.phase=="READY")
  if not ready then controls.waitHeading=true;controls.waitThrottle=true;controls.request=0;controls.yaw=0
  else self.awaitResume=false;self.reason="PRESETS RESTORED" end
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
