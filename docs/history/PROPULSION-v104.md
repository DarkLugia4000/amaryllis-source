# Propulsion update v104

Thrust control runs in an independent native runtime tab (or cooperative worker on single-shell systems). It renews unchanged absolute commands at intervals of at most 0.2 seconds and one quarter of the command lease. The endpoint lease remains one second. A three-second core supervision deadline, cockpit freshness, identity/assembly gates, restart state and emergency lift kill continue to revoke propulsion authority. Stops invalidate an in-progress send.

Selected-speed and AP braking discard opposing accumulated integral demand while preserving the configured output slew. Confirmed maximum main-prop output with eight seconds without a 0.25 b/s speed gain reports UNABLE TO REACH TARGET: MAX THRUST, without a propulsion fault or abort. Lease faults, stale readbacks or reduced applied output reset that confirmation. Both forward and reverse output use the configured limit. Current main-prop limit remains 64 RPM; the analog transmission supports 256 RPM.

Offline validation covers renewal during slow supervision, supervision/cockpit/restart/emergency cutoffs, stop during send, selected-speed braking, output-limit confirmation, native main emergency integration, propulsion, airborne restart/recovery, manual/lateral control, AP/anchor simulations and navigation UI. Live performance remains to be verified.

Load through Settings page 2 Restart Systems with propulsion neutral and the vessel secure. No thrust/chamber computer restart is required for this update. For the next recording: wait for SYSTEMS READY, leave AP off, begin debug recording, hold a selected speed, then select zero and leave recording running until stopped.
