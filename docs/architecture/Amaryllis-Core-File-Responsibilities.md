# Amaryllis core: file responsibilities

Inspected 26 October 2026. Source: Amaryllis Trial Journeys, core computer #0.

Source folder: `C:\Users\user\AppData\Roaming\ATLauncher\instances\CreateAeronautics\saves\Amaryllis Trial Journeys\computercraft\computer\0`

**146 files: 96 Lua programs/modules and 50 configuration, record and backup files.**

The tables account for every file found in this core folder. Program descriptions follow the source code and launch paths. Saved records describe their stored purpose; file presence alone does not establish whether a particular task is currently running.

## Execution and storage boundaries

- `avionics/main.lua`, `flight.lua`, `io.lua` and `thrust.lua` coordinate the central runtime, lift, sensor/network boundary and propulsion.
- Auxiliary package files are installation sources for other computers. This existing core also boots its shared console from `packages/common/console.lua`.
- `remote_client.lua` and `remote_ap_client.lua` are client programs held for provisioning remote computers. `state_reader.lua` is the STATE program retained among core sources.
- `recorder.lua` is an older CSV recorder. The inspected current main runtime references `debug_recorder.lua`.
- New installers exported by builder 1.7.1 place auxiliary package sources on removable media and install core's console under `avionics/common/console.lua`. The inventory here describes the existing ship.

## Boot and identity (3 files)

| File | Responsibility |
|---|---|
| [amaryllis-install.json](../../source/core/amaryllis-install.json) | Core's local installation receipt: release ID, computer ID, role and pending/completed state. |
| [fleet.json](../../source/core/fleet.json) | This installation's role-to-computer-ID and label registry. |
| [startup.lua](../../source/core/startup.lua) | Boot entry point. Loads packages/common/console.lua and starts its console/supervision workflow. |

## Core software and configuration (39 files)

