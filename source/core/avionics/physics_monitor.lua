-- @ama-section: Physics observations | Consistency of measured acceleration, lift and pressure.
-- Physics consistency monitor. The lift model multiplies the balloons' lift
-- by air pressure, so a bad pressure source makes every altitude decision
-- wrong while looking perfectly valid (logged 2026-10-21 near Y 306: the
-- altitude sensor read 0.003 against Sable's 0.21, the model said 2% of
-- weight while she was plainly floating). Newton gives an independent check:
-- support/weight must equal 1 + vertical acceleration / g. While holding,
-- if the modelled support is far from that for 5 s, the other pressure
-- source is tried; if it fits much better the composer is told to prefer
-- it. Otherwise the inconsistency is reported (core log, snapshot).
local Monitor={}
Monitor.__index=Monitor
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
-- Legitimate lift-model error reaches ~17% at Y 306 (hover memory learns
-- it), so only a gross mismatch counts.
local TOLERANCE,DWELL=0.35,5
function Monitor.new() return setmetatable({},Monitor) end
local function log(text)
    if type(os.__amaryllisLog)=="function" then pcall(os.__amaryllisLog,text,"core.physics") end
end
-- @ama-section: Physics observations | Consistency of measured acceleration, lift and pressure.
-- @ama-summary: Compare measured motion and lift with the current gravity/pressure model.
function Monitor:update(io,flight,now)
    local s=flight and flight.systemsRun
    local v=io.vessel or {}
    local env=v.environment or {}
    local d=s and s.dynamics or {}
    local gravity=env.gravity and finite(env.gravity.y) and math.abs(env.gravity.y) or nil
    local accel=finite(d.verticalAcceleration) and d.verticalAcceleration or d.verticalAccelerationRaw
    local ratio=d.actualRatio
    local used=env.airPressure
    if not s or s.phase~="READY" or s.telemetryRecovery or not finite(ratio) or not finite(accel) or
        not gravity or gravity<=0 or not finite(used) or used<=0 then
        self.badSince=nil;return
    end
    local expected=1+accel/gravity
    local miss=math.abs(ratio-expected)
    self.lastCheck={ratio=ratio,expected=expected,source=env.airPressureSource,at=now}
    if miss<=TOLERANCE then
        if self.warning then log("Lift model consistent again (support "..string.format("%.2f",ratio).." vs physics "..
            string.format("%.2f",expected)..")") end
        self.badSince=nil;self.warning=nil;return
    end
    self.badSince=self.badSince or now
    if now-self.badSince<DWELL then return end
    local source=tostring(env.airPressureSource or "")
    local sensor,sable=env.airPressureSensor,env.airPressureSable
    local alternative,altName
    if source:find("SABLE",1,true) and finite(sensor) and sensor>0 then alternative,altName=sensor,"ALTITUDE SENSOR"
    elseif source:find("SENSOR",1,true) and finite(sable) and sable>0 then alternative,altName=sable,"SABLE AERO" end
    if alternative then
        local altRatio=ratio*alternative/used
        local altMiss=math.abs(altRatio-expected)
        if altMiss<=TOLERANCE and altMiss<miss*0.5 then
            io.pressurePreference=altName
            log(string.format("Pressure source %s implies support %.2f but physics says %.2f; %s implies %.2f. Preferring %s",
                source,ratio,expected,altName,altRatio,altName))
            self.badSince=nil;self.warning=nil
            return
        end
    end
    local text=string.format("LIFT MODEL INCONSISTENT: SUPPORT %.2f, PHYSICS %.2f (PRESSURE %s %.3f)",ratio,expected,source,used)
    if self.warning~=text and (not self.warnedAt or now-self.warnedAt>=60) then log(text);self.warnedAt=now end
    self.warning=text
end
function Monitor:snapshot(io)
    return {warning=self.warning,pressurePreference=io and io.pressurePreference or nil,lastCheck=self.lastCheck}
end
return Monitor
