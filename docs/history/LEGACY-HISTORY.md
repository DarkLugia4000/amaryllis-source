# Amaryllis portable installer

Current installer build: **v146, 24 October 2026, bundled Amaryllis lift-learning defaults**.
The installer includes an explicit snapshot of Amaryllis' five saved 20-block
hover-correction bands and saved roll/pitch leveling bias. These two small JSON
files seed a fresh core's existing learning loaders. They are copied only when
the corresponding local file is absent, including after an interrupted install.
Local learned values always win. Adaptive learning continues after installation.
The profile is a starting point for the Amaryllis blueprint; changed load or
balloon geometry can require further settling and learning.
No live PID integrals, derivative history, restart checkpoints, kill flags,
gas commands, vessel IDs or remote credentials are bundled. Installer validation
pins the two allowed data paths, schema, numerical bounds and checksums before
any installation writes. Existing complete installations remain protected by
the fresh-install gate. Live computers and the in-world disk were not changed.
Core/controller code and configured gains are identical to the tested v145 build.
The portable minimum selectable altitude remains 100 (Journeys uses 120).

Previous core build: **v145, 24 October 2026, pending lift-ACK queue priority and timing**.
Cockpit input retains its dedicated fast receiver and checks before radio work.
The bounded 128-message radio inbox selects registered navigator requests first,
then identity/session/boot/sequence-bound applied reports for the current lift
batch, followed by routine traffic. FIFO remains within each class. Current
applied reports can displace routine status in a full inbox and cannot be erased
by an ordinary out-of-order replacement. Every report still passes the complete
IO validation and exact-target readback checks; priority never grants authority.
New debug schema 5 records core receiver entry, handler entry, queue wait and
priority in the existing bounded recording buffers. It adds no status messages,
peripheral reads or disk writes in the control path. Original receipt time still
governs telemetry freshness. PID settings, prediction, batch completion checks,
lease durations and control cadence are unchanged for this comparison.
Live deployment changes only core's main.lua, radio_inbox.lua, io.lua and
debug_recorder.lua. The portable state payload also receives the compatible
optional IO timing arguments through its existing shared dependency; live state
does not require an update. In-game timing improvement remains unverified.

Previous build: **v144, 23 October 2026, lift recovery after a locally blocked control send**.
Core now detects an expired chamber probe lease even when its local send guard
rejects the control command before creating a pending sequence. Recovery
reconciles the retained maps, re-enters the probe stage, verifies acknowledgments
and then restores control. Existing identity, hardware and retry pacing guards
remain in force. Probe preserves each actual bulk ceiling and activation state.
Only core's flight.lua changes; chamber packages, state and navigator are unchanged.
The simulated failure reproduces on v143. Validation passes 48 focused checks,
236 existing recovery checks and five real chamber-receiver fault-lifecycle checks.
An invalid current altitude still blocks probe; a newly accepted valid probe
clears the retained altitude/application fault. Cockpit and remote AP regressions
also pass. In-game acceptance remains pending loading the staged core update.

Previous diagnostic build: **v143, 23 October 2026, per-sample cockpit timing**.
Core and ama-state keep fixed-size 256-sample timing buffers, with bounded
mutation-cursor exports over the existing read-only diagnostic connection.
The trace correlates read completion, transmit attempt/return, receiver entry,
validation and first Controls consumption. Rechecking an already-consumed batch
does not change its first-consumption timestamp. Two scheduling wakeups per
second and bounded core-operation timings help distinguish waiting from work.
Installer pause checks and its loop heartbeat are inspected from memory.
No onboard trace files, extra sensor polls or control commands are introduced.
The operator loaded core/state with supported restarts, and both virtual traces
are verified publishing. The neutral warm/paused/resumed comparison is complete:
nearly all measured delay precedes core receiver entry; consumption after entry
took at most 2 ms. Installer pause improved the recorded distribution but left
stalls near two seconds. A shell-operated pause/resume cycle worked without a
tab restart; the earlier host-removal issue remains unexplained. Full findings
are in diagnostics/2026-10-23/v143-cockpit-timing/findings.md. The collector and
comparison procedure are in [COCKPIT_TIMING_RUN.md](../diagnostics/COCKPIT_TIMING_RUN.md).

