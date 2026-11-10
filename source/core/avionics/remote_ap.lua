local Mathx = require("avionics.mathx")
-- Section: Remote command service | Authenticated requests serviced by core's supervisor.
-- Remote requests are serialized by core's supervisor, never executed in a radio worker.
local Ops={}
local INPUTS={"prop_forward","prop_reverse","left_press","left_lift","right_press","right_lift",
    "ap_disconnect","altitude_up","altitude_down"}
local function copy(v) if type(v)~="table" then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local finite = Mathx.finite
local function id(s) return type(s)=="string" and #s>0 and #s<=100 and s:match("^[%w_%.:%-]+$") end
function Ops.new(io,flight,deps)
    deps=deps or {}
    return setmetatable({io=io,flight=flight,enabled=false,generation=0,queue={},results={},order={},
        reason="ENABLE REMOTE AP ON CORE",epoch=deps.epoch or function() return os.epoch("utc") end,
        permission=deps.permission or function(pair) return (os.__amaryllisRemotePermissions or {})[pair]==true end}, {__index=Ops})
end
function Ops:alive()
    local now=self.io:nowSeconds();local at=self.io.propulsionHeartbeat
    return finite(at) and now>=at and now-at<3
end
-- Summary: Change remote AP permission for this boot and advance its command generation.
function Ops:setEnabled(enabled)
    if enabled and not self:alive() then return false,"CORE SUPERVISOR UNAVAILABLE" end
    self.enabled=enabled==true;self.generation=self.generation+1
    if not self.enabled then self.cancelPending=true end
    self.reason=self.enabled and "REMOTE AP ENABLED FOR THIS CORE BOOT" or "REMOTE AP DISABLED ONBOARD"
    return true,self.reason
end
-- Section: Remote command service | Authenticated requests serviced by core's supervisor.
-- Summary: Identify local pilot activity that supersedes a queued remote operation.
function Ops:pilotAction(action)
    local kind=type(action)=="table" and action.type
    if kind and ({ap_engage=true,ap_disengage=true,anchor_engage=true,anchor_cancel=true,cockpit_mode=true,
        systems_stop=true,systems_stop_confirm=true,restart_systems=true,emergency_kill_lift=true,
        kill_lift=true,altitude_disengage=true,altitude_engage=true})[kind] then
        self.pilotRevision=(self.pilotRevision or 0)+1
        if self.owner or (self.io.autopilot and self.io.autopilot.remoteOwner) then
            self.enabled=false;self.generation=self.generation+1;self.cancelPending=true
            self.reason="ONBOARD PILOT OVERRIDE; RE-ENABLE REMOTE AP ON CORE"
        end
    end
end
-- Summary: Evaluate the neutral-input gate for the current remote command.
function Ops:neutral(now)
    local c=self.flight.controls
    if not c or type(c.fresh)~="function" then return false,"COCKPIT INPUT VERIFICATION UNAVAILABLE" end
    local fresh,why=c:fresh(self.io,now)
    if not fresh then return false,why or "FRESH COCKPIT INPUTS REQUIRED" end
    for _,key in ipairs(INPUTS) do if self.io.inputs.raw[key]~=0 then return false,"PILOT INPUT ACTIVE; REMOTE REQUEST REJECTED" end end
    return true
