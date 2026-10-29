# Cockpit timing investigation

The operator must keep Amaryllis physically supported for this comparison.
Keep the world, machinery, flight modes and game settings steady. The current
supported deployment is Journeys, core #0, ama-state #1 and navigator #5.

## Load and verify

Stage the verified v143 core/state delta with backups and identity/hash guards.
Reboot ama-state #1 first, then core #0. Leave navigator and other computers
running. The first restarted installer will verify its fourteen bundles once;
wait until all fourteen are cached and subsequent checks add hits without new
misses. Verify both virtual traces and the installer's in-memory probe before
starting the comparison. No removable debug disk is needed for this trace.

The trace is a 256-sample memory ring per computer. Each report returns at most
twelve records, a bounded list of slow core operations and scheduling delays,
plus the installer's latest loop/pause observations. Export uses the existing
read-only read_file command with a fixed virtual path and mutation cursor:
`/avionics/data/cockpit-timing-<cursor>.json`. No such file is written onboard.
The same read-only diagnostic host and credentials are used; no host capability
or frame-size increase is required.

## First comparison

1. With cockpit controls neutral, record three minutes with the warm installer
   active. The agent runs the collector; leave her untouched during this phase.
2. Create `/installer/paused` through core's shell. Confirm both the displayed
   PAUSED state and the live pause-check probe. Keep runtime running.
3. Repeat the same three-minute untouched recording.
4. Delete `/installer/paused` through core's shell. Check whether the running
   installer observes removal and resumes without a tab restart. If it does
   not, retain the evidence before restarting only that tab.

Use the same diagnostic polling interval in both phases. Do not change terrain,
rendering, view distance, PID tuning or freshness settings during the comparison.
Three-minute samples support useful distribution comparisons; they are not
full failure acceptance or a proof of flight safety.

Only if an input-specific trace is still needed, agree on a separately supported
test with automation disengaged and propulsion deliberately inhibited, then
apply a short agreed input sequence. Do not move thrust or lift controls merely
to make the timing trace visible: neutral samples already traverse the path.

## Interpretation

- Each sample retains the state boot, input sequence and original completion
  stamp. Metadata is fixed-shape and cannot alter command authority/freshness.
- First consumption is stamped at the actual Controls sample assignment.
  Consumption includes neutral-return handling; it does not mean an actuator
  moved. Later duplicate checks cannot inflate this timestamp.
- Send-attempt-to-receiver time includes sender API scheduling and delivery.
  It is not a measurement of pure wire transit. Sender API return provides a
  separate interval and can occur after core has received the packet.
- Receiver-to-consumption time identifies delay after core's receiver enters.
  Slow-operation spans and independent wake-up timestamps provide context.
- Timing uses the existing shared UTC epoch. Negative stage deltas are reported
  as anomalies rather than silently clamped. Exports report overwritten history.
- Job durations include yields and peripheral waits; they are not CPU profiles.

The collector writes bounded-duration evidence only to this workspace's
diagnostics folder. It sends no control, reboot, pause or configuration request.
The analyser merges later mutations of the same record and reports p50, p95,
maximum, missing history and the slowest correlated samples. Empty or partial
records must remain distinguishable from valid zero-duration work.
