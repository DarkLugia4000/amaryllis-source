# Lift kill and chamber status update

Release: **v117**, `amaryllis-6811e0c38e6c`.

## Load the update

The Lua changes are staged in **New World** and **New World (2)**. Their computer identities, hardware assignments and configuration files were preserved.

With Amaryllis safely parked, leave and reopen the world once. This loads the updated chamber and thrust computer programs as well as core and navigator. The existing Restart Systems action reloads core and navigator; it does not reload all chamber programs.

For a fresh installation, use `releases/2026-10-20-v117-kill-restart-status`.

## Kill and recovery

1. Confirm **KILL LIFT** to arm the persistent kill latch and perform the existing bulk-off, probe-on operation.
2. The red button becomes **DISARM KILL**. **START SYSTEMS** and **RECOVER LIFT** remain disabled while the kill is armed.
3. **RESTART SYSTEMS** may reload core and navigator while the kill is armed. The kill stays armed after the reboot. This restart creates no resumable flight checkpoint.
4. Press **DISARM KILL** explicitly. Core waits for fresh acknowledgements from all four current chamber boots, then saves the stopped state and clears its own latch.
5. Disarming leaves output settings unchanged and systems stopped. Use **START SYSTEMS** separately when ready. Normal startup checks still apply.

An unavailable chamber or a failed save keeps disarming pending and Start blocked. A new kill supersedes an unfinished disarm. A disarm request cancels an unfinished software restart.

## Chamber and thrust status

The flight tiles, Ship pages and computer consoles show independent **THRUST** and **LIFT** states:

| State | Thrust | Lift |
| --- | --- | --- |
| CMD | A requested output change is still being applied or verified. | A setting change, activation operation or controlled handover is underway. |
| RDY | Communication and readbacks are healthy; requested settings are applied. Steady nonzero thrust can be RDY. | The requested settings are applied or the controller is idle without a blocking fault. |
| FAULT | The thrust computer or its hardware is unresponsive, reports an error or lacks valid current feedback. | A provider, binding, communication, command or timing fault prevents reliable control. |

CMD is yellow, RDY green and FAULT red. The internal command leases and authority guards remain separate from these display states.

## Validation

Passed:

- Core disarm and reboot persistence, explicit Start/Recover interlocks, kill-preserving software restart and lost/stale acknowledgement cases.
- Chamber kill/disarm protocol, sender/session/boot/sequence checks, persistence failure, output retention and idempotent retry checks.
- Real core IO validation for the new packet and status fields, plus existing lift-debug transport checks.
- Package, chamber hardware, relay, navigation display and console suites, including independent CMD/RDY/FAULT states.
- Normal restart and bridge Start/Stop lifecycle checks, with the existing test mock updated to expose the current cockpit interface.
- All **360 portable installer checks**.
- Both worlds verified against the staged code: **126 Lua files**, with **32 fleet/configuration files** preserved byte-for-byte.

The broad legacy cockpit boundary tests still contain two earlier behavioral expectations that fail on both the pre-change and updated sources. The old propulsion cadence mock likewise uses the earlier cockpit interface. The full telemetry-recovery suite also contains another mock lacking the current `usable` method. These broad suites are not being reported as fully passing. No live actuator commands, in-game restart or flight test were issued during this update.

Code backups and synchronization reports are under `repair-backups/`, including `v117-worlds-20261020-122833`.
