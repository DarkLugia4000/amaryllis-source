# Amaryllis: computer systems plan

Updated 23 October 2026, Europe/Berlin.

This is the current plan for reliability, engineering, remote operations and
manual backup flight. Confirmed decisions, proposed designs and unfinished work
are distinguished below. Saving this plan does not change the running vessel,
world settings or actuator outputs.

## 1. Operating requirements

### Essential control

Lift and propulsion have absolute priority. The intended minimum degraded
capability is functional manual steering and propulsion, with existing lift
support preserved. Failure of an optional subsystem must not remove that
capability.

There are two parts to recovery:

1. Preserve support during an error. A loss of core supervision, telemetry or
   command authority must not become an implicit instruction to remove lift.
2. Restore useful control automatically. Retry, reconnect, recover workers and
   re-establish verified authority without a full Start Systems cycle.

Recovery adopts existing chamber outputs and retained pilot intent. It must not
blindly reseed gas, replay old pilot inputs, or interrupt healthy controllers.
Selected targets and modes survive faults where they remain applicable.

Explicit Stop Systems and Lift Kill remain deliberate shutdown paths. Both
clear running systems intent. Lift Kill additionally latches a restart lock;
Disarm Kill removes the lock and leaves systems stopped.

Preserving an applied output is not a guarantee of constant altitude forever.
Continued support still depends on working machinery, fuel, power and suitable
local controller behavior. The design must identify those shared dependencies.
Software recovery cannot compensate for every destroyed or disconnected part.

### Fault isolation

- Separate unavailable measurements from real zero values.
- Retain source timestamps. Repeated delivery does not make old data fresh.
- Keep unaffected control available. Loss of absolute position pauses AP and
  anchor; it does not by itself disable manual propulsion or steering.
- Distinguish loss of automation from physical loss of lift or thrust.
- Keep fault detection and recovery active while an operation is blocked.
- Show the failed component, remaining capability and recovery state.
- Treat deliberate shutdowns and kill latches separately from transient faults.

## 2. Current baseline

v143 diagnostic delta is loaded in the supported Journeys deployment:
`2026-10-23-v143-cockpit-timing`, release `amaryllis-2a05c59dd9c2`.
It adds per-sample state/core timing, first-consumption stamps, bounded
mutation-cursor exports, independent scheduling-delay probes and an in-memory
installer loop/pause probe. Twelve core/state files were staged with v142
baseline hash guards and a permanent backup; fleet and application configs
were preserved, served actuator/navigator packages are byte-identical to v142.
No flight or reboot command was sent by the agent. The operator restarted
ama-state #1 then core #0. Both virtual traces publish successfully; a twelve-
second smoke capture correlated 33 samples with no export errors, history gaps
or negative stage deltas. Installer cache subsequently reached fourteen misses
and a growing hit count. The comparison completed with 662 warm-active samples,
657 paused samples and 207 resumed samples. Completion-to-consumption p95 was
1.568 s, 1.315 s and 1.842 s respectively; maxima were 2.375 s, 1.896 s and
2.612 s. Receiver-entry-to-consumption took at most 2 ms in every phase.
No export errors, history gaps or negative stage deltas were reported. All nine
cockpit inputs stayed neutral in the two main phases. Cache misses stayed at
fourteen. The shell-operated pause/resume cycle worked without a tab restart;
the earlier host-removal problem remains unexplained. Next: compare a minimal
independent wired receiver with runtime dispatch and, if needed, a timestamped
round-trip probe. Delay before receiver entry includes delivery/queueing/dispatch,
so it must not yet be attributed to pure modem transit or a specific scheduler.
Full findings: Amaryllis-portable/diagnostics/2026-10-23/v143-cockpit-timing/findings.md.

