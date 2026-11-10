# Pilot reference

## Readouts

SEL is the entered selection. SPD is measured forward speed in b/s. On the heading display, REQ is AP cruise speed during AP operation or the selected throttle speed in SEL. The heading scale shows actual heading and the commanded selection; signed turn information indicates the correction direction. HDG BIAS is AP's learned route-heading offset. DEV is signed route deviation; DIST is remaining distance.

## Altitude indications

READY means the normal altitude-control stage is established. STATIC INFLATION and CAPTURING PITCH ZERO describe startup fill/settling. ACQUIRING SEL ALT describes initial acquisition. ALT OFFLINE means altitude control is inactive. An ABORTED indication takes precedence over the altitude advisory.

The current heading display's LOW PRESS advisory is altitude-triggered: yellow at Y >=285, clearing below Y 284. At Y >=305 it alternates red LOW PRESS and DESCEND once per second. These are the actual display thresholds, independent of which pressure source is selected. DESCEND advises a lower selection; it does not itself change that selection.

## Heading centre and SEL 0

In heading SEL, hold both heading pedals A+D for 1.5 seconds by default to set SEL heading to the fresh measured heading. Release both before using them again. AP blocks this pedal-centre action while active.

Ordinary SEL 0 coasts below the configured threshold, shipped as 2 b/s. A new movement above 3 b/s re-arms braking. Direction reversal also returns it to coasting. AP heading acquisition and route capture request zero primary drive through their own control flag.

## AP, anchor and recovery

AP acquires heading, captures the route with laterals, accelerates, follows the route and hands arrival to the destination anchor. Anchor retains its point and damps position/velocity according to its active stage. Pilot heading and throttle selectors remain selected through AP/anchor handovers.

A watchdog warning means control error has not made the expected progress. Read the issue details and current telemetry before changing a selection. State failover uses available peripheral measurements while reader verification continues. Read current issues from the navigator warning or Settings. Missing absolute position can suspend position guidance while other valid control data remains available.

Core reboot and recovery retain lift-provider settings. Stop Systems and Kill Lift are explicit operating actions with different consequences. Follow their on-screen confirmation and status. A red KILL LIFT ARMED indication requires disarming before Start Systems.

For source checks, calibration limits and current known issues, see the maintenance delivery record and pressure evidence. This card describes current code; physical-flight acceptance is reported separately.
