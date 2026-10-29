# Amaryllis UI presentation plan

Updated 27 October 2026, Europe/Berlin.

Status: implementation 1 is complete in builder 2.1.0. Implementation 2's core
interface is implemented in builder 2.3.0. This document is the running plan for
the visual, text and presentation changes discussed in this chat.

## Existing-install update support

Completed 27 October 2026 in builder 2.2.0. The Windows utility now previews and
replaces all 16 registered computers in place, retains stored settings and data,
backs up outside the save and removes obsolete managed code and core's package
library. It supports migration from loose files and later bundled updates.
Future installer ZIPs include the standalone Windows updater. The live save has
not been updated by this task.

- [Builder 2.2.0 ZIP](../../releases/builders/Amaryllis-Installer-Builder-v2.2.0.zip)
- [Update validation report](../../diagnostics/2026-10-27/existing-install-update/README.md)
- [Update instructions](../../Amaryllis%20Installer%20Builder/README.md)

Validation: 14 updater, 20 bundling, 30 builder, 13 bridge presentation and 23
settings cases passed. The standalone GUI preview/apply/restore flow was also
rerun after its visibility fix. Implementation 2 is recorded below.

Follow-up: in-game startup exposed an auxiliary launcher environment defect.
Builder 2.2.1 corrects it, adds targeted startup repair and handles older media.
The 14 affected launchers in Trial Journeys were repaired with a verified external
backup after Minecraft was closed. [Repair and regression report](../../diagnostics/2026-10-27/bundled-startup-fault/README.md).

## Implementation 1: Systems dropdown and wording revamp

Status: completed 27 October 2026 in builder 2.1.0. The exported bundled bridge
UI includes this group. No live save was changed and no installer was built
for distribution.

- [Updated builder ZIP](../../releases/builders/Amaryllis-Installer-Builder-v2.1.0.zip)
- [Illustrated implementation report](../../diagnostics/2026-10-27/implementation-1/report.html)
- [Menu overview images](../../diagnostics/2026-10-27/implementation-1/images/menu-overview.png)
- [Validation results](../../diagnostics/2026-10-27/implementation-1/validation.json)

Validation passed: 13 presentation cases, 18 bundling regressions, 30 builder
regressions and 2,052 assertions in the simulated bundled UI/core startup run.
Image captures reproduce the actual exported Lua renderer with CC:Tweaked's
bitmap font. The core flight bundle is unchanged from the 2.0.0 baseline.

### Systems controls

Replace the top-right `ALTITUDE TARGET` heading with `SYSTEMS`. Beneath it,
replace the changing action button with a consistent `Options [v]` dropdown.

The dropdown contains:

- Start Systems
- Stop Systems
- Restart Systems
- Kill Lift

Move Kill Lift into this dropdown and remove its standalone button from the
flight page. Preserve the existing action availability checks, confirmation
steps and lift-kill/disarm behavior when mapping the existing controls into the
menu. Opening the menu must not execute an action.

The selected numeric altitude remains in the flight readout beside `TGT`.
This change does not alter altitude selection or flight-control behavior.

### Confirmed wording changes

| Location | Current text | Required presentation |
| --- | --- | --- |
| Flight: vertical speed | `VERTICAL SPEED <value> b/s` | `V/S <value> b/s`, for example `V/S +0.00 b/s`. The value is measured data; the word VALUE is not displayed. |
| Chamber diagram: orientation label | `BOW UP` | `^ BOW ^`, centred above the chamber diagram. This indicates the bow is toward the top of the diagram. |
| Debug recording: disk instructions | The block beginning “Use one writable disk visible to core.” and continuing “Installer disks are refused. Flight is unaffected.” | “Use an empty disk in one of core's disk drives.” |
| Debug recording: log location | “Logs use /amaryllis-logs/ on the disk.” | “Logs are located under /amaryllis-logs/ directory on the disk.” |
| Display settings: specification footer | “Text scale 0.5; fixed 57 x 24 layout.” | Remove this line. |

Fit the approved text within the supported monitor dimensions. Wrap explanatory
sentences as needed while preserving their wording and leaving controls readable.

### Dropdown interaction details