The trace also corrects an earlier diagnostic ambiguity: v142's service routine
could update cockpitProcessedAt on a duplicate check even when lastSample had
not changed. v143 stamps first consumption at Controls' actual sample assignment.
Earlier processing-age values alone should not be treated as per-sample queue
latency. Independently measured send-to-receiver delays remain separate evidence.
The collector exports fixed-size memory pages through the existing read_file
allowlist and writes evidence only to the workspace. Run procedure:
[cockpit timing procedure](../diagnostics/COCKPIT_TIMING_RUN.md).

| Item | State as of this plan |
| --- | --- |
| Portable release | v143, `2026-10-23-v143-cockpit-timing`; per-sample cockpit timing diagnostics on the v142 control baseline |
| Final release ID | `amaryllis-2a05c59dd9c2` |
| Flight software | Existing AP, anchor, altitude, heading and selected-speed control; v133 altitude refinements retained, with configurable selected-target input ramps in v134 |
| Core/state split | Core #35; ama-state #68 collects vessel and cockpit readings over a wired link |
| Active fresh deployment | Amaryllis Trial Journeys: v143 core #0/state #1, navigator #5 package v11; served wireless packages unchanged from verified v142 |
| Recovery software | Running intent, output adoption, telemetry recovery and reader/worker fallback are present; comprehensive failure acceptance remains work |
| Docked remote provisioning | Implemented on core Utilities; operator reported a working in-game installation |
| New remote application | Paired status and SEND TO / disengage implemented; operator confirmed remote AP working in game; no caller-location SUMMON or engineering commands yet |
| Existing pocket #63 | Legacy administration program and credentials preserved |
| Motion warnings | v138: POSSIBLE IMPACT / POSSIBLE OBSTRUCTION on Flight, with diagnostic recording; offline verified, in-world threshold acceptance pending |
| Engineering computer | Proposed; no engineering system implemented by this planning work |
| Manual backup computer | Proposed; no backup controller or authority handover implemented yet |
| Storage quota | Last checked at 4,000,000 bytes per computer; increase to 32,000,000 proposed, not applied |

Deployed v142: `2026-10-23-v142-cockpit-priority`. This supersedes the
prepared v141/v140 candidates and includes both prior changes.
Release ID: `amaryllis-865d3930df88`; 125 core files, 3,693,360 payload bytes,
391,083 state payload bytes and a 542,767-byte ZIP. Source/object/bootstrap/
state/media/ZIP verification and 452 portable installer checks passed. Cockpit input
now has a fixed-size state-to-core message sent immediately by the existing
cockpit sampling worker, independently of full-frame transmission. Core uses
an independent receiver and immediate Controls processing. Full telemetry also
consumes any newer cockpit batch before calibration reads and composition;
older full frames cannot overwrite newer input. State boot/session/IDs/side/
channel/sequence and input freshness/level validation remain required.

Core checks current pilot input before routine radio drains and between handled
messages, ahead of discovery/housekeeping/remote operations. Trusted navigator
requests precede routine radio reports while preserving command order. Sampler
startup order puts cockpit first. Existing duplicate-sample, neutral-return,
assembly, identity and freshness checks remain intact, and unchanged-input
service is throttled. State gains no actuator writes or additional sensor reads.
Priority applies within cooperative application execution, not global server or
Lua preemption. Diagnostics expose fast receipt/transport and consumed-input
processing timestamps. Command deadlines use execution time, while telemetry
retains original reception time. Priority tests: 54 passing; navigator requests:
195; radio backlog equivalence, input tuning, remote AP, docking and pocket UI
regressions pass. The operator confirmed physical support, then restarted
ama-state #1/core #0 after a backed-up, hash-guarded code update. Navigator #5
received its v11 package through the normal authenticated transaction and was
restarted afterward. All targeted core/state files match release objects; all
14 wireless packages have matching receipts, identities and Lua files, with no
pending commit journals or recovery flags. No agent control commands were sent.
The in-world commissioning disk remains unchanged by the delta deployment.

