# State-reader design history

This historical note records the design of a dedicated sensor and cockpit
reader. See [the state-module guide](../architecture/STATE_MODULE.md) for setup
and the maintained source for current behavior.

## Design boundaries

- Core remains the flight-control authority. The reader samples vessel sensors,
  cockpit links and assembly information through read-only getter wrappers.
- Core and reader use wired modems and cable. Adjacent computer blocks alone
  cannot transport the frames. Computer IDs come from the fleet registry.
- A dedicated wired protocol binds peer IDs, core session, reader boot and
  increasing sequence numbers. Reject wrong peers, stale sessions and replays.
- Preserve measurement timestamps. Frame receipt and heartbeats do not make
  stale sensor values fresh or authorize actuator output.
- Delegated mode avoids core sensor polling even when the wired network exposes
  those peripherals. Unassigned state roles retain local sampling behavior.
- Target-altitude pressure requests use the reader's bounded query/cache path.
- Reader restart, telemetry loss and assembly changes retain their existing
  control, identity and recovery protections.

## Installation design

Install the state reader with its own startup, configuration and sampling
modules. Bind it to the installation's core and state IDs. Preserve other
assignments, calibration and settings during updates. The original design used
portable-disk provisioning; current web installation and wired updates are
covered in the [installer guide](../../disk-builder/README.md).

## Verification scope

Check peer/session/boot/sequence binding, malformed and nonfinite data,
future/stale timestamps, replay rejection, retained input ages, restart handover,
field loss, assembly gates and read-only peripheral access. Verify wired-only
transport, remapped installation IDs and pressure queries. Run the existing
propulsion, restart and installer regressions, then validate source freshness
and cockpit latency in game. A heartbeat alone does not prove usable telemetry.