Previous package: **v142, 23 October 2026, cockpit processing priority**.
This includes the current HOLD integral-learning changes, commanded
vertical-speed feed-forward and its debug recording field. It also retains
remote AP, docked remote provisioning and the optional ama-state reader.
Packaging checks do not establish in-game acceptance of the latest PID tuning.

Deployed in Amaryllis Trial Journeys: **v142, 23 October 2026**.
This includes the v141 navigator queue and v140 installer workload changes
below. With the operator confirming physical support, core #0 and ama-state #1
were updated and restarted, then navigator #5 received a committed v11 package
and was restarted. All fourteen wireless package receipts, identities, Lua files
and cleared commit journals were verified. Core/state delta files match release
objects. Fleet assignments and existing core/state settings were preserved.
The in-world commissioning disk was not rewritten by this delta deployment.

Live acceptance remains partial. The cockpit fast path is receiving and processing
input, and the installer warmed fourteen bundles (3,748,256 payload bytes) with
hundreds of subsequent cache hits and no further misses at the final audit.
Short samples still caught roughly two-second processing delays with the cache
warm, so priority and caching have not eliminated the latency problem. Removing
the pause marker did not advance the running PAUSED tab in this session; the
operator restarted only that installer tab to resume. The cause is unconfirmed.
See diagnostics/2026-10-23/v142-live-deployment for the audit and timing samples.

Ama-state sends each completed valid cockpit batch immediately as a small
cockpit_frame, independently of the full sensor-frame builder/sender. The
existing cockpit polling interval is unchanged. Core receives these messages
in a separate coroutine, before its full telemetry receiver, and consumes the
pilot batch without waiting for calibration I/O or telemetry composition. Full
frames retain compatibility and cannot overwrite a newer cockpit sample.
The fast path requires an already validated state-reader boot, matching wired
side/channel, IDs, core session, sequence and fresh, coherent raw input levels.

Core services current cockpit input before routine message drains, between
handled messages, and before discovery/housekeeping/remote operations. Updates
of unchanged input are throttled, while Controls retains its duplicate-sample,
stale-input, neutral-return, identity and assembly gates. Trusted navigator
commands precede routine radio reports without reordering their own requests.
Cockpit workers start first on state and in core's local/failover readers.
No extra sensor polls, actuator writer on state, persisted input queue or
relaxed freshness limits were added. This gives priority within the application;
it cannot preempt a stalled Minecraft server or non-yielding Lua operation.

State-reader diagnostics now include fast-input receipt/transport counters,
the timestamp actually consumed by Controls, processing time and callback
errors. Queued navigator deadlines are checked at execution time, while
telemetry keeps its original reception timestamp for age calculations.
Priority tests pass 54 checks, including a telemetry coroutine blocked in
calibration I/O while actual Controls consumes fresh throttle, AP disconnect,
replay/authority/freshness rejection, neutral return, immediate state-side
publication, supervisor order and delayed command expiry. Radio backlog,
navigator queue (195), input tuning (54), remote AP (78), docking (73) and
pocket radio/UI (29) regressions pass.

Navigator keeps a volatile outbox of up to eight commands, with one ordinary
request in flight. It displays COMMAND QUEUED / WAITING FOR CORE instead of
retiring a request after one status timeout. Retries reuse the original boot,
core session, sequence, action and deadline, with backoff capped at five seconds.
Core remembers up to 32 results and returns the prior result for an identical
retry without repeating the action. A late matching acknowledgement can resolve
the request even when the latest display snapshot is stale. Wrong sender,
protocol, boot, session and sequence cannot acknowledge it.

Newer unsent settings and mode selections replace older requests for the same
field. Relative trim adjustments retain order. Stop/kill and disengagement
commands take priority and retire obsolete queued work. Core-session changes
clear the outbox. Ordinary commands expire after 30 seconds; restart, lift-kill,
disarm, start/recover, confirmation and other context-sensitive actions use ten
seconds. Core checks expiry before executing. An unsent expired command is
CANCELLED; a sent request lacking a result becomes NOT CONFIRMED; CHECK CORE.
That outcome can still resolve on a late matching reply. The queue is not saved
across boots, and acceptance is distinct from completed actuator work.