Live comparison: the priority cockpit receiver is active, with no rejected fast
frames in the sampled captures. All fourteen installer bundles are cached
(3,748,256 payload bytes); cache misses stayed at fourteen while hits rose above
four hundred. Short samples still caught cockpit processing ages around two
seconds with a warm cache. This establishes remaining latency, not its cause;
neither the installer nor general server load is proven to be the sole source.
Removing /installer/paused did not advance the running PAUSED tab even though
the file was absent in both host and computer shell. Restarting only the
installer tab resumed checks. That liveness issue remains unexplained.
Audit and timing captures: Amaryllis-portable/diagnostics/2026-10-23/v142-live-deployment.

Earlier prepared v141 candidate superseded v140: `2026-10-23-v141-navigator-requests`.
Final release ID: `amaryllis-4bf57c63d1ca`; 125 core files, 3,687,651 payload
bytes and a 540,870-byte ZIP. Source/object/bootstrap/state/media/ZIP audit and
452 portable-install checks passed.
Navigator now has a volatile eight-command outbox, one ordinary request in
flight, bounded retry backoff and matching late-result handling. Core caches
32 results per navigator boot, so retrying the same request does not repeat its
effects. Reusing an ID with a changed action/deadline is rejected. Newer unsent
settings/mode selections supersede prior values; relative adjustments remain
ordered. Stop/kill/disengagement requests take priority and retire queued work.
Core-session changes clear pending work. Ordinary requests expire after 30 s;
context-sensitive requests use 10 s, enforced again on core before execution.
Unsent expiry is CANCELLED; sent but unacknowledged expiry remains NOT CONFIRMED
until a matching result resolves it. UI no longer converts brief ACK delays
into TIMED OUT. New core acknowledgements bind navigator boot as well as session
and sequence. These changes were subsequently included in the supported v142
Journeys deployment described above.

v141 targeted request tests: 195 passing. Input tuning (54), remote AP (78),
docking (73), pocket radio/UI (29), installer workload (40), receipt/progress
(465), bootstrap, targeted restart-state and 46 airborne-restart checks pass.
The broader telemetry fixture fails on a missing controls.usable mock method
with both old and new flight code; the unchanged baseline failure is recorded
under diagnostics/2026-10-23/v141-navigator-requests. The restart harness was
updated to copy its current Lua dependencies rather than mixing old modules.

Earlier prepared v140 candidate: `2026-10-23-v140-installer-workload`, final release ID
`amaryllis-6fccd53f16cd`. Deployment was originally deferred while the operator
reported the vessel airborne or unsupported. These changes were subsequently
included in the supported v142 deployment above. Source changes are in the separate New World development
tree, backed up under `Amaryllis-portable/repair-backups/before-v140-installer-workload`.

The installer currently rereads and checksums full packages before determining
that a client's installation is current. v140 adds a per-installer memory cache
bounded to 14 packages / 8 MiB payload bytes, metadata rechecks every five seconds
per cached package, and paced cold verification with a yield every 8 KiB and
between file reads. Missing metadata uses full verification; changed sources
invalidate the cached package; changes during a paced build reject that attempt.
Force requests verify afresh. Live fleet/core authority and receipt validation
remain independent of cached payloads. `/installer/paused` pauses the new service
and retires transfers at their next authority boundary without stopping flight
workers. Existing v139 cannot observe this marker, so loading the new control
requires one restart when physically supported. CHECK/PAUSED are visible in UI.

v140 offline checks: 40 workload/cache/pause checks, 465 receipt/transport/UI
checks, bootstrap guards and 452 portable-install checks passed. All 125 core
files match build inputs; packaged core payload is 3,678,183 bytes. A supported
vessel comparison is still required. Core's measured diagnostic delays and
sporadic state-reader delays do not prove installer causation or sustained TPS
loss. The screenshot showed 20 TPS and 29.8 ms integrated-server time at capture.
Do not loosen altitude freshness or lease limits as a substitute for diagnosis.