| File | Responsibility |
|---|---|
| [avionics/anchor.lua](../../source/core/avionics/anchor.lua) | Digital anchor. Captures a horizontal position and calculates the forward/lateral corrections needed to hold it. |
| [avionics/autopilot.lua](../../source/core/avionics/autopilot.lua) | Autopilot route execution: destination validation, engagement, heading/speed guidance, approach, arrival, cancellation and recovery checkpoints. |
| [avionics/cockpit_timing.lua](../../source/core/avionics/cockpit_timing.lua) | Bounded timing records for cockpit sampling, transmission, receipt and consumption, plus worker delays. Used to locate input latency. |
| [avionics/config.json](../../source/core/avionics/config.json) | Core configuration: controller gains, operating limits, input tuning, networking, commissioning and hardware discovery settings. |
| [avionics/config.json.bak](../../source/core/avionics/config.json.bak) | Backup of avionics/config.json retained by configuration writes. |
| [avionics/control_presets.lua](../../source/core/avionics/control_presets.lua) | Saves and restores the pilot's selected heading, speed, altitude and control modes after checking core and vessel identity; restored SEL selections hold propulsion until START SYSTEMS is READY. |
| [avionics/controls.lua](../../source/core/avionics/controls.lua) | Interprets cockpit inputs according to MANUAL, SEL and DIRECT modes; updates selections; levers act at their position after a handover (short THRUST NOT NEUTRAL warning), and only anchor release waits for neutral levers. |
| [avionics/debug_recorder.lua](../../source/core/avionics/debug_recorder.lua) | Operator-controlled debug recorder. Captures detailed flight, lift, propulsion and timing data and writes it to a separate removable data disk through its worker. |
| [avionics/destinations.lua](../../source/core/avionics/destinations.lua) | Reads, validates and edits the named destination library on a removable disk. |
| [avionics/diagnostics.lua](../../source/core/avionics/diagnostics.lua) | Read-only connection to the external diagnostic host. Exposes bounded inventory, approved sensor getters, cached runtime status and console logs. |
| [avionics/display_payload.lua](../../source/core/avionics/display_payload.lua) | Constructs the smaller status snapshot sent to heading displays; the bridge receives the full snapshot. |
| [avionics/fleet.lua](../../source/core/avionics/fleet.lua) | Loads and validates the fleet registry; resolves roles to computer IDs and labels and saves approved ID changes. |
| [avionics/flight.lua](../../source/core/avionics/flight.lua) | Central lift controller: Start/Stop Systems, altitude and vertical-speed control, four-chamber leveling, lift limits, saved hover/level learning, tuning, maintenance, lift kill and recovery. Coordinates cockpit controls, anchor and autopilot. |
| [avionics/input_tuning.lua](../../source/core/avionics/input_tuning.lua) | Defines and validates selection-input response settings, including initial change rate, acceleration and maximum rate. |
| [avionics/io.lua](../../source/core/avionics/io.lua) | Core hardware/network boundary. Discovers sensors and links, composes vessel readings, validates node messages and acknowledgements, sends lift commands and publishes display snapshots. |
| [avionics/lateral.lua](../../source/core/avionics/lateral.lua) | Interprets lateral/strafe input and calculates lateral guidance demands for the propulsion controller. |
| [avionics/main.lua](../../source/core/avionics/main.lua) | Core runtime entry point and supervisor. Starts sampling, command processing, lift supervision, propulsion/debug workers and status publication; also provides the core monitor view. |
| [avionics/motion_warnings.lua](../../source/core/avionics/motion_warnings.lua) | Detects possible impacts and obstructions from fresh motion measurements and applied-power readbacks. Publishes advisory warnings. |
| [avionics/navigation_settings.lua](../../source/core/avionics/navigation_settings.lua) | Shared defaults, limits and editable fields for anchor and autopilot settings. |
| [avionics/physics_monitor.lua](../../source/core/avionics/physics_monitor.lua) | Compares modeled lift/support with measured vertical acceleration. Reports inconsistencies and can prefer a better-fitting pressure source. |
| [avionics/pid.lua](../../source/core/avionics/pid.lua) | Reusable PID calculation: proportional, integral and derivative terms, output limits and anti-windup. |
| [avionics/progress_watchdog.lua](../../source/core/avionics/progress_watchdog.lua) | Tracks whether altitude, heading and speed errors are shrinking. Reports stalled control progress and supplies altitude-stall feedback. |
| [avionics/propulsion_worker.lua](../../source/core/avionics/propulsion_worker.lua) | Runs propulsion updates on their own cadence, checks the core supervisor heartbeat and handles stale supervision or restart/kill restrictions. |
| [avionics/radio_inbox.lua](../../source/core/avionics/radio_inbox.lua) | Bounded wireless message queue with priority scheduling and replacement of superseded status reports. IO performs the final message validation. |
| [avionics/reconnect-diagnostics.lua](../../source/core/avionics/reconnect-diagnostics.lua) | Manual diagnostic recovery utility. Saves a worker/runtime probe and opens a fresh diagnostics tab. |
| [avionics/recorder.lua](../../source/core/avionics/recorder.lua) | Older startup CSV flight recorder, with a size limit and previous-run rotation. The inspected current main.lua has no reference to this module; it uses debug_recorder.lua. |
| [avionics/remote_ap.lua](../../source/core/avionics/remote_ap.lua) | Core-side remote AP request handling: permission/neutral-input checks, queued requests, duplicate-request handling and execution through the core supervisor. |
| [avionics/remote_ap_client.lua](../../source/core/avionics/remote_ap_client.lua) | Remote-computer AP interface stored on core for provisioning: destination review, request submission, acknowledgements and progress display. Runs on the provisioned remote. |
| [avionics/remote_client.lua](<../../disk-builder/assets/remote-panel.lua>) | Remote-computer status interface stored on core for provisioning. Shows overview, fleet, lift, propulsion, navigation and logs on the paired remote. |
| [avionics/remote_install.lua](../../source/core/avionics/remote_install.lua) | Core Utilities workflow for installing and pairing a docked remote, managing remote flight permissions and serving authenticated remote requests. |
| [avionics/restart.lua](../../source/core/avionics/restart.lua) | Coordinates deliberate core/navigator restarts, writes a one-shot flight-intent checkpoint and restores it through telemetry recovery. |
| [avionics/runtime_metrics.lua](../../source/core/avionics/runtime_metrics.lua) | Measures elapsed time for named runtime jobs and publishes bounded in-memory timing summaries. |
| [avionics/sampling.lua](../../source/core/avionics/sampling.lua) | Sampling timeout/retry wrapper. Cancels expired attempts and retries while preserving the actual age of the last successful measurement. |
| [avionics/state_reader.lua](../../source/core/avionics/state_reader.lua) | The ama-state program retained among core's source files. Samples vessel/cockpit data and sends it over the wired state link when deployed on STATE. |
| [avionics/state_wire.lua](../../source/core/avionics/state_wire.lua) | Wired state-reader protocol. Selects the wired link, exchanges context, validates sensor/input frames and passes their timestamps and readings into core. |
| [avionics/storage.lua](../../source/core/avionics/storage.lua) | Configuration/settings validation and JSON persistence, including verified writes and backup handling. |
| [avionics/telemetry_recovery.lua](../../source/core/avionics/telemetry_recovery.lua) | Classifies telemetry interruptions, validates vessel/provider identity and applied target maps, and coordinates retained-lift control recovery. |
| [avionics/thrust.lua](../../source/core/avionics/thrust.lua) | Central propulsion controller: controller discovery and authority, speed/heading/manual-acceleration loops, lateral/yaw mixing, direction interlocks, command renewal and learned speed feedforward. |
| [avionics/vessel_sources.lua](../../source/core/avionics/vessel_sources.lua) | Samples and calibrates fallback sensors, selects fresh sources for individual vessel fields and composes the resulting vessel telemetry. |

