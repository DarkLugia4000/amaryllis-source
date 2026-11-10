local Mathx = require("avionics.mathx")
-- Section: Worker supervision | Completion tracking and paced replacement decisions.
-- Progress watchdog. Each controller has gates that pause or freeze it while
-- some precondition is unmet; one that never clears leaves the vessel holding
-- still while the controller believes it is working (logged 2026-10-21: an
-- unmeasured response lag froze the climb integral, 11 blocks below target
-- at +0.01 b/s). This watches the outcome instead of the gates: if a loop
-- is commanded away from its target and the error has not shrunk for a
-- while, it is reported with the loop's own state, and the altitude loop is
-- told so it can lean harder (see Flight HOLD support bias).
local Watchdog={}
Watchdog.__index=Watchdog
local finite = Mathx.finite
local function wrap(d) return (d+180)%360-180 end
-- name -> {minimum error to watch, improvement that counts, seconds allowed}
local RULES={
    altitude={floor=2,improve=0.5,window=45},
    speed={floor=1,improve=0.3,window=30},
    heading={floor=5,improve=2,window=30},
    anchor={floor=2,improve=0.5,window=60},
}
function Watchdog.new() return setmetatable({tracks={},stalls={}},Watchdog) end
local function log(text)
    if type(os)=="table" and type(os.__amaryllisLog)=="function" then pcall(os.__amaryllisLog,text,"core.watchdog") end
end
-- Section: Worker supervision | Completion tracking and paced replacement decisions.
-- Summary: Record a worker's completion progress for stall detection.
function Watchdog:observe(name,error,now,detail)
    local rule=RULES[name];local track=self.tracks[name]
    if not finite(error) or math.abs(error)<rule.floor then
        if self.stalls[name] then log("Progress restored: "..name) end
        self.tracks[name]=nil;self.stalls[name]=nil;return
    end
    local magnitude=math.abs(error)
    -- A new target (error jumps up, or flips sign) starts a fresh window.
    if not track or (track.sign~=(error>0 and 1 or -1)) or magnitude>track.best+rule.improve*4 then
        track={best=magnitude,bestAt=now,sign=error>0 and 1 or -1};self.tracks[name]=track
    end
    if magnitude<=track.best-rule.improve then track.best=magnitude;track.bestAt=now end
    local stalledFor=now-track.bestAt
    if stalledFor>=rule.window then
        local stall=self.stalls[name]
        local text=string.format("%s: NO PROGRESS FOR %.0f S (ERROR %.2f)%s",string.upper(name),stalledFor,error,
            detail and ("; "..detail) or "")
        if not stall then log("Stall: "..text);self.stalls[name]={since=now,loggedAt=now,text=text}
        else
            stall.text=text
            if now-stall.loggedAt>=60 then stall.loggedAt=now;log("Still stalled: "..text) end
        end
    elseif self.stalls[name] then
        log("Progress restored: "..name);self.stalls[name]=nil
    end
end
local function f(v,d) return finite(v) and string.format("%."..(d or 3).."f",v) or "--" end
-- Summary: Evaluate worker progress and advance the paced restart decision.
function Watchdog:update(io,flight,now)
    local v=io.vessel or {}
    -- Altitude: READY hold away from its target.
    local s=flight and flight.systemsRun
    if s and s.phase=="READY" and finite(s.target) and finite(v.altitude) and not s.telemetryRecovery then
        local d=s.dynamics or {}
        self:observe("altitude",s.target-v.altitude,now,
            "VS "..f(v.verticalSpeed,2).."/"..f(flight.verticalTarget,2).." SUPPORT "..f(s.lastDesiredRatio).."/"..
            f(d.actualRatio).." INNER I "..f(flight.inner and flight.inner.i,2).." LAG "..f(s.responseLagSeconds,1)..
            (s.speedLimiter and (" LIMIT "..tostring(s.speedLimiter)) or ""))
    else self:observe("altitude",nil,now) end
    if flight then flight.altitudeProgressStalled=self.stalls.altitude~=nil end
    local thrust=io.thrust
    local speed=thrust and thrust.speedControl
    if speed and speed.available==true and finite(speed.targetSpeed) and speed.targetSpeed~=0 and finite(speed.measuredSpeed) then
        self:observe("speed",speed.targetSpeed-speed.measuredSpeed,now,
            "OUTPUT "..f(speed.output).." FF "..f(speed.feedforward).." STATE "..tostring(speed.state))
    else self:observe("speed",nil,now) end
    local heading=thrust and thrust.headingControl
    if heading and heading.available==true and finite(heading.targetHeading) and finite(heading.measuredHeading) then
        self:observe("heading",wrap(heading.targetHeading-heading.measuredHeading),now,"STATE "..tostring(heading.state))
    else self:observe("heading",nil,now) end
    local anchor=io.positionAnchor
    if anchor and anchor.active and not anchor.velocityOnly and finite(anchor.distance) and anchor.state~="PAUSED" then
        self:observe("anchor",anchor.distance,now,"STATE "..tostring(anchor.state))
    else self:observe("anchor",nil,now) end
end
function Watchdog:snapshot()
    local out={}
    for name,stall in pairs(self.stalls) do out[#out+1]=stall.text end
    table.sort(out)
    return out
end
return Watchdog
