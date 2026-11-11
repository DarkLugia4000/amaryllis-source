local Mathx = require("avionics.mathx")
-- Section: Debug recording | Removable-media capture and paced buffered writes.
-- Optional removable-media diagnostics. Only the worker performs disk I/O.
local Debug={};Debug.__index=Debug
local BUILD="amaryllis-debug-disk-v145-lift-ack-priority"
local columns={"epoch_ms","sample","sample_dt","ap_phase","ap_active","distance","cross_track","cross_speed",
 "selected_speed","cruise_speed","planned_speed","forward_speed","acceleration","sensor_age","sensor_at","speed_error","speed_integral",
 "speed_output","request_left","request_right","applied_left","applied_right","left_direction","right_direction",
 "left_ack","right_ack","left_status_age","right_status_age","heading","heading_error","yaw_rate","yaw_demand",
 "anchor_state","anchor_distance","anchor_speed","altitude","vertical_speed","systems_phase","dropped_samples",
 "systems_reason","systems_abort_reason","altitude_reason","propulsion_reason","fault_changed_epoch_ms",
 "left_endpoint_phase","left_stop_reason","left_lease_remaining_at_status","left_command_age","left_retry_attempts",
 "right_endpoint_phase","right_stop_reason","right_lease_remaining_at_status","right_command_age","right_retry_attempts",
 "core_snapshot_ms","core_propulsion_ms","core_receive_ms","core_lift_ms","core_display_send_ms"}
local baseColumnCount=#columns
local liftColumns={"core_clock_s","systems_active","systems_target_altitude","vertical_speed_target","build_limiter",
 "systems_warning","desired_support_ratio","actual_support_ratio","hover_support_ratio","feed_effort",
 "requested_vertical_acceleration","measured_vertical_acceleration","climb_stall_boost","acquisition_stall_recovery",
 "response_lag_s","fill_response_lag_s","lift_response_lag_s","command_ack_wait_s","last_lift_calculation_core_s",
 "last_command_core_s","last_applied_core_s","supply_stable","supply_step","efficiencies_valid","outputs_valid",
 "pid_active","outer_integral","inner_integral","vessel_pitch_deg","vessel_roll_deg","roll_error_blocks","pitch_error_blocks",
 "roll_rate_blocks_s","pitch_rate_blocks_s","coarse_roll_correction","coarse_pitch_correction","coarse_roll_integral",
 "coarse_pitch_integral","trim_authority_limited","level_spread_blocks","lift_recovery_state","lift_recovery_attempts","dropped_events",
 "vessel_mass","air_pressure","gravity_y","telemetry_mode","altitude_sensor_source","heading_sensor_source",
 "velocity_sensor_source","forward_speed_source","forward_speed_sable_core","forward_speed_sable_reader","forward_speed_sensor","attitude_sensor_source","mass_sensor_source","absolute_position_available","primary_pose_age_s","core_event_lag_s",
     "core_event_lag_max_s","position_projected_s","air_pressure_source","air_pressure_sensor","air_pressure_sable",
 "estimated_vertical_drag","drag_support_compensation","applied_drag_support_compensation","hold_feedforward_limited",
 "support_correction_fraction","ceiling_slew_s","vertical_speed_feedforward",
 "motion_warning","motion_warning_tone","motion_warning_axis","motion_warning_event_seq","motion_warning_event",
 "motion_warning_event_detail","motion_warning_gate","motion_delta_speed","motion_acceleration","motion_heading_delta",
 "motion_yaw_rate","motion_angular_acceleration","motion_applied_power","motion_obstruction_seconds"}
