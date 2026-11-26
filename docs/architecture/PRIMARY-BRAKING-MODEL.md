# Primary-engine brake release model

This provisional Amaryllis model releases SEL-zero reverse braking before
residual primary output carries the vessel through zero speed. It does not
change the AP approach envelope or braking toward nonzero selected speeds.

## Evidence and fitted estimates

Evidence: a baseline SEL-zero braking recording. The
zero-speed request starts at sample 177 with measured speed 29.017 b/s.
Forward travel stops about 19 seconds and 343 integrated blocks later;
the subsequent reverse-speed peak is 1.373 b/s.

The recorder contains requested output, applied output, direction and vessel
speed. Applied output is a controller readback, not measured shaft RPM.

An initial fit used overlapping windows spanning at least two seconds during
recording seconds 110 through 140. For each window, integrate average applied
left/right output and vessel speed using trapezoids, then solve ordinary
least squares for `deltaSpeed = gain * integral(output) - drag * integral(speed)`.
The estimates are gain 7.94 b/s² per normalized output and drag 0.108 /s;
the window delta-speed RMS residual is about 0.625 b/s. This is a descriptive
fit to one maneuver, with correlated windows and sample-and-hold readings.
It does not independently identify propeller inertia or establish a physical
model across operating conditions.

The runtime rounds gain to 8. Applied reverse-output release in this recording
is roughly 0.08–0.09 normalized output per second; the forecast uses 0.08.
A fixed 2.5 b/s allowance covers unmeasured residual response and reporting
delay. Pass one used 1.5 b/s; an independent second braking recording still
reached 0.877 b/s backward, so pass two adds a
rounded 1 b/s release margin. This is a tuning correction, not an independently
identified physical constant. These constants require
validation on another braking run and are currently vessel-specific.

## Runtime forecast

For each side, take only applied output opposing the original travel direction.
Assume its magnitude `u` falls linearly to zero at rate `r = 0.08 /s`.
Its integrated output is `u² / (2r)`. Average the two sides, multiply by gain
8, and add the 2.5 b/s tail allowance. If neither side opposes travel, loss
is zero. If either readback is unavailable, retain the existing speed cutoff.

Release braking when predicted remaining speed in the original direction is
at most the greater of this residual loss and the configured stop band.
The existing final target selection sends zero to both primaries when the
coast latch is active. A release-specific rearm threshold is retained at
least 0.5 b/s above release speed, preventing the decaying forecast from
immediately rearming the brake. Existing low-speed coasting remains available.

Drag is omitted from the release-loss integral. Including it as extra stopping
power could conceal how much reverse velocity the remaining thrust can cause.
The existing sensor-age speed predictor still runs before the release check.

## Coordinated primary rundown

During a selected-zero stop, core suppresses primary turn-assist differentials.
As equal primary demand decreases below applied output, it sends both primary
controllers the same UTC start time, starting magnitude and 0.08/s falling
envelope. Each controller evaluates the envelope at its own current UTC time,
bounded by the common requested magnitude, its current output and its normal
rate limit. The lower side holds until the envelope reaches it; the higher side
catches down. Neither side increases output to match its peer during rundown.
Increasing demand or a changed requested direction cancels the old envelope.

Command leases, direction interlocks and readback checks remain authoritative.
Invalid profiles revoke the command, and lease expiry falls back to the normal
local safe-zero ramp. This coordinates transmission settings, not physical
shaft RPM; existing mismatches converge rather than disappearing instantly.
Network timing, independent quantization and different hardware responses can
still produce small differences. Physical symmetry requires flight validation.

Recorder build `amaryllis-debug-disk-v147-rundown-renewal-trace` appends core release
loss/threshold/coast state and shared profile parameters. Each side reports
diagnostic version 2, last evaluation epoch, profile epoch, envelope, target,
reason, readback age and boot identity. An absent version identifies code that
does not advertise this diagnostic protocol. `ACTIVE` means the writer evaluated
the envelope; compare its timestamp, target, applied output and status age to
assess actual execution. It is not proof of a successful write. Other reasons
include `NO_PROFILE`, `LEASE_INACTIVE`, `DIRECTION_NOT_READY`,
`DIRECTION_MISMATCH`, `DEMAND_CHANGED`, `CLOCK_INVALID` and `NOT_EVALUATED`.

Version 2 retains the last evaluation across command renewals with identical
profile epoch, magnitude, rate and direction. Its evaluation timestamp and
sequence stay unchanged until another writer evaluation occurs. New profiles,
profile removal, invalidation and lease expiry clear the trace. The CSV appends
each side's evaluation sequence and latest received sequence separately; an
older evaluation sequence is historical evidence, not proof that the latest
command has run. Older version-1 endpoints remain readable by core, with blank
evaluation-sequence fields. This is a diagnostic-only correction.

## Renewal-safe writes and elapsed rundown

Identical live rundown renewals preserve the writer token only when every
drive target, profile field and direction permission matches. Changed demand,
changed permission, profile replacement/removal and expired leases retain
ordinary invalidation. Session and boot checks still precede command acceptance.

Coordinated rundown uses elapsed local time since the last successful output
update, with at most one second of rate credit per update. Cancelled/failed
writes retain this credit; a successful write or unchanged output resets it.
An unchanged output includes the lower side holding below the shared envelope.
Ordinary acceleration and direction-change ramps retain their original dt.

Recorder `v148-rundown-write-trace` and endpoint diagnostics version 3 append
write attempts, completed/failed counts, last result, attempt epoch, original
command sequence, requested shift level and profile epoch. Independent matching
readback records a confirmation epoch and level. `SETTER_COMPLETED` means the
hardware wrapper returned success; a later matching readback is separate evidence.
A failed wrapper can have issued the setter before losing authority, so failure
does not prove that the physical setting remained unchanged. Counters and the
last write trace are retained across profiles; compare their recorded epochs
and profile identity with the current evaluation before attributing them.

## Future measured shaft model

TODO: Add timestamped primary shaft RPM to recordings. Replace the output
triangle and fixed tail allowance with identified shaft decay and thrust
response. Keep observed controller output, measured shaft state, and estimated
physical thrust distinct. Do not substitute raw RPM directly for normalized
output without identifying its speed/thrust relationship.

## Validation scope

Regression coverage checks symmetric forward/reverse release, differing travel
directions, missing readbacks, the integrated rundown allowance and retention
of the coast latch after output disappears. These checks validate implementation
and modeled behavior; they do not prove an improved real flight stop.

Before tuning AP stopping distances, record another SEL-zero stop and inspect
release speed, remaining applied reverse output, final reverse overshoot and
stopping distance. Other speeds, masses and operating altitudes remain untested.
