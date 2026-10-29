# Lift debug runs

The v114 recorder adds lift measurements and command timing to disk debug mode.
It samples existing cached readings and never polls extra flight peripherals.
The core builds bounded log queues; only the background recorder writes disk files.

## Setup in world

1. Park the vessel and stop systems before rebooting computers for this update.
2. Reboot core and the four chamber computers so the new recorder and chamber
   timestamp instrumentation load. Wait for the fleet and chamber hardware to be ready.
3. Leave exactly one writable debug disk visible to core. Remove the installer disk.
4. Open Settings, Debug Mode and start recording. Confirm RECORDING before starting systems.
5. Start systems with the normal selected altitude. Keep the gyroscopes running.
6. Let the recording cover lift building, the approach to the selected altitude,
   and roughly one minute of settled hold or any repeated oscillation.
7. Stop debug recording to flush both CSV queues. Leave the disk inserted until
   its state is OFF. Settings reports an error if writing fails or space runs out.

Use a fresh recording for another test. Earlier recordings are preserved.

## Files on the disk

All three files share one run ID under `/amaryllis-logs/`:

- `<run>.json`: configuration, core identity/session, column lists and interpretation notes.
- `<run>.csv`: flight, lift-controller and per-chamber measurements, nominally every 0.5 seconds.
- `<run>.events.csv`: command sends, send results, accepted status sequence changes and verified ACKs.

The sample and event CSVs share an 8 MiB maximum per run. The recorder also keeps
128 KiB free on the disk and stops earlier if that reserve cannot be maintained.
Each queue holds at most 128 rows. Sample and event drops are counted separately;
the Settings DROPPED total includes both. The files are never redirected to core storage.

## Reading the timing

Match events by the metadata's core session, quadrant, node boot and command sequence.
`send` marks core's call into rednet; `send_result` marks its return and reports
whether it succeeded. Neither proves chamber receipt.

Chamber `node_received_epoch_ms` marks acceptance into its systems writer queue.
`node_applied_epoch_ms` marks successful writes and target/activation readback validation.
It does not mean the balloon has finished filling. `status_sent_epoch_ms` marks
the outgoing chamber report. A `status` event's epoch is the core's receipt time
for an accepted report that advances receipt/application sequence or changes boot.
`ack_verified` marks core's first successful target/readback acknowledgement check.
Repeated reports and ACK checks do not create repeated events.

UTC epoch fields are in milliseconds. Check for clock jumps before subtracting
timestamps. `core_clock_s` and fields ending in `_core_s` are core-local monotonic
seconds and must never be compared with a chamber's `os.clock()`.

## Reading the samples

The sample CSV includes requested vertical speed, BUILD limiter, actual/desired
support ratios, PID integrals, acceleration demand and measurement, response-lag
estimates, ACK wait, trim errors/rates/corrections, and recovery state.

The v128 recorder also captures the learned vertical drag, requested and applied
drag support compensation, whether HOLD braking limited that compensation,
the support correction fraction and ceiling slew budget. These distinguish a
speed PID braking request from an opposing feed-forward demand, and show whether
gas target changes respect the incremental HOLD limit when response lag is unknown.

Each of FL, FR, BL and BR includes lift, gas output, fill/capacity, provider ceiling
totals, core target totals, pending command target totals, readback target totals,
sequence numbers, timing, readiness and status age. Core target totals can differ
from readback totals when a fine burner's logical zero retains a physical minimum
ceiling with its activation signal off.

Missing or invalid values remain blank. Totals remain blank for incomplete provider
maps. Cached measurements retain their status age; a numeric value alone is not
proof of fresh telemetry. Older chamber software can still operate but leaves
its new receive/application timestamps blank.
