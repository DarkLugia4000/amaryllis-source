# Amaryllis: next session scope

Current roadmap, 22 October 2026:
[Amaryllis computer systems plan](Amaryllis-project-plan.md). The dated scope
below is retained as historical context; use the current plan for recovery,
engineering, REMOTE OPS and manual backup priorities.

Agreed 14 October 2026. Planned work for morning of 14 October 2026, Europe/Berlin.
This is a saved implementation plan, not a scheduled task. No flight changes
or live computer restarts are authorized by saving this document alone.

Progress update, 14 October 2026: single-destination AP, Navigation tabs,
floppy destination library, click disengagement and intentional-restart
support are implemented and verified offline. Live flight tuning remains.
The portable installer has been rebuilt with these features. The broader
safe disassembly/reassembly work below remains pending; AP itself now cancels
on confirmed disassembly while recovering from unknown assembly telemetry.

## 1. Single-destination autopilot

- Add ANCHOR and AUTOPILOT views inside NAV. Anchor stays out of the top bar.
- First version: one destination, straight-line horizontal guidance.
- Enter destination X/Z; offer USE CURRENT POSITION. Present the selected
  destination, cruise speed and flight altitude before explicit ENGAGE.
- Maintain selected altitude through the existing altitude controller.
- Use the existing heading controller to turn toward the destination.
- Build forward speed as alignment permits; reduce speed for large heading
  errors. Slow before arrival using measured speed and braking response.
- At arrival, transfer to anchor at the DESTINATION X/Z. Do not capture an
  overshoot position as the intended arrival point.
- Expose distance and activity: turning, cruising, approaching, anchoring,
  and recovering. Do not claim obstacle avoidance or terrain clearance.
- AP DISENGAGE, including the light-blue/purple click input while AP is active,
  ends route authority and requests SEL speed zero, which actively controls
  forward/back velocity. It does not implicitly engage a position anchor.
- Preserve heading and altitude selections on disengagement. Resolve any
  further handover details consistently with existing cockpit neutral gates.
- Retain destination and flight intent during transient telemetry loss; pause
  commands that cannot be safely calculated and retry recovery indefinitely.
  Report prolonged failure around 120 seconds without permanent lockout.
- Preserve active AP intent across an explicit airborne RESTART SYSTEMS,
  subject to fresh same-vessel identity and hardware verification.
- Use a route-entry structure and separate guidance, arrival action and
  storage concerns so later waypoint playlists can reuse this implementation.
- Playlist editing and multiple-waypoint execution are future scope.
- Future waypoint actions may include continue, anchor/wait and finish.

## 2. Saved destinations and floppy disk

- One drive accessible to core, directly or through its wired network, is
  sufficient. Discover and verify the actual drive before implementation.
- Store named X/Z destinations on a floppy, with a versioned format that can
  later include ordered waypoint routes.
- Offer save current position, save entered destination, select, rename and
  delete. Selecting a saved destination populates it for review; it does not
  engage AP automatically or overwrite current cruise/altitude selections.
- Use a dedicated library file and preserve unrelated disk files.
- Handle missing, removed, read-only, full or malformed disks with specific
  readable errors. Failed writes must preserve the last valid library.
- Copy an engaged destination into core's active state. Removing the disk
  makes library operations unavailable but does not interrupt active flight.
- Store active flight intent in core's intentional-restart checkpoint;
  destination library persistence remains on the disk.

## 3. Safe disassembly and reassembly

### State distinction

Confirmed disassembly is different from missing or stale assembly telemetry.
Telemetry uncertainty initiates recovery and retains flight intent; it must
not be treated as confirmed disassembly. Commands requiring fresh verified
state remain gated. Keep communications, discovery and recovery running.

### Confirmed disassembly

1. Record the transition and revoke movement authority.
2. Command primaries and laterals to zero. End altitude, anchor and AP control.
3. Request and verify steam vents off with telemetry burners still running,
   using the same intended physical state as KILL LIFT. Explicitly distinguish
   this physical shutdown state from any emergency-stop latch semantics.
4. Preserve configuration, saved destinations and last selected targets.
5. Keep reading cockpit inputs for diagnostics, without interpreting held
   controls as accumulated speed, heading or altitude adjustments.
6. Continue fleet communications, sensor reads, hardware discovery, disk
   operations, settings access and recovery attempts.
7. Show DISASSEMBLED and specific verification failures. Update recurring
   timestamped log entries rather than append duplicates.

### Confirmed assembly

1. Confirm vessel identity and refresh core/chamber hardware bindings.
2. Obtain fresh world position, orientation, velocity, chamber and propulsion
   readings. Verify hardware belongs to the current vessel before commanding.
3. Read existing actuator and gas states; do not blindly zero gas or apply a
   startup boost merely because assembly was detected.
4. Require neutral cockpit inputs before manual authority returns.
5. Expose available controls and specific reasons for blocked operations.
6. Assembly alone must not launch, resume AP or re-engage an old anchor.
   START SYSTEMS, ANCHOR and AP engagement require explicit requests.
7. Keep explicit RESTART SYSTEMS while assembled/airborne as a separate
   recovery path preserving gas targets and active flight intent.

## Implementation and verification notes

- Core code is computer 35/avionics; navigator source is
  35/packages/navigation/ui.lua and installed navigator is 38/avionics/ui.lua.
- Flight.config contains ALTITUDE settings only. Anchor/AP must use full
  io.config for propulsion enable state, geometry and network timeouts.
- Keep core as command authority: reapply intended targets after transient
  mismatches. Missing hardware, unwritable providers, out-of-bounds targets,
  unverified recipients and explicit stop states need specific reasons.
- Preserve propulsion RPM caps and verified direction/reversal interlocks.
- Use current physical turning signs. Do not assume lateral translation has
  been flight-tuned simply because synthetic anchor tests passed.
- Anchor already has a world-frame controller and restart checkpoint support.
  Extend it with explicit destination-point engagement for AP arrival.
- Verify north/south/east/west guidance, bearing wraparound, heading-dependent
  acceleration, approach braking, overshoot recovery and destination anchor.
- Verify AP cancellation, manual handover, disk removal/write failures,
  prolonged telemetry loss, same-vessel reboot and changed-vessel rejection.
- Verify confirmed disassembly separately from telemetry uncertainty, held
  inputs during reassembly, altered bindings, steam-off/burner-on confirmation,
  and no automatic launch or route resumption after genuine disassembly.
- Run relevant core, navigator/package and installer checks. Clearly separate
  offline simulation evidence from live flight validation.
- Do not remotely restart or actuate the live vessel merely to test the plan.