## Saved operating data and backups (16 files)

| File | Responsibility |
|---|---|
| [avionics/data/control-presets.json](../../source/core/avionics/data/control-presets.json) | Saved pilot selections and modes, bound to core and vessel identity. |
| [avionics/data/control-presets.json.bak](../../source/core/avionics/data/control-presets.json.bak) | Backup of avionics/data/control-presets.json: Saved pilot selections and modes, bound to core and vessel identity. |
| [avionics/data/hover-offset.json](../../source/core/avionics/data/hover-offset.json) | Learned hover correction by altitude band. |
| [avionics/data/hover-offset.json.bak](../../source/core/avionics/data/hover-offset.json.bak) | Backup of avionics/data/hover-offset.json: Learned hover correction by altitude band. |
| [avionics/data/level-bias.json](../../source/core/avionics/data/level-bias.json) | Learned roll and pitch lift-balance corrections. |
| [avionics/data/level-bias.json.bak](../../source/core/avionics/data/level-bias.json.bak) | Backup of avionics/data/level-bias.json: Learned roll and pitch lift-balance corrections. |
| [avionics/data/navigation.json](../../source/core/avionics/data/navigation.json) | Saved autopilot destination/draft. |
| [avionics/data/navigation.json.bak](../../source/core/avionics/data/navigation.json.bak) | Backup of avionics/data/navigation.json: Saved autopilot destination/draft. |
| [avionics/data/sensor-fallback.json](../../source/core/avionics/data/sensor-fallback.json) | Saved fallback-sensor calibration. |
| [avionics/data/sensor-fallback.json.bak](../../source/core/avionics/data/sensor-fallback.json.bak) | Backup of avionics/data/sensor-fallback.json: Saved fallback-sensor calibration. |
| [avionics/data/speed-feedforward-v2.json](../../source/core/avionics/data/speed-feedforward-v2.json) | Learned propulsion feedforward gain and speed bands. |
| [avionics/data/systems-intent.json](../../source/core/avionics/data/systems-intent.json) | Persistent indication that the operator intends the lift systems to remain running. |
| [avionics/data/systems-intent.json.bak](../../source/core/avionics/data/systems-intent.json.bak) | Backup of avionics/data/systems-intent.json: Persistent indication that the operator intends the lift systems to remain running. |
| [avionics/data/systems-restart.json](../../source/core/avionics/data/systems-restart.json) | One-shot systems-restart checkpoint or its cleared/pending marker. |
| [avionics/data/systems-restart.json.bak](../../source/core/avionics/data/systems-restart.json.bak) | Backup of avionics/data/systems-restart.json: One-shot systems-restart checkpoint or its cleared/pending marker. |