The proposed interaction is to open the menu on touch, select an action on a
second touch, and dismiss it on an outside touch. The outside touch is consumed
so it cannot activate a control underneath. Existing confirmation steps follow
selection of an action that requires confirmation.

The exact menu placement, row spacing and presentation of unavailable actions
remain layout details to settle as the visual plan develops. No new command or
control behavior is requested by this presentation change.

## Open presentation decisions

| Element | Established meaning | Decision still open |
| --- | --- | --- |
| Space previously occupied by standalone Kill Lift | Implementation 1 removes the button and leaves that slot clear; strafe remains in place. | Optional reuse or reflow in a later presentation change. |

## Review and validation when implementation is requested

1. Apply implementation 1 as one group, including both the dropdown and wording.
2. Check the menu in stopped, starting, running and lift-kill states. Preserve
   existing confirmations and action availability.
3. Update the simulated touch tests for the new control locations. Check outside
   dismissal, stale status, unavailable actions and the kill confirmation flow.
4. Render the main pages and affected settings pages at the supported monitor
   sizes, including 57 × 24. Inspect text fit, overlap and overlay dismissal.
5. Provide fresh images and a report of the results. Distinguish simulated
   software checks from any subsequent in-game testing.
6. Update the builder if its sources or assets require it. Build a new installer
   when requested; the presentation work does not require a new installer for
   every revision or a live-save deployment.

## Current visual baseline

- [Illustrated UI simulation report](../../diagnostics/2026-10-26/bundled-ui-start/report.html)
- [Startup overview image](../../diagnostics/2026-10-26/bundled-ui-start/images/startup-overview.png)
- [Test results](../../diagnostics/2026-10-26/bundled-ui-start/results.json)

The baseline uses builder 2.0.0. Its images reproduce captured monitor cells and
colours with a desktop monospace font. Hardware, network delivery and vessel
physics were simulated; the live ship was not operated by those tests.

## Implementation 2: Console interface overhaul

Status: core interface implemented in builder 2.3.0 on 27 October 2026. The
gray Panel Home layout, computer diagnostics, parent navigation, embedded
installation progress and on-demand tools are complete for core. Auxiliary
consoles keep their existing presentation in this release. The live ship has
not been updated for this UI change.

- [Builder 2.3.0](../../releases/builders/Amaryllis-Installer-Builder-v2.3.0.zip)
- [Illustrated report](../../diagnostics/2026-10-27/console-overhaul/report.html)
- [Screen overview](../../diagnostics/2026-10-27/console-overhaul/images/overview.png)
- [Validation](../../diagnostics/2026-10-27/console-overhaul/validation.json)
- [Implementation report](../../diagnostics/2026-10-27/console-overhaul/README.md)

Validation: 15 focused UI cases and 63 regression cases passed. Bundled startup
integration passed 63 checks separately on Lua 5.2 and CC:Tweaked Cobalt. An
update of a copied installation preserved configuration and persistent data.
Screens use simulated telemetry rendered by the exported Lua code and original
CC:Tweaked font. No live deployment has been performed for this UI change.

Core uses an application host adapted in memory from the installed CraftOS
multishell. The native per-process resume function, event filters and service
dispatch are retained. The visible UI does not dispatch flight-worker events.
Service tabs are concealed; tools have a Back header and F1 return. F2 opens or
focuses a recovery shell directly through the host. Drawing failures restart the
UI while healthy workers continue, and reopening startup reuses existing workers.

The new UI source is embedded in the existing core bundle. Core retains five
installed payload files, and this implementation adds no persistent UI files.
Navigation and scroll state stay in memory. Persistent ship values remain in
their existing JSON files. Keep future file divisions purposeful and installed
file counts low.
Computer names are lowercase in lists, detail titles, installation rosters and
issue messages: `chamber-fl`, `bridge`, `hdg-l`, and the other canonical names.

### Existing functions mapped into the application