end
local function key(sender,pair,command) return tostring(sender)..":"..pair..":"..command end
-- Summary: Build bounded remote command and route progress from cached core state.
function Ops:status(pair)
    local ap=self.io.autopilot;local v=self.io.vessel or {}
    local entry=ap and ap.route and ap.route.entries and ap.route.entries[ap.route.index or 1]
    return {enabled=self.enabled,permitted=self.permission(pair),coreAlive=self:alive(),session=self.io.session,
        generation=self.generation,reason=self.reason,active=ap and ap.active==true or false,
        owned=ap and ap.active and ap.remoteOwner==pair or false,state=ap and ap.state or "OFF",
        apReason=ap and ap.reason,destination=entry and copy(entry) or nil,
        distance=ap and ap.distance,altitude=v.altitude,speed=v.forwardSpeed,
        selectedAltitude=self.flight.controls and self.flight.controls.targets.altitude,
        digitalAnchor=self.io.positionAnchor and self.io.positionAnchor.active==true or false,
        queued=#self.queue}
end
-- Summary: Validate, correlate and queue an authenticated remote operation.
function Ops:request(sender,pair,p)
    if p.action=="ap_status" then return self:status(pair) end
    if not id(p.commandID) then return {status="REJECTED",reason="INVALID COMMAND ID"} end
    local k=key(sender,pair,p.commandID)
    if p.action=="ap_result" then return copy(self.results[k] or {status="UNKNOWN",reason="COMMAND NOT KNOWN IN THIS CORE SESSION"}) end
    if p.action~="ap_send" and p.action~="ap_cancel" then return {status="REJECTED",reason="UNSUPPORTED REMOTE FLIGHT ACTION"} end
    -- Repeats return the original result, including a pending command, without another execution.
    if self.results[k] then return copy(self.results[k]) end
    local why
    if p.coreSession~=self.io.session then why="CORE SESSION CHANGED; REVIEW REQUEST AGAIN"
    elseif not self:alive() then why="CORE SUPERVISOR UNAVAILABLE"
    elseif not self.permission(pair) then why="THIS REMOTE HAS NO FLIGHT PERMISSION"
    elseif not self.enabled then why=self.reason
    elseif p.generation~=self.generation then why="ONBOARD AUTHORITY CHANGED; REVIEW REQUEST AGAIN"
    elseif not finite(p.sentAt) or p.sentAt>self.epoch()+1000 or self.epoch()-p.sentAt>6000 then why="REMOTE COMMAND EXPIRED"
    elseif #self.queue>=8 then why="REMOTE REQUEST QUEUE FULL" end
    if why then return {status="REJECTED",reason=why} end
    if p.action=="ap_send" then
        local d=p.destination
        if type(d)~="table" then return {status="REJECTED",reason="DESTINATION MISSING"} end
        -- Copy only the bounded, understood fields; never retain arbitrary radio tables.
        d={name="Remote CMD",x=d.x,z=d.z,altitude=d.altitude,cruiseSpeed=d.cruiseSpeed}
        local ap=self.flight:ensureAutopilot(self.io)
        if not ap:validDraft(d,true) then return {status="REJECTED",reason="DESTINATION / SPEED / ALTITUDE INVALID"} end
        p={action=p.action,destination=d,commandID=p.commandID,sentAt=p.sentAt,
            releaseAnchor=p.releaseAnchor==true,generation=p.generation}
    else p={action=p.action,commandID=p.commandID,sentAt=p.sentAt,generation=p.generation} end
    while #self.order>=64 do
        local oldest=self.order[1]
        if self.results[oldest] and (self.results[oldest].status=="PENDING" or
            self.epoch()-self.results[oldest].createdAt<15000) then return {status="REJECTED",reason="REMOTE RESULT BUFFER BUSY"} end
        table.remove(self.order,1);self.results[oldest]=nil
    end
    self.results[k]={status="PENDING",commandID=p.commandID,createdAt=self.epoch(),reason="WAITING FOR CORE VALIDATION"}
    self.order[#self.order+1]=k
    self.queue[#self.queue+1]={sender=sender,pair=pair,key=k,packet=p,pilotRevision=self.pilotRevision or 0}
    return copy(self.results[k])
end
-- Summary: Apply the queued remote action through core's flight request interface.
function Ops:execute(item,now)
    local io,f,p=self.io,self.flight,item.packet
    if not self.enabled or p.generation~=self.generation then return false,self.reason end
    if not self.permission(item.pair) then return false,"REMOTE FLIGHT PERMISSION REVOKED" end
    if self.epoch()-p.sentAt>6000 then return false,"REMOTE COMMAND EXPIRED BEFORE EXECUTION" end
    if item.pilotRevision~=(self.pilotRevision or 0) then return false,"ONBOARD COMMAND TAKES PRIORITY" end
    local ap=f:ensureAutopilot(io)
    if p.action=="ap_cancel" then
        if not ap.active or ap.remoteOwner~=item.pair then return false,"THIS REMOTE DOES NOT OWN THE ACTIVE ROUTE" end
        ap:cancel(io,f.controls,"REMOTE PILOT DISENGAGED; SELECTED MODES RETAINED")
        self.owner=nil;return true,"AUTOPILOT DISENGAGED; SELECTED MODES RETAINED"
    end
    if ap.active then return false,"AUTOPILOT ALREADY ACTIVE; ROUTE REPLACEMENT REFUSED" end
    if f.emergencyLiftLatched or f.shutdownJob or f.stopReview or f.tuningRun or f.maintenanceJob or
        (f.restart and (f.restart.job or f.restart.saved)) then return false,"SYSTEMS STOP / KILL / OPERATION IN PROGRESS" end
    if not f.enabled or (f.systemsRun and f.systemsRun.phase~="READY") then return false,"ESTABLISH ALTITUDE HOLD ONBOARD FIRST" end
    local neutral,why=self:neutral(now);if not neutral then return false,why end
    if io.identityReady~=true then return false,"CORE IDENTITY UNVERIFIED" end
    if type(io.assemblyGate)=="function" then local ok,reason=io:assemblyGate(now);if not ok then return false,reason end end
    if type(io.routeAllowed)=="function" then local ok,reason=io:routeAllowed();if not ok then return false,reason end end
    local anchor=io.positionAnchor
    if anchor and anchor.active and not p.releaseAnchor then return false,"CONFIRM DIGITAL ANCHOR RELEASE" end
    local ready,reason=ap:ready(io,f.controls,now,p.destination,p.releaseAnchor)
    if not ready then return false,reason end
    -- All preflight checks use cached data. No provider calls or saves occur in this transaction.
    local previous=ap.draft;local previousRoute=ap.route;local previousAltitude=f.controls.targets.altitude
    ap.draft=copy(p.destination)
    if anchor and anchor.active then io.positionAnchor=nil end
    local ok,accepted,issue=pcall(f.request,f,io,{type="ap_engage"},now)
    io.positionAnchor=anchor
    if not ok or not accepted then
        if ap.active then pcall(ap.cancel,ap,io,f.controls,"REMOTE ENGAGE FAILED; SELECTED MODES RETAINED") end
        ap.route=previousRoute;ap.draft=previous;f.controls.targets.altitude=previousAltitude
        return false,ok and issue or tostring(accepted)
    end
    -- Remote CMD is transient; retain navigator's destination editor.
    ap.draft=previous
    if anchor and anchor.active then anchor:cancel(nil,"REMOTE ROUTE ACCEPTED; DIGITAL ANCHOR RELEASED") end
    ap.remoteOwner=item.pair;self.owner=item.pair
    self.reason="REMOTE ROUTE ACCEPTED"
    return true,"AUTOPILOT ENGAGED; ARRIVAL WILL ANCHOR AT DESTINATION"
end
-- Summary: Service the next remote operation after higher-priority ship work.
function Ops:step(now)
    local ap=self.io.autopilot
    if ap and ap.active and ap.remoteOwner then self.owner=ap.remoteOwner end
    if self.owner and ap and ap.active then
        local fresh=self.flight.controls and self.flight.controls:fresh(self.io,now)
        local moving=false
        if fresh then for _,name in ipairs(INPUTS) do if self.io.inputs.raw[name]~=0 then moving=true;break end end end
        if moving then
            self.enabled=false;self.generation=self.generation+1;self.cancelPending=true
            self.reason="PILOT INPUT OVERRIDE; RE-ENABLE REMOTE AP ON CORE"
        elseif not self.permission(self.owner) then
            self.cancelPending=true;self.reason="REMOTE FLIGHT PERMISSION REVOKED"
        end
    end
    if self.owner and (not ap or not ap.active or ap.remoteOwner~=self.owner) then
        self.owner=nil;self.enabled=false;self.generation=self.generation+1
        self.reason="ROUTE ENDED OR CANCELLED ONBOARD; RE-ENABLE REMOTE AP ON CORE"
    end
    if self.cancelPending then
        if ap and ap.active and ap.remoteOwner then ap:cancel(self.io,self.flight.controls,self.reason) end
        self.cancelPending=nil;self.owner=nil
    end
    local item=table.remove(self.queue,1)
    if item then
        local ok,accepted,reason=pcall(self.execute,self,item,now)
        self.results[item.key]={status=ok and accepted and "ACCEPTED" or "REJECTED",
            commandID=item.packet.commandID,createdAt=self.epoch(),reason=ok and reason or ("REMOTE REQUEST ERROR: "..tostring(accepted))}
        if type(os.__amaryllisLog)=="function" then
            pcall(os.__amaryllisLog,"Remote AP #"..item.sender..": "..self.results[item.key].status.." / "..tostring(self.results[item.key].reason),"core.remote-ap")
        end
    end
end
return Ops