## Installer support (5 files)

| File | Responsibility |
|---|---|
| [installer/bundle_cache.lua](../../source/core/installer/bundle_cache.lua) | Keeps verified package bundles in bounded memory so repeated installer requests can reuse them. |
| [installer/config.json](../../source/core/installer/config.json) | Package-transfer settings: protocol, chunk/file limits, retries, timeouts and polling/heartbeat intervals. |
| [installer/install_status.json](../../source/core/installer/install_status.json) | Saved installer progress/status: target role, transfer totals, package identity, retries, errors and cache statistics. |
| [installer/progress.lua](<../../disk-builder/assets/core-progress.lua>) | Draws core's installer progress screen from cached transfer state. |
| [installer/server.lua](../../source/core/installer/server.lua) | Package distribution server: identifies registered clients, checks versions, builds offers, transfers files and verifies installation acknowledgements. |

## Shared package files (5 files)

| File | Responsibility |
|---|---|
| [packages/common/chamber_link.lua](../../source/core/packages/common/chamber_link.lua) | Shared chamber/thrust transport. Resolves paired roles, checks relay envelopes, forwards commands/status and carries corner-altitude readings. |
| [packages/common/chamber_relay.lua](../../source/core/packages/common/chamber_relay.lua) | Shared chamber-side launcher for forwarding traffic to the paired thrust computer. |
| [packages/common/console.lua](../../source/core/packages/common/console.lua) | Shared console, status/log pages, program supervision, installer and diagnostic tabs, and core remote utilities. The existing core startup loads this copy directly. |
| [packages/common/diagnostics.lua](../../source/core/packages/common/diagnostics.lua) | Shared diagnostic-client source distributed to auxiliary computers. |
| [packages/common/thrust_main.lua](../../source/core/packages/common/thrust_main.lua) | Shared thrust endpoint launcher; starts the child-side chamber link and thrust runtime. |

## Chamber packages (32 files)

