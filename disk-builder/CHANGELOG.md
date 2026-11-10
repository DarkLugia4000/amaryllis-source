# Amaryllis Disk Builder changelog

Version entries describe the changes recorded for each release. See the
[README](README.md) for current usage.

## Unreleased

### Altitude ceiling replaces Maximum target Y

- `altitude_control.maximum_world_y` is removed (`config.json`, `config_registry.lua`, `storage.lua`,
  `plant-profile.json`; `TUNING-REFERENCE.md` regenerated). `altitude_ceiling` is the one upper altitude bound:
  `Controls.altitudeCeiling` returns it, and the START SYSTEMS target, the retained-run recovery, the live
  systems target, the control context sent to the chambers (`io.lua`), PID tuning limits and RESTART SYSTEMS
  (`restart.lua`) check against it. A retained or saved restart target above the ceiling is lowered to it
  instead of refused. AP destinations and saved cockpit presets accept altitudes up to Y 2048; the control
  update lowers any target above the ceiling. `storage.lua` drops the reversed-bounds check, and keeps the
  ceiling-above-minimum check. A saved `maximum_world_y` on an existing ship is left in place and unused.
- `flight.lua`: "Minimum target Y" moves from LIMITS to ALTITUDE PID / LIMITS, above "Altitude ceiling (Y)";
  "Maximum target Y" is removed.
- `test_altitude_ceiling`, `test_config_registry` updated.

### Unused and migration-only code removed

- `ui.lua`: the heading-display renderer is removed (`compassLabel`, `shortestDelta`, `putCentered`,
  `drawCompass`, `targetAvailable`, `altitudeHoldIndicator`, `drawCenterHeading`, `drawHeading`,
  `headingErrorSurface`, `nonemptyHeadingReason`, `headingIssue`, `reportHeadingIssue`, the `heading` role
  branches in `UI:draw` and `UI:touch`, `renderer.role` and `UI.MIN_HEADING_*`). The heading displays run
  `heading-main.lua`. `drawTooSmall` names only the bridge size.
- Functions with no callers removed: `Installer.setApplicationState` and `existingStatus` (`installer.lua`,
  asset hash updated), `Hardware.isFinite` and `Hardware.readReadbacks` (`primary-hardware.lua`,
  `thrust-hardware.lua`) and `Hardware.requiredProviderMethods` (`thrust-hardware.lua`).
- `flight.lua`: the constant-rate altitude target used when flight ran without the cockpit controls module is
  removed, along with its setting `altitude_control.target_rate_blocks_per_second` (`config.json`,
  `config_registry.lua`, `storage.lua`, `plant-profile.json`; `TUNING-REFERENCE.md` regenerated). A saved value
  on an existing ship is left in place and unused.
- `updater.py`: the RL/RR to BL/BR chamber rename, the old-launcher replacement (`LEGACY_LAUNCHER_SHA256`,
  `current_launcher`) and the startup launcher repair (`preview_startup_repair`, **Preview startup repair**,
  `--repair-startup`) are removed. The test world has neither the old launcher nor RL/RR chambers.
  `disk-builder/README.md`, the maintenance catalogue and `test_project_release` updated.
- `docs/installation/Amaryllis-Owner-Installation-and-First-Flight-DRAFT.md` removed; links point to the v3 guide.

### Propulsion state kept until STOP SYSTEMS

- `flight.lua`: START SYSTEMS no longer saves propulsion as disabled, so the saved `thrust.enabled` in
  `config.json` survives core reboots, START SYSTEMS, auto-resume and RESTART SYSTEMS. `disablePropulsionForStart`
  is replaced by `disablePropulsionForStop`, which a confirmed STOP SYSTEMS calls: it cancels AP and the anchor
  and saves propulsion as disabled ("PROPULSION OFF: SYSTEMS STOPPED"). Enabling still requires READY, and READY
  still enables a disabled propulsion after 10 s of steady hold.
- Owner guide v3 step 7 and `source_notes.py` updated. `test_lever_handover` checks the stop path and that START
  and RESTART SYSTEMS leave the state alone.

### PID page notes removed

- `ui.lua`: the VS, PROP SPEED, PROP ACCEL, PROP YAW and TRIM PID pages no longer show a gray note; the
  `PID_NOTES` table is removed.

### ALTITUDE PID / LIMITS note removed

- `ui.lua`: the ALTITUDE PID / LIMITS page no longer shows the gray note "Altitude error -> target climb/descent
  speed". The other PID pages keep theirs.

### Altitude tapes stop at the ceiling

- `flight.lua`: the `altitudeControl` snapshot carries `ceiling` (`Controls.altitudeCeiling`).
  `display_payload.lua` sends it to the heading displays, and the `heading-main.lua` sanitizer keeps it.
- `heading-main.lua` / `ui.lua`: the heading display's and the bridge's altitude tapes leave levels above the
  ceiling blank, with no tick or number. Without a ceiling from core the tape shows every level as before.
- `test_altitude_ceiling`: renders the heading display's tape with and without a ceiling.

### Altitude ceiling setting; LOW PRESS moved up

- `config.json`: new `altitude_control.altitude_ceiling`, shipped at Y 280. Updated ships get it from the
  defaults. `storage.lua` bounds it to -2048..2048 and requires it to be above `minimum_world_y`;
  `config_registry.lua` records it.
- `controls.lua`: `Controls.altitudeCeiling` gives the highest selectable altitude: the ceiling, or
  `maximum_world_y` when that is lower. The altitude selector stops at it. Every control update lowers a target
  above it (from a lowered ceiling, a restored record or a restart checkpoint) to the ceiling, so the bridge and
  heading displays show no selected altitude above it.
- `autopilot.lua`: a destination altitude edited above the ceiling is set to the ceiling, and engaging AP
  targets the lower of the destination altitude and the ceiling.
- `flight.lua` / `ui.lua`: the ALTITUDE PID settings page is now ALTITUDE PID / LIMITS and lists
  "Altitude ceiling (Y)" first.
- `heading-main.lua`: LOW PRESS (yellow) starts at Y 285 and clears below Y 284; the red LOW PRESS / DESCEND
  alternation starts at Y 305. `PILOT-REFERENCE.md` updated.
- Tests: new `test_altitude_ceiling`; `test_recovery` uses the new warning heights; `test_config_registry` lists
  the ceiling as a cross-field bound. `TUNING-REFERENCE.md` regenerated.

### Cockpit modes survive a new vessel ID

- `control_presets.lua`: after a core restart, the saved heading and throttle modes are restored whatever the
  Sable vessel ID, so a ship reassembled before the restart keeps her modes. When the ID matches, the saved
  heading, speed and altitude targets are restored as before. When it differs, each SEL axis takes the current
  heading or speed (speed clamped to the selectable range), and the altitude target is the current height. A
  restored SEL axis still holds propulsion until START SYSTEMS is READY. A record saved by another core computer
  is still discarded ("SAVED PRESETS BELONG TO A DIFFERENT CORE").
- `test_persistent_modes`: covers the new vessel ID and another core computer.

### Panel Home Tools page scrolls

- `panel-console.lua`: Tools buttons keep one blank row between them. When they do not all fit, the list scrolls
  with the arrow keys, Page Up/Down and the mouse wheel, and the visible range shows bottom right (for example
  `1-7 / 8` on a 51 x 19 terminal). This replaces the consecutive-row fallback from "Fix gas mix lag moves to
  core's Panel Home".
- Tests: `tests.test_gas_mix_fix` case `test_tools_page_scrolls_when_buttons_do_not_fit`.

### Fix gas mix lag moves to core's Panel Home

- The button moves from the bridge to core's own screen: Panel Home > Tools > **Fix gas mix lag**. Its page shows
  the description, "Turns each chamber's probe link off and on again. Altitude control must be disengaged.", a
  status line (core's maintenance status, a refusal reason, "DISENGAGE ALTITUDE CONTROL FIRST" while altitude
  control is engaged, or READY) and a **Fix gas mix lag** button that asks for Confirm or Cancel
  (`panel-console.lua`). Tools buttons sit on consecutive rows when every second row does not fit.
- Confirm queues `amaryllis_core_action` with `maintenance_probe_cycle`; core's supervisor (`main.lua`) runs it
  through `Flight:request` and publishes the result in `os.__amaryllisCoreAction` (documented in
  `docs/architecture/RUNTIME-GLOBALS.md`). The chamber operation and core's job are unchanged.
- Bridge: the FLIGHT SETTINGS 2/2 button and its `GAS MIX LAG` page are removed, and the navigator no longer
  sends `maintenance_probe_cycle`.
- Tests: `tests/test_gas_mix_fix.py` adds the Panel Home page (confirmation, status, short terminal) and core's
  action handler; the bridge page test is removed from `tests.test_information`.

### Fix gas mix lag

- Bridge: FLIGHT SETTINGS 2/2 has a **FIX GAS MIX LAG** button. Its page (`GAS MIX LAG`) reads "Mixing Hot Air and
  Steam in balloons can at times create inexplicable lag spikes. If you're experiencing these, this should fix
  most of it.", notes "Turns each chamber's probe link off and on again.", shows the job status, and sends
  `maintenance_probe_cycle` for all chambers. The button is available while altitude control is off and no other
  lift maintenance is running.
- Core (`flight.lua`): `maintenance_probe_cycle` runs as chamber maintenance operation `probe_cycle`, one chamber
  at a time (FL, FR, BL, BR), each acknowledged before the next; status reads `<Q> RESTARTING PROBE`, then the
  chamber's reply, then `GAS MIX FIX COMPLETE`. Refused with "DISENGAGE ALTITUDE CONTROL FIRST" while altitude
  control is engaged. `io.lua` (`sendLiftMaintenance`) accepts `probe_cycle`.
- Chambers (`chamber-hardware.lua` `Hardware.cycleProbeLink`, `chamber-lift.lua`): `lift_maintenance` accepts
  `probe_cycle`. The sole writer sets the trim probe's redstone link (`trimActivationFrequency` on the activation
  bridge) to 0, waits 1 s, sets it back to its previous level and verifies the readback (up to five reads 0.1 s
  apart). A link that was off stays off. The idle-probe keeper waits during the cycle (`probeCycleActive`).
- Tests: `tests/test_gas_mix_fix.py` (added to `project.SUITES`) covers the link cycle, a link that was off, an
  unreadable link, and core's job across all four chambers; `tests.test_information` covers the bridge page.

### Bridge disassembled panel: instruction lines together

- `ui.lua` (`drawAssemblyPanel`): "Previous gas levels will be carried over." moves from row 17 to row 14, directly
  under "Please assemble the vessel to enable controls." on row 13. Each of the two holds one line; the cause on
  row 9 still wraps to two.

### Bridge disassembled panel spacing

- `ui.lua` (`drawAssemblyPanel`): the panel text spreads over the panel as the earlier layout did, one sentence
  per group with blank rows between: "Core module reports physics assembler is not engaged." from row 9 (white),
  "Please assemble the vessel to enable controls." from row 13 (yellow), "Previous gas levels will be carried
  over." from row 17 (light gray). Each group wraps to at most two lines. Other assembly states show their reason
  from row 9.
- Tests: `tests.test_information` case `test_disassembled_vessel_shows_only_that_issue` checks the three rows.

### Bridge disassembled panel: maintenance line removed

- `ui.lua` (`drawAssemblyPanel`): "Settings > Lift maintenance remains available." is removed from the panel.
  Lift maintenance under SETTINGS is unchanged.

### Bridge disassembled panel: gas levels sentence

- `ui.lua` (`drawAssemblyPanel`): "If airborne, lift will be retained." now reads "Previous gas levels will be
  carried over."

### Bridge disassembled panel wording

