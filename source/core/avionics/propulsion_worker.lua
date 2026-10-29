-- @ama-section: Propulsion worker | Independent control cadence and completion heartbeat.
-- Independent control cadence; never renew abandoned core authority.
local Worker={}
-- @ama-section: Propulsion worker | Independent control cadence and completion heartbeat.
-- @ama-summary: Run one propulsion-control step and publish its completion heartbeat.
function Worker.step(io,flight,now,heartbeat)
 local t=io.thrust
 if not t then return end
 if not heartbeat or now<heartbeat or now-heartbeat>=3 then
  t:stop(io,"CORE SUPERVISION STALE");return
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