Navigator request tests pass 195 checks, including dropped/delayed replies,
duplicate relative actions, bounded queues/result ledgers, priority, source
session changes, expiry, altered-ID replay and actual UI feedback. Input tuning,
remote AP, docking, bootstrap and installer regressions pass. The targeted
restart checks and 46 airborne-restart checks pass. An older broad telemetry
fixture still fails on its missing controls.usable mock method in both the
pre-v141 and v141 flight code; it is not claimed as a passing check.

v140 keeps verified wireless packages in an installer-local memory cache,
bounded to 14 entries and 8 MiB of payload bytes. It checks source file sizes
and modification timestamps at most every five seconds per cached package.
Changed files, forced reinstalls and restarted installers require verification;
missing or unsupported metadata falls back to full verification. Sources that
change during verification are rejected for that attempt. Cold checksums yield
every 8 KiB and package reads yield between files. Fleet/session authority is
still checked live before delivery and during transfers.

The presence of `/installer/paused` pauses package service without stopping
flight workers. Removing that file resumes service. Pause requests retire an
active transfer at its next authority check; a commit already sent may finish
on its recipient. The old v139 service does not recognize this control, so its
first use requires loading v140. CHECK and PAUSED appear in the progress view.
The cache is memory-only and is never written as a second package copy on disk.
No PID gains, altitude freshness limits, leases or actuator behavior changed.

Offline verification: 40 workload checks, 465 receipt/transport/terminal checks,
bootstrap guard checks and 452 portable installer checks passed. Source, objects
and ZIP match. These checks do not establish that the installer caused all
observed lag; a supported-vessel paused/active comparison remains outstanding.

## Installation progress and recovery

Core's installer tab shows the active computer and role, acknowledged transfer
percentage, file count, retry count, and a fleet list with WAIT, OFFER, SEND,
VERIFY, DONE or FAULT. DONE means a committed package, not a hardware or flight
readiness check. The wired state reader is installed locally and is excluded
from the wireless package total. The view uses cached installer state, redraws
at most four times per second, and adds no sensor polls or status-file reads.

The complete local receipt, including installedCoreID, is saved before any
installed state is published. Fresh bootstraps reboot only after commit cleanup
and a matching computer/core identity. A prior committed install missing only
installedCoreID can recover that field after every other receipt check and a
live matching core registration pass. Conflicting identity records and pending
commit journals remain blocked. This prevents repeated downloads after an early
bootstrap restart without weakening the installer identity checks.

Fresh-install space checks include per-file allocation padding, generated
metadata and temporary replacement writes. A newly created file is counted
once. Retrying an owned interrupted install verifies and reuses unchanged
files, rather than rewriting them; existing-install and journal checks remain
in force. The computer storage requirement remains 4,000,000 bytes.

## Cockpit input tuning

Open SETTINGS > INPUT TUNING. Selected heading has a tap size, initial held
adjustment rate, held-input acceleration and maximum adjustment rate. Selected
speed has its own initial rate, held-input acceleration and maximum rate.
Altitude retains its slow/medium/fast input rates and hold thresholds on a
separate page. The repeat delay is shared by heading and altitude input.

These settings change how quickly the selected value changes while an input
is held. They do not change vessel turn-rate limits, physical acceleration
limits or PID gains. A held-input acceleration of zero gives a constant rate;
existing configurations default to zero and retain their previous initial
heading and speed selection rates. Heading taps retain their previous size.

Changes save to core configuration and survive reboot. Release the relevant
input after saving before adjusting a target again. Release, reversal, input
loss and mode interlocks reset the held-input ramp. Selection bounds remain
enforced, and missed input samples cannot accumulate a burst of adjustments.

## Possible impact and obstruction warnings

The Flight message row shows POSSIBLE IMPACT in red after an abrupt change in
measured velocity or rotation, and POSSIBLE OBSTRUCTION in yellow after
sustained applied propulsion without the expected forward, sideways or turning
response. These are advisory messages: neither changes lift, propulsion, AP,
anchor state, modes or authority. They do not provide obstacle avoidance.

The initial obstruction window is 10 seconds with at least 50% of configured
drive authority confirmed in fresh controller readbacks. Translation below
0.15 b/s or turning below 0.1 degrees/s must also show little acceleration.
Anchors, braking/opposed drive direction, turning before forward acquisition,
low/unconfirmed output and stale/unavailable controllers reset the relevant
checks. The detector requires verified vessel identity/assembly and fresh
original velocity/heading sample times. Source changes, measurement gaps and
new vessel identities start a fresh two-second baseline. Cached duplicate
frames never advance the observation window.