v139 corrects a reproduced fresh-install race: local commit published installed
before installedCoreID was persisted, while the bootstrap could reboot before
the final acknowledgement supplied that field. Commit now persists the complete
identity first; bootstrap reboot waits for matching core/computer metadata and
finished journal cleanup. A previously committed receipt missing only core ID
can repair that field after all other receipt checks and live core binding pass.
No conflicting identity or pending commit journal is bypassed.

Core's installer tab now displays the active node, acknowledged bytes, file
progress, retries, and a cached per-role WAIT/OFFER/SEND/VERIFY/DONE/FAULT roster.
DONE describes the package, not flight hardware readiness. Display faults are
isolated from transport, with at most four redraws per second and no additional
sensor reads or status-file polls. State is installed locally and excluded from
the 14 wireless targets. Regression, transport and terminal tests passed 465
checks; bootstrap guards and 449 portable-install checks passed. Original client
fails the new core-ID regression as expected. Source/object/ZIP verification
passed: 124 core entries, 3,671,547 payload bytes, 534,623-byte archive.

Journeys corrections are #10 chamber_br, #11 chamber_bl, #12 thrust-ls and #13
thrust-rs. Installer/bootstrap code was updated with backups; assignments,
application settings and receipts were preserved. Temporary diagnostic changes
on #7 were removed. Operator confirmed the progress screen is visible. Final
live cached reports show all four chambers and thrust relays, three headings,
state and both primary telemetry nodes online. Bridge receives reports and
shows degraded only because the vessel is disassembled. A new core runtime
session was observed during reload and the fleet recovered on it. No flight
actuation or automated computer reboot was issued by the agent. The diagnostic
host now uses Journeys' fleet path for this host process. The existing v138
commissioning disk was not rewritten; use the separate v139 archive for future
fresh installations. In-world flight/hardware commissioning remains outstanding.

v132 passed 73 docked-remote checks, 72 remote-AP authority checks against the
real Flight/AP/Controls modules, 29 radio/pocket checks and 434 portable-installer
checks offline. The operator's earlier successful docking report confirms the
v131 installation path in game. On 22 October, the operator also confirmed
remote AP working in game and declared this task complete. This is an operator
observation, not a recorded pass of every permission, interruption, arrival or
flight-failure/hardware-failure acceptance case.

v133 packages the operator's further altitude PID refinements and their debug
recording field. All 121 core payload files match the current build inputs after
the normal portable identity/default transformations; state/bootstrap/media
inputs and ZIP contents also match. It passed 434 installer checks, 72 remote-AP
authority checks, 73 docking checks and 29 radio/UI checks. These packaging and
offline checks do not establish in-game acceptance of the latest altitude tuning.

v134 adds Settings > Input Tuning pages for selected heading, selected speed and
altitude inputs. Heading and speed adjustments have configurable initial rates,
held-input acceleration and rate caps; acceleration defaults to zero to preserve
existing input response. Release/reversal/loss resets ramps, input changes save
before applying and require released controls, and input edits preserve altitude
PID history. No physical flight limits or PID gains were retuned. The release
matches all 122 current core payload files and passed 54 input/UI/persistence
checks and 442 installer checks. Remote AP/docking/radio checks also pass.
An older controls suite fails its input-loss availability expectation with both
the v133 controls and the new controls; that unchanged baseline failure is not
claimed as a passing regression check. In-game input-feel acceptance is pending.

v135 removes the Yaw Sensitivity editor from main Settings and gives Cockpit
Timeout and each following button row one blank separating line. It retains
the existing input-tuning behavior and passed the 54 input/UI checks and 442
installer checks; the ZIP matches all 122 current core payload files.

v136 removes the selection-versus-vessel-response tip from all input pages and
the equivalent reminder from the input menu. Installer checks remain at 442
passing; all 122 core payload files and ZIP contents match the current source.

