# Amaryllis split chamber/thrust installation

## Registered computers

| Corner | Chamber coordinator | Thrust controller |
|---|---|---|
| FL / left bow | chamber_fl, #50 | thrust-lb, #58 |
| FR / right bow | chamber_fr, #45 | thrust-rb, #60 |
| BL / left stern | chamber_bl, #51 | thrust-ls, #61 |
| BR / right stern | chamber_br, #47 | thrust-rs, #62 |

Core remains #35, bridge #38, instrument computers #36/#37/#39, primary
bearing-sensor computers #40/#43. Fleet registry now has fifteen roles.

## Hardware

Every chamber coordinator uses its back gas network: 32 steam vents, one trim
burner, and the gas activation Redstone Link Bridge. Corner altitude sensors
are no longer expected on the gas network. Existing steam/trim frequencies stay.

Each dedicated thrust controller uses left for port lateral, right for starboard
lateral, and back for its corner altitude sensor. The two stern controllers also
have their primary transmission and dedicated reversal link bridge on back.
Left primary reversal remains comparator/hopper; right remains
comparator/observer. Transmission input remains 256 RPM.

All four chamber hardware JSON files have been updated for 32 vents and back
gas discovery. Thrust package configurations describe the separate wiring.

## Command and telemetry flow

Core retains altitude, steering, heading, speed, autopilot, anchor and engine
mixing logic. It addresses its existing chamber endpoints. The chamber routes
each thrust request to the paired dedicated computer using the current fleet
registry, without recalculating targets or replaying requests periodically.

The dedicated computer reuses the existing transmission controller, ramping,
interlocks, direction sequencing and readback verification. Its core identity,
session, node boot and sequence checks remain enforced behind the relay.
Direct core flight commands cannot bypass the chamber transport.

Commands include their original issue time. Time spent in transit is removed
from the lease; the chamber cannot renew an old request when core disappears.
Acceptance and applied-readback acknowledgements are forwarded separately.
Readback age includes the child-to-chamber transit delay.

Corner altitude is sampled at the thrust computer and relayed back through its
coordinator. Relayed samples expire after 1.5 seconds and are cleared when a new
child boot is discovered. The existing four-block sensor mounting offset and
height-difference levelling logic are retained; no new angle conversion is used.

Discovery is local. Control and inter-computer pairing require registered fleet
identities. A propulsion-link failure does not directly change gas targets or
activation. Core still applies its existing flight recovery policy to lost data.

## Loading the change

This update stages code and bootstrap files. It does not reboot any computer,
enable propulsion, or write gas/transmission outputs from the host.

1. With the revamped vessel supported, restart core/bridge using the existing
   Restart Systems function to load the fleet and installer changes.
2. Restart each chamber computer so it loads the updated installer client.
   The client needs its expanded package allowlist for the relay modules.
3. Start or restart #58, #60, #61 and #62. Bootstrap files and assigned target
   roles are already staged. They await their packages from core.
4. Allow the fleet installer to finish, then confirm installed receipts and
   running programs on all eight chamber/thrust computers.
5. Check gas discovery on each chamber and transmissions/altitude on each thrust
   computer. Verify all four relayed corner heights reach core and become invalid
   if their source stops updating.
6. Commission low DIRECT thrust, both steering directions, primary reversal and
   lift before testing heading, anchor or autopilot. Offline tests do not verify
   physical propeller direction or redstone receiver wiring.

Restart Systems still restarts core and navigator only; it does not itself reboot
the chamber or thrust computers. Local package reloads are managed by their
installer/runtime wrappers. The existing local installation receipt checks remain.

The PC diagnostics server's role allowlist was expanded too. Restart that server
process when convenient to load it; the onboard controllers do not depend on it.

Portable setup now offers all fourteen auxiliary roles and preserves remapping
for other worlds. Core install continues to start with propulsion disabled.