- `ui.lua` (`drawAssemblyPanel`): with the vessel disassembled, the FLIGHT panel under `ERROR: VESSEL NOT
  ASSEMBLED` reads "Core module reports physics assembler is not engaged." and "Please assemble the vessel to
  enable controls. If airborne, lift will be retained." in place of the assembly check's reason
  (`physics_assembler_1.isAssembled() = false`). Other assembly states keep their reason there.
- Removed from the panel in every assembly state: "Source: physics assembler isAssembled()", "Blocked: START
  SYSTEMS, altitude hold, trim, PID tuning, cockpit modes and propulsion.", "Applied lift ceilings are retained."
  and "Nothing resumes automatically after reassembly." "Settings > Lift maintenance remains available." stays.
- Tests: `tests.test_information` case `test_disassembled_vessel_shows_only_that_issue` checks the panel text.

### Bridge bottom line: ASSEMBLE VESSEL TO ENABLE CONTROLS

- `ui.lua` (`Info.collect`): while the vessel is definitely disassembled, the one current issue reads
  `ASSEMBLE VESSEL TO ENABLE CONTROLS` on the bottom line and the issues page; the assembly check's message
  (`VESSEL DISASSEMBLED: physics_assembler_1.isAssembled() = false`) is its detail. Unverified assembly states keep
  the assembly message as the issue text.
- Tests: `tests.test_information` case `test_disassembled_vessel_shows_only_that_issue` checks the text, the detail
  and the bottom line.

### Bridge shows only the disassembled issue while disassembled

- `ui.lua` (`Info.collect`): while the vessel is definitely disassembled (`assembly.state` DISASSEMBLED), the
  current issues list holds only the assembly issue, after a latched lift kill if one is active. Every other
  warning returns once she is assembled. This replaces the repeated-text merge (`sameIssue`) from "Bridge shows
  one issue for one fault" below, which is removed.
- Tests: `tests.test_information` case `test_disassembled_vessel_shows_only_that_issue` replaces
  `test_one_fault_reported_several_ways_is_one_issue`.

### Bridge shows one issue for one fault

- With the vessel disassembled, the bridge's bottom warning line rotated through the same fault three times:
  `VESSEL DISASSEMBLED: physics_assembler_1.isAssembled...` (assembly lock and reported fault),
  `VESSEL DISASSEMBLED` (vessel data reason) and `FAULT VESSEL DISASSEMBLED: physics_assembler_1.isAs...`
  (propulsion reason, cut to 48 characters).
- `ui.lua` (`Info.collect`, new `sameIssue`): an issue is left out when its text matches one already listed,
  is the heading before the other's colon, or is the other cut short with "..."; a leading `FAULT ` is ignored.
  The first report listed is kept (here the assembly lock).
- Tests: `tests.test_information` case `test_one_fault_reported_several_ways_is_one_issue`.

### Web install: undo options

- `web-setup.lua` on core's registration screen:
  - **R** resets the installation: writes `/installer/web/reset-pending.json`, boots core into registration and
    reboots; registration then runs `Setup.unassignCore` and `Setup.installCore` (programs kept). Core's
    discovery reply carries the previous roster (`reset`), so a computer re-registering its role keeps its
    programs and settings (`Setup.installRegistered` returns `retained`).
  - **U** uninstalls core before import (`uninstallCore`): deletes `/startup.lua`, `/avionics`, `/installer`,
    `/fleet.json`, `/amaryllis-install.json` and the label. After import it asks for a reset first.
  - An `unregister` message from a computer clears that computer's role.
- On other computers, **3 Remove this computer's registration** (`removeRegistration`) deletes the receiver
  (`/startup.lua`, `/installer.lua`, `/installer`, `/config.json`) or the state reader's programs (`/avionics`),
  the registration record and the label, and sends `unregister` to core. A computer running its role package is
  refused.
- `auxiliary-startup.lua`: the commissioning screen reads "Wrong role? Hold Ctrl+T and run the loader again, or
  boot the setup disk, before core imports." (was "Insert the setup disk and reboot. Open Assignments before
  importing on core.")
- `disk-builder/README.md` lists the fixes. Tests: `tests/test_web_setup.py` adds reset with retained computers,
  uninstall before and after import, and removing a receiver and a state reader registration.

### Pastebin loader text in the repository

- New `tools/pastebin/loader.lua`: the Pastebin loader with the repository set to
  `DarkLugia4000/amaryllis-source`, ready to paste. It is `disk-builder/assets/pastebin-loader.lua` with
  `__REPOSITORY__` filled in, the same text the release workflow writes to `media/loader.lua`.

### Closed-world update option removed

- `updater.py` and `project.py update`: `--require-closed` and the hidden `--minecraft-closed` are removed, together
  with `hold_world` (the `session.lock` byte lock), `live_world`, `_already_held`, `WORLD_OPEN` and the
  `world_lock` parameter of `apply` and `restore`. Updates and restores always run with the world open or closed.
- Docs: `disk-builder/README.md`, `docs/maintenance/Amaryllis-Maintenance-Catalogue.md` and
  `docs/development/HANDOFF-CLAUDE.md` no longer describe the option.
- Tests: `tests/test_world_lock.py` keeps the open-world update, runtime-file and save-folder cases and checks that
  the options are gone; `tests/test_project_release.py` calls `apply` and `restore` without a lock.
- The recovery message no longer asks to keep Minecraft closed: "An update transaction needs recovery. Use Restore
  backup with the folder named in .amaryllis-update.json".

### Web install from GitHub through a Pastebin loader

- New `disk-builder/assets/web-setup.lua`, exported as `media/web-setup.lua`. Run by the Pastebin loader, it
  installs core from the web and registers the other computers over rednet (`amaryllis.setup.v1`, messages
  `discover`, `core`, `register`, `registered`):
  - Core: **1 Install core** downloads `release.json`, `library.json`, `setup.lua` and `web-setup.lua` into
    `/installer/web/` (each checked against `download.json`), records the pinned address in `source.json`, runs
    `Setup.installCore` with package objects fetched over HTTP, and opens the registration screen. Core's own
    `startup.lua` waits in `/installer/web/core-startup.lua` and core boots into registration until import.
  - Core's screen lists the 16 roles with their computer IDs, answers discovery, records registrations
    (`Setup.registerRole`), clears a role with Backspace (`Setup.clearRole`), and imports with Enter once every
    role is registered (`Setup.importFleet`), restoring core's startup and rebooting.
  - Other computers: **2 Register this computer** finds core, downloads core's own release, lists the roles,
    registers the chosen one, and installs the wireless receiver (state reader: its programs)
    (`Setup.installRegistered`), then reboots to wait for core. A registered computer without a role package
    moves to another role (`Setup.checkRoleChange`, `move`).
- New `disk-builder/assets/pastebin-loader.lua`, exported as `media/loader.lua`: pins the newest `release` branch
  commit through the GitHub API (falls back to the branch name) and runs `web-setup.lua` from
  `raw.githubusercontent.com/<repo>/<commit>/media/`. The release workflow fills in the repository.
- New `.github/workflows/release.yml`: every push to `main` builds the media (`python project.py build`) and
  commits it to the `release` branch. Package objects accumulate, so an installed core keeps serving its release.
- `core-media.lua` (`/installer/media.lua`): a core with `/installer/web/source.json` fetches package objects from
  its web release (`Media:openWeb`), checked against the trusted catalogue; `server.lua` passes `http`.
- `setup.lua`: `Setup.readObject` hook for package objects; `writeRoleConfig` shared by disk and web installs.
  The floppy-disk route is unchanged and stays as a fallback.
- Builder: `web-setup.lua` joins `download.json`; `loader.lua` stays out of the index (its repository is filled in
  after the build). Installer README and `disk-builder/README.md` describe the web install.
- Tests: `tests/test_web_setup.py` (added to `project.SUITES`) runs core and computers against a built release on a
  simulated network: core install, registration, taken roles, role moves, import and core's web package source.

### AP emergency stop on a measured impact

- `autopilot.lua` (`AP:emergencyStop`, `AP.impactSeq`): a POSSIBLE IMPACT from the motion monitor while AP is
  engaged ends AP at once with reason `EMERGENCY STOP: POSSIBLE IMPACT (MOTION)` or `(ROTATION)`. The route is
  cancelled (re-engaging starts a new route from the destination settings), live propulsion demand drops to zero,
  a SEL speed target becomes 0, and the pilot takes over once every lever reads neutral. Pilot modes are kept.
  Impacts measured before engagement are ignored (`impactSeqAtEngage`).
- The motion monitor's impact rule is unchanged: velocity change of at least 4 b/s between samples with at least
  8 b/s^2 (`impact_delta_speed`, `impact_acceleration`), or a heading jump of 15 degrees at 30 degrees/s and more,
  or a yaw-rate jump of 12 degrees/s at 25 degrees/s^2 and more. `motion_warnings.lua` now keeps the latest impact
  as `lastImpactEvent` with its sequence number.
- `controls.lua`: the neutral-lever handover takes a cause (`neutralCause`), so the bridge reads
  `EMERGENCY STOP: SET <LEVER> TO NEUTRAL`; anchor release keeps `ANCHOR RELEASED: ...`.
- Tests: `tests.test_autopilot` cases `impact_is_an_emergency_stop` and
  `impact_before_engagement_does_not_stop_the_route`.

### AP ACCEL is the initial run-up only

- Found in debug recording `3-1794010337384` (AP run, cruise 18 b/s): the phase flicked from CRUISE to ACCEL for
  1 to 2 s about every 10 s, whenever speed dipped below 17.9 b/s (lowest 17.84). Heading-bias learning
  (`AP:updateHeadingBias`) runs only in CRUISE and reset its drift filter at every flick.
- `autopilot.lua`: ACCEL covers the initial run-up to cruise speed. CRUISE is entered as before (speed target at
  cruise and speed within 0.1 b/s of it) and then holds until DECEL; the speed loop corrects later speed changes.
  A restarted speed target (after ACQ or CAPTURE) runs up through ACCEL again.
- Tests: `tests.test_autopilot` case `accel_is_only_the_initial_run_up_to_cruise`.

### Bridge request line names AP's request

- `ui.lua` (`propulsionRequestText`): while AP is engaged, the request line on the FLIGHT page reads
  `AP TARGET x.xx b/s` (in place of `SEL TARGET`) and `AP RPM +0` (in place of `REQ RPM`). AP runs the speed
  controller in SEL toward its ramped speed target, and in DIRECT at idle during ACQ and CAPTURE; the line showed
  those with the pilot labels while the THROTTLE MODE row kept the pilot's own selection.
- Tests: `tests/test_ap_request_labels.py` (added to `project.SUITES`) covers both labels with AP engaged and disengaged.

### Thrust readback stays fresh while commands arrive

- Found in debug recording `3-1794009150404` (AP test): AP fell back from ACCEL to ACQ four times in 90 s with
  `thrust-ls: TRANSMISSION READBACK STALE` or `thrust-rs: ...` while every status packet arrived within 0.45 s. The
  endpoint phase read `COMMAND ACCEPTED` in every sample, so controller passes were rarely finishing.
- Cause: a controller pass reads every drive, writes, then reads every drive again, and only the end of the second
  read set `readbackSampleAt`. Each accepted command (about every 0.5 s) advances `writerToken`, and the pass
  returned at the next check, discarding its readings. The BL/BR thrust endpoints read three drives (main prop and
  two laterals), so their passes outlast the command interval most often; two discarded passes in a row aged the
  readback past `readbackStaleSeconds` (1 s), and core stopped propulsion.
- `chamber-thrust.lua` and `thrust-controller.lua` (`controllerTick`): both read passes finish even when a command
  arrives; a complete first pass records the readings (`Thrust.updateReadbacks`) and `readbackSampleAt` before any
  write. Writes still stop as soon as a newer command arrives, and the pass then restarts with the new targets.
  `Thrust.controllerTick` is exported for tests.