Initial impact thresholds are a velocity-vector change of at least 4 b/s and
8 b/s^2, or abrupt actual rotation (at least 15 degrees at 30 degrees/s, or a
12 degrees/s yaw-rate change at 25 degrees/s^2). An impact message remains for
10 seconds; repeated impact events have a 15-second cooldown. Heading wrap
uses the shortest signed angle. These conservative starting thresholds still
need in-world evaluation; a warning indicates a possible event, not confirmed
physical contact. Very short disturbances between published samples can be
missed.

Warnings use existing cached telemetry in the status publication path, with
bounded state and no extra sensor polls or control loops. Onset and recovery
are logged without repeating a continuing warning. Debug CSVs include active
warning, axis, event sequence/detail, velocity and rotation changes, confirmed
power, observation duration and detector gate. Recording metadata includes the
resolved thresholds. Optional core motion_warnings configuration overrides are
bounded by avionics/motion_warnings.lua; invalid warning configuration disables
the detector without disabling flight control.

This release contains current core software, every auxiliary package, the
existing verified vessel layout and tuning, and a fresh-computer setup menu.
It includes the single-destination autopilot, Navigation views and floppy
destination library support. It does not include active flight state, logs,
backups, tests, old computer IDs or the user's saved destinations. The broader
disassembly/reassembly work remains separate planned scope.

## Optional ama-state reader

For an isolated core, install an additional computer using auxiliary role
`state`. This role is installed directly from the disk and connects to core
through enabled wired modems and cable. Place it aboard the vessel and connect
the sensors and cockpit link bridge to its peripheral network. It needs no
wireless modem. Computer blocks touching alone cannot exchange the data.

Return the disk to core and import role assignments, then boot ama-state before
core. Core normally delegates sensor/input polling when the state role is
assigned, and can start local readers if the helper stops supplying accepted
frames. Keep the shared sensors reachable over the wired network for this
fallback. An unassigned state role retains local sampling. All flight decisions and
actuator commands remain on core. Initial testing must be done with the vessel
supported and flight stopped. Existing state-reader upgrades currently use
managed file staging; automatic wired package updating is not implemented.

## Autopilot use

The forward selected-speed and AP cruise ceiling is 30 b/s. Reverse selected
speed retains its existing -20 b/s limit. Existing pockets need a docked remote
update to accept cruise speeds above 20 b/s in their local entry form.

Use RESTART SYSTEMS to load core/navigator updates on an existing airborne
installation; this disk menu itself is for fresh computers only.

Under NAV, choose AUTOPILOT. Set destination X/Z, cruise speed and altitude,
or use your current position or a saved destination. Establish altitude hold,
enable propulsion, release throttle/steering inputs and explicitly ENGAGE.
The route follows a straight line, reduces forward speed while turning,
slows on approach and anchors at the destination's exact X/Z.

DISENGAGE or the light-blue/purple click input returns throttle, heading and
lateral controls to MANUAL, requiring neutral input before pilot control resumes.
Selected targets are retained and altitude hold remains independent.
Transient telemetry failures retry without discarding the route. An intentional
RESTART SYSTEMS preserves active AP/anchor intent. Confirmed disassembly or
changed vessel identity requires explicit re-engagement.

One disk drive accessible to core is enough for the destination library.
Save, select, rename and delete named X/Z destinations using SAVED DESTINATIONS.
The dedicated amaryllis-destinations.json file preserves unrelated disk files.
Removing the disk does not change the active flight destination. Routes,
terrain clearance and obstacle avoidance are not implemented in this version.

## Disk debug recording

On the bridge, open SETTINGS > DEBUG MODE and choose START DEBUG RECORDING.
Core must see exactly one writable data disk. Installer media (release.json,
setup.lua or deployment.json) is refused before any write. Validation and
recording errors appear on the Debug settings page. Debug starts OFF after
reboot and does not change flight authority.