| Existing console function | New access |
| --- | --- |
| Overview: identity, program/hardware, operation, altitude, selected altitude, propulsion, autopilot, anchor, sampling phases/errors | Home summary and Status > Overview |
| Fleet registry, IDs, package/runtime/hardware health, faults and timings | Computers > individual computer; Status > Fleet diagnostics |
| Detailed lift, altitude authority, startup and chamber data | Status > Flight / Lift |
| Propulsion readiness, controller/unit/drive data and acknowledgements | Status > Propulsion; matched component data under Computer > More details |
| Autopilot and anchor state | Status > Navigation |
| Core logs and scroll anchoring while the bounded log rolls | Logs |
| Events associated with a selected computer | Computer > Related logs; Errors > Related logs, with Back returning to the computer |
| Installer state, current target/file, bytes/percentage, retries, errors and roster | Installation and Installation details; cached progress plus full saved metadata |
| Shell, Lua, diagnostic client | Tools, opened on demand; no automatic shell window |
| Full core monitor and fleet ID editor | Tools > Full core view / edit IDs |
| Remote installation/pairing and remote flight access | Tools > Install / pair remote and Remote flight access |
| Service inspection and UI-independent shell access | Tools > Background services; F2 recovery shell |

Response time uses a measured request/reply duration only. Current core telemetry
does not publish that measurement, so the field displays `--`; report age remains
separate. No network probes were added for these pages. Related logs use events
already collected on core.

### Confirmed goals

- Reduce clutter in the computer's own console interface.
- Move away from presenting concurrent services as a row of user-facing tabs.
- Provide a more graphical, application-like interface with clickable controls.
- Use a gray backdrop and a restrained palette. Avoid a heavily coloured UI;
  distinguish normal controls and sections primarily through gray shades,
  spacing and text contrast.
- Keep mockups faithful to ComputerCraft display capabilities: a fixed character
  grid, the supported palette, bitmap characters and whole-cell rectangular
  controls. Use a 51 × 19 computer console as the initial design target and
  check larger monitor dimensions separately. Do not base the proposed product
  appearance on smooth browser fonts, rounded controls or sub-cell positioning.
- Use Panel Home as the chosen navigation layout.
- Preserve core's per-computer status and diagnostic functionality. The new
  interface must retain individual computer identities, runtime/hardware
  states, available timing measurements, current errors and associated logs.
  Group summaries alone do not satisfy this requirement.
- Preserve concurrent background operation and the responsiveness of essential
  services while the user navigates the console.

### Current architecture relevant to the design

The shared console currently launches shell and diagnostics tabs at startup.
Core also launches independently scheduled runtime, installer and remote-service
tabs, then displays its dashboard. The dashboard has its own numbered pages.
Utility actions can open further tabs.

These are two separate sources of clutter: the service tab strip and the
dashboard's page-navigation controls. The redesign should address both.

Core currently relies on CraftOS-managed worker event queues. Its source
explicitly avoids routing flight-worker timer/peripheral completion events
through the visible dashboard. Replacing this with one shared UI event loop
would need separate scheduling and recovery validation.

### Approved interface direction

- One visible Amaryllis application, opening on a compact Home screen.
- Clickable panels, status indicators, menus and dialogs within the terminal's
  character grid. Fit the computer screen independently of the bridge monitor.
- Home prioritizes computer identity, role, current operation and actionable
  faults. Show details when the relevant panel is opened.
- Home panels: Status, Computers, Installation and Logs, with Tools available
  beneath the panels. Computers is core's entry to the full fleet diagnostics.
- Installation progress remains available inside the application; it does not
  require switching to a worker's terminal.
- Open shell, Lua and diagnostic tools on demand rather than displaying them
  at every boot. Keep an accessible troubleshooting/recovery route.
- Use a shared visual design with role-specific functions on each computer.
- Preserve independently scheduled services. Decide how to replace or conceal
  the service tab presentation without making UI redraws responsible for
  dispatching essential control events.
- A UI failure should permit restarting the interface while healthy background
  services continue running.

Panel Home, the restrained gray presentation, the individual-computer detail
flow and the consistent top-left Back navigation are approved. Use the revised
mockup as the presentation baseline. The approach to the stock CraftOS tab strip
and background service execution remains technical design work. No change to
flight behavior is requested by this interface overhaul.

### Approved mockup and navigation