| File | Responsibility |
|---|---|
| [packages/chamber/bl/chamber_link.lua](../../source/core/packages/chamber/bl/chamber_link.lua) | Local copy of the chamber/thrust transport module for this chamber. |
| [packages/chamber/bl/config.json](../../source/core/packages/chamber/bl/config.json) | This chamber's role, gas-provider discovery rules, hardware limits, redstone/link configuration and paired thrust role. |
| [packages/chamber/bl/hardware.lua](../../source/core/packages/chamber/bl/hardware.lua) | Chamber peripheral adapters: discover/validate gas providers, read lift/balloon status and apply verified gas settings; also contains thrust adapter support. |
| [packages/chamber/bl/lift.lua](../../source/core/packages/chamber/bl/lift.lua) | Node-side lift controller. Validates core sessions and commands, manages probe/control authority, applies gas targets, reports readbacks and handles lift kill/recovery. |
| [packages/chamber/bl/main.lua](../../source/core/packages/chamber/bl/main.lua) | Chamber supervisor. Runs the lift component and the paired-thrust relay, publishes component health and restarts failed components. |
| [packages/chamber/bl/manifest.json](../../source/core/packages/chamber/bl/manifest.json) | Package identity, version, role and installation destination-file list. |
| [packages/chamber/bl/relay.lua](../../source/core/packages/chamber/bl/relay.lua) | Starts this chamber's parent-side link to its paired thrust computer. |
| [packages/chamber/bl/thrust.lua](../../source/core/packages/chamber/bl/thrust.lua) | Retained node-side thrust module included in the chamber package. This split layout's main.lua launches relay.lua for its thrust component. |
| [packages/chamber/br/chamber_link.lua](../../source/core/packages/chamber/br/chamber_link.lua) | Local copy of the chamber/thrust transport module for this chamber. |
| [packages/chamber/br/config.json](../../source/core/packages/chamber/br/config.json) | This chamber's role, gas-provider discovery rules, hardware limits, redstone/link configuration and paired thrust role. |
| [packages/chamber/br/hardware.lua](../../source/core/packages/chamber/br/hardware.lua) | Chamber peripheral adapters: discover/validate gas providers, read lift/balloon status and apply verified gas settings; also contains thrust adapter support. |
| [packages/chamber/br/lift.lua](../../source/core/packages/chamber/br/lift.lua) | Node-side lift controller. Validates core sessions and commands, manages probe/control authority, applies gas targets, reports readbacks and handles lift kill/recovery. |
| [packages/chamber/br/main.lua](../../source/core/packages/chamber/br/main.lua) | Chamber supervisor. Runs the lift component and the paired-thrust relay, publishes component health and restarts failed components. |
| [packages/chamber/br/manifest.json](../../source/core/packages/chamber/br/manifest.json) | Package identity, version, role and installation destination-file list. |
| [packages/chamber/br/relay.lua](../../source/core/packages/chamber/br/relay.lua) | Starts this chamber's parent-side link to its paired thrust computer. |
| [packages/chamber/br/thrust.lua](../../source/core/packages/chamber/br/thrust.lua) | Retained node-side thrust module included in the chamber package. This split layout's main.lua launches relay.lua for its thrust component. |
| [packages/chamber/fl/chamber_link.lua](../../source/core/packages/chamber/fl/chamber_link.lua) | Local copy of the chamber/thrust transport module for this chamber. |
| [packages/chamber/fl/config.json](../../source/core/packages/chamber/fl/config.json) | This chamber's role, gas-provider discovery rules, hardware limits, redstone/link configuration and paired thrust role. |
| [packages/chamber/fl/hardware.lua](../../source/core/packages/chamber/fl/hardware.lua) | Chamber peripheral adapters: discover/validate gas providers, read lift/balloon status and apply verified gas settings; also contains thrust adapter support. |
| [packages/chamber/fl/lift.lua](../../source/core/packages/chamber/fl/lift.lua) | Node-side lift controller. Validates core sessions and commands, manages probe/control authority, applies gas targets, reports readbacks and handles lift kill/recovery. |
| [packages/chamber/fl/main.lua](../../source/core/packages/chamber/fl/main.lua) | Chamber supervisor. Runs the lift component and the paired-thrust relay, publishes component health and restarts failed components. |
| [packages/chamber/fl/manifest.json](../../source/core/packages/chamber/fl/manifest.json) | Package identity, version, role and installation destination-file list. |
| [packages/chamber/fl/relay.lua](../../source/core/packages/chamber/fl/relay.lua) | Starts this chamber's parent-side link to its paired thrust computer. |
| [packages/chamber/fl/thrust.lua](../../source/core/packages/chamber/fl/thrust.lua) | Retained node-side thrust module included in the chamber package. This split layout's main.lua launches relay.lua for its thrust component. |
| [packages/chamber/fr/chamber_link.lua](../../source/core/packages/chamber/fr/chamber_link.lua) | Local copy of the chamber/thrust transport module for this chamber. |
| [packages/chamber/fr/config.json](../../source/core/packages/chamber/fr/config.json) | This chamber's role, gas-provider discovery rules, hardware limits, redstone/link configuration and paired thrust role. |
| [packages/chamber/fr/hardware.lua](../../source/core/packages/chamber/fr/hardware.lua) | Chamber peripheral adapters: discover/validate gas providers, read lift/balloon status and apply verified gas settings; also contains thrust adapter support. |
| [packages/chamber/fr/lift.lua](../../source/core/packages/chamber/fr/lift.lua) | Node-side lift controller. Validates core sessions and commands, manages probe/control authority, applies gas targets, reports readbacks and handles lift kill/recovery. |
| [packages/chamber/fr/main.lua](../../source/core/packages/chamber/fr/main.lua) | Chamber supervisor. Runs the lift component and the paired-thrust relay, publishes component health and restarts failed components. |
| [packages/chamber/fr/manifest.json](../../source/core/packages/chamber/fr/manifest.json) | Package identity, version, role and installation destination-file list. |
| [packages/chamber/fr/relay.lua](../../source/core/packages/chamber/fr/relay.lua) | Starts this chamber's parent-side link to its paired thrust computer. |
| [packages/chamber/fr/thrust.lua](../../source/core/packages/chamber/fr/thrust.lua) | Retained node-side thrust module included in the chamber package. This split layout's main.lua launches relay.lua for its thrust component. |