Each start creates unique CSV and JSON files in amaryllis-logs/ on that disk.
Metadata records the diagnostic build, core session and loaded configuration.
Telemetry includes AP phase, planned/measured speed, acceleration, PID state,
requested/applied thrust, direction, acknowledgements and anchor state.
Recording uses an independent worker and a bounded memory queue. Each run is
limited to 8 MiB across sample and event CSV files and reserves 128 KiB of disk space. Older runs and destinations
are never deleted. A full, removed, replaced or unwritable disk stops recording
and reports an error without stopping flight. Stop recording before removing
the disk or restarting systems to flush the last buffered samples.
Automatic internal flight-log CSV writes are disabled; existing logs remain.

## Docked remote installation

Core's own console has UTILITIES > [R] Install / pair remote. Insert a pocket
computer (or a standalone computer intended as a remote) into a disk drive
accessible to core, select the drive, review it, and type INSTALL to confirm.
Inserting media alone never installs software. Floppies, installer media and
onboard controller installations are refused. No bridge UI action is needed.

The utility installs a local remote application and startup launcher, pairs
it with the actual core ID, and preserves other files. An existing startup
is retained at /remote/original-startup.lua. Existing /admin.lua management
tools and their credentials are retained and available through A on the new
remote home screen. O opens the original startup when no admin tool is present.
Reinstallation preserves the same pairing. A remote paired to another core
is refused rather than silently reassigned. Interrupted installs report an
error; leave or reinsert the same device and inspect any unfinished journal
before retrying. Existing startup/pairing pointers are restored on handled
failures when the original device is still mounted.

Remove the computer from the drive, equip/attach a wireless modem, and start
it. Its actual computer ID is bound on the first successful connection; the
drive's floppy disk ID is not used as a computer ID. Core supports up to 32
paired remotes. Pairings remain in core's /avionics/data/remotes.json and are
excluded from portable releases, as are all other world-specific data files.

The remote home provides core overview, fleet, lift, propulsion, navigation
and log pages. It marks disconnected data stale and reconnects automatically.
Press P for REMOTE AP. Legacy administration is unchanged. The radio service
is a separate core worker, answers paired requests and uses cached readings.
Flight requests enter a bounded queue in core's normal supervisor; the radio
worker never directly operates actuators. Rednet pairing does not encrypt
radio traffic; use on a trusted network.

### Remote AP

On core, open UTILITIES > [O] Remote flight access. Select the intended pocket
and explicitly ALLOW its flight permission. E enables remote AP for this core
boot; D disables it and requests cancellation of any remote-owned route.
Docking or updating a pocket never grants flight permission. Permission is
saved per pocket, while the overall enable flag resets after core reboot.

On the updated pocket, P opens REMOTE AP. X and Z edit the destination, H its
flight altitude and S its cruise speed. Enter reviews the route; G confirms
the actual send request. D toggles explicit permission to release a currently
engaged digital position anchor. This does not release a physical anchor or
bypass propulsion's anchor interlock. C reviews disengagement of a route owned
by that pocket. Q returns without cancelling an already accepted flight.

Core must already have altitude hold established, propulsion and speed/heading
control enabled, valid navigation, verified identity/assembly, and fresh neutral
cockpit inputs. Remote AP cannot start systems, clear a kill, enable propulsion
or replace an active route. It uses existing RPM limits and AP readiness gates.
An accepted route anchors at its destination. Caller location discovery,
SUMMON TO CALLER, obstacle avoidance, landing and remote engineering are not
included. Choose a clear route and a suitable altitude.

PENDING means queued, not engaged. The pocket queries the final command result;
duplicate requests retain the same result. A queued command expires after six
seconds. Lost acknowledgement recovery queries the existing result instead of
resending departure. Caller disconnection does not stop an accepted route.

Pilot steering/throttle/strafe/altitude inputs cancel a remote-owned route and
disable new remote AP requests until re-enabled onboard. Relevant onboard
flight actions also take priority over already queued remote commands. Lift
support is not shut down by this handover. Other remotes cannot disengage a
route they do not own. Revoking its owner's flight permission cancels the
remote route. Intentional restart checkpoints retain route ownership, while
new remote requests remain disabled until E is selected again.

For the first in-world check: support the vessel and stop flight, load the new
core software, then update the pocket through Utilities R. Connect the pocket,
grant its permission and enable access on core. Establish normal flight readiness
before requesting a short clear-space route. Check PENDING then ACCEPTED, exact
destination/altitude/speed, arrival anchor and pilot override. Do not deliberately
remove critical machinery in live flight to reproduce offline failure tests.