- Tests: `tests/test_thrust_readback.py` (added to `project.SUITES`) delivers a command during the first read and
  checks the readback stays fresh, for both controller variants.

### Installer disk from the web (`download.lua`)

- New `disk-builder/assets/disk-download.lua`, exported as `media/download.lua` (registered in `asset-hashes.json`,
  `PURPOSES` and `SUMMARIES`). Run on any computer with a disk drive and a disk attached, it fills the disk with a
  release published on the web, in the same layout the builder writes to `media/`:
  `wget run <raw link to media/download.lua> <user>/<repo>[/<branch>]` (GitHub raw address, branch `main` by
  default) or a full link to the media folder.
- The builder writes `media/download.json` (`write_download_index`): every media file with its size and Adler-32,
  objects first and `library.json`, `setup.lua`, `download.lua`, `release.json`, `startup.lua` last. The downloader
  removes `startup.lua` first and writes it last, so a disk boots only from a complete download; each file is
  checked on arrival and the whole disk again at the end, with three attempts per file.
- A disk that already holds files gets a choice. Same release: check and repair (keeps `deployment.json` and
  `role-repair.json`), replace (clears them) or cancel. Other release: replace or cancel, with a note that saved
  progress belongs to the old release (`setup.lua` accepts progress only for its own release ID). Other files:
  erase or cancel.
- Free space is checked before anything is written; a short disk names `floppy_space_limit`. The address is saved
  on the disk (`download-source.json`), so `/disk/download.lua` with no argument updates the same disk later. An
  unlabeled disk is labeled "Amaryllis installer".
- The installer README describes the web route. Tests: `tests/test_disk_download.py` (added to `project.SUITES`)
  runs the downloader against a built media folder on a simulated drive.

### Heading display: yaw-rate readout removed

- `heading-main.lua`: the gray `RATE +x.x` readout (measured yaw rate) on the right of row 2 in manual heading is
  removed. Row 2 right shows `HDG Δ +x.x°` in SEL heading only; in manual heading the space is free for the
  DIST / TURNING / strafe text that moves there when REQ owns the bottom left. `sanitizeSnapshot` keeps only
  `targetYawRate` from `headingControl` (it sets the turn-arrow blink period).
- Tests: `tests.test_heading_glyphs` checks the readout is gone.

### Forward speed back to Sable; one Sable reader at a time

- `vessel_sources.lua`: forward speed is Sable's world velocity (`getLinearVelocity`) along the horizontal bow again;
  the velocity sensor on the bow axis is the fallback when no velocity vector is available (source
  `VELOCITY SENSOR`, telemetry mode FALLBACK). This replaces the sensor-first choice in "Forward speed from the
  velocity sensor" below; the selected-speed stall fix there stays.
- Sable velocity is kept per reader: `Sources.acceptPrimary` takes an origin, `core` from `io.lua` and `reader` from
  `state_wire.lua`. The shared velocity slot takes core's own reading while it is under 2 s old, so the two readers
  no longer alternate. The state reader's velocity fills in when core's own read stops.
- `debug_recorder.lua`: new columns `forward_speed_sable_core`, `forward_speed_sable_reader` and
  `forward_speed_sensor` (each source's forward speed side by side).
- Tests: `tests/test_speed_source.py` covers Sable primary, sensor fallback, core over reader and reader fill-in.

### Pilot presets and vessel state

- `storage.lua` (`sectionPath`, `readState`, `importState`, `Storage.readJson`
  and `Storage.writeJson`) routes pilot modes and selected targets into
  `pilot-presets.json`. AP draft, learned speed feedforward, calibration,
  systems intent and remote pairings go into `vessel-state.json`.
- Each file imports its own sections on first write from the prior combined
  `persistent-state.json` or the original individual records. Each file has
  its own backup. Tests: `tests.test_persistence`, `tests.test_persistent_modes`
  and `tests.test_source_integrity`.

### Core persistent state

- `Storage.readJson` and `Storage.writeJson` route pilot presets, AP draft,
  hover and level calibration, fallback sensor calibration, speed feedforward,
  systems intent and remote pairings into `persistent-state.json`. First write
  imports legacy records and retains their files. Section writes serialize across
  workers and use verified replacement and backup rotation.
- `readState` recovers a valid backup with systems intent inactive and remote
  flight grants cleared. Emergency latches, restart checkpoints and diagnostic
  exports retain their independent files.
- `AP.new`, `Flight:configureHoverMemory` and `Flight:configureLevelMemory`
  load through storage after removing legacy file-existence checks.
  `remote_install.lua` routes pairing saves and rollback through core storage.
- Redundancy pass removes core's unused display-settings schema and helpers
  and the unused remote registry path export. Navigator owns its own settings.
- Tests: `tests.test_persistence` and `tests.test_source_integrity`.

### Updater dialog

- `updater.py` (`open_dialog`, Apply update and Restore backup) removes the
  checkbox `Only apply or restore while the world is closed`. Both actions use
  live mode. The command line retains `--require-closed`.
- Checks: `tests.test_project_release` GUI update case, `tests.test_world_lock`
  and `tests.test_source_integrity`.

### Forward speed from the velocity sensor; selected-speed stall

- Found in debug recording `3-1793974093040` (SEL 4.23 b/s, actual about 6 b/s): core and the state reader both read
  Sable `getLinearVelocity` into the same slot, and one of them returned 3.87 b/s while the other returned 6.26 b/s.
  Every 3.87 reading (about every 15 s) flipped the speed error from -2.03 to +0.35, and the selected-speed output
  jumped from 0.155 to about 0.28 (about 40 to 72 of 256 shift levels), then ramped back down: the jolts.
- `vessel_sources.lua`: forward speed now comes from the velocity sensor on the bow axis
  (`geometry.velocity_forward`, +X on Amaryllis) whenever it reads fresh; source `VELOCITY SENSOR`, telemetry mode
  stays PRIMARY. Sable's world velocity along the horizontal bow is the fallback. Vertical speed, position projection
  and the rest of the velocity data keep their sources. The sensor reads along the hull, so a pitched hull adds a
  small climb component.
- `thrust.lua` selected speed: the trim (integral) also integrates after 3 s of steady speed (|dv/dt| < 0.05 b/s^2),
  whatever the error. The recording showed her settled 2.03 b/s over the target, just outside the 2 b/s integration
  band, with the integral frozen at 18.7 and the proportional term too weak to correct it. Large speed changes still
  integrate only inside the band.
- `debug_recorder.lua`: new `forward_speed_source` column.
- Tests: `tests/test_speed_source.py` (added to `project.SUITES`).

### Rear chambers are BL/BR everywhere

- The rear chamber IDs `RL`/`RR` (rear-left/right) are renamed `BL`/`BR` (back-left/right), the names their roles,
  setup names, package folders and every display already used. This covers core (`flight.lua`, `io.lua`, `fleet.lua`,
  `restart.lua`, `recorder.lua`, `debug_recorder.lua`, `telemetry_recovery.lua`, `state_wire.lua`, `main.lua`), the
  chamber and thrust packages (`chamber-hardware.lua`, `chamber_link.lua`, `thrust-hardware.lua`, the BL/BR
  `config.json` `quadrant` values), the navigator (`ui.lua`) and the panel console asset (`panel-console.lua`, hash
  updated in `asset-hashes.json`).
- The seven ID-to-label swaps (`{RL="BL",RR="BR"}`) and the two tile labels are removed; IDs are shown as they are.
- Flight recording columns are now `yBL`, `yBR`, `fineBL`, `fineBR`, `liftBL`, `liftBR`, `ceilBL`, `ceilBR`.
- Migration: the live updater rewrites a chamber's stored `quadrant` `RL`/`RR` to `BL`/`BR` (stored settings are
  otherwise kept as they are). A coordinated-restart checkpoint saved with `RL`/`RR` keys loads with `BL`/`BR` keys
  (`restart.lua`, beside the phase-name mapping).
- Deployment: core and the chambers exchange the IDs, so after the live update reboot every computer, not only core
  and the navigator.
- Tests and fixtures use the new IDs (`control-stage-baseline.json`, `plant-profile.json` and the Lua cases in nine
  test modules). `test_project_release.py` adds `test_update_renames_stored_rear_chamber_quadrants`.

### PID settings labels

- `flight.lua`: new `Flight.PID_LABELS`. Every PID gain on the settings pages (altitude, vertical speed, trim, selected
  speed, manual acceleration, turn rate) now reads by what it does, with the short name kept in brackets:
  `Response to error (kp)`, `Lasting-error correction (ki)`, `Damping (kd)`, `Lasting-error cap (i-limit)`,
  `Damping smoothing s (d-filter)`. Keys, ranges and saved values are unchanged.
- Navigator: each PID page shows one gray line on row 17 naming the error it reads and the output it sets, for
  example `Altitude error -> target climb/descent speed` on ALTITUDE PID.

### Unnamed destinations use their coordinates

- `autopilot.lua`: new `AP.label(destination)` returns the entered name, or `"X, Z"` from the whole-block destination
  coordinates when no name is entered. The draft starts without a name (was `"Destination"`); a saved draft named
  `"Destination"`, the earlier default, loads as unnamed. Saving a blank name removes it. Route entries, the ENGAGED log
  line and saving the draft to the destination library use the label. `AP:snapshot` adds `destination.label`.
- Navigator NAV > AUTOPILOT: the destination button and the AP status title show the label; the name editor starts
  empty for an unnamed destination and accepts a blank name. Renaming a saved library entry still needs a name.
- Heading display: a destination name longer than its space keeps its start and ends in `..`
  (for example `3000000..`).
- Tests: `test_autopilot.py` adds `unnamed_destination_uses_its_coordinates`; `test_heading_glyphs.py` adds
  `HeadingDestinationNameTests`.

### Navigator wording (owner edits in `ui.lua`)

- FLIGHT page: `APPLIED THROTTLE` is now `MAIN ENG. POWER`; the L/R readback stays at column 18.
- SHIP > TRIM: the `SELECTED ALTITUDE STAYS UNCHANGED` line on row 20 is removed.
- SETTINGS > COCKPIT INPUTS: the held-input acceleration hint is removed. PID / LIMITS: the tuning-test approval
  hint is removed.
- NAV > AUTOPILOT hint: `Enter coordinates, cruise speed and altitude`. NAV > ANCHOR hint: `Holds the vessel in the
  specified coordinate.` SHIP fault line with nothing reported: `CLEAR` (was `NO REPORTED FAULTS`).
- NAV > AUTOPILOT: `USE CURRENT POSITION` is now `SET CURRENT POSITION`.
- SHIP > propulsion: the lateral readback row reads `LVL PORT … STB …` (was `LVL P … S …`).
- RESET LEVELING page: shorter description; the READY line reads `LEVEL RESET READY`.
- Tests: `test_ship_boiler_display.py` checks the `MAIN ENG. POWER` label (renamed
  `test_main_engine_power_value_is_separated_from_its_label`).

### Leveling: large-tilt boost, tilt warning and RESET LEVELING

- Large-tilt boost (`flight.lua` `Flight:updateTrim`): steam leveling scales per axis with the tilt beyond
  `altitude_control.level_boost_start_blocks` (0.5 blocks), up to `level_boost_max` (10x). The boost multiplies the
  coarse slew rate, the learned transfer (building and unwinding), the proportional cap and the rate damping, the same
  terms the MAIN_LIFT `climb_trim_boost` multiplies; the larger of the two applies. Within the start tilt, leveling runs
  at its previous rates. Example: about 340 per vent of roll correction (the left/right split after the ship was held
  tilted with a creative staff) took roughly 13 minutes to build or unwind at 1x; at 2 blocks of tilt the boost is 4x.
  `trimStatus` reports `rollBoost` and `pitchBoost`.