The approved revised Panel Home mockup uses the CC:Tweaked
terminal's original ASCII bitmap glyphs on a fixed character grid. The preview
can also show a 57 × 24 monitor. Its sample status data and local navigation
demonstrate presentation only; it is not connected to the ship.

Approved screen references:

- [Panel Home](../../diagnostics/2026-10-26/gray-console-mockup/panel-home.png)
- [Individual computer list](../../diagnostics/2026-10-26/gray-console-mockup/computers.png)
- [Computer status and timings](../../diagnostics/2026-10-26/gray-console-mockup/computer-detail.png)
- [Computer errors](../../diagnostics/2026-10-26/gray-console-mockup/computer-errors.png)

Home's Computers panel opens the individual-computer list. Each row shows its
ID, name, state, reply timing and error count. Pagination preserves access to
all computers on the small console. Selecting a row opens its runtime/hardware
state, timing and report age, package state, relevant component state, current
errors and detailed diagnostics. The error view links to that computer's
associated log events. The Home issue shortcut goes directly to the affected
computer.

Use a consistent top-left Back control on every child page. It navigates one
level up in the current section's hierarchy, preserving the selected computer,
list pagination and other local view state. Home is the root and has no Back
button. This replaces the earlier top-right Home/Back placement.

Examples:

- Flight/Lift, Propulsion and Navigation return to Status.
- A computer page returns to Computers, on the same list page.
- Computer errors, detailed diagnostics and related logs return to that computer.
- Installation details return to Installation.
- Shell, Diagnostics, Lua and remote tools return to Tools.
- Status, Computers, Installation, general Logs and Tools return to Home.

Back follows these parent relationships rather than jumping to Home from every
screen. Returning from related logs must preserve the source computer.

Keep timing meanings explicit: response time measures an actual request/reply
interval; report age measures time since the last received status. They are
different measurements. Use `--` when a measurement is unavailable, preserve
historical data with its age, and label stale program/hardware values as last
reported. The prototype's reply values are illustrative. During implementation,
map the existing telemetry fields accurately and identify any unavailable
measurement rather than treating report age as a reply time or adding probes
solely for this visual change.

Before replacing the console, inventory its existing Overview, Fleet, Lift,
Propulsion, Navigation, Logs, Installer and Utilities fields and actions and map
each to the new interface. Preserve access to full diagnostics and remote tools.

### Validation for implementation 2

- Verify that every existing diagnostic field and action remains accessible.
- Check all registered computers, pagination, unavailable measurements, stale
  reports, associated errors and computer-specific logs.
- Check that Back returns to the parent page and preserves computer selection
  and list pagination throughout the approved navigation.
- Inspect the fixed-grid rendering on the computer console and larger monitors.
- Verify that navigation, tools and UI recovery do not interrupt independently
  scheduled control, installer, telemetry or remote services.
- Provide updated images and a report after implementation. The current mockup
  checks validate prototype layout and navigation only.

## Automatic package recovery: builder 2.4.0

Completed 27 October 2026. Builds recover verified sources from the registered
computers automatically. New bundles retain clean package defaults and source
manifests in their existing metadata, so a complete installation no longer needs
its last applied media for later exports. Known older bundles use the builder's
verified legacy JSON defaults. Automatic media discovery supports incomplete
sources, and the manual library field is an optional override.

Core retains no auxiliary package library, and no extra ship file is installed.
Identical program bundles retain object sharing on installer media. The current
reference export remains below the existing 4 MB media capacity.

- [Builder 2.4.0](../../releases/builders/Amaryllis-Installer-Builder-v2.4.0.zip)
- [Recovery report](../../diagnostics/2026-10-27/package-recovery/README.md)
- [Validation](../../diagnostics/2026-10-27/package-recovery/validation.json)

Validation: 21 recovery and 92 regression cases passed. A copied installation
was updated and rebuilt without previous media. Configuration and saved learning
were preserved. Bundles compiled on Lua 5.2 and CC:Tweaked Cobalt. The live ship
was not changed.

## Console host compatibility: builder 2.4.1

