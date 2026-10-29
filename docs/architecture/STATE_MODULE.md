# ama-state sensor and cockpit module

Amaryllis can use an optional dedicated state reader. Core remains the flight-control authority. The reader samples sensors and cockpit links, supplies source records with their original measurement times, and performs no actuator writes.

## Current installation

New World has core **35 / ama-core** and reader **68 / ama-state**. The reader's files and core's compatible runtime are staged. Reboot ama-state first, then core, with Amaryllis supported and flight control stopped. Leave core's wireless modem attached for the workload test.

New World (2) has compatible code but no reader assigned. It continues local sampling. No nonexistent state-computer ID has been added there.

Live check on 2026-10-20: the operator loaded core and reader, then reconnected the missing cockpit bridge. Wired exchange, valid cockpit inputs and advancing sensor workers were verified. No reader timeouts occurred during observation. Core still intermittently selects fallback because primary readings arrive or are published late enough to exceed the two-second source preference window. The v126 receive-isolation change is loaded, but did not remove that remaining delay. See `diagnostics/2026-10-20/state-module-live-check.md` for evidence. This has not passed a flight test.

## Wiring

- Place the reader aboard Amaryllis so its Sable API refers to the same vessel.
- Connect core and the reader using wired modems and cable; enable their wired peripheral connections. Computer blocks merely touching cannot carry these frames.
- Move the sensor/peripheral connections to the state reader. It needs access to the navigation table, altitude sensor, gimbal, three velocity sensors, physics assembler and cockpit link bridge.
- Core keeps its wireless modem for the existing chamber/thrust/display network. The state reader does not require a wireless modem.
- If the reader has a separate wired sensor bus, the link selects the modem exposing the expected peer's computer ID. Ensure those computer peripherals are exposed on the link network.
- A recording drive must remain accessible to core, locally or on its wired network, for disk debug recording.

## Responsibilities

The state reader runs the existing independent vessel, cockpit, fallback, assembled-state and assembler-data readers, plus target-pressure queries and discovery. A restricted peripheral adapter exposes only sensor getters to these sampling methods. The transport has no remote code execution or actuator command operation.

Core receives fixed-shape records over dedicated wired channels and retains source selection/calibration, age validation, input interpretation, selected modes/targets, altitude control, stabilization, propulsion, AP, anchor, kill handling and actuator commands. Assigned state mode does not fall back to core polling when the reader is unavailable. Core scans its local communication devices without enumerating the remote sensor methods.

The wired link binds the configured computer IDs, the current core session, reader boot and increasing frame sequence. Old-session, wrong-peer, wrong-side, duplicate and retired-boot frames are rejected. These checks protect logical routing and stale-message handling; this is not a cryptographically authenticated network.

Frame receipt does not renew any sensor timestamp. A running reader/transport cannot make stale measurements authoritative. Missing state frames leave original source ages to expire under the existing limits. A reader reboot resets manual neutral gates before demands can resume. Confirmed disassembly and existing kill/identity rules remain effective.

## Fresh installation from the portable disk

1. Install core on a fresh computer using the usual disk workflow.
2. On the new sensor computer, choose the auxiliary role **state**. This role installs its complete reader directly from the disk, so it can start without wireless package discovery.
3. Install/register the remaining auxiliaries as usual. Return the disk to core and import role assignments.
4. Connect the wired core/state link and sensors, remove the installer disk, then boot the reader and core.

IDs are taken from that deployment, not copied from New World. The state role is optional: leaving it unassigned preserves local core sampling. The setup menu retains its fresh-computer-only protection. Existing state readers do not yet have automatic package updates through the wired protocol; use the managed file-staging workflow for updates to this installation.

## First verification

Keep flight stopped for 30 to 60 seconds with wireless attached. Check:

- Core's subsystem view lists **ama-state / wired sensor / cockpit reader** as online.
- Core snapshots expose `stateReader` with a progressing frame sequence and low receipt age.
- The vessel, cockpit and assembler readers continue completing on ama-state.
- Source timestamps advance, cockpit inputs are valid, and fresh Sable position is available when Sable is healthy.
- Deliberately stopped flight remains stopped. Starting systems is a separate operator action.

Helper diagnostics use the existing local, read-only diagnostic host under the **state** role. A transport heartbeat or frame counter alone does not establish healthy sensor data; inspect the measurement ages and validity fields.

## Cockpit reader tab

On an advanced state computer, the cockpit reader tab shows all nine named raw
inputs, from 0 to 15. READ is the latest completed read attempt; USED is the last
valid complete batch retained for core. Missing reads are `--`, so a failed getter
is not displayed as a zero signal. Both sample ages and the read duration appear
above the values. Use the up/down keys to select an input and inspect its exact
configured frequency pair and any read error. The pane also identifies the link
bridge. It renders cached reader results and adds no peripheral reads.

Reboot ama-state with flight systems stopped to load this display update. Core
does not need rebooting solely for the cockpit tab change.

## Offline verification

The state-module suite tests peer/session/boot/sequence binding, replay rejection, future/stale timestamps, malformed data, retained input ages, neutral-reset signaling, read-only wrappers, separate wired buses, absence of core sensor enumeration and pressure API calls, and the actual sampling pipeline in a lightweight helper runtime. Existing source, propulsion, restart, kill/disarm and radio-load checks also pass. Installer tests exercise a fresh reader with remapped IDs. The older full-runtime scheduler fixture limitation remains documented in the earlier diagnostics.

Staging and offline checks do not establish live flight acceptance. An in-world load and workload comparison are required before claiming that this resolves the wireless-related stalls.