- Tilt warning: a tilt beyond the boost start held for 120 s during READY sets `trimStatus.levelingWarning`
  `TILT UNCORRECTED 2 MIN: CHECK LOAD OR RESET LEVELING`; the navigator lists it as a yellow current issue.
- RESET LEVELING: `Flight:resetLeveling` (action `level_reset`) sets the learned coarse split to the saved level bias
  (`level-bias.json`, written while airborne and level), or to zero when none is saved, and clears the fine trim PID and
  the tilt timer. Vent targets follow at the leveling slew rate; total lift is unchanged. Refused outside READY and
  during lift telemetry recovery. Logged as `LEVELING RESET TO SAVED BIAS` / `LEVELING RESET TO ZERO`.
- Navigator: FLIGHT SETTINGS 2/2 shows only its buttons; its two help lines (the reset description and the SEL strafe
  brake hint) are removed.
- Navigator: FLIGHT SETTINGS 2/2 has **RESET LEVELING**, which opens a confirmation page showing the learned roll and
  pitch split, with **CONFIRM RESET** (enabled in READY) and **BACK**. `level_reset` is a short-lived request.
- Settings: PID / LIMITS > ACTUATOR / HOVER / TRIM LIMITS gains `Large-tilt boost start (blocks)` (0.05 to 10) and
  `Large-tilt boost maximum (x)` (1 to 20). Added to `config.json`, `storage.lua` bounds and defaults,
  `config_registry.lua` and `docs/development/TUNING-REFERENCE.md` (regenerated).
- `source_notes.py`: summary for `resetLeveling`. Tests: `tests/test_leveling_boost.py` (added to `project.SUITES`).

### SEL strafe keeps nothing after it finishes

- `lateral.lua`: when a SEL strafe settles (within 0.2 blocks at under 0.05 b/s for 1 s), the offset and remaining
  distance return to 0 and the travel count restarts at her current position. While SEL strafe is idle, the travel
  count stays at 0, so drift between commands is left out of the next one. A new press measures from where she is
  at that moment. Previously the finished offset stayed set, later presses added to it, and a heading change re-ran
  the finished approach.
- The `completedHeading` re-run after a heading change is removed; offsets are relative to her present track since the
  per-sample travel change.
- Tests: `test_autopilot.py` adds `test_finished_selected_strafe_keeps_no_offset`; the forward-travel test runs on an
  active approach.

### Heading display: ANCHORED label

- `heading-main.lua` (horizontal heading view, used by the heading displays and by every display during autopilot
  or SEL strafe): while the digital anchor is engaged (core reports `BRAKING` or `ANCHORED`), the bottom-left corner
  shows `ANCHORED` in yellow. It replaces everything that corner shows otherwise (REQ, DIST, the strafe phase) until
  the anchor is released. A stale display keeps its stale presentation.
- Tests: `tests/test_heading_glyphs.py` adds `HeadingAnchorLabelTests`, which renders the view with the anchor
  anchored, braking during an autopilot route, and off.

### Autopilot disengage keeps the AP heading in SEL HDG

- `autopilot.lua`: new `AP:handHeadingToPilot`. When an engaged autopilot is cancelled with heading mode SEL (the
  disengage button, the AP-disconnect click and every other cancel that hands control back), the selected heading is
  set to the autopilot's heading target and the heading loop is reset, so she holds the heading she was flying.
  Other heading modes keep their target. Arrival uses the same helper.
- Fixed: `AP:cancel` logged its reason only through a variable the previous change removed; the
  `DISENGAGED; SELECTED MODES RETAINED` (or given reason) log line is written again.
- Tests: `test_autopilot.py` adds `disengage_sets_selected_heading_to_ap_heading`.

### Autopilot arrival hands over to the anchor at once

- `autopilot.lua`: on reaching the arrival radius (or passing the destination) the autopilot engages the digital
  anchor at the destination and disengages in the same update: state `ARRIVED`, log
  `ARRIVED: <name>; ANCHOR ENGAGED AT DESTINATION`. The anchor then brakes and positions her on its own. Previously the
  autopilot stayed engaged in `DECEL` with zero speed and zero sideways demand until the anchor reported `ANCHORED`.
- If the anchor is already active at that point (a restored checkpoint), the autopilot hands over to it without
  re-engaging it.