v137 raises the core forward selected-speed ceiling, onboard AP validation,
AP restart checkpoint validation and pocket cruise entry limit to 30 b/s.
Reverse selection remains -20 b/s, and physical thrust/braking limits are
unchanged. Existing pockets need a docked update for the new entry limit.
It passed 78 remote-authority checks, 73 docking checks, 29 radio/UI checks
(including a reviewed 30 b/s pocket request), and 442 installer checks. Source
and ZIP verification match all 122 core payload files. Core reload is required
for the on-disk configuration and code changes to become active.

v138 adds an advisory cached-data motion monitor. Possible impact uses abrupt
world-velocity or actual-rotation changes; possible obstruction covers forward,
sideways and turning demand with confirmed substantial applied drive and little
response over 10 seconds. Identity, assembly, original sample times, source
changes, gaps, anchors, braking and controller readbacks gate detection. The
monitor changes no flight authority or outputs. Flight prioritises the message
on its single cleared status row. Debug schema 4 records trigger metrics,
event sequence/detail, gates and resolved thresholds; console events are paced.
Initial thresholds need in-world evaluation and brief between-sample events
can be missed. It passed 54 motion/UI checks, debug recording checks, 54 input
checks, 78 remote authority checks, 73 docking checks and 29 radio/UI checks.

Its 446 installer checks include enforced temporary-write capacity, fresh and
interrupted installs at the existing 4 MB limit. Installer preflight now counts
fresh files once, reserves replacement/configuration writes and per-file
padding, and reuses verified unchanged files during an owned interrupted
install. Fresh-computer/journal protections are retained. All 123 current core
payload files, bootstrap/state payloads, installer media and ZIP contents match.
No live restart or flight actuation was performed during implementation.

The FL installation incident during that session was traced to copied computers
in the display vessel. The operator removed the duplicates and reported normal
operation. No code correction or computer-folder purge was required.

## 3. Responsibilities and connections

| Computer | Owns | Must remain independent of |
| --- | --- | --- |
| ama-core | Normal flight decisions, selected modes, AP/anchor, flight coordination, remote provisioning | Engineering polling, display rendering and remote UI work |
| ama-state | Vessel and cockpit measurements, source times and validity | Actuator writes and flight decisions |
| Chamber controllers | Local lift actuation, output retention and verified recovery | A continuously healthy core for retaining established support |
| Propulsion controllers | Local thrust actuation, RPM limits, reversal protections and source acceptance | Unrelated navigation or display availability |
| ama-bridge | Flight and engineering presentation; onboard requests | Core as a relay for engineering display traffic |
| ama-engineering | Fuel, boilers, skycrane monitoring; later permitted machinery controls | Core as its telemetry/command relay |
| Manual backup computer | Minimal manual steering and propulsion when selected | Core, ama-state and absolute-position telemetry |
| Remote computers | Local user interface and paired requests | A permanent installer disk or continuous download connection |

Engineering communicates directly with bridge. Information required for a
controller's decisions should also reach that controller directly. For example,
a chamber could receive its boiler availability from engineering without core
relaying the report.

Core is the normal flight authority. Engineering owns its assigned machinery
outputs. The backup is an alternative flight authority selected through a
handover mechanism, not another simultaneous writer. Remotes make requests to
the relevant onboard authority; they do not directly compete with actuators.

## 4. Workstream A: reliability and manual backup

**Priority: essential flight capability.**

First inventory the full paths from cockpit input to propulsion output, and
from chamber control to sustained lift. Record the computers, modems, bridges,
power supplies, fuel feeds and shared machinery on each path.

### Proposed backup scope

- Manual forward/reverse throttle and steering.
- Strafe if it can be included without substantial extra dependencies.
- No AP, position hold, selected-speed PID or heading-hold PID.
- No dependence on Sable or absolute position for basic manual commands.
- Retain configured RPM caps, direction conventions and reversal interlocks.
- Leave chamber lift support intact during takeover.
- A small status view showing authority and responding propulsion controllers.