Completed 27 October 2026. Fixed the Panel host adapter's rejection of Windows
line endings in CC:Tweaked Unicode Support's ROM override. Added 18-row fallback
layouts and guarded upgrades from the previous embedded Panel revision. Only the
core Panel module changes; flight and PID sources are unchanged.

- [Builder 2.4.1](../../releases/builders/Amaryllis-Installer-Builder-v2.4.1.zip)
- [Cause, fix and validation](../../diagnostics/2026-10-27/console-host-fix/README.md)

Validation: 17 UI/adapter and 54 regression cases passed. Full bundled startup
passed 65 checks for each of three raw host variants on both Lua 5.2 and Cobalt.
The live save has not been modified by this repair.

## Relayed controller status: builder 2.4.2

Completed 27 October 2026. Fixed false WAIT states for the four thrust computers
whose controller reports arrive through chamber relays. Computer pages now show
the existing controller status, age, binding availability, faults and relay.
Program is labelled REPORTING when there is no explicit running flag; catalog
package identities are labelled Package (expected). Direct role-health faults
retain precedence. No probes, hardware writes or additional installed files.

- [Builder 2.4.2](../../releases/builders/Amaryllis-Installer-Builder-v2.4.2.zip)
- [Observation, correction and validation](../../diagnostics/2026-10-27/computer-status-mapping/README.md)

23 UI cases and 41 regression cases passed; bundled startup passed 69 checks on
each Lua engine using the real Unicode/CRLF host and a captured status layout.
The live ship was not modified.

## Keyboard disk installer: builder 2.5.0

Completed 27 October 2026. Disk setup uses Left/Right pages, Up/Down row
selection, Enter activation and an arrow-key YES/NO confirmation defaulting to
NO. Computer-name typing and menu-letter selection are removed.

Assigned roles are gray and cannot be registered again; their owner ID appears
in the row and a simple message. Assignments merges review and correction,
showing all 16 expected computer names, roles and IDs or a dash. Corrections
retain the pre-import/bootstrap-only restrictions and two-computer swap barrier.
Interrupted installation remains resumable on its original computer.

- [Builder 2.5.0](../../releases/builders/Amaryllis-Installer-Builder-v2.5.0.zip)
- [Screen gallery](../../diagnostics/2026-10-27/keyboard-disk-installer/report.html)
- [Report and validation](../../diagnostics/2026-10-27/keyboard-disk-installer/README.md)

19 keyboard/transaction and 50 regression tests passed. The keyboard smoke
fixture passed 18 checks on each Lua engine. The generated disk and instructions
were verified, with no increase in installed file count. The live ship and
existing installer disks were not changed.

## Further implementation groups

New visual and presentation requests will be recorded here with their approval
status before implementation.


## Unified remote panel, 27 October 2026

Implemented in builder 2.6.0: gray Home with Status, Computers, Autopilot, Logs
and Tools; no shell. Parent-level Back navigation retains computer selection and
scroll. All 16 computer states, errors and related logs reuse core telemetry.
Destination editing, reviewed AP requests and result/progress tracking share the
same app. Pairing/permissions are retained; existing remotes are updated by docking
after core receives the release. See diagnostics/2026-10-27/remote-panel/README.md.


## Remote follow-up requirements, 27 October 2026

- Computer details: add Reboot directly beside Errors, More details and Related
  logs. Explicit target confirmation, Cancel initially selected, existing admin
  authorization and verified reconnection required. Pending implementation.
- Status overview: show vessel X/Z, altitude/target, speed, V/S, heading, systems,
  AP phase, active destination/distance and anchor state. Pending implementation.
- Remote AP: always Remote CMD; one-off active route, no destination memory or
  saved entry, no navigator AP > Destination replacement, no destination file or
  route checkpoint. Implemented in builder 2.6.1; target cleared when ended.

### Remote reads and commands, builder 2.6.4

Ship systems/chamber communication keep their existing priority. Within remote
work, cached reads take precedence; only state-changing AP commands use the
acknowledged command queue. Menu navigation is local, active-view refresh is up
to 2 Hz, repeated reads can reuse a bounded-age reply, and rate-limit replies
from older cores no longer show OFFLINE. Direct Reboot and expanded vessel
Overview remain pending.
