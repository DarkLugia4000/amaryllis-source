-- @ama-section: Systems recording | Cached startup/hold observations appended to CSV.
-- START SYSTEMS flight recorder. Appends one CSV row per published core
-- snapshot while a systems run is active, so launch behaviour (attitude,
-- leveling, lift per chamber, climb control) can be analysed afterwards.
-- Read-only with respect to flight: it never changes control state.
local Recorder={}
Recorder.__index=Recorder
local QUADS={"FL","FR","RL","RR"}
local COLUMNS={"clock","phase","altitude","target","vs","vsTarget","limiter","ackWait","lag",
    "pitchDeg","rollDeg","yFL","yFR","yRL","yRR","rollBlocks","pitchBlocks","rollRate","pitchRate",
    "coarseRoll","coarsePitch","coarseRollI","coarsePitchI","fineFL","fineFR","fineRL","fineRR",
    "liftFL","liftFR","liftRL","liftRR","ceilFL","ceilFR","ceilRL","ceilRR","liftRatio","fwdSpeed","fwdAlongBow",
    "primL","primR","propIdle","desiredRatio","effort","stallBoost","reqAccel","reason"}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function cell(v)
    if v==nil then return "" end
    if type(v)=="number" then return finite(v) and string.format("%.4g",v) or "" end
    if type(v)=="boolean" then return v and "1" or "0" end
    return (tostring(v):gsub("[,\r\n]"," "))
end
function Recorder.new(options)
    options=options or {}
    return setmetatable({fs=options.fs or fs,path=options.path or "/avionics/data/flight-log.csv",
        maxBytes=options.maxBytes or 100000,active=false},Recorder)
end
-- @ama-section: Systems recording | Cached startup/hold observations appended to CSV.
-- @ama-summary: Create the systems-run recording and write its column header.
function Recorder:open()
    local fsApi=self.fs
    if type(fsApi)~="table" then return false end
    pcall(fsApi.makeDir,"/avionics/data")
    -- Keep the previous run beside the new one; one run per file.
    if fsApi.exists(self.path) then
        local old=self.path..".prev"
        if fsApi.exists(old) then pcall(fsApi.delete,old) end
        pcall(fsApi.move,self.path,old)
    end
    local ok,handle=pcall(fsApi.open,self.path,"w")
    if not ok or not handle then return false end
    handle.write(table.concat(COLUMNS,",").."\n");handle.close()
    self.bytes=0;self.active=true
    return true
end
-- @ama-summary: Append the current systems-run snapshot to the flight recording.
function Recorder:record(flight,io,now)
    local s=flight and flight.systemsRun
    if not s then self.active=false;return end
    if not self.active and not self:open() then return end
    if self.bytes>self.maxBytes then return end
    local v=io.vessel or {};local nodes=io.nodes or {}
    local trim=flight.trim or {};local coarse=flight.coarseSteamTrim or {}
    local coarseI=flight.coarseSteamTrimIntegral or {};local rates=flight.levelRates or {}
    local y,lift,ceil={},{},{}
    local totalLift=0
    for _,q in ipairs(QUADS) do
        local n=nodes[q] or {}
        y[q]=n.altitude and n.altitude.sensorWorldY
        lift[q]=n.balloon and n.balloon.lift
        if finite(lift[q]) then totalLift=totalLift+lift[q] end
        local sum=0
        for _,value in pairs(s.currentTargets and s.currentTargets[q] or {}) do if finite(value) then sum=sum+value end end
        ceil[q]=sum
    end
    local rollBlocks,pitchBlocks
    if finite(y.FL) and finite(y.FR) and finite(y.RL) and finite(y.RR) then
        rollBlocks=(y.FL+y.RL-y.FR-y.RR)/4;pitchBlocks=(y.FL+y.FR-y.RL-y.RR)/4
    end
    local thrust=io.thrust;local requested=thrust and thrust.requested or {}
    local row={finite(now) and string.format("%.2f",now) or "",s.phase,v.altitude,s.target,v.verticalSpeed,flight.verticalTarget,s.speedLimiter,
        s.lastAckWaitSeconds,s.responseLagSeconds,v.pitch,v.roll,y.FL,y.FR,y.RL,y.RR,rollBlocks,pitchBlocks,
        rates.roll,rates.pitch,coarse.roll,coarse.pitch,coarseI.roll,coarseI.pitch,
        trim.FL,trim.FR,trim.RL,trim.RR,lift.FL,lift.FR,lift.RL,lift.RR,ceil.FL,ceil.FR,ceil.RL,ceil.RR,
        s.dynamics and s.dynamics.actualRatio,v.forwardSpeed,v.forwardSpeedAlongBow,
        requested["primary-left"],requested["primary-right"],io.propulsionHoldSuppressed~=nil,
        s.lastDesiredRatio,flight.effort,s.climbStallBoost,s.lastRequestedAcceleration,s.reason}
    local out={}
    for i=1,#COLUMNS do out[i]=cell(row[i]) end
    local line=table.concat(out,",").."\n"
    -- Diagnostic logging must leave room for atomic restart/configuration saves.
    if type(self.fs.getFreeSpace)=="function" then
        local ok,free=pcall(self.fs.getFreeSpace,self.path)
        if ok and type(free)=="number" and free<262144 then return end
    end
    local ok,handle=pcall(self.fs.open,self.path,"a")
    if ok and handle then handle.write(line);handle.close();self.bytes=self.bytes+#line end
end
return Recorder