### Authority work required before takeover

1. Decide how actuators select the normal or backup source. A physical
   NORMAL/BACKUP selector is the leading proposal, not a completed decision.
2. Ensure selection still works when core is completely unresponsive.
3. Give backup its own usable cockpit-input and actuator-command paths.
4. Change propulsion source/lease checks so backup can operate without requiring
   healthy core supervision or unrelated flight telemetry.
5. Reject late commands from the retired source after handover.
6. Specify neutral-input and output-transition behavior to avoid sudden thrust.
7. Prevent recovered core from automatically taking authority away from backup.
8. Specify separate responses to lost input, lost command transport and lost
   controller. Holding lift and retaining a stale throttle demand are different
   decisions; do not apply one generic timeout action to both.

Automatic takeover is later scope. Start with deliberate pilot-selected
takeover and return, then test it before considering automatic selection.

### Mandatory takeover properties

The operator requires the backup switch to be as airtight as possible. Treat
the following as acceptance requirements. The exact circuit and transport are
still design work.

- The physical selector must reach propulsion authority enforcement without
  depending on core, bridge UI, ama-state or the normal flight command worker.
- Enforce the selected source at the receiving controllers and, where required
  by the failure coverage, at the physical output stage. A command sender's
  promise to stop transmitting is insufficient.
- A dead or unresponsive core must not be required to acknowledge, release a
  lease or authorize takeover. Receiver-side exclusion revokes its authority.
- Exactly one source may command each actuator. Selector transition, conflicting
  selector inputs and unknown selection must never authorize both sources.
  Consider break-before-make hardware and distinguish NORMAL, BACKUP and invalid
  selection explicitly. Specify invalid-state output behavior before building.
- Reject delayed normal-source packets after backup is selected. A return to
  normal must also retire previous backup commands and establish a fresh command
  epoch; old queued inputs must not regain authority.
- Recovery or reboot must not change the pilot's physical selection. Controllers
  read the selector and establish authority before accepting movement commands.
- Lift support remains independent of the propulsion authority transition.
  Switching modes must never invoke Stop Systems, Lift Kill or gas reseeding.
- Define throttle/steering handover, input-neutral checks, output ramps and
  direction-change protections explicitly. Takeover must not jump to an old or
  held command merely because it was valid before the failure.
- Show selected mode separately from achieved authority. Confirm source
  acceptance from the propulsion controllers, identify missing or inconsistent
  receivers, and show which control capability remains available. Unrelated
  display or failed-controller acknowledgements must not block control of
  healthy units indefinitely.
- Do not use restored heartbeats as permission to take control away from the
  backup. Return is a deliberate pilot action followed by verified handover.

Failure coverage must be stated precisely. Independent source acceptance in
propulsion software can protect against core failure while the propulsion
controller is healthy. It cannot force a hung propulsion computer to change
its already latched outputs. To cover that failure, provide a hardware selector
or interlock downstream of the failed output, and a genuinely independent
manual command path. Shared actuator, power, fuel and mechanical failures must
remain listed as residual dependencies.

Acceptance cases include: core frozen while commanding thrust; core absent;
normal input/command transport lost; backup selected while delayed normal
packets arrive; core recovering during backup flight; controller reboot while
BACKUP is selected; held throttle at handover; reversal requests; selector
transition/invalid signals; partial controller availability; and a propulsion
controller frozen with a nonzero output. The last case must test the physical
interlock if protection against controller hangs is claimed.

## 5. Workstream B: engineering

**Confirmed direction:** a separate engineering computer, publishing directly
to bridge. Start with readings and warnings. Add actuation after the readings,
machinery behavior and ownership are verified.

### Fuel basin and two primary reservoirs

- Read each tank separately: fluid, quantity, capacity or configured capacity,
  fill fraction and freshness.
