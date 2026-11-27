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
layout rasterized into pixels. The navigator and its touch controls still use
their existing text renderer.

## Requirements and installation

Install [CC: Graphics](https://modrinth.com/mod/cc-graphics/) for Minecraft
1.21.1 / NeoForge alongside CC: Tweaked 1.117.0 or newer. The mod lists client
and server support; use the matching mod environment on both sides.

Build and distribute the updated source through the normal project installer
or updater. Refresh all three heading-display role packages and restart their
programs. No new core command, sensor, modem or flight-controller configuration
is required for graphics. Monitor resolution is queried through `getSize(1)`.

Graphics is selected automatically when the monitor exposes `setGraphicsMode`
and `drawPixels`. To force the existing text renderer on a heading computer,
add `"graphicsMode": "text"` to its `/avionics/config.json`, preserving valid
JSON, then restart the program. Removing that property restores automatic
selection. This local override is not an installer menu or core setting.

## Frame handling and recovery

The backend uses zero-based pixel coordinates and byte rows with palette
indices 0 through 15. It batches adjacent changed rows into `drawPixels` calls;
an identical frame sends no pixel data. `setFrozen`, when available, holds
presentation while those batches are written. The existing receiver refresh
and status-packet cadence determine redraws; this adds no animation timer.

A failed graphics draw attempts to unfreeze the monitor, restores text mode,
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
sizes and the core-unreachable and vessel-disassembled screens. There is no
claim of a measured frame rate or a complete graphical bridge overhaul yet.

The standalone pixel fill reproduced a blank-output interaction with CC:
Tweaked Unicode Support 1.0.1; updating that mod restored visible graphics in
the tested setup. A successful pixel write alone cannot detect that client
rendering problem, so use the standalone fill when checking compatibility.

Navigator touch coordinates and menus need their own layout and input work
before enabling graphics there.

API reference: [CraftOS-PC graphics mode](https://www.craftos-pc.cc/docs/gfxmode).