## Thrust packages (24 files)

| File | Responsibility |
|---|---|
| [packages/thrust/xx/chamber_link.lua](../../source/core/packages/thrust/lb/chamber_link.lua) | Local transport module linking this thrust computer to its parent chamber and carrying its corner-altitude readings. |
| [packages/thrust/xx/config.json](../../source/core/packages/thrust/lb/config.json) | This thrust computer's role, drive bindings, transmission/direction settings, limits and parent chamber. |
| [packages/thrust/xx/hardware.lua](../../source/core/packages/thrust/lb/hardware.lua) | Peripheral discovery, validation, transmission/direction adapters and readbacks for this endpoint. |
| [packages/thrust/xxmain.lua](../../source/core/packages/thrust/lb/main.lua) | Starts the child-side chamber link and thrust runtime. |
| [packages/thrust/xx/manifest.json](../../source/core/packages/thrust/lb/manifest.json) | Package identity, version, role and installation destination-file list. |
| [packages/thrust/xx/thrust.lua](../../source/core/packages/thrust/lb/thrust.lua) | Node-side propulsion command handling, command-lease checks, transmission ramping, direction interlocks, hardware writes and status publication. |

## Heading-display packages (9 files)

<pos> = "left"/"main"/"right"
| File | Responsibility |
|---|---|
| [packages/heading/<pos>/config.json](../../source/core/packages/heading/left/config.json) | Selects this instrument's left/right/center display role, protocol, timeout, refresh rate and text scale. |
| [packages/heading/<pos>/main.lua](../../source/core/packages/heading/left/main.lua) | Receives validated core snapshots and renders this instrument display with stale-data, assembly and fault indications. |
| [packages/heading/<pos>/manifest.json](../../source/core/packages/heading/left/manifest.json) | Package identity, version, role and installation destination-file list. |
| [packages/heading/<pos>/config.json](../../source/core/packages/heading/main/config.json) | Selects this instrument's left/right/center display role, protocol, timeout, refresh rate and text scale. |
| [packages/heading/<pos>/main.lua](../../source/core/packages/heading/main/main.lua) | Receives validated core snapshots and renders this instrument display with stale-data, assembly and fault indications. |
| [packages/heading/<pos>/manifest.json](../../source/core/packages/heading/main/manifest.json) | Package identity, version, role and installation destination-file list. |
| [packages/heading/<pos>/config.json](../../source/core/packages/heading/right/config.json) | Selects this instrument's left/right/center display role, protocol, timeout, refresh rate and text scale. |
| [packages/heading/<pos>/main.lua](../../source/core/packages/heading/right/main.lua) | Receives validated core snapshots and renders this instrument display with stale-data, assembly and fault indications. |
| [packages/heading/<pos>/manifest.json](../../source/core/packages/heading/right/manifest.json) | Package identity, version, role and installation destination-file list. |

## Primary-bearing packages (8 files)

