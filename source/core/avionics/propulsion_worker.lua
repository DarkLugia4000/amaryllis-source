-- Section: Propulsion worker | Independent control cadence and completion heartbeat.
-- Independent control cadence; never renew abandoned core authority.
local Worker={}
-- Section: Propulsion worker | Fault wording for a missing core heartbeat.
function Worker.supervisionText(now,heartbeat)
 if type(heartbeat)~="number" then return "CORE SUPERVISION NEVER REPORTED; CHECK CORE" end
 if now<heartbeat then return "CORE SUPERVISION CLOCK WENT BACKWARDS; CHECK CORE" end
 -- Propulsion stops after 3 s; the age is named once the gap passes 10 s.
 if now-heartbeat<=10 then return "WAITING FOR CORE SUPERVISION" end
 return string.format("CORE SUPERVISION SILENT %.0f S; SERVER LAG OR CORE STALL",now-heartbeat)
end
-- Section: Propulsion worker | Independent control cadence and completion heartbeat.
-- Summary: Run one propulsion-control step and publish its completion heartbeat.
function Worker.step(io,flight,now,heartbeat)
 local t=io.thrust
 if not t then return end
 -- Published for the propulsion enable check: enabling waits for START SYSTEMS READY.
 io.systemsReady=flight.systemsRun~=nil and flight.systemsRun.phase=="READY"
 if not heartbeat or now<heartbeat or now-heartbeat>=3 then
  t:stop(io,Worker.supervisionText(now,heartbeat));return
 end
 if flight.restart.saved or flight.emergencyLiftLatched then
  t:stop(io,flight.emergencyLiftLatched and "EMERGENCY LIFT KILL" or "SYSTEMS RESTARTING");return
 end
 local controls=flight.controls
 if not controls then return end
 -- Lever data loss alone does not stop propulsion: levers read as neutral
 -- and SEL / autopilot / anchor keep their authority.
 if type(controls.usable)=="function" then
  local usable,reason=controls:usable(io,now)
  if not usable then t:stop(io,reason or "COCKPIT CONTROLS UNAVAILABLE");return end
 end
 io.propulsionHoldSuppressed=flight.systemsRun and flight.systemsRun.phase~="READY" and "IDLE DURING START SYSTEMS" or nil
 t:update(io,now,controls)
end
return Worker