- Track combined reserve, imbalance and each side's depletion trend.
- Prioritize either side approaching empty. A healthy combined total must not
  conceal side starvation, which can cause that side's balloon to fail.
- Account for incoming lava from the dripstone farm. Show rising/stable/falling
  reserves; estimate time remaining only with a sustained usable net-drain
  measurement.
- Test direct wired fluid-storage readings first. Use Threshold Switches for
  independent low-level signals and, where useful, display-linked fill readings.
- Later decide the valve/pump arrangement for balancing or preferential filling.
  Computer or bridge failure must not implicitly close the essential fuel feed.

### Steam-vent boilers

- Test a boiler Display Link feeding a CC:C Bridge Target Block.
- Capture the actual status, heat, water-supply and size information provided.
- Inspect useful units and update behavior before defining the software fields.
- Add a Stressometer/Speedometer where it helps verify available mechanical
  output or identify overload independently of boiler status text.
- Separate boiler readiness, commanded vent state and actual gas production.
- Later define how boiler unavailability constrains new lift requests without
  turning an engineering communication failure into a lift shutdown.

### Skycrane

The platform moves horizontally into a shaft and is then moved vertically out
of the craft. It therefore needs a coordinated sequence and position checks
for both axes.

- Identify the actual horizontal and vertical drive blocks and transfer steps.
- Use available gantry/piston/pulley/winch readbacks before adding redundant
  sensors solely to reproduce readings already available.
- Confirm platform stowed, shaft alignment and vertical transfer position.
- Detect movement, lack of progress, stalls and assembly/transfer failures.
- Specify which axis may move in each state. Vertical travel requires verified
  shaft alignment; horizontal travel requires the correct transfer height.
- Define stop, manual recovery and unknown-position behavior before automation.
- Keep crane faults separate from vessel flight authority.

Initial hardware trial: engineering computer, one reservoir reading, one
Threshold Switch and one boiler Display Link/Target Block pair. Verify those
before instrumenting all boilers or adding automatic fuel/crane operation.

## 6. Workstream C: REMOTE OPS

### Existing foundation

Core Utilities installs and pairs a docked pocket only after user confirmation.
The release carries both core's provisioner and the remote application. Core
holds the operational copy, so normal provisioning needs no installer disk.
Vessel-specific pairing records remain outside distributable packages.

v132 adds reviewed SEND TO and owner-only AP disengagement, plus explicit
onboard per-pocket permission and per-boot remote enable. Commands run in the
normal core supervisor with expiry, duplicate protection and pilot override.
The offline tests use the actual Flight/AP/Controls modules and simulate lost
acknowledgements and the pocket UI. The operator confirmed remote AP working in
game on 22 October and declared the implementation task complete; detailed
failure-case acceptance has not been recorded. Existing #63 administration
remains a separate preserved function.

### Proposed progression

1. Show compatible core/remote versions and make update status clear.
2. Add onboard remote enable/disable and a permissions/revocation model.
3. Define command ownership alongside normal/backup flight authority. Onboard
   pilot commands take priority; remote requests cannot bypass explicit stops,
   kill latches or controller protections.
4. Add SEND TO for reviewed saved/entered clear rendezvous coordinates using
   the existing AP. Report acceptance, progress, arrival and failure reasons.
5. Add SUMMON TO CALLER once the caller has a verified coordinate source. A
   stationary terminal can use configured coordinates. CC GPS was discussed for
   a portable caller, using four stationary loaded hosts and the carried pocket's
   position. GPS integration and its in-world verification remain unfinished.
6. Add permitted engineering operations directly through engineering's command
   endpoint, with acknowledgement and physical verification where available.

Requests need unique IDs, expiry, deduplication and acknowledgements. Losing
the caller connection should not remove an already accepted onboard route.
Replacing an active route requires an explicit rule and user-visible result.