## Storage and preparation

- Set computer_space_limit to at least 4,000,000 bytes in the destination
  world's ComputerCraft server configuration before installation.
- See storage-report.json for the exact installer media size. Core contains
  expanded copies of all role packages; installer media deduplicates them.
- A default-sized floppy may be too small. Use a floppy with sufficient
  configured capacity (4,000,000 bytes recommended), or an appropriate mounted
  computer storage medium. No capacity settings are changed by this release.
- The ZIP is for transporting the release on your PC. Extract it first;
  ComputerCraft runs the extracted Lua files, not the ZIP archive.
- Copy the CONTENTS of media/ onto the installer medium. Keep unrelated files
  separate. The disk must be writable to record this deployment's role IDs.
- Use matching Minecraft/mod versions and the same physical Amaryllis build,
  connection sides, frequencies and sensor-axis convention. This is a vessel
  profile, not an automatic installer for arbitrary airship geometries.

## In-game procedure

The blueprint's primary reversing-gearshift receiver frequencies are fixed:
left is dropper then hopper; right is hopper then dropper. Item order
matters. Both chamber and dedicated thrust packages use these same pairs.
Forward uses signal 0 and reverse uses signal 15, with the zero-speed
direction-change interlock retained.

1. Keep the vessel disassembled. Use fresh computers with modems on a shared
   network. One disk drive can be moved between them during setup.
2. Insert the installer disk at the intended core. Run disk/startup.lua (or
   the actual disk mount path) and choose Install core. Its actual ID is used.
   Core is installed with propulsion disabled. Do not start it yet.
3. Move the same disk to each auxiliary computer. Run its startup.lua and
   choose Register auxiliary, then the physical computer's role. The disk
   records its ID and installs the bootstrap. Remove the disk and reboot
   that auxiliary; it waits for core to supply its verified role package.
4. Return the disk to core. Run its startup.lua and choose Import role
   assignments. Missing roles are listed; duplicate IDs/assignments are refused.
5. Remove the disk and reboot core. The existing fleet installer sends the
   packages, rewrites role/core identities and starts the auxiliary consoles.
6. Review the existing core Computers/installation status and hardware recheck
   pages. Verify all expected chamber providers, velocity sensor axes, vessel
   identity, monitors, transmissions and primary direction links.
7. Perform deliberate direction/control commissioning before enabling flight.
   The release does not actuate the ship or claim a new-world installation is
   flight-verified. START SYSTEMS and propulsion enable remain explicit actions.

## Scope and recovery

- The menu refuses to overwrite existing installations. It is not a live
  upgrade or airborne reinstall tool.
- All source objects are size/checksum verified before copying. Startup is
  written last and interrupted copies have a same-release retry journal.
- The setup script refuses registry imports while core's runtime is active.
- Each release starts without deployment.json. Use a fresh copy for a second
  world; do not carry an old world's deployment registry into the new one.
- Preserve backups of this release separately from live flight checkpoints.
- Existing fleet and hardware status pages supply verification. A new graphical
  installation/commissioning wizard and automatic ambiguous-peripheral
  identification are not included in this first portable installer.

## Saved control selections

Heading/throttle modes and selected heading, speed and altitude are retained
in a small atomic core state file. Mode changes save immediately; continuous
target adjustments save at most once per second. A crash can therefore lose
the last second of a held target adjustment. On ordinary reboot, fresh core
and vessel identity, verified sensors and neutral inputs are required before
restoration. Strafe is not replayed. Running systems intent is saved separately:
after a reboot, lift control can automatically adopt the existing chamber
outputs when its airborne/support and recovery checks pass. Fault recovery
retains applied lift rather than performing a takeoff sequence again.
Confirmed STOP SYSTEMS or LIFT KILL clears running intent. LIFT KILL also
persists a restart lock until explicitly disarmed; disarming leaves systems
stopped. Ordinary reboot does not automatically engage AP.
Restored commands wait for ready lift control or explicit pilot mode selection.
An intentional RESTART SYSTEMS checkpoint takes precedence. Save failures are
shown on Settings; debug recordings continue to use removable disk only.
