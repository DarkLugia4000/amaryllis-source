# CC: Graphics display preparation

## Current scope

The shared heading-display program supports an optional CC: Graphics backend
for all three heading monitors, using a bundled bitmap font and 16-colour pixel
mode. At pixel dimensions of at least 240 by 80, the graphical layout places
current heading above its fixed marker and target heading below its moving
amber marker. Targets beyond the visible heading span use edge arrows with
their values kept within the instrument. The right column contains a moving
altitude tape, measured altitude, an amber target value and marker, altitude
hold status and vertical speed. The background is black and target values
have no `SEL` prefix. AP deviation/distance, strafe progress and anchor state
remain available in their applicable modes.

Monitors at least 300 pixels wide show speed, heading and altitude from left
to right. The speed dial spans 0..40 b/s with signed measured speed below it.
Its header follows the active throttle mode: `MAN THR`, `SEL SPD` or `DIR RPM`.
The yellow selector below measured speed shows requested acceleration, speed
or verified RPM respectively, with the corresponding unit in the footer.
An amber speed-dial rim marker is present only for selected-speed requests.
The horizontal dividers continue across all three columns. The compact core
display packet includes the bounded propulsion request fields consumed here;
update core along with the heading packages for acceleration/RPM values.

Native instruments use a 5-by-7 bitmap font with a six-pixel character advance
before integer scaling. Numerals distinguish zero from O, one from I, five
from S and eight from B. The smaller character-layout fallback retains its
original font.

A fresh `DISASSEMBLED` snapshot replaces the instruments with a static purple
six-petal flower, `VESSEL DISASSEMBLED` and the vessel name. Stale telemetry,
uncertain assembly, fleet startup and other existing display issues retain
their wrapped status screens. Smaller monitors use the existing character
layout rasterized into pixels.

The navigator uses a dedicated CC: Graphics renderer with a 342-by-216 logical
canvas. Its previous character renderer has been removed. Larger monitors scale
the canvas while preserving its aspect ratio; smaller monitors report the
minimum resolution on the computer console. Navigator has no text-renderer
fallback. The heading displays retain their separate fallback described below.

Navigator pages share the vessel name, current page, Systems dropdown and footer.
The green Systems status is replaced in the same position by the purple AP phase
while autopilot is active. Flight shows mode selectors, measured speed, primary
engine requests and animated shaft icons, heading-controller status, attitude and
four lift chambers in two divided envelopes. Ship contains detailed Lift, Prop
and Trim views. Settings retains configuration groups, diagnostics and maintenance.

Navigation Main edits the destination X/Z, altitude and cruise speed. Advanced
contains Single Destination and Waypoint Route views using the same removable-disk
destination library. Saved entries can include altitude and speed; older entries
inherit those fields from the draft when selected or added to a route. The ordered
playlist is stored with the draft in `/avionics/data/navigation.json`. Starting a
route always copies the list from its first entry. Reordering or editing the saved
list leaves an already flying copy intact. Intermediate arrivals acquire the next
leg; only the final arrival hands control to the digital anchor.

While AP is active, Navigation shows a dedicated progress page with phase chevrons,
the current target and coordinates, actual and requested values, distance and
cross-track deviation. A waypoint route also shows the next queued entry, except
on its final leg. Cancel AP remains available on this page.

The Systems dropdown contains Start, Stop, Restart and the red Kill Lift action.
Kill Lift opens a ten-second confirmation and changes to Disarm Kill while latched.
Recover Lift is absent from the new interface. Core retains the existing command
validation, acknowledged request transport and actuator authority.

## Requirements and installation

Install [CC: Graphics](https://modrinth.com/mod/cc-graphics/) for Minecraft
1.21.1 / NeoForge alongside CC: Tweaked 1.117.0 or newer. The mod lists client
and server support; use the matching mod environment on both sides.

Build and distribute the updated source through the normal project installer
or updater. Refresh core and the navigator together for ordered routes, and
refresh heading packages when their instruments change. Monitor resolution is
queried through `getSize(1)`.

Graphics is selected automatically when the monitor exposes `setGraphicsMode`
and `drawPixels`. To force the existing text renderer on a heading computer,
add `"graphicsMode": "text"` to its `/avionics/config.json`, preserving valid
JSON, then restart the program. Removing that property restores automatic
selection. This local override is not an installer menu or core setting.

## Frame handling and recovery

The heading backend uses zero-based pixel coordinates and byte rows with palette
indices 0 through 15. It batches adjacent changed rows into `drawPixels` calls;
an identical frame sends no pixel data. `setFrozen`, when available, holds
presentation while those batches are written. The existing receiver refresh
and status-packet cadence determine redraws; this adds no animation timer.

A failed heading graphics draw attempts to unfreeze the monitor, restores text mode,
and paints the text frame. That attachment stays on text until reattachment
or program restart. If restoring text mode itself fails, normal display fault
reporting applies. Attachment resets graphics mode so a previous program cannot
leave an explicitly text-configured display hidden. Termination restores text
mode and paints the existing stale-data frame.

## Validation and remaining work

Host regression checks exercise pixel bounds and palette bytes, full initial
painting, frame caching, resizing, stale-data redraws, graphics-write failure,
text override, missing graphics methods and cleanup. Additional checks exercise
heading wrap, distant targets, assembly freshness, recovery modes and multiple
monitor dimensions. The normal display,
builder and release checks also cover the shared heading package.

In-game validation remains required for actual monitor API compatibility,
font readability, palette appearance and redraw cost. Test all three monitor
sizes and the core-unreachable and vessel-disassembled screens. Frame rate and
redraw cost still need to be measured in game.

The standalone pixel fill reproduced a blank-output interaction with CC:
Tweaked Unicode Support 1.0.1; updating that mod restored visible graphics in
the tested setup. A successful pixel write alone cannot detect that client
rendering problem, so use the standalone fill when checking compatibility.

Navigator maps zero-based pixel `monitor_touch` coordinates through the current
canvas scale and offset. A resize invalidates old touch regions until the next
frame. Dropdowns and confirmations capture background touches. Fresh receipt and
current control locks are rechecked before sending commands; core validates them
again. Navigator emits changed pixel rows and restores text mode on termination,
rebind or drawing failure, with the fault reported on its computer console.

Run `python tools/navigator_preview.py` with the project's Lupa environment to
capture production Lua frames under `output/tests/navigator-graphics`. Run the
same command with `--png` in an environment with Pillow to create enlarged PNGs
and a contact sheet. These previews use fixture telemetry and the actual packaged
renderer. In-game checks are still needed for touch alignment, rendering cost,
readability and end-to-end waypoint flight on the vessel.

API reference: [CraftOS-PC graphics mode](https://www.craftos-pc.cc/docs/gfxmode).