The existing AP does not provide terrain/obstacle avoidance or automatic
landing. Initial remote arrival means a deliberately clear rendezvous at a
chosen altitude, followed by destination anchor hold. Crane deployment and
landing are separate operations.

## 7. Efficiency requirements

- One sampling owner per measurement; displays and remotes consume cached data.
- Prefer coherent grouped getters. Every sample retains source age and validity.
- Every worker yields. Reads and writes have bounded waits and paced recovery.
- Bound queue length, history, cache entries, outstanding commands and retries.
- Coalesce outdated telemetry. Never accumulate a disconnected-device backlog.
- Load configuration as needed and cache it. Save changes deliberately, using
  recoverable writes and debouncing for continuously adjusted targets.
- Verify packages at installation/update/load boundaries. Cache verification
  for unchanged packages during that boot; invalidate after writes or updates.
- Avoid repeated full-fleet copies, filesystem scans and byte-by-byte checks in
  ordinary control loops.
- Debug recordings remain on the data disk with explicit limits. Retention and
  deletion rules must be stated; do not silently delete user data.
- Repeat installs reuse unchanged software and preserve settings. Backups and
  update remnants need a defined retention/recovery policy as the updater grows.

Initial engineering budgets, to be validated rather than treated as measured
limits: fuel 1 Hz; boilers 1-2 Hz; active crane up to 5 Hz; idle machinery slower.
Remote status currently requests every two seconds. Do not change established
flight-control cadence merely to make these rates uniform.

Measure event lag, sample age, command/acknowledgement time, queue depth and
storage growth before and after substantial additions. Opening a page, adding
a remote or losing a peripheral must not materially delay essential control.

## 8. Acceptance and implementation order

| Step | Deliverable | Acceptance evidence |
| --- | --- | --- |
| 1 | Dependency/failure map and normal/backup authority specification | Every required steering/thrust and lift-support dependency identified; remaining shared failures stated |
| 2 | Essential-path recovery audit and fixes | Loss of supervision preserves support; unaffected controls keep working; recovery adopts current state |
| 3 | Manual backup MVP | With core unavailable, selected backup can steer and command thrust; late core commands rejected; deliberate return works |
| 4 | Engineering readings and bridge pages | Tank/boiler values verified against machinery; unknown differs from empty; engineering loss does not interrupt flight |
| 5 | Permitted fuel/crane controls | One owner per output, meaningful acknowledgements, sequencing/interlocks and recoverable interruption behavior |
| 6 | Remote flight requests | Permissions, pilot priority, duplicate/expired request handling and clear-space AP arrival verified |
| 7 | Portable release and commissioning guide | New identities install correctly; optional roles handled; no live credentials/state distributed; in-game commissioning recorded |

Operator steering on 22 October: remote AP implementation was requested first,
ahead of the proposed backup work order. This does not imply that manual-backup
hardware or the authority interlock already exists.

Engineering read-only work can proceed alongside backup design once its
hardware is available. Remote flight commands depend on the authority and
permission contract. Storage can be expanded separately; the proposed 32 MB
quota is not a substitute for the efficiency rules.

Test failures deliberately with the vessel supported or in a controlled test
environment: core termination/reboot, helper loss, peripheral timeouts, modem
loss, worker failure, controller loss, full/removed disks and interrupted
updates. State which functions survive each test and which physically shared
failures remain. A running heartbeat alone is not proof of usable control.

Each in-world test begins with an explicit setup phase describing required
hardware, support/control state and operator actions. Keep offline checks,
operator observations and measured in-game acceptance separate.

## 9. Immediate next work

Write the dependency and authority map for manual steering/thrust, then choose
the physical backup input path and selection mechanism. In parallel preparation,
inventory the fuel plumbing, boiler count and crane drives. These resolve the
hardware decisions that implementation depends on.

Historical reference: [previous next-session plan](Amaryllis-next-session-plan.md).
Older recovery/status statements in historical notes are not current acceptance
evidence; use this plan and the current source when they conflict.