- The `arrivalAnchor` field is removed: AP checkpoints no longer carry it (an older checkpoint's value is ignored),
  `AP:cancel` no longer releases the anchor, and the requested-speed overrides in `autopilot.lua`, `flight.lua`
  (effective targets) and `debug_recorder.lua` use the route speed directly. `anchor_cancel` in `flight.lua` no
  longer cancels the autopilot.
- Navigator AP page: during the en-route `DECEL` state the hint now reads "Slowing for the destination".
- Owner's manual v3 (section 14): states the arrival handover. Tests: `test_autopilot.py` arrival cases updated, with
  `arrival_hands_over_to_anchor_at_once` replacing `arrival_precedes_acquisition_and_preserves_anchor`.

### SEL strafe: sideways travel measured per sample

- `lateral.lua`: SEL strafe previously measured travel as the offset from a fixed world origin projected onto the
  current reference axis. After a heading change, the forward distance flown since selection appeared as sideways
  error (about `forward distance × sin(heading change)`), and she strafed to correct it.
- Travel is now summed per sample: `track.travelled += Δposition · normal`, with the normal of the reference heading at
  that sample. Forward flight adds nothing, and the offset stays relative to her present track after a turn. Samples
  taken while SEL strafe reports a turn (turn input, yaw rate above 0.5°/s, or heading more than 3° from the reference)
  update the position without adding travel. `self.origin` is replaced by `self.track = {x, z, travelled}`.
- `source_notes.py`: `Lateral:select` summary updated. Tests: `test_autopilot.py` adds
  `test_selected_strafe_ignores_forward_travel_across_a_heading_change`; the overshoot test uses `track`.

### Heading display: heading difference readout

- In SEL HDG, the heading displays' row-2 readout `ERROR +x.x` is now `HDG Δ +x.x°`: the signed shortest turn from the
  current heading to the selected heading, in degrees (`heading-main.lua`).
- The display writes Δ and ° as UTF-8 for the installed unicode mod. A new `GLYPH` table in `heading-main.lua` splits
  text into monitor cells, keeping each of the two glyphs in one cell; any other non-ASCII character becomes one `?`.
  `put`, `center`, `centerColumn` and the right-aligned readout measure text in cells. A row holding a multi-byte glyph
  is written per colour run with `write`, since `blit` takes one byte per cell; all other rows still use `blit`.
- `source_notes.py`: summary for `GLYPH.cells`. Tests: `tests/test_heading_glyphs.py` (added to `project.SUITES`).
- Low pressure warning: the alternating red LOW PRESS / DESCEND label now starts at Y 285 (was Y 270). Steady yellow
  LOW PRESS still starts at Y 265 and clears below Y 264.

### Project-source builds only; dead code removed

The builder now builds from the maintained project source only. Saved-ship export and the compatibility code that
served it are removed. A ship is still updated in place with the updater (`--source` names the ship to update, as before).

- Builder interface: the **Software source** dropdown is removed. The window shows **Amaryllis project folder**,
  **Include shipped hover and leveling defaults**, **Build installer** and **Update existing ship…**, which opens the
  updater with the selected project.
- Command line: `builder.py --source` and `--library` are removed; a command-line build needs `--project` and `--output`.
- `builder.build(selection, output_parent, include_learning, log, bundle, *, installer_package)` always builds the
  project: the `project_source` and `library` parameters are gone, release metadata and the build report always carry
  the source provenance, and the output folder must be outside `source/`. `updater.preview_project` and
  `project.py build` call it without `project_source`.
- `collect()` remains as the validation step for the staged project core that `collect_project` writes. It no longer
  locates a core in a save (`locate_core` removed), expands installed bundles, recovers package libraries, reverses
  comment revisions, copies the navigator's installed bootstrap, rewrites chamber/thrust link items or skips a missing
  `packages/` folder. The four notes describing the old overlays are removed from build logs.
- Removed builder functions: `package_catalog`, `read_package_media`, `discover_package_media`,
  `recover_package_library`, `disk_server`, `lift_recovery_overlays`, `vessel_recovery_overlays`, `identity_overlays`,
  `control_persistence_overlays`, the main.lua header and io.lua comment replacements, and the disk-library role-metadata
  injection. Each one was checked against the project build first: with it disabled, every core, state and library file
  came out byte-identical, so the project source already contains everything they added.
- `information.py` keeps only `strip_notes`; the guarded navigator and assembly overlays are removed.
  `presentation.py` keeps `apply_console` and `apply_remote`, which generate the core console from the package console;
  their older-revision hash lists and historical-label branches are removed, and `apply`, `apply_remote_transient` and
  `apply_remote_reads` are removed. `bundling.py` loses `recover_library` and `server_source`.
- Assets removed: `systems-menu.lua` and `legacy-package-metadata.json`, with their `asset-hashes.json` entries.
- Installer README: the software-source block always describes the maintained project; the "complete ships can rebuild
  without it" wording is removed.
- After the refactor the project build matched the previous build byte for byte, before the dead-code removal below.

Unused Lua removed (no callers anywhere in source, assets or tests):

- `flight.lua`: `Flight:emergencyLiftRecoveryVerified`, `Flight:startVents`.
- `io.lua`: `IO:findMainMonitor`, `IO:sendLiftCommand`, and `IO:sendVentStartup` (called only by `startVents`).
- `telemetry_recovery.lua`: `Recovery.needsLeaseRearm`, `Recovery.attach`, `Recovery.reconcileTargetMaps`.
- `fleet.lua`: `Fleet:roleForQuadrant`, `Fleet:quadrantIDs`.
- `installer/server.lua`: `checkAuthority`.
- `navigation/ui.lua`: `valueOrUnavailable`, `providerPairs`, `suffixText`, `nodeBooleanText`.
- Package console and the generated core console: the `SETTINGS_PATH` constant.
- `source_notes.py`: summaries for the removed functions and the two "(legacy exports)" bow-axis summaries are removed.
  Every remaining summary key matches a defined Lua function.
- Python: unused imports in `builder.py`, `project.py` and seven test modules, and an unused exception name in
  `cc_settings.py`.

Tests:

- The legacy fixture (`tests/fixtures/legacy-source-2.7.1.zip`, `legacy-source.json`) and `project.fixture()` are removed.
  Tests that collected or built a synthetic saved ship now use `collect_project(project.ROOT)` or `build(project.ROOT, ...)`.
- `tests/test_windows_builder.py` is rewritten for project builds on disposable project copies: manifest, JSON,
  identity-field, learning, output-location, asset-integrity, snapshot, export, progress-asset, installer-hook and GUI
  cases. Saved-ship cases (core detection, registry records, library override, overlay idempotence) are removed.
- `tests/test_persistent_modes.py` runs against the current control modules; four cases now check the current handover
  rules (AP fault hands levers over at position, anchor release still needs neutral, a held disconnect click is latched,
  presets restore with a lever held).
- `tests/test_presentation.py` covers the two console generators and a rejected remote callback; the Systems-menu and
  historical-label cases are removed. The Systems-menu overlay case in `test_bridge_presentation.py`, the legacy
  comparison in `test_information.py` and the installed-core re-export case in `test_runtime_bundling.py` are removed.
- Docs: root README, `disk-builder/README.md` and the maintenance catalogue no longer describe saved-ship export.

### Auxiliary core reachability

- Auxiliary consoles show `CORE UNREACHABLE` after ten seconds without a validated core registry reply. State uses its validated wired context packets; the remote uses correlated core replies.
- Navigator and heading displays use the same warning text when their core data is unavailable.
- Chamber thrust-link timeouts remain available in component details while the primary status reports the missing core connection. Fresh core traffic restores ordinary fault reporting automatically.
- Computers waiting for installation validation retain their retry loop while core is unreachable, without spending automatic receipt-repair reboots.
- The state describes communication health. Existing sampling, command leases, retained lift outputs and recovery services continue.

### Message rewording and cockpit handover batch (tracked in the "Amaryllis message rewording tracker" doc)

All items below are in source and tests; none is on the ship until the next live update. Every computer must update
together because core, navigator and heading displays compare the renamed phase names.

- Phase names: `BUILDING_LIFT` is now `MAIN_LIFT` and `CONTROL_START` is now `VENT_IGNITION` everywhere (flight.lua,
  restart.lua, telemetry_recovery.lua, storage.lua comment, heading-main.lua, navigation/ui.lua, disk-builder/information.py,
  disk-builder/builder.py overlays, tests, `tests/fixtures/control-stage-baseline.json`, docs/plans). `restart.lua` maps the old
  names (and the older `HOLDING`) when a saved restart checkpoint is loaded, so a checkpoint written before the update resumes.
- Messages (flight.lua unless noted):
  - `ANCHOR RELEASED; SELECTED MODE RETAINED; NEUTRAL REQUIRED` -> `ANCHOR RELEASED` (`Flight:request` reply and
    `Anchor:cancel` log default).
  - `ANCHOR SUPPRESSES COCKPIT` removed (`Controls:update`); the legacy io.anchor lockout now pauses the cockpit silently.
  - `CORE STATE UNAVAILABLE` -> `CORE READER UNAVAILABLE` (`Flight:manualTrimAvailability`; the navigator already shows
    the manual-bias reason in yellow).
  - `<q> LIFT NODE STALE` and `LIFT NODE STALE` -> `WAITING FOR LIFT NODE <q>` (flight.lua maintenance and preflight,
    io.lua maintenance send and both emergency-stop readbacks). The tuning-readiness message `<q> LIFT NOT READY / STALE`
    is split into `WAITING FOR LIFT NODE <q>` and `<q> LIFT NOT COMMISSIONED`.
  - `AIRBORNE START: CURRENT LIFT ADOPTED; NO TAKEOFF OR BUILD` -> `AIRBORNE START`.
  - `CONTROL START TARGETS UNAVAILABLE` -> `VENT IGNITION TARGETS UNAVAILABLE`.
  - io.lua: `CORE ID/LABEL DOES NOT MATCH THE FLEET REGISTRY` -> `... MATCH FLEET REGISTRY`.
  - `ACTIVATING BULK VENTS` unchanged by decision.
- Settings groups: `INPUT STRAFE` -> `STRAFE SETTINGS`, `INPUT HEADING` -> `SEL HEADING`, `INPUT SPEED` -> `SEL THROTTLE`
  (flight.lua, input_tuning.lua, ui.lua). `INPUT ALTITUDE` keeps its name. `Flight.COCKPIT_INPUT_GROUPS` replaces the
  `^INPUT` prefix match when a cockpit setting is saved.
- Navigator BACK navigation (`ui.lua` drawSettings): a `SETTINGS_PAGES` table gives each page its parent and, where needed,
  its title. Unlisted pages return to GENERAL. Replaces the `^INPUT` / `^PROP` prefix checks and `INPUT_PAGE_TITLES`. The
  "Release inputs after saving a change." note is removed because saving no longer gates the levers.
  Test: `tests/test_settings_navigation.py` (every page reaches GENERAL in at most 4 presses, no loops).
- Cockpit handover (controls.lua, anchor.lua, autopilot.lua, thrust.lua, control_presets.lua, restart.lua, lateral.lua,
  flight.lua, main.lua, ui.lua): the neutral-lever gates are removed except after anchor release. Levers act at their
  current position after a mode change, lever-data recovery, a long input gap, propulsion enable, AP disengage, preset
  restore and restart restore. `Controls:noteHandover` checks the next fresh sample; a held W/S lever sets
  `cockpitControl.thrustNotNeutral` for `Controls.NOT_NEUTRAL_WARNING_SECONDS` (3 s) and the navigator shows yellow
  `THRUST NOT NEUTRAL`, replacing `RETURN CONTROLS TO NEUTRAL`.
  - Kept: anchor release still waits for every lever to read neutral (`requireNeutral`); its reason is now
    `ANCHOR RELEASED: SET <KEY> TO NEUTRAL`.
  - Kept as gestures: the heading-centre hold (both heading pedals) latches until both are released (`centreLatch`), and
    the strafe brake gesture keeps its release latch. A disconnect click that ends the autopilot is latched until released
    (`disconnectLatch`), so it does not also zero the selected speed.
  - Removed: `waitHeading`, `waitThrottle`, `waitAltitude`, `waitSpeedSelection`, the propulsion-enable lever check
    (`RELEASE THROTTLE AND STEERING INPUTS`), `PRESETS WAIT: <KEY> NOT NEUTRAL`, the tuning-test check
    `RETURN COCKPIT CONTROLS TO NEUTRAL`, and the strafe `waitNeutral` after a cancel.
  - Restored presets hold propulsion with an explicit `controls.holdPropulsion` (`PRESETS RESTORING`,
    `PRESETS HELD UNTIL START SYSTEMS READY`); AP, anchor and position proxies clear it.
  - `PROPULSION ENABLED; RELEASE INPUTS BEFORE COMMANDING` -> `PROPULSION ENABLED`.
  - Snapshot fields `headingWaitingForNeutral`, `throttleWaitingForNeutral`
    and `altitudeWaitingForNeutral` are replaced by `thrustNotNeutral`, `anchorNeutralRequired` and `holdPropulsion`.
  - Not changed: the remote-AP check that rejects a remote command while pilot inputs are active (`Ops:neutral`), and the
    peripheral thrust controllers' new-session neutral drive-demand interlock.
  Tests: `tests/test_lever_handover.py`; `tests/test_recovery.py` and `tests/test_persistent_modes.py` updated.
- Propulsion and START SYSTEMS: `Flight:disablePropulsionForStart` saves propulsion as disabled (config.json) when START
  SYSTEMS begins, with stop reason `PROPULSION OFF UNTIL START SYSTEMS READY`. `Thrust:setEnabled` refuses enabling with
  `START SYSTEMS NOT READY` until `io.systemsReady` (published by the propulsion worker and the enable request) is true, and
  the navigator's enable availability shows the same reason. The automatic enable after the 10 s READY settle turns it on.
  `Thrust:setEnabled` takes an optional stop reason. Tests: `tests/test_lever_handover.py` (PropulsionStartGateTests).
- Stale messages (rule: show the age; show the message only after more than 10 s of stale data):
  - Thrust (`Thrust.staleText`): `STATUS STALE` / `NO STATUS` -> `WAITING FOR <ROLE> STATUS` up to 10 s, then
    `<ROLE> STATUS STALE <n> S`, or `<ROLE> NO STATUS SINCE CORE START`. `CONTROLLER STATUS STALE` and
    `CONTROLLER READBACK STALE` use the same wording with the role name (`<ROLE> READBACK STALE <n> S`).
  - Cockpit (`Controls:fresh`): `COCKPIT INPUTS STALE` -> `WAITING FOR COCKPIT INPUTS` up to 10 s, then
    `COCKPIT INPUTS STALE <n> S`; a future sample time reads `COCKPIT INPUT CLOCK INVALID`.
  - Navigator (`ui.lua` `staleLabel`, age from the receiver's new `displayAgeSeconds`): `COCKPIT STALE`,
    `THRUST STATUS STALE`, `HDG STATUS STALE`, `MAN ACCEL STALE`, `THRUST REQUEST STALE`, `FAULT STATUS STALE` and
    `SEL CONTROL STALE` read `WAITING FOR CORE` up to 10 s, then `CORE UNREACHABLE <n> S`, both yellow. This merges the
    shared CORE UNREACHABLE state (entry at the top of Unreleased) with the age-and-10-s rule. Compact header tags that say only `STALE`
    are unchanged.
  Tests: `tests/test_stale_status_text.py`, `tests/test_supervision_text.py`.
- Chamber computers (`chamber-hardware.lua`, `thrust-hardware.lua`, `chamber-lift.lua`): vent and probe faults follow the
  probe-only balloon rule on the chamber's own console and fault list. A bulk vent with a working interface that gives no lift
  or no balloon reading reports `VENT <name> LIFT FAIL; CHECK BOILER` (inactive or no gas output) or `VENT <name> FAIL; CHECK
  BOILER`, in place of `PROVIDER_UNREADY:<name> | provider is inactive; provider reports no attached balloon`. The trim probe
  reporting no balloon gives `PROBE <name> FAIL: CHECK BALLOON INTEGRITY`. Interface faults (missing peripheral, unwritable,
  unreadable target or signal) keep `PROVIDER_UNREADY:<name> | <detail>`. The trim handover check now says
  `VENT <name> FAIL; CHECK BOILER` and `BULK VENTS GIVE NO BALLOON READING; CHECK BOILER`. `addProviderFaults` recognises the
  new forms for suppression and leaves them as worded. The hardware page still lists the raw API readback in `provider.error`.
  Tests: `tests/test_vent_balloon_hint.py` (ChamberProviderFaultTests).
- Navigator (`ui.lua`): reported faults that say `CHECK BOILER` (vent faults the probe does not confirm) are yellow in the
  current-issues list and on the ship fault line; other reported faults stay red. Chamber tiles keep their colour rules.
- Core (`io.lua` `IO:emergencyLiftStopStateVerified`): the kill check follows the probe-only balloon rule. An incomplete
  envelope reading gives `CHAMBER <q> UNCONFIRMED; CHECK PROBE`. A no-balloon flag fails the check only when the reading
  comes from the trim probe (`<q> PROBE FAIL: CHECK BALLOON INTEGRITY`); the probe's own attachment flag gives the same
  messages in place of `ATTACHED BALLOON STATUS NOT VERIFIED` and `FINE PROBE ATTACHMENT NOT VERIFIED`.
  Tests: `tests/test_vent_balloon_hint.py` (NavigatorAndKillCheckTests).
- Navigator PROPULSION settings page: the fallback note now reads `Propulsion enables once START SYSTEMS is READY.`
  (stale neutral-lever wording). A temporary PROP-page bow-axis line used to confirm the +X axis was removed again
  after the axis was locked.
- Bow axis from configuration only (`config.json` `geometry.sable_bow_axis`, `io.lua` `resolveVesselAttitude`,
  `vessel_sources.lua`, `storage.lua`): bow-axis learning is removed. `IO:chamberAttitudeAxis`, `IO:loadAttitudeAxis`, the
  heading-match latch and `/avionics/data/attitude-axis.json` are gone; the chamber-height learner flipped between +X and
  +Z and put sideways motion on the speed display. The bow in Sable's pose frame is `geometry.sable_bow_axis`, or
  `geometry.bow_forward` when that key is absent; Amaryllis uses +X (`{"x":1,"y":0,"z":0}`), confirmed in flight. With
  Sable's pose available, heading, pitch, roll, forward speed and thrust mapping come from the pose and that axis
  (source `CONFIGURED`, heading source `Sable pose / configured bow`), and it takes priority over the saved fallback
  calibration and the axis the state reader sends. Config validation accepts only +X, -X, +Z or -Z. The live updater adds
  the key to the ship's stored config; an existing `attitude-axis.json` on a computer is left unused.
  `tests/test_control_stages.py` io_traces runs with `sable_bow_axis` removed unless one is passed.
  Tests: `tests/test_bow_axis_lock.py`. docs/architecture file list updated.
- Comments and summaries corrected for the new handover behaviour: controls.lua header, `Controls:clear`, the ramp
  summary, the assembly-gate note, anchor and AP cancel summaries, the lateral cancel summary, the preset update summary,
  main.lua's preset display note, io.lua's input-retry note, storage.lua's startup-limit note, and `source_notes.py`
  entries (`AP:cancel`, `Anchor:cancel`, `Controls:clear`, `Presets:update`, `Lateral:cancel`, `ventBalloonIssue`, new
  `autoEnablePropulsion`, `disablePropulsionForStart`, `IO:staleStatusText`). docs/architecture and docs/maintenance
  descriptions of the neutral handover are updated.

### Navigator and autopilot (avionics source)

- Core (`source/core/avionics/propulsion_worker.lua`): the propulsion stop reason `CORE SUPERVISION STALE` is replaced by
  `Worker.supervisionText`: `WAITING FOR CORE SUPERVISION` up to 10 s, then `CORE SUPERVISION SILENT <n> S; SERVER LAG OR CORE
  STALL`; also `CORE SUPERVISION NEVER REPORTED; CHECK CORE` and `CORE SUPERVISION CLOCK WENT BACKWARDS; CHECK CORE`. The 3 s
  stop limit and the stop behaviour are unchanged. Tests: `tests/test_supervision_text.py`.
- Core (`source/core/avionics/io.lua`): the per-chamber fault `STALE STATUS` is replaced by `IO:staleStatusText`. A chamber
  silent for more than `IO.STALE_NOTICE_SECONDS` (10 s) shows `CHAMBER <q> SILENT <n> S; CHECK POWER AND LINK`, or
  `CHAMBER <q> SILENT SINCE CORE START (<n> S); CHECK POWER AND LINK` when nothing has arrived since core start (counted from the
  first snapshot). Shorter gaps show no fault. The 6 s offline limit (`network.node_stale_seconds`) is unchanged. The snapshot
  fault summary uses the same text in place of `<q> LIFT STATUS STALE`. Tests: `tests/test_stale_status_text.py`.
- Flight (`source/core/avionics/flight.lua`): `Flight:ventBalloonIssue` words balloon attachment faults. Only the trim probe
  burner decides whether a balloon is attached; vent readings are not reliable for envelope integrity. A probe reporting no
  balloon gives `<chamber> PROBE FAIL: CHECK BALLOON INTEGRITY` (also used when the trim probe's own attachment flag is false). Every vent fault the probe does not confirm points at the
  boiler: probe sees a balloon (`<chamber> VENT <name> FAIL; CHECK BOILER`), vent has no lift readings
  (`<chamber> VENT <name> LIFT FAIL; CHECK BOILER`), or the probe reading is unavailable or not from the probe (`CHAMBER <chamber> UNCONFIRMED; CHECK PROBE; CHECK BOILER`). Blocking behaviour is the
  same. The two vent checks and the representative balloon check in `systemsEnvelopeReady` use it.
  Tests: `tests/test_vent_balloon_hint.py`.
- Flight (`source/core/avionics/flight.lua`): START SYSTEMS now enables propulsion automatically. `Flight:autoEnablePropulsion`
  runs in the READY phase after `rememberHoverOffset`; once altitude is within 1.5 m of the target and vertical speed is
  within 0.1 m/s for 10 s it calls `Thrust:setEnabled` (same checks as the manual switch: usable cockpit,
  verified hardware, no anchor). Rejections retry every 2 s; it succeeds once per start sequence and skips when propulsion
  is already enabled. Any disturbance restarts the 10 s timer. Tests: `tests/test_auto_propulsion.py`.
- Navigator (`source/library/packages/navigation/ui.lua`): every command or control lease message (`COMMAND LEASE EXPIRED`,
  `LIFT CONTROL LEASE LOST`, etc.) is replaced by one yellow `CORE STALL; RESOLVING` notice, with `(RETRY n)` from the
  lift recovery attempt count when known. Detection is `leaseText()`; the mapping lives in `Info.collect`'s `add` and in
  `firstThrustIssue`. Real faults stay red. Test: `tests/test_ship_boiler_display.py`. Summary registry entry for
  `rawThrustIssue` added to `disk-builder/source_notes.py`.
- Flight settings menu (`source/library/packages/navigation/ui.lua`, `source/core/avionics/flight.lua`): the page-1
  button and page title "INPUT TUNING" are now "COCKPIT INPUTS". Its menu is, top to bottom, SEL HEADING SETTINGS
  (was SELECTED HEADING INPUT), SEL THROTTLE SETTINGS (was SELECTED SPEED INPUT), ALTITUDE SELECTOR SETTINGS (was
  ALTITUDE TARGET INPUT) and the new STRAFE SETTINGS. Internal group keys are unchanged (`INPUT HEADING`,
  `INPUT SPEED`, `INPUT ALTITUDE`) so back navigation and the wait-for-neutral rules still apply; the four cockpit strafe
  fields moved from group `LATERAL` to the new `INPUT STRAFE` group and no longer appear on flight settings page 2
  (which keeps only the START/STOP and RESTART SYSTEMS buttons). Page titles come from `INPUT_PAGE_TITLES` in `drawSettings`.
  Stored config keys did not change. Tests: `tests/test_ship_boiler_display.py`, `tests/test_strafe_balance.py`.
- Ship > PROP page (`drawShipPropulsion` in `ui.lua`): the "LATERALS / APPLIED LEVEL AND REQUEST" heading sat on row 12,
  the same row as the first `FL THRUST` indicator, so the two overwrote each other. The heading is now on row 11.
  Test: `tests/test_ship_boiler_display.py` (checks 57x24, 80x30 and 100x36).
- Flight page (`ui.lua`): the "APPLIED THROTTLE" label (16 characters) was followed directly by its value in column 17, so
  they read as one word (`APPLIED THROTTLEUNAVAIL`). The value now starts in column 18 with width `leftWidth - 17`.
  Test: `tests/test_ship_boiler_display.py` (57x24, 80x30, 100x36).
- Flight page (`drawQuadrantTiles` in `ui.lua`): the chamber column header "GAS M3/T  TARGET  LIFT" is now "CHAMBERS".
  The tiles below still label their own GAS, TARGET and LIFT rows. Test: `tests/test_ship_boiler_display.py`.
- Autopilot: on arrival, if heading mode is SEL the selected heading becomes the cruise heading (no turn on handover).
  Capture accepts 2.5 blocks / 0.4 b/s (was 0.5 / 0.1); drift-bias learning window widened from 2 to 4 blocks.
  Tests in `tests/test_autopilot.py`.

### Bundled Python for the Windows helpers

- `disk-builder/builder.py`: `bundle_python_runtime` copies the Windows Python that runs the build (Lib, DLLs, tcl, executables;
  no site-packages, tests or debug files) into `python/` at the root of `amaryllis-installer.zip`, then runs
  `python.exe -I -c "import tkinter; tkinter.Tcl()"` on the copy and removes it if the check fails. Builds on a non-Windows
  Python, or one without Tcl/Tk, skip the runtime and log why; the zip still builds.
- `helper_launcher` writes `Configure ComputerCraft.cmd` and `Update Amaryllis.cmd`. Both try `..\python\pythonw.exe` first,
  then the previous search (codex runtime, `pyw`, `pythonw`, `py`, `python`).
- The runtime sits outside `windows-settings/` and `windows-update/`, so both helpers share one copy. Keep the zip structure
  intact when extracting. Build on the Windows PC to include it. Tests: `tests/test_python_bundle.py`.

### Live ship updates (updater, command line and dialog)

For the next agent: `disk-builder/updater.py` no longer needs the world closed. ComputerCraft
supports live file replacement and `atomic_write` swaps each file atomically.

- `apply` and `restore` default to `world_lock=live_world`, which does nothing. The strict
  `hold_world` (byte lock on `session.lock`) remains and is selected by `--require-closed` on the
  command line or the dialog's "Only apply or restore while the world is closed" checkbox.
  `project.py update` passes extra arguments through to the updater, so `--require-closed` works there too.
- New `VOLATILE_FILES` / `VOLATILE_FOLDERS` / `volatile()` / `scan_computer()`: `installer/install_status.json`
  and `avionics/data/**` are rewritten continuously by running computers. They are excluded from the
  before/after snapshots, so they are never compared, backed up, replaced or deleted. This removes the
  old "Computer files changed after preview" failure on a running ship. Add any new runtime file to this list.
- Restore filters the same files out of the recorded hashes, so older backups that listed them still restore.
- The "changed after preview" and "Target changed while preparing the backup" errors now name up to six
  differing files (`drift()`), because a real edit (for example a flight setting saved in game) still
  requires a fresh preview.
- `atomic_write` retries `os.replace` for up to 10 s on `PermissionError` (Windows while a computer has the file open).
- Found by updating the real running ship: running installers also rewrite `installer/status.json` (state, heartbeat,
  active package), `installer/status.json.bak`, `installer/boot-counter(.bak)` and `installer/*.tmp`. The `.bak`, boot
  counter and temp files are now volatile. `status.json` is write-only for the update: it is still written so the
  receipt fields match, but `quiet()` leaves it out of every before/after/restore comparison.
- `valid_receipt` no longer requires status.json `version`/`manifestChecksum` to equal the receipt
  (`LIVE_REFRESHED_RECEIPT_FIELDS`): a computer that has not rebooted still reports its old release, and a second
  preview would otherwise fail with "receipt/status mismatch".
- Startup self-heal (`source/library/packages/common/console.lua`, `refreshLiveUpdateStatus`, called from `receiptReady`):
  after a live update the still-running old installer rewrites `installer/status.json` with the OLD release
  (`installedVersion`, `installedManifestChecksum`), so the rebooted computer refused to start with
  "installed package receipt is not committed" (seen on navigator #6). The new console now rewrites those release
  fields (and `version`) from the committed receipt when every identity field already matches exactly (role,
  package, label, computer ID, core ID, install ID, client/server/core sessions), `hasInstalled` is true and no
  recovery or commit is pending. Anything else is still refused. A line is logged when it repairs. The core copy
  `source/core/avionics/common/console.lua` was regenerated from the package console. Test: `tests/test_live_update_status.py`
  (registered in `project.SUITES`); `rawThrustIssue` and `refreshLiveUpdateStatus` summaries are in `disk-builder/source_notes.py`.
  Manual repair if a computer is already stuck: set `installedManifestChecksum` in its `installer/status.json` to the
  receipt's `manifestChecksum` in `avionics/config.json` under `install`.
- Bounded automatic reboot (`rebootForStatusMismatch` in the package console, called from `waitReady`): a peripheral
  (non-core) computer that stays 20 s on "receipt is not committed" or "identity does not match its receipt" reboots
  itself, at most twice per hour, recording `/installer/auto-reboot.json` (`count`, `at`, `reason`) and logging
  "Automatic reboot n of 2". After the cap it keeps waiting as before. The core never reboots itself and other wait
  reasons never reboot. `installer/auto-reboot.json` is volatile for the updater. Tests: `tests/test_live_update_status.py`.
- Interrupted live apply recovery: a killed apply leaves `.amaryllis-update.json` and a journal in phase `applying`.
  `restore(backup)` rolls it back; if every file was written, verify the journal's `after` hashes (using `quiet`),
  prune, set phase `applied`, remove the marker and call `discard_stage`.
- Dialog and README text no longer tell the user to close Minecraft; the finish message says to reboot computers.
- Unchanged on purpose: `disk-builder/cc_settings.py` (floppy and disk capacity, computer threads) still
  requires Minecraft/server closed, since ComputerCraft reads that TOML only at startup.
- Tests: `tests/test_world_lock.py` (live default ignores an open world, no session.lock needed, volatile files
  excluded, strict mode still refuses), `tests/test_project_release.py` (live update with rewritten runtime files
  and restore; drift error names the file).

- Refreshed the shipped hover and leveling defaults from Amaryllis's saved calibration.
- Renamed the maintained utility directory to `disk-builder` and updated project commands, tests, packaging and documentation links.
- Separated release history from the current-functionality README.

## 3.0.0

### Project-source builds and updates

**Project source** builds maintained Lua, configuration defaults and optional
shipped hover/level defaults. A Minecraft save is not required for this mode.
The repository and packaged utility locate their source automatically.

1. Open **Start Builder.cmd** using Python 3.11+ with Tcl/Tk.
2. Leave **Software source** set to **Project source**.
3. Check the selected Amaryllis project folder.
4. Choose **Build installer** to create a new commissioning package, or
   **Update existing ship…** to build it and open the existing-ship updater.
5. For an update, select the destination save and external backup folder,
   preview the file changes, close Minecraft and apply the reviewed replacement.

Results are written to the utility's local `Installers` folder. **Open result**
and **Saved to** give the output location. The distributable file is
`amaryllis-installer.zip`; its media is used by the same installer and updater.

Project releases include the source commit, uncommitted-change status and input
fingerprint in their metadata and README. A standalone utility ZIP includes a
snapshot of that source and its revision record, so Git is optional. Updates
retain each destination ship's stored settings, PID configuration, learning,
computer IDs and restart records, with the previous installation backed up
outside the save. New installs use project defaults and optional shipped learning.

**Saved ship export** explicitly captures an installed ship's software and
portable data. Select that mode to use the saved-ship export instructions below.

## 2.9.0

### Disk Builder interface and commissioning reset

- Renamed the product to Amaryllis Disk Builder.
- Removed the library and output fields from the interface; exports use automatic package recovery and the local Installers directory.
- Added the red Unassign core action with a confirmation that defaults to Cancel.
- Added resumable commissioning reset and recommissioning of retained installations.

After core is assigned, **Install core** becomes a red **Unassign core** action.
Run it on the registered core. On another computer, the installer displays the
core ID to visit. Interrupted core installation instead offers **Resume core installation**.

The reset confirmation defaults to **CANCEL**. Select **RESET INSTALLATION**
and confirm to clear the disk’s assignments, import status and correction plan,
and remove core’s fleet registry and its automatic recovery copies.

The disk retains the previous roster as recommissioning metadata. Registering
those same computers again preserves their installed programs, configuration
and learned data. Reuse the original core for retained auxiliary installations.
The core program must be closed before resetting. This action makes no actuator calls.
A reset interrupted during record cleanup is resumed from **Resume installation reset**.

Register all 16 computers and import the assignments to complete commissioning again.

## 2.8.0

### Navigator information and assembly continuity

Version 2.8.0 exports the agreed startup wording: OPENING STEAM VENTS,
STATIC INFLATION, CAPTURING PITCH ZERO, ACQUIRING SEL ALT and READY.
Acquisition describes the initial ascent. An accepted selected-altitude change
ends that presentation for the current run. Airborne adoption displays READY.

Lift, autopilot and anchor recovery show RETRYING (#) using attempt counts.
The inactive altitude indicator reads ALT OFFLINE. Limits read MAX CLB and
V/S DEMAND LIM. Kill Lift progress and disarming notices are yellow; the armed
latch reads KILL LIFT ARMED; DISARM BEFORE START in red.

Warnings of the highest active severity rotate every three seconds. Touch the
displayed warning to open Current Issues, focused on that warning. Settings
also opens Current Issues. It lists active notices, their source, available
details and time visible, with four entries per page. Back restores the invoking
view. These navigation actions use the current cached snapshot.

State checks its fresh Sable association first, then the fresh physics-assembler
result. Only an explicit current disassembled result, with Sable association
unavailable, closes the assembly gate. Unresolved checks continue with available
peripheral telemetry. After five minutes, navigator shows the yellow warning
ASSEMBLY UNVERIFIED; OPERATOR CHECK REQUIRED. Successful verification clears it.
Routine verification messages stay in state's logs.

A fresh changed Sable vessel UUID is adopted during assembler uncertainty.
Retained control references, selected modes, target values and saved control
records follow that association. Source calibration is revalidated against fresh
measurements. This UUID is the vessel identity; fleet computer IDs and protocol
credentials retain their existing checks.

The revised assembly gate and information pages preserve applied provider
settings. Stop Systems and Kill Lift retain their existing operator-confirmed
shutdown paths. The current confirmed-disassembly lifecycle remains in place.

The export documentation pass adds section descriptions and short summaries to
major runtime and installer functions. The builder's Python helpers also have
function summaries. Lua token and Python syntax-tree comparisons check that
documentation leaves executable behavior unchanged. Readable runtime bundles
and installed file counts are retained.

Cockpit input frequency pairs come from config.json. Each item is validated as
namespace:item, including modded namespaces, while required inputs and duplicate
ordered-pair checks remain enforced. Existing default pairs are retained.

Build a fresh installer with this version, then use Update existing ship with
that export's media folder to apply the release. The updater's file preview and
external backup cover all registered computers and preserve stored ship data.

## 2.7.1

### Readable bundled source

Version 2.7.1 writes embedded Lua modules as readable multiline source blocks.
Original indentation, comments and line structure remain visible inside the
single runtime bundle. Installed file counts stay the same.

The builder reads both older escaped bundles and the new readable format.
Source recovery remains byte-exact, including original line endings and Unicode.
Unusual mixed line endings or control bytes use one escaped fragment per line.
The existing runtime loader and module error locations are retained.

Use this builder for subsequent builds and updates of readable bundles. The
normal Build installer and Update existing ship workflow applies. Existing
installed files change only when that update is applied.

## 2.7.0

### Persistent pilot modes

Version 2.7.0 preserves explicit heading MANUAL/SEL and throttle MANUAL/SEL/DIRECT
selections and their selected values across supported core/navigator restarts.
The existing avionics/data/control-presets.json remains the only preset file.
Successful mode selections invoke saving before their core acknowledgement;
routine target adjustments retain the existing coalesced save cadence.

AP cancellation and anchor release retain the underlying pilot selections and
reset live demands through the neutral-input handover. They no longer force
MANUAL or DIRECT, and the AP-disconnect sample is not reused as a throttle
shortcut. Freshness, identity, neutral-input and lift-readiness gates remain.
Preserving SEL does not itself start ship systems or grant actuator authority.

Update the existing ship through the usual builder/updater path. The updater
preserves existing presets and learned data. Core owns these selections;
navigator displays them and does not need its own preset file. A fresh
installation starts from its ordinary defaults when no saved presets exist.

## 2.6.4

### Remote refresh and command ordering

Version 2.6.4 makes cached menu navigation local and refreshes the active view
up to twice per second. Core reuses recent status replies instead of rejecting
rapid reads; cached age is preserved. Older-core throttling does not mark the
remote offline. Reads have no request queue. AP mutations retain the existing
acknowledged command queue and core supervision. Ship-control and chamber
processing order is unchanged. Update core and re-dock the remote to load both
sides.

## 2.6.3

### Builder runtime and error details

Version 2.6.3 makes Start Builder.cmd prefer the existing bundled workspace Python
runtime when available. Other computers continue through the installed Python
launcher/PATH fallbacks. No runtime is downloaded or installed. The window title
shows the builder version, and each build log identifies its Python executable.
GUI failures write a private traceback report under Logs beside the builder;
the popup links that report. Source contents and pairing data are not logged.

## 2.6.2

### Python 3.14 bundling compatibility

Version 2.6.2 replaces the Lua string encoder generator with an explicit byte
loop. This fixes the Python 3.14.7 failure reporting a list is not an iterator
after source validation. Encoded runtime objects remain identical on Python
3.12 and 3.14. No Python downgrade or Minecraft configuration change is needed.

## 2.6.1

### One-off remote AP commands

Version 2.6.1 names remote autopilot destinations Remote CMD on both client and
core. They are one-off active targets: they never enter navigator destination
memory, its AP > Destination selection, the saved destination library, or route
restart checkpoints. The remote no longer loads or writes remote/destination.json.
An existing file is left untouched and ignored. The active route target is
cleared when the remote operation ends. Normal onboard destination editing,
saving and ordinary route checkpoint behavior remain available.

Update core and re-dock the remote through Install / pair remote to apply both
sides. Core enforces the fixed name and preserves navigator's destination even
for requests from older clients. An old client's own local file-writing behavior
changes only when that remote receives the new software.

## 2.6.0

### Unified remote panel

Version 2.6.0 gives the provisioned remote one gray Home interface: Status,
Computers, Autopilot, Logs and Tools. It supports the 26 x 20 pocket screen,
keyboard/mouse input and parent-level Back navigation. No shell is exposed.
Computers includes all 16 roles, errors, report age and related core logs,
including relayed thrust-controller reports. Stale readings remain labelled.
Autopilot editing, review, result tracking and route progress stay in this app.
Existing pairing, permissions and the core flight handlers are preserved.

After updating core through the normal Windows updater, dock an existing remote
and run core Tools > Install / pair remote again to load the new application.
That provisioning path retains its existing pairing and flight-access setting.
The fleet updater does not directly update pocket remotes. The UI replaces an
existing embedded source and adds no installed core file or persistent UI file.

## 2.5.0

### Keyboard disk installer

Version 2.5.0 replaces typed menu letters and computer names with keyboard lists.
Left/Right changes pages: Setup, Chambers, Thrust, Displays, State and Assignments.
Up/Down moves the cursor, Enter selects, and Escape goes back. A long Assignments
list scrolls vertically so all 16 expected computers remain accessible.

Confirmation dialogs use a YES/NO selector. Left selects YES, Right selects NO,
and Enter confirms the selected choice. NO is selected initially. Escape cancels.

Assigned roles are gray on registration pages. Focusing one shows its owner ID;
Enter cannot register it again. A matching interrupted installation can resume
on its original computer. No other completed assignment is overwritten.

Assignments combines the old review and correction screens. It shows each
computer name, role description and assigned ID, or a dash when unassigned.
The current computer is highlighted in yellow. Read-only rows direct you to
revisit the desired computer with this disk.
Enter on a destination role previews a correction for the current computer.
A swap lists both computers and must be completed on both before import.
Core/state, imported assignments and installed packages retain their correction
restrictions. Pending plans can be inspected and finished from Assignments.

These changes stay within the existing disk setup.lua and temporary commissioning
helper. No additional file is installed. Previously built disks keep their old
interface; create a new installer with 2.5.0 to get the keyboard version.

## 2.4.2

### Relayed controller status

Version 2.4.2 uses the existing propulsion-controller reports for computers whose
status is relayed through a chamber. Their status page shows report age,
controller binding availability, faults and the relay source. A fresh report
without an explicit program-running flag is labelled REPORTING. Direct role
health flags retain precedence. Stale reports remain stale.

When only core's package catalog supplies a package identity, the page labels
it Package (expected). A directly reported package remains labelled Package.
Response time stays unavailable unless an actual request/reply measurement exists.
No additional radio probes or hardware writes are introduced.

## 2.4.1

### Console host compatibility

Version 2.4.1 handles Windows line endings in resource-pack overrides of
CraftOS multishell, including CC:Tweaked Unicode Support 1.0.1. The adapter
normalizes line endings before applying its guarded presentation changes.
The native per-process event filtering and scheduling code remains intact.

Normal startup provides the full 51 x 19 console without service tabs.
If the host adapter cannot be used, Panel Home also fits a 51 x 18 tab window.
This avoids a resize-only screen on the standard advanced computer.
Older 2.3.0/2.4.0 Panel bundles upgrade through the normal build/update flow;
stored settings and learned values are retained.

## 2.4.0

### Automatic package recovery

Select the saved ship, then click **Build installer**.
Builds are saved under `Installers` beside the utility. The result shows its full path. The builder recovers the auxiliary
package sources automatically from the registered computers and verifies every
program against core's saved package catalog. It checks each computer's role,
ID, committed installation receipt and package version before accepting it.
The build log and build-report.json identify the source that was used.

A complete installation made with builder 2.4.0 or later contains everything
needed to rebuild its package library. The original manifest and clean package
configuration are stored inside each existing auxiliary runtime bundle. These
are release defaults, without installed IDs, sessions or pairing credentials.
No extra file is installed, and core keeps no duplicate package library.
The source metadata does not execute at runtime.

For the existing reference installation, the builder includes verified legacy
JSON metadata for its earlier bundles. Actual executable code is recovered
from the ship and must match core's catalog exactly. Unknown older bundles
may still require their media if their original defaults cannot be recovered.

If a registered computer is missing, incomplete or does not match the catalog,
the builder searches the save's ComputerCraft disk folders and the utility's
usual Installers folders for a verified matching library. It checks catalog
identity and all object hashes; folder dates do not decide which release to use.
The command-line `--library` option accepts matching media outside these search locations.
The graphical interface uses automatic recovery.

A partial or damaged ship with no complete matching source cannot be rebuilt
by guessing. Restore its missing source from backup or provide matching media.
Installer media remains useful for in-game installation, updates and repairs;
you do not need to retain it solely to rebuild a complete 2.4.0+ installation.

## 2.3.0

### Core console: Panel Home

Version 2.3.0 adds the gray Panel Home application to core. Home opens Status,
Computers, Installation, Logs and Tools. Computers lists all 16 registered roles,
with IDs, state, reply timing when measured and current error counts. Selecting a
computer shows its reported program/hardware state, report age, package, component
details, errors and related core log events. Stale values are labelled as last
reported. Reply time remains `--` when telemetry has no measured request/reply
duration; report age is shown separately. Opening these pages adds no probes.
Computer names use lowercase throughout, such as `chamber-fl`, `bridge` and `hdg-l`.

Every child page has a top-left **< Back** control. Back returns one level up and
retains the selected computer, list page and diagnostic scroll position. Related
logs return to the source computer. Installation shows cached transfer progress
and the per-computer package roster within the application.

Core's concurrent services use the CraftOS process scheduler inside the
application host. Service tabs are concealed. Shell, Lua, diagnostics, the full
core view/ID editor, remote pairing and remote flight access open from Tools.
Tools have a top-left Back header; **F1** also returns to Tools. **F2** opens or
focuses a recovery shell through the host, independently of UI drawing.
The interface restarts after a drawing failure while healthy services keep
running. Reopening startup focuses the existing application and reuses workers.

The initial console target is 51 x 19; the renderer also supports larger grids.
The host adapter validates the installed CraftOS scheduler's structure before
using it. Its per-process event dispatch and filters are retained. Core's flight,
PID and actuator source modules are unchanged by this presentation update.

In the default bundled export, the UI module stays inside core's existing runtime bundle. Core's installed
payload remains five files including its configuration and catalog. Existing
learning and runtime records remain separate. This change adds no installed UI files or persistent UI data files.
Navigation state stays in memory. Existing persistent data remains in its JSON
files. Auxiliary consoles and their packages retain their current presentation.

## 2.2.1

### Auxiliary launcher environment

Version 2.2.1 corrects the auxiliary startup launcher so it retains CraftOS's
program environment, including shell.run and require. The missing environment
could leave all auxiliary consoles repeatedly reporting an attempt to call a nil
value while core continued to run.

To repair an installation affected by this specific launcher bug, fully close
Minecraft, open **Update existing ship…**, select the target save, and click
**Preview startup repair**. A media folder is unnecessary for this action.
Review the 14 auxiliary startup.lua replacements, choose an external backup
folder, select the closed-game checkbox and click **Apply update**. Core, state,
installed bundles, settings, PID learning and package receipts remain unchanged.
The normal update path also corrects this known launcher when using older media.

## 2.2.0

### Offline existing-ship migration

Version 2.2.0 adds offline migration of existing loose-file and bundled ships.
Automated Lua 5.2, installation, rollback, worker-loader and rebuild checks cover
the reference source. In-game flight acceptance remains a commissioning step.

## 2.1.0

### Bridge Systems menu

Version 2.1.0 includes the bridge's Systems menu and presentation update.
`SYSTEMS` / `Options [v]` offers Start Systems, Stop Systems, Restart Systems
and Kill Lift. The kill option retains its confirmation dialog and becomes
Disarm Kill when the existing latch requires disarming. Menu selections use
fresh availability checks; an outside touch closes the menu without activating
the control underneath. Existing Stop Systems confirmation remains in place.

The flight readout uses `V/S`, chamber diagrams use `^ BOW ^`, debug disk/log
instructions use the approved wording, and the display specification footer is
removed. The bridge package version advances once; rebuilding the same source
does not keep incrementing it. This update changes bridge presentation only.

## 2.0.0

### Bundled installations

Version 2.0.0 bundles installed Lua modules by computer. Configuration, saved
learning and recovery records remain separate writable files. The editable
source files in the selected save are preserved.

With the current reference source, core's payload is seven files including two
learning files, STATE is three files, and each of the 14 wireless packages is
three files. Startup/updater support and records created during operation add
to those totals. The exported disk occupies approximately 3.3 MB; use the
exact capacity in the build report.

Bundles preserve named source modules, original error locations, worker entry
points and task-local module caches. Workers continue using the existing
supervision and restart logic. Core retains client source needed to provision
remote computers inside its bundle. Auxiliary transfer destinations remain an
exact allowlist and use the existing checksums, staging, commit and rollback.

The builder verifies and extracts embedded sources when exporting a bundled
ship again. Package recovery is automatic; a media override is optional. Rebuilding
preserves package versions and does not nest bundles. Damaged sources, an
unknown loader or conflicting loose/bundled files stop the export.

## 1.7.1

### Computer names in setup

Version 1.7.1 uses computer names in setup choices, confirmations, assignment
reviews and correction plans: `chamber-fr/fl/br/bl`, `thrust-rs/ls/rb/lb`,
`bridge`, `hdg-l/r/m` and `state`. Core and primary computers use `core`,
`primary-l` and `primary-r`. Select names with Up/Down and Enter. These names map to the existing
internal roles and fleet labels.

## 1.7.0

### Vessel telemetry recovery

Version 1.7.0 separates stale/incomplete vessel telemetry and unavailable vessel
identity from a fresh, valid sample confirming another vessel. Missing data waits
for revalidation and preserves lift. A confirmed identity change remains blocked.
Aborted operations can recover partially applied commands by restoring core's
retained absolute target map after identity, hardware and target-limit checks.

## 1.6.0

### Lift-handshake recovery

Version 1.6.0 includes automatic lift-handshake recovery in exported core software.
An expired control/probe lease or missed lift-command acknowledgement suspends
feedback, retains the operation and applied lift, and retries after validating
fresh identity, hardware and provider readbacks. During recovery, chambers that
still own control renew their observed targets while expired peers re-probe.
Altitude control resumes after verified acknowledgements. Operator stops, lift
kill and incompatible identity or hardware changes retain their existing guards.
This update does not change PID gains or export a new installer automatically.

## Earlier documented additions

The previous README recorded these additions without release numbers.

### Duplicate computer identity warnings

New exports include an onboard advisory for copied computers competing with the
registered ship. It uses existing registry and status traffic, with no additional
sensor polling or periodic network messages. The Windows diagnostic host is not
required for detection.

Core watches for a different active core session using its own computer ID, and
for two boot identities that continue advancing within one assigned computer's
status stream. It requires repeated observations over time. One changed boot,
a burst, replayed sequence or ordinary reboot does not by itself raise a warning.
Separate lift, relayed thrust and role-console identities are tracked separately.

The bridge's Flight and Ship views display **POSSIBLE DUPLICATE ID #...**. Core's
monitor shows the affected role and evidence, and its log records warning onset
and clearance. The warning clears after competing traffic has remained quiet.
Emergency lift and assembly warnings retain their existing Flight-row priority.

This is advisory evidence, not proof of a second physical hull or an authentication
mechanism. It does not shut down, reassign IDs, change sessions, extend leases,
reset controllers or change PID behavior. A copy must be loaded, running and able
to exchange relevant traffic to be detected. An offline or silent copy cannot
be identified this way. A delayed legacy registry stream can warrant a possible-
duplicate warning, so inspect the reported identities before making changes.

When creating another independent Amaryllis, use distinct computer IDs and run
its own role registration. A copied blueprint may retain the original IDs.
This builder update does not install itself onto the running ship.

### Core's installer tab

New exports include the builder's progress display in core's existing installer
tab. It shows all 14 expected wireless package roles, including missing IDs,
waiting computers, sending, verification, completion and faults. The active
transfer shows its acknowledged-byte percentage, file and retry count. A transfer
at 100% is still waiting for commit verification. DONE requires the sender's
validated installed acknowledgement or its existing strict up-to-date check.

The roster retains faults when another computer becomes active, marks all-package
completion explicitly, and rechecks results after identity/session changes.
The state reader uses direct disk setup and is identified separately; this view
does not claim to have verified its wired link or any hardware behavior.

The display reads cached installer state only, redraws at most twice a second,
and does not poll peripherals or add network messages. Existing server behavior
isolates a display failure from the download process. The normal installer
service checks for auxiliary updates while matching media is inserted. Without
media, it idles and displays **Insert matching installer disk**.

The builder overlays the progress display and a read-only disk package adapter,
adds disk-presence checks to the existing sender's authority checkpoints, relocates
core's console to `/avionics/common/console.lua`, and changes core's role-version
lookup to local metadata. It records these overrides in the build report.
The transfer protocol, strict receipts, fleet identity checks and flight controller
come from the selected source save. Unknown sender layouts are refused.

### Removable package library

New cores receive their own flight software, console, installer service and a small
trusted package catalog. They receive **no `/packages` directory**. All auxiliary
program sources stay as verified objects on the installer disk. In our current
source snapshot the core payload is about 1.19 MB and the library is 2.62 MB;
actual figures are recorded in each build report. Objects shared between packages
are stored once on disk.

After installation you may remove the disk. Core's flight software, role health
checks, remote operation and existing auxiliary programs continue without it.
Removing the disk during a transfer retires the transfer before commit; existing
receiver recovery records handle unfinished writes. Reinsert the matching disk
to resume package checking and auxiliary repair. A damaged object, wrong catalog
or several matching disks prevents installation rather than changing flight control.
The package adapter yields while verifying large files and keeps the existing
bounded RAM cache; it does not write a package cache onto core.

For a newer **auxiliary** library, boot core from that disk so its flight runtime
has not started. Choose
**U Adopt auxiliary library**. This explicitly checks the registered fleet,
core runtime compatibility, catalog and every library object before replacing
the local version catalog. Then choose **S** to start core with that disk.
Changing a core/state program is outside this action: a different core runtime
is refused and needs an offline software upgrade. Saved calibration, flight
settings, fleet IDs and pairings are preserved by library adoption.

Keep media available when you need in-game installation or repair. Complete
ships built with 2.4.0+ can be exported again without the old media. The builder
checks all recovered source files and any media it used for changes during export. This change applies to
new installations; exporting does not migrate or delete an existing ship's
`/packages` folder. Do not delete that folder manually on an older core: its
startup and version checks still depend on it.
