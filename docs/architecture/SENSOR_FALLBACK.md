# Independent vessel sensor fallback

Implemented 2026-10-20, with reader-cycle corrections in v121. Installer: `releases/2026-10-20-v121-reader-cycle-recovery`.

## Setup in world

1. Park Amaryllis safely before loading the new core runtime. Re-enter the world, or reboot core while safely supported, to start the additional independent sensor worker.
2. Keep the navigation table, altitude sensor, gimbal, all three velocity sensors and physics assembler connected and configured.
3. Allow a healthy overlap between Sable and the backup readings before testing a dropout. Core learns the navigation-frame and altitude-datum corrections during this overlap. A previously saved matching calibration can be reused after reboot.
4. Start a disk debug recording before the test. Use a writable recording disk visible to core, with the installer disk removed.
5. During a controlled Sable interruption, check that heading, altitude and selected-speed control continue. If absolute X/Z disappears, AP/anchor should show PAUSED, retain the route/anchor point, hold heading and request braking toward zero speed. Restore telemetry and confirm position guidance resumes.

The implementation has been staged on disk in both New World and New World (2). Running Lua code must reload to use it. No live flight test or actuator command was issued as part of this implementation.

## Source selection

| Measurement | Preferred source | Backup |
| --- | --- | --- |
| Altitude | Sable world center of mass | Altitude sensor plus saved datum correction |
| Vertical speed | Sable velocity | Altitude sensor vertical speed |
| Heading/orientation | Sable pose | Calibrated navigation-table orientation; heading and gimbal can also form a fallback basis |
| Pitch/roll and turn rates | Sable pose/angular velocity | Gimbal gravity and body angular rates |
| Velocity and hull speed | Sable velocity | Three body-axis velocity sensors transformed to world/hull coordinates |
| Mass and vessel identity | Sable | Physics assembler |
| Air pressure/gravity | Primary environment data | Altitude sensor pressure and gimbal gravity magnitude |
| Absolute X/Z | Sable world pose and center of mass | No dead reckoning; position guidance pauses when unavailable |

Each getter commits separately and retains its own timestamp. An unrelated fresh reading cannot renew an old reading's age. Primary readings are preferred while no more than two seconds old, bounded by the configured sensor grace. Backup readings use the existing configured sensor grace; the two worlds' settings have not been overwritten.

The fallback reader operates independently of the Sable worker. A two-second partial-batch deadline allows healthy fast backup readings to publish even when another fast backup getter hangs. Assembler identity, mass and center of mass run in their own worker, with a six-second attempt deadline and a two-second interval. Their main-thread replies are no longer cancelled at the fast worker's two-second deadline. Failed reads do not renew timestamps. Readers continue retrying.

Vessel identity uses the configured sensor stale grace, rather than the two-second primary-motion preference window. Identity disagreement and explicit disassembly still block. Hardware discovery retains completed bindings while a new scan yields and only replaces them when discovery reaches a completed result. Retry recovery does not scan all known peripherals merely because a read was slow.

Failed cockpit read attempts retain the last coherent batch at its original timestamp. That batch still expires at the configured cockpit/network stale gate; a real bridge detach invalidates it immediately. Bridge snapshots include `inputs.lastReadError` and bounded `readers` stage, error and pending-call diagnostics.

The existing physics-assembler gate remains separate: three six-second unknown/stale failures are tolerated, while a verified disassembly still blocks immediately. Fallback does not override an explicit disassembly, identity disagreement, lift kill or missing required measurement.

## Position-control pause

AP and digital anchor retain their intent while absolute position is unavailable. They report PAUSED. The thrust controller requests zero selected speed for braking, holds heading, and removes positional lateral demand. This proxy preserves the pilot's original selected values. Position guidance resumes automatically when fresh position returns for the same vessel.

Manual, selected heading, selected speed and altitude control can continue when their required backup measurements remain usable. Losing an individual required sensor can still make the corresponding function unavailable. All three velocity axes are currently required for the reconstructed velocity vector.

## Calibration and limitations

Calibration is saved atomically in `/avionics/data/sensor-fallback.json`, with a backup. It is tied to vessel identity and the hardware binding fingerprint and saved at most once every 30 seconds. Invalid or mismatched stored calibration is rejected. A failed save leaves valid live calibration in memory.

The altitude sensor measures its mounting point. The saved center-of-mass datum correction is approximate during large changes in pitch or roll. Fresh Sable overlap updates the correction. A fresh assembler center of mass allows current local mass-distribution shifts to be included when orientation is available. Exact mount-position reconstruction is not implemented.

Independent API workers cannot make a shared stalled game thread or disconnected peripheral network healthy. The change isolates stalled getter paths and selects available measurements; it does not invent missing data. Predicted pressure at a distant target altitude is unavailable without absolute world position.

## Diagnostics

Core snapshots include `vessel.sources`, per-field source timestamps/ages, `validFields`, `positionUnavailable`, backup-read errors and calibration-save errors. The core console includes the fallback reader.

Disk recordings add these CSV fields: `telemetry_mode`, `altitude_sensor_source`, `heading_sensor_source`, `velocity_sensor_source`, `attitude_sensor_source`, `mass_sensor_source`, `absolute_position_available`, and `primary_pose_age_s`.

## Verification

- Independent source tests: primary/fallback/primary switching, mounting-frame correction, signed velocity, gyro units, timestamp aging, field loss, identity disagreement, disassembly, persistent calibration and save failure.
- Actual IO integration: blocked primary getter, blocked backup getter, partial-batch deadline, per-getter publication and lift-guard acceptance.
- Position guidance: AP/anchor pause with retained intent and zero-speed braking proxy that preserves pilot selection.
- Existing propulsion suite: 3,754 assertions. Airborne restart suite: 46 assertions. Command renewal, navigation response, restart/bridge lifecycle, disk recorder, kill/disarm and status UI checks passed.
- Portable installer: 363 checks passed, including simulated installation onto remapped computer IDs.
- Staging verified 166 Lua files and preserved 32 fleet/config files byte for byte. Earlier and final staging backups are under `repair-backups/v119-vessel-sources-*` and `repair-backups/v120-vessel-sources-*`.

An older full-runtime scheduler fixture also fails on the pre-change baseline because it does not model the nested receiver/supervisor workers. It is not counted as a passing runtime test. The controlled source and controller tests above passed. In-world flight validation remains outstanding.