local quadrants={{"FL","fl"},{"FR","fr"},{"BL","bl"},{"BR","br"}}
local chamberColumns={"lift","filled_volume","capacity","altitude","gas_output","bulk_gas_output","provider_ceiling_total",
 "core_target_total","command_target_total","applied_target_total","trim_correction","boiler_efficiency_min","lift_rate",
 "fill_fraction","status_age_s","status_seq","received_seq","applied_seq","pending_seq","pending_sent_core_s","pending_age_s",
 "last_sent_seq","last_sent_epoch_ms","node_timing_seq","node_received_epoch_ms","node_applied_epoch_ms",
 "status_sent_epoch_ms","status_received_epoch_ms","boot","stage","ready","armed","core_ack_epoch_ms","core_ack_core_s",
 "core_receiver_epoch_ms","core_handler_epoch_ms","core_queue_wait_s","radio_priority",
 "core_first_ack_receiver_epoch_ms","core_first_ack_queue_wait_s","core_ack_reports_coalesced"}
for _,key in ipairs(liftColumns) do columns[#columns+1]=key end
for _,q in ipairs(quadrants) do for _,key in ipairs(chamberColumns) do columns[#columns+1]=q[2].."_"..key end end
local autopilotColumns={"ap_route_heading","ap_heading_bias","ap_lateral_demand","ap_primary_idle","ap_capture_settled_s"}
for _,key in ipairs(autopilotColumns) do columns[#columns+1]=key end
local throttleColumns={"throttle_mode","effective_throttle_mode","prop_forward_signal","prop_reverse_signal",
 "pilot_drive_request_pct","manual_target_acceleration","manual_measured_acceleration",
 "manual_hold_speed","manual_acceleration_state","manual_acceleration_reason","throttle_request_reason"}
for _,key in ipairs(throttleColumns) do columns[#columns+1]=key end
local eventColumns={"epoch_ms","core_clock_s","event","quadrant","node_boot","command_seq","stage","status_seq",
 "received_seq","applied_seq","node_received_epoch_ms","node_applied_epoch_ms","status_sent_epoch_ms","send_succeeded",
 "core_receiver_epoch_ms","core_handler_epoch_ms","core_queue_wait_s","radio_priority",
 "core_first_ack_receiver_epoch_ms","core_first_ack_queue_wait_s","core_ack_reports_coalesced"}
local finite = Mathx.finite
local function cell(v)
 if v==nil then return "" end
 if type(v)=="number" then return finite(v) and string.format("%.15g",v) or "" end
 if type(v)=="boolean" then return v and "1" or "0" end
 return tostring(v):gsub("[,\r\n]"," ")
end
function Debug.new(options)
 options=options or {}
 return setmetatable({fs=options.fs or fs,disk=options.disk or disk,peripheral=options.peripheral or peripheral,
  json=options.json or textutils,clock=options.clock or function() return os.epoch("utc") end,
  enabled=false,state="OFF",queue={},eventQueue={},dropped=0,droppedEvents=0,bytes=0,maxBytes=options.maxBytes or 8388608,
  reserveBytes=options.reserveBytes or 131072,maxQueue=options.maxQueue or 128},Debug)
end
-- Section: Debug recording | Removable-media capture and paced buffered writes.
-- Summary: Stage an operator request to start or stop disk debug recording.
function Debug:request(enabled)
 if type(enabled)~="boolean" then return false,"DEBUG MODE VALUE INVALID" end
 if enabled then
  if self.enabled or self.pending or self.wantStop then return false,"DEBUG MODE ALREADY ACTIVE / CHECKING DISK" end
  self.pending=true;self.state="CHECKING DISK";self.reason=nil;self.wantStart=true
  return true,"CHECKING DEBUG DISK"
 end
 self.enabled=false;self.wantStart=false;self.pending=true;self.wantStop=true;self.state="STOPPING"
 return true,"STOPPING DEBUG RECORDING"
end
-- Summary: Find removable media eligible for the current debug recording.
function Debug:media()
 local found
 if not self.peripheral or not self.disk then error("DISK DRIVE API UNAVAILABLE",0) end
 for _,name in ipairs(self.peripheral.getNames()) do
  local ok,path=pcall(self.disk.getMountPath,name)
  if ok and type(path)=="string" then
   if found then error("MULTIPLE DISKS: LEAVE ONE DEBUG DISK INSERTED",0) end
   found={name=name,path=path,id=self.disk.getID(name)}
  end
 end
 if not found then error("NO DISK: INSERT A WRITABLE DISK AT CORE",0) end
 local f=self.fs
 for _,marker in ipairs({"release.json","setup.lua","deployment.json"}) do
  if f.exists(f.combine(found.path,marker)) then error("INSTALLER DISK INSERTED: USE A DIFFERENT DISK",0) end
 end
 if f.isReadOnly(found.path) then error("DEBUG DISK IS READ ONLY",0) end
 return found
end
-- Summary: Validate the recording disk and current writable output path.
function Debug:checkMedia()
 local current=self:media();local old=self.medium
 if not old or current.name~=old.name or current.path~=old.path or current.id~=old.id then
  error("DEBUG DISK REMOVED OR REPLACED",0)
 end
 local free=self.fs.getFreeSpace(current.path)
 if free~="unlimited" and (not finite(free) or free<self.reserveBytes+4096) then error("DEBUG DISK FULL",0) end
end
-- Summary: Append the prepared debug data and track the written byte count.
function Debug:write(path,mode,data)
 local free=self.fs.getFreeSpace(self.medium.path)
 if free~="unlimited" and (not finite(free) or free<#data+self.reserveBytes) then error("DEBUG DISK FULL",0) end
 local handle,why=self.fs.open(path,mode)
 if not handle then error(why or "DEBUG DISK WRITE FAILED",0) end
 local ok,issue=pcall(function() handle.write(data);if handle.flush then handle.flush() end end)
 local closed,closeIssue=pcall(handle.close)
 if not ok or not closed then error(tostring(issue or closeIssue),0) end
end
-- Summary: Create a recording run and its disk output files.
function Debug:start(io)
 self.medium=self:media();self:checkMedia()
 local folder=self.fs.combine(self.medium.path,"amaryllis-logs")
 self.fs.makeDir(folder)
 local stem=tostring(io.localID).."-"..string.format("%.0f",self.clock())
 local run=stem;local suffix=0
 while self.fs.exists(self.fs.combine(folder,run..".csv")) or self.fs.exists(self.fs.combine(folder,run..".json")) or
  self.fs.exists(self.fs.combine(folder,run..".events.csv")) do
  suffix=suffix+1;run=stem.."-"..suffix
 end
 self.path=self.fs.combine(folder,run..".csv");self.runID=run
 self.eventPath=self.fs.combine(folder,run..".events.csv")
 local metadata={schemaVersion=6,build=BUILD,runID=run,startedEpochMs=self.clock(),coreID=io.localID,
  motionWarningThresholds=io.motionWarnings and io.motionWarnings:settings() or nil,
  coreSession=io.session,config=io.config,columns=columns,sampleIntervalSeconds=.5,
  eventColumns=eventColumns,eventFile=run..".events.csv",
  maximumRunBytes=self.maxBytes,reservedDiskBytes=self.reserveBytes,
  diagnosticNotes={fault_changed_epoch_ms="First observed sample or change of recorded core fault messages; not original fault onset",
   lease_remaining_at_status="Seconds remaining on endpoint clock when its latest status was generated; see status_age for freshness",
   command_age="Seconds since core last sent a command; does not prove endpoint receipt",
   lift_events="Core send/send_result, first accepted reports of sequence changes, and first ack_verified after target validation; matched by session, node_boot and command_seq",
   core_queue_wait_s="Core rednet receiver entry to handler entry; independent of original arrival time used for freshness; blank on backward wall clock",
   core_first_ack_queue_wait_s="First eligible applied ACK report entry to handler; survives same-sequence status coalescing while latest telemetry keeps its own receipt timestamp",
   radio_priority="Core queue hint: 2 navigator command, 1 current applied lift batch report, 0 routine; never authority or proof of target readback",
   node_applied_epoch_ms="Chamber finished writes and validated target/activation readbacks; does not mean balloon lift has settled",
   epoch_ms="UTC wall-clock milliseconds; missing endpoint stamps mean old instrumentation or unavailable clock; inspect clock jumps before subtracting",
   core_clock_s="Core monotonic seconds only; never subtract from another computer's os.clock",
   lift_samples="Existing cached readings only; chamber status_age_s and validity determine freshness; totals are blank for incomplete maps",
   support_ratio="Total pressure-adjusted envelope support divided by vessel weight",
   trim_units="Roll/pitch errors and rates are height differences in blocks; vessel_pitch_deg/vessel_roll_deg are degrees",
   prop_signals="Fresh forward and reverse cockpit redstone inputs, each 0 through 15",
   pilot_drive_request_pct="Signed cockpit request after input gates, from -100 to 100 percent",
   manual_acceleration="Lever acceleration target and filtered controller measurement in blocks/s^2; manual_hold_speed is the captured neutral speed in blocks/s",
   maximumRunBytes="Combined sample CSV and event CSV cap; recording stops earlier if disk reserve cannot be maintained"}}
 self:write(self.fs.combine(folder,run..".json"),"w",self.json.serializeJSON(metadata))
 local header=table.concat(columns,",").."\n"
 self:write(self.path,"w",header)
 local eventHeader=table.concat(eventColumns,",").."\n"
 self:write(self.eventPath,"w",eventHeader)
 self.bytes=#header+#eventHeader;self.queue={};self.eventQueue={};self.dropped=0;self.droppedEvents=0
 self.sequence=0;self.lastAt=nil;self.lastSpeed=nil;self.lastFaultKey=nil;self.faultChangedAt=nil
 self.enabled=true;self.pending=false;self.wantStart=false;self.wantStop=false;self.state="RECORDING";self.reason=nil
end
-- Summary: Append a bounded lift-command or readback event to the debug buffer.
function Debug:liftEvent(event)
 if not self.enabled then return end
 if #self.eventQueue>=self.maxQueue then self.droppedEvents=self.droppedEvents+1;return end
 local row={event.epochMs,event.clock,event.kind,event.quadrant,event.boot,event.seq,event.stage,event.statusSeq,
  event.receivedSeq,event.appliedSeq,event.nodeReceivedEpochMs,event.nodeAppliedEpochMs,event.statusSentEpochMs,event.sendSucceeded,
  event.coreReceiverEpochMs,event.coreHandlerEpochMs,event.queueWaitSeconds,event.radioPriority,
  event.firstAckReceiverEpochMs,event.firstAckQueueWaitSeconds,event.ackReportsCoalesced}
 local out={};for i=1,#eventColumns do out[i]=cell(row[i]) end
 self.eventQueue[#self.eventQueue+1]=table.concat(out,",").."\n"
end

local function targetTotal(map,providers,expected)
 if type(map)~="table" or type(providers)~="table" or next(providers)==nil then return nil end
 local sum,count=0,0
 for name in pairs(providers) do if not finite(map[name]) then return nil end;sum=sum+map[name];count=count+1 end
 return count==expected and sum or nil
end
-- Summary: Sum valid provider observations for a chamber measurement.
local function providerTotal(providers,key,validity,bulkOnly,expected)
 if type(providers)~="table" or next(providers)==nil then return nil end
 local sum,count=0,0
 for _,p in pairs(providers) do
  if not bulkOnly or p.controlRole=="bulk" then
   if p[validity]~=true or not finite(p[key]) then return nil end
   sum=sum+p[key];count=count+1
  end
 end
 return count==expected and sum or nil
end
-- Summary: Convert the current cached runtime snapshot into buffered debug records.
function Debug:capture(snapshot,io,now,flight)
 if not self.enabled then return end
 local v=io.vessel or {};local t=io.thrust or {};local ap=io.autopilot or {}
 local speed=t.speedControl or {};local loop=t.speedLoop or {};local heading=t.headingControl or {}
 local applied=type(t.speedApplied)=="function" and t:speedApplied(now) or {}
 local roles=(snapshot.thrust or {}).roles or {};local left=roles["thrust-ls"] or {};local right=roles["thrust-rs"] or {}
 local anchor=snapshot.anchorControl or {};local dt=self.lastAt and now-self.lastAt
 local acceleration=dt and dt>0 and finite(v.forwardSpeed) and finite(self.lastSpeed) and (v.forwardSpeed-self.lastSpeed)/dt or nil
 local systems=snapshot.systemsStartup or {};local altitude=snapshot.altitudeControl or {}
 local propulsion=snapshot.thrust or {}
 local faultValues={systems.reason or "",systems.abortReason or "",altitude.reason or "",propulsion.reason or ""}
 local faultKey=table.concat(faultValues,"\0")
 if self.lastFaultKey~=faultKey then self.lastFaultKey=faultKey;self.faultChangedAt=self.clock() end
 local function endpoint(role)
  local node=(t.controllers or {})[role] or {};local status=node.status or {};local recovery=node.commandRecovery or {}
  local age=finite(node.lastCommandAt) and now>=node.lastCommandAt and now-node.lastCommandAt or nil
  return {status.phase,status.reason,status.leaseRemainingSeconds,age,recovery.attempts}
 end
 local le,re=endpoint("thrust-ls"),endpoint("thrust-rs")
 local performance=snapshot.performance or (io.runtimeMetrics and io.runtimeMetrics:snapshot()) or {}
 local function timing(name) return (performance[name] or {}).lastMs end
 self.sequence=self.sequence+1
 local row={self.clock(),self.sequence,dt,ap.state,ap.active,ap.distance,ap.crossTrack,ap.crossSpeed,
  snapshot.targets and snapshot.targets.speed,ap.cruiseSpeed,ap.speedTarget,v.forwardSpeed,acceleration,
  snapshot.vessel and snapshot.vessel.sampleAgeSeconds,v.at,speed.error,loop.integral,speed.output,
  t.requested and t.requested["primary-left"],t.requested and t.requested["primary-right"],applied.left,applied.right,
  left.direction,right.direction,left.commandAcknowledged,right.commandAcknowledged,left.statusAgeSeconds,right.statusAgeSeconds,
  v.heading,heading.headingError,heading.measuredYawRate,heading.yawDemand,anchor.state,anchor.distance,anchor.horizontalSpeed,
  v.altitude,v.verticalSpeed,systems.phase,self.dropped,
  systems.reason,systems.abortReason,altitude.reason,propulsion.reason,self.faultChangedAt,
  le[1],le[2],le[3],le[4],le[5],re[1],re[2],re[3],re[4],re[5],
  timing("snapshot"),timing("propulsion"),timing("receive"),timing("lift_control"),timing("display_send")}
 flight=flight or {}
 local run=flight.systemsRun or {};local dynamics=run.dynamics or {};local trim=flight.trimStatus or {}
 local rates=flight.levelRates or {};local coarse=flight.coarseSteamTrim or {};local coarseI=flight.coarseSteamTrimIntegral or {}
 local recovery=run.telemetryRecovery or {};local feed=run.hoverFeedForward or {}
 local motion=snapshot.motionWarnings or {};local motionData=motion.measurements or {};local motionEvent=motion.event or {}
 local extra={core_clock_s=now,systems_active=systems.active,systems_target_altitude=run.target or systems.target,
  vertical_speed_target=flight.verticalTarget or systems.verticalSpeedTarget,build_limiter=run.speedLimiter or systems.speedLimiter,
  systems_warning=systems.warning,desired_support_ratio=run.lastDesiredRatio,actual_support_ratio=dynamics.actualRatio,
  hover_support_ratio=feed.targetSupportRatio,feed_effort=flight.effort,requested_vertical_acceleration=run.lastRequestedAcceleration,
  measured_vertical_acceleration=dynamics.verticalAccelerationRaw,climb_stall_boost=run.climbStallBoost,
  acquisition_stall_recovery=run.acquisitionStallRecovery,response_lag_s=run.responseLagSeconds,
  fill_response_lag_s=run.fillResponseLagSeconds,lift_response_lag_s=run.liftResponseLagSeconds,
  command_ack_wait_s=run.lastAckWaitSeconds,last_lift_calculation_core_s=run.lastLiftCalculationAt,
  last_command_core_s=run.lastTargetCommandAt,last_applied_core_s=run.lastTargetAppliedAt,
  supply_stable=dynamics.supplyStable,supply_step=dynamics.supplyStep,efficiencies_valid=dynamics.efficienciesValid,
  outputs_valid=dynamics.outputsValid,pid_active=run.acquisitionPidActive,outer_integral=(flight.outer or {}).i,
  inner_integral=(flight.inner or {}).i,vessel_pitch_deg=v.pitch,vessel_roll_deg=v.roll,
  roll_error_blocks=trim.rollHeightError,pitch_error_blocks=trim.pitchHeightError,roll_rate_blocks_s=rates.roll,
  pitch_rate_blocks_s=rates.pitch,coarse_roll_correction=coarse.roll,coarse_pitch_correction=coarse.pitch,
  coarse_roll_integral=coarseI.roll,coarse_pitch_integral=coarseI.pitch,trim_authority_limited=trim.authorityLimited,
  level_spread_blocks=trim.levelSpreadBlocks,lift_recovery_state=recovery.stage,lift_recovery_attempts=recovery.attemptCount,
  dropped_events=self.droppedEvents,vessel_mass=v.mass,air_pressure=(v.environment or {}).airPressure,
  gravity_y=((v.environment or {}).gravity or {}).y,telemetry_mode=(v.sources or {}).mode,
  altitude_sensor_source=(((v.sources or {}).fields or {}).altitude or {}).source,
  heading_sensor_source=(((v.sources or {}).fields or {}).heading or {}).source,
  velocity_sensor_source=(((v.sources or {}).fields or {}).linearVelocity or {}).source,
  forward_speed_source=(((v.sources or {}).fields or {}).forwardSpeed or {}).source,
  forward_speed_sable_core=v.forwardSpeedSableCore,forward_speed_sable_reader=v.forwardSpeedSableReader,
  forward_speed_sensor=v.forwardSpeedSensor,
  attitude_sensor_source=(((v.sources or {}).fields or {}).pitch or {}).source,
  mass_sensor_source=(((v.sources or {}).fields or {}).mass or {}).source,
  absolute_position_available=(v.sources or {}).positionAvailable,primary_pose_age_s=(v.sources or {}).primaryAgeSeconds,
  core_event_lag_s=io.eventLagSeconds,core_event_lag_max_s=io.eventLagMaxSeconds,position_projected_s=(v.sources or {}).positionProjectedSeconds,
  air_pressure_source=(v.environment or {}).airPressureSource,air_pressure_sensor=(v.environment or {}).airPressureSensor,air_pressure_sable=(v.environment or {}).airPressureSable,
  estimated_vertical_drag=dynamics.verticalDragEstimate,drag_support_compensation=run.dragSupportCompensation,
  applied_drag_support_compensation=run.appliedDragSupportCompensation,hold_feedforward_limited=run.holdFeedForwardLimited,
  support_correction_fraction=run.lastSupportCorrectionFraction,ceiling_slew_s=run.lastCeilingSlewSeconds,
  vertical_speed_feedforward=run.verticalSpeedFeedForward,
  motion_warning=motion.text,motion_warning_tone=motion.tone,motion_warning_axis=motion.axis,
  motion_warning_event_seq=motion.eventSeq,motion_warning_event=motionEvent.kind,motion_warning_event_detail=motionEvent.detail,
  motion_warning_gate=motion.gate,motion_delta_speed=motionData.deltaSpeed,motion_acceleration=motionData.acceleration,
  motion_heading_delta=motionData.headingDelta,motion_yaw_rate=motionData.yawRate,motion_angular_acceleration=motionData.angularAcceleration,
  motion_applied_power=motion.appliedPower,motion_obstruction_seconds=motion.obstructionSeconds}
 local nextColumn=baseColumnCount
 for _,key in ipairs(liftColumns) do nextColumn=nextColumn+1;row[nextColumn]=extra[key] end
 for _,q in ipairs(quadrants) do
  local id=q[1];local n=(io.nodes or {})[id] or {};local b=n.balloon or {};local p=n.providers
  local bulkCount=n.steamCount or 8;local providerCount=bulkCount+1
  local state=(dynamics.quadrants or {})[id] or {};local pending=(run.pending or {})[id] or {}
  local command=n.lastSystemsCommand or {};local stamps=n.systemsCommandTiming or {}
  local age=finite(n.lastSeen) and now>=n.lastSeen and now-n.lastSeen or nil
  local data={lift=b.liftValid==true and b.lift or nil,filled_volume=b.filledVolumeValid==true and b.filledVolume or nil,
   capacity=b.capacityValid==true and b.capacity or nil,altitude=(n.altitude or {}).valid==true and n.altitude.sensorWorldY or nil,
   gas_output=providerTotal(p,"gasOutput","gasOutputValid",false,providerCount),bulk_gas_output=providerTotal(p,"gasOutput","gasOutputValid",true,bulkCount),
   provider_ceiling_total=providerTotal(p,"targetAmount","targetValid",false,providerCount),core_target_total=targetTotal((run.currentTargets or {})[id],p,providerCount),
   command_target_total=targetTotal((run.batchTargets or {})[id],p,providerCount),applied_target_total=targetTotal(n.appliedTargets,p,providerCount),
   trim_correction=(flight.trim or {})[id],boiler_efficiency_min=state.minimumBoilerEfficiency,lift_rate=state.liftRate,
   fill_fraction=state.fillFraction,status_age_s=age,status_seq=n.statusSeq,received_seq=n.lastReceivedSeq,applied_seq=n.lastAppliedSeq,
   pending_seq=pending.seq,pending_sent_core_s=pending.sentAt,pending_age_s=finite(pending.sentAt) and now>=pending.sentAt and now-pending.sentAt or nil,
   last_sent_seq=command.seq,last_sent_epoch_ms=command.sentEpochMs,node_timing_seq=stamps.seq,node_received_epoch_ms=stamps.receivedEpochMs,
   node_applied_epoch_ms=stamps.appliedEpochMs,status_sent_epoch_ms=n.statusSentEpochMs,status_received_epoch_ms=n.statusReceivedEpochMs,
   core_receiver_epoch_ms=n.statusReceiverEpochMs,core_handler_epoch_ms=n.statusHandlerEpochMs,
   core_queue_wait_s=n.statusQueueWaitSeconds,radio_priority=n.statusPriority,
   core_first_ack_receiver_epoch_ms=n.statusFirstAckReceiverEpochMs,
   core_first_ack_queue_wait_s=n.statusFirstAckQueueWaitSeconds,core_ack_reports_coalesced=n.statusAckReportsCoalesced,
   boot=n.boot,stage=n.systemsStage,ready=n.ready,armed=n.armed,
   core_ack_epoch_ms=command.ackEpochMs,core_ack_core_s=command.ackAt}
  for _,key in ipairs(chamberColumns) do nextColumn=nextColumn+1;row[nextColumn]=data[key] end
 end
 local apData={ap_route_heading=ap.routeHeading,ap_heading_bias=ap.headingBias,
  ap_lateral_demand=ap.crossDemand,ap_primary_idle=ap.primaryIdle==true,
  ap_capture_settled_s=ap.captureSettledSeconds}
 for _,key in ipairs(autopilotColumns) do nextColumn=nextColumn+1;row[nextColumn]=apData[key] end
 -- Record pilot intent beside the controller decision, using the fresh input
 -- snapshot and the MAN controller fields for the current propulsion request.
 local inputs=snapshot.inputs or {}
 local raw=inputs.valid==true and inputs.raw or {}
 local request=propulsion.request or {}
 local manual=request.manualDriveOutput and propulsion.manualAcceleration or {}
 local throttleData={
  throttle_mode=(snapshot.modes or {}).throttle,
  effective_throttle_mode=(snapshot.effectiveModes or {}).throttle,
  prop_forward_signal=raw.prop_forward,prop_reverse_signal=raw.prop_reverse,
  pilot_drive_request_pct=(snapshot.cockpitControl or {}).propulsionRequestPercent,
  manual_target_acceleration=manual.targetAcceleration,manual_measured_acceleration=manual.measuredAcceleration,
  manual_hold_speed=manual.holdingSpeed,manual_acceleration_state=manual.state,
  manual_acceleration_reason=manual.reason,throttle_request_reason=request.throttleReason,
 }
 for _,key in ipairs(throttleColumns) do nextColumn=nextColumn+1;row[nextColumn]=throttleData[key] end
 local out={};for i=1,#columns do out[i]=cell(row[i]) end
 self.lastAt=now;self.lastSpeed=v.forwardSpeed
 if #self.queue>=self.maxQueue then self.dropped=self.dropped+1;return end
 self.queue[#self.queue+1]=table.concat(out,",").."\n"
end
-- Summary: Write buffered records and update saved/dropped counters.
function Debug:flush()
 if #self.queue==0 and #self.eventQueue==0 then return end
 self:checkMedia()
 local data=table.concat(self.queue)
 local eventData=table.concat(self.eventQueue)
 if self.bytes+#data+#eventData>self.maxBytes then error("DEBUG RUN SIZE LIMIT REACHED; START A NEW RUN",0) end
 local free=self.fs.getFreeSpace(self.medium.path)
 if free~="unlimited" and free<#data+#eventData+self.reserveBytes then error("DEBUG DISK FULL",0) end
 local samples,events=#self.queue,#self.eventQueue
 self.queue={};self.eventQueue={}
 if #data>0 then
  local ok,issue=pcall(self.write,self,self.path,"a",data)
  if not ok then self.dropped=self.dropped+samples;self.droppedEvents=self.droppedEvents+events;error(issue,0) end
  self.bytes=self.bytes+#data
 end
 if #eventData>0 then
  local ok,issue=pcall(self.write,self,self.eventPath,"a",eventData)
  if not ok then self.droppedEvents=self.droppedEvents+events;error(issue,0) end
  self.bytes=self.bytes+#eventData
 end
end
-- Summary: Advance queued recording requests and paced buffer writes.
function Debug:step(io)
 local ok,issue=pcall(function()
  if self.wantStart then self:start(io) end
  if self.enabled then self:checkMedia();self:flush() end
  if self.wantStop then self:flush();self.wantStop=false;self.pending=false;self.state="OFF";self.reason=nil end
 end)
 if not ok then
  self.enabled=false;self.pending=false;self.wantStart=false;self.wantStop=false
  self.state="ERROR";self.reason=tostring(issue):gsub("[\r\n]"," "):sub(1,180)
  self.dropped=self.dropped+#self.queue;self.droppedEvents=self.droppedEvents+#self.eventQueue
  self.queue={};self.eventQueue={}
 end
end
function Debug:snapshot()
 return {enabled=self.enabled,pending=self.pending,state=self.state,reason=self.reason,runID=self.runID,
  path=self.path,diskID=self.medium and self.medium.id,drive=self.medium and self.medium.name,
  bytes=self.bytes,queued=#self.queue+#self.eventQueue,dropped=self.dropped+self.droppedEvents,
  droppedSamples=self.dropped,droppedEvents=self.droppedEvents,eventPath=self.eventPath,build=BUILD,maxBytes=self.maxBytes}
end
return Debug