<pos> = "left"/"right"
| File | Responsibility |
|---|---|
| [packages/primary/<pos>/config.json](../../source/core/packages/primary/left/config.json) | Selects this side's primary-bearing telemetry role and sensor endpoint settings. |
| [packages/primary/<pos>/hardware.lua](../../source/core/packages/primary/left/hardware.lua) | Discovers and reads primary-bearing hardware. Its shared adapter also includes transmission helper functions; the primary endpoint is configured as a sensor. |
| [packages/primary/<pos>/main.lua](../../source/core/packages/primary/left/main.lua) | Primary-bearing telemetry endpoint. Validates identity/session and publishes bearing hardware/status readings. |
| [packages/primary/<pos>/manifest.json](../../source/core/packages/primary/left/manifest.json) | Package identity, version, role and installation destination-file list. |
| [packages/primary/<pos>/config.json](../../source/core/packages/primary/right/config.json) | Selects this side's primary-bearing telemetry role and sensor endpoint settings. |
| [packages/primary/<pos>/hardware.lua](../../source/core/packages/primary/right/hardware.lua) | Discovers and reads primary-bearing hardware. Its shared adapter also includes transmission helper functions; the primary endpoint is configured as a sensor. |
| [packages/primary/<pos>/main.lua](../../source/core/packages/primary/right/main.lua) | Primary-bearing telemetry endpoint. Validates identity/session and publishes bearing hardware/status readings. |
| [packages/primary/<pos>/manifest.json](../../source/core/packages/primary/right/manifest.json) | Package identity, version, role and installation destination-file list. |

## Bridge package (5 files)

| File | Responsibility |
|---|---|
| [packages/navigation/config.json](../../source/core/packages/navigation/config.json) | Bridge role, communications, status timeout and display configuration. |
| [packages/navigation/main.lua](../../source/core/packages/navigation/main.lua) | Bridge runtime: receives core status, manages session identity, queues/retries pilot UI requests, matches acknowledgements and handles monitor touches. |
| [packages/navigation/manifest.json](../../source/core/packages/navigation/manifest.json) | Package identity, version, role and installation destination-file list. |
| [packages/navigation/storage.lua](../../source/core/packages/navigation/storage.lua) | Loads/validates bridge configuration and persists local display settings. |
| [packages/navigation/ui.lua](../../source/core/packages/navigation/ui.lua) | Renders FLIGHT, NAV, SHIP and SETTINGS pages and returns the actions associated with touched controls. |


## Measurement and recovery flow

State normally supplies vessel and cockpit frames. Core checks their accepted-frame age after a 15 s boot grace. Five seconds without a frame can start local sensor readers; core event lag above 2 s defers that takeover. Five seconds of continuously fresh restored frames permits handback. Repeated failures within 120 s double the handback interval, capped by the implemented flap limit. Worker guards bind local readers to their current failover context.

Vessel composition first honours an explicit session sensor preference, then current Sable pressure, then an eligible held Sable value, then sensor pressure. The held value lasts at most 30 s within three altitude blocks and yields to a sensor reading within 30%. Snapshots and recordings expose selected, Sable and sensor pressure plus source names. Target-altitude queries have a separate cache and state-reader request path. See [pressure evidence](../diagnostics/PRESSURE-EVIDENCE.md).

The physics monitor compares modeled support with 1 + vertical acceleration/gravity. A five-second mismatch beyond 0.35 can select an alternate source if it meets tolerance and halves the error; otherwise it publishes an inconsistency. The progress watchdog tracks error reduction for altitude, speed, heading and anchor. Altitude-stall feedback is consumed by the altitude control calculation; its other observations are diagnostics. Their source ownership and calibration assumptions belong to the tuning/model references.

Persistent cruise learning uses validated JSON primary/backup replacement. Remote provisioning publishes permissions only after successful activation. See [maintenance delivery record](../development/MAINTENANCE-ROADMAP.md) for tested transaction boundaries and pending refactoring.
