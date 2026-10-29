# Amaryllis Installer Builder 2.8.0

A standalone Windows utility for exporting fresh Amaryllis installers from a
Minecraft save. It works offline, independently of this chat and the Codex app.
Build installer reads the chosen save and writes a separate installer folder.
Update existing ship replaces programs in an existing save after a file preview
and a verified external backup. Minecraft must be fully closed for that action.
The separate ComputerCraft settings action edits a selected server configuration.

## Navigator information and assembly continuity

Version 2.8.0 exports the agreed startup wording: OPENING STEAM VENTS,
STATIC INFLATION, CAPTURING PITCH ZERO, ACQUIRING SEL ALT and READY.
Acquisition describes the initial ascent. An accepted selected-altitude change
ends that presentation for the current run. Airborne adoption displays READY.

Lift, autopilot and anchor recovery show RETRYING (#) using attempt counts.
The inactive altitude indicator reads ALT OFFLINE. Limits read MAX CLB and
V/S DEMAND LIM. Kill Lift progress and disarming notices are yellow; the armed
latch reads KILL LIFT ARMED; DISARM BEFORE START in red.

Warnings of the highest active severity rotate every three seconds. Touch the
displayed warning to open Current Issues, focused on that warning. Settings
also opens Current Issues. It lists active notices, their source, available
details and time visible, with four entries per page. Back restores the invoking
view. These navigation actions use the current cached snapshot.

State checks its fresh Sable association first, then the fresh physics-assembler
result. Only an explicit current disassembled result, with Sable association
unavailable, closes the assembly gate. Unresolved checks continue with available
peripheral telemetry. After five minutes, navigator shows the yellow warning
ASSEMBLY UNVERIFIED; OPERATOR CHECK REQUIRED. Successful verification clears it.
Routine verification messages stay in state's logs.

A fresh changed Sable vessel UUID is adopted during assembler uncertainty.
Retained control references, selected modes, target values and saved control
records follow that association. Source calibration is revalidated against fresh
measurements. This UUID is the vessel identity; fleet computer IDs and protocol
credentials retain their existing checks.

The revised assembly gate and information pages preserve applied provider
settings. Stop Systems and Kill Lift retain their existing operator-confirmed
shutdown paths. The current confirmed-disassembly lifecycle remains in place.

The export documentation pass adds section descriptions and short summaries to
major runtime and installer functions. The builder's Python helpers also have
function summaries. Lua token and Python syntax-tree comparisons check that
documentation leaves executable behavior unchanged. Readable runtime bundles
and installed file counts are retained.

Cockpit input frequency pairs come from config.json. Each item is validated as
namespace:item, including modded namespaces, while required inputs and duplicate
ordered-pair checks remain enforced. Existing default pairs are retained.

Build a fresh installer with this version, then use Update existing ship with
that export's media folder to apply the release. The updater's file preview and
external backup cover all registered computers and preserve stored ship data.

## Readable bundled source

Version 2.7.1 writes embedded Lua modules as readable multiline source blocks.
Original indentation, comments and line structure remain visible inside the
single runtime bundle. Installed file counts stay the same.

The builder reads both older escaped bundles and the new readable format.
Source recovery remains byte-exact, including original line endings and Unicode.
Unusual mixed line endings or control bytes use one escaped fragment per line.
The existing runtime loader and module error locations are retained.

Use this builder for subsequent builds and updates of readable bundles. The
normal Build installer and Update existing ship workflow applies. Existing
installed files change only when that update is applied.

## Persistent pilot modes

Version 2.7.0 preserves explicit heading MANUAL/SEL and throttle MANUAL/SEL/DIRECT
selections and their selected values across supported core/navigator restarts.
The existing avionics/data/control-presets.json remains the only preset file.
Successful mode selections invoke saving before their core acknowledgement;
routine target adjustments retain the existing coalesced save cadence.

AP cancellation and anchor release retain the underlying pilot selections and
reset live demands through the neutral-input handover. They no longer force
MANUAL or DIRECT, and the AP-disconnect sample is not reused as a throttle
shortcut. Freshness, identity, neutral-input and lift-readiness gates remain.
Preserving SEL does not itself start ship systems or grant actuator authority.

Update the existing ship through the usual builder/updater path. The updater
preserves existing presets and learned data. Core owns these selections;
navigator displays them and does not need its own preset file. A fresh
installation starts from its ordinary defaults when no saved presets exist.

## Remote refresh and command ordering

Version 2.6.4 makes cached menu navigation local and refreshes the active view
up to twice per second. Core reuses recent status replies instead of rejecting
rapid reads; cached age is preserved. Older-core throttling does not mark the
remote offline. Reads have no request queue. AP mutations retain the existing
acknowledged command queue and core supervision. Ship-control and chamber
processing order is unchanged. Update core and re-dock the remote to load both
sides.

## Builder runtime and error details

Version 2.6.3 makes Start Builder.cmd prefer the existing bundled workspace Python
runtime when available. Other computers continue through the installed Python
launcher/PATH fallbacks. No runtime is downloaded or installed. The window title
shows the builder version, and each build log identifies its Python executable.
GUI failures write a private traceback report under Logs beside the builder;
the popup links that report. Source contents and pairing data are not logged.

## Python 3.14 bundling compatibility

Version 2.6.2 replaces the Lua string encoder generator with an explicit byte
loop. This fixes the Python 3.14.7 failure reporting a list is not an iterator
after source validation. Encoded runtime objects remain identical on Python
3.12 and 3.14. No Python downgrade or Minecraft configuration change is needed.

## One-off remote AP commands

Version 2.6.1 names remote autopilot destinations Remote CMD on both client and
core. They are one-off active targets: they never enter navigator destination
memory, its AP > Destination selection, the saved destination library, or route
restart checkpoints. The remote no longer loads or writes remote/destination.json.
An existing file is left untouched and ignored. The active route target is
cleared when the remote operation ends. Normal onboard destination editing,
saving and ordinary route checkpoint behavior remain available.

Update core and re-dock the remote through Install / pair remote to apply both
sides. Core enforces the fixed name and preserves navigator's destination even
for requests from older clients. An old client's own local file-writing behavior
changes only when that remote receives the new software.

## Unified remote panel

Version 2.6.0 gives the provisioned remote one gray Home interface: Status,
Computers, Autopilot, Logs and Tools. It supports the 26 x 20 pocket screen,
keyboard/mouse input and parent-level Back navigation. No shell is exposed.
Computers includes all 16 roles, errors, report age and related core logs,
including relayed thrust-controller reports. Stale readings remain labelled.
Autopilot editing, review, result tracking and route progress stay in this app.
Existing pairing, permissions and the core flight handlers are preserved.

After updating core through the normal Windows updater, dock an existing remote
and run core Tools > Install / pair remote again to load the new application.
That provisioning path retains its existing pairing and flight-access setting.
The fleet updater does not directly update pocket remotes. The UI replaces an
existing embedded source and adds no installed core file or persistent UI file.

## Keyboard disk installer

Version 2.5.0 replaces typed menu letters and computer names with keyboard lists.
Left/Right changes pages: Setup, Chambers, Thrust, Displays, State and Assignments.
Up/Down moves the cursor, Enter selects, and Escape goes back. A long Assignments
list scrolls vertically so all 16 expected computers remain accessible.

Confirmation dialogs use a YES/NO selector. Left selects YES, Right selects NO,
and Enter confirms the selected choice. NO is selected initially. Escape cancels.

Assigned roles are gray on registration pages. Focusing one shows its owner ID;
Enter cannot register it again. A matching interrupted installation can resume
on its original computer. No other completed assignment is overwritten.

Assignments combines the old review and correction screens. It shows each
computer name, role description and assigned ID, or a dash when unassigned.
The current computer is highlighted in yellow. Read-only rows direct you to
revisit the desired computer with this disk.
Enter on a destination role previews a correction for the current computer.
A swap lists both computers and must be completed on both before import.
Core/state, imported assignments and installed packages retain their correction
restrictions. Pending plans can be inspected and finished from Assignments.

These changes stay within the existing disk setup.lua and temporary commissioning
helper. No additional file is installed. Previously built disks keep their old
interface; create a new installer with 2.5.0 to get the keyboard version.

## Relayed controller status

Version 2.4.2 uses the existing propulsion-controller reports for computers whose
status is relayed through a chamber. Their status page shows report age,
controller binding availability, faults and the relay source. A fresh report
without an explicit program-running flag is labelled REPORTING. Direct role
health flags retain precedence. Stale reports remain stale.

When only core's package catalog supplies a package identity, the page labels
it Package (expected). A directly reported package remains labelled Package.
Response time stays unavailable unless an actual request/reply measurement exists.
No additional radio probes or hardware writes are introduced.

## Console host compatibility

Version 2.4.1 handles Windows line endings in resource-pack overrides of
CraftOS multishell, including CC:Tweaked Unicode Support 1.0.1. The adapter
normalizes line endings before applying its guarded presentation changes.
The native per-process event filtering and scheduling code remains intact.

Normal startup provides the full 51 x 19 console without service tabs.
If the host adapter cannot be used, Panel Home also fits a 51 x 18 tab window.
This avoids a resize-only screen on the standard advanced computer.
Older 2.3.0/2.4.0 Panel bundles upgrade through the normal build/update flow;
stored settings and learned values are retained.

## Automatic package recovery

Select the saved ship and an output folder, then click **Build installer**.
Leave **Package library override** blank. The builder recovers the auxiliary
package sources automatically from the registered computers and verifies every
program against core's saved package catalog. It checks each computer's role,
ID, committed installation receipt and package version before accepting it.
The build log and build-report.json identify the source that was used.

A complete installation made with builder 2.4.0 or later contains everything
needed to rebuild its package library. The original manifest and clean package
configuration are stored inside each existing auxiliary runtime bundle. These
are release defaults, without installed IDs, sessions or pairing credentials.
No extra file is installed, and core keeps no duplicate package library.
The source metadata does not execute at runtime.

For the existing reference installation, the builder includes verified legacy
JSON metadata for its earlier bundles. Actual executable code is recovered
from the ship and must match core's catalog exactly. Unknown older bundles
may still require their media if their original defaults cannot be recovered.

If a registered computer is missing, incomplete or does not match the catalog,
the builder searches the save's ComputerCraft disk folders and the utility's
usual Installers folders for a verified matching library. It checks catalog
identity and all object hashes; folder dates do not decide which release to use.
You may select a library manually in **Package library override** when it lives
elsewhere. An explicit incompatible override produces an error.

A partial or damaged ship with no complete matching source cannot be rebuilt
by guessing. Restore its missing source from backup or provide matching media.
Installer media remains useful for in-game installation, updates and repairs;
you do not need to retain it solely to rebuild a complete 2.4.0+ installation.

## Core console: Panel Home

Version 2.3.0 adds the gray Panel Home application to core. Home opens Status,
Computers, Installation, Logs and Tools. Computers lists all 16 registered roles,
with IDs, state, reply timing when measured and current error counts. Selecting a
computer shows its reported program/hardware state, report age, package, component
details, errors and related core log events. Stale values are labelled as last
reported. Reply time remains `--` when telemetry has no measured request/reply
duration; report age is shown separately. Opening these pages adds no probes.
Computer names use lowercase throughout, such as `chamber-fl`, `bridge` and `hdg-l`.

Every child page has a top-left **< Back** control. Back returns one level up and
retains the selected computer, list page and diagnostic scroll position. Related
logs return to the source computer. Installation shows cached transfer progress
and the per-computer package roster within the application.

Core's concurrent services use the CraftOS process scheduler inside the
application host. Service tabs are concealed. Shell, Lua, diagnostics, the full
core view/ID editor, remote pairing and remote flight access open from Tools.
Tools have a top-left Back header; **F1** also returns to Tools. **F2** opens or
focuses a recovery shell through the host, independently of UI drawing.
The interface restarts after a drawing failure while healthy services keep
running. Reopening startup focuses the existing application and reuses workers.

The initial console target is 51 x 19; the renderer also supports larger grids.
The host adapter validates the installed CraftOS scheduler's structure before
using it. Its per-process event dispatch and filters are retained. Core's flight,
PID and actuator source modules are unchanged by this presentation update.

In the default bundled export, the UI module stays inside core's existing runtime bundle. Core's installed
payload remains five files including its configuration and catalog. Existing
learning and runtime records remain separate. This change adds no installed UI files or persistent UI data files.
Navigation state stays in memory. Existing persistent data remains in its JSON
files. Auxiliary consoles and their packages retain their current presentation.

## Bundled installations

Version 2.1.0 includes the bridge's Systems menu and presentation update.
`SYSTEMS` / `Options [v]` offers Start Systems, Stop Systems, Restart Systems
and Kill Lift. The kill option retains its confirmation dialog and becomes
Disarm Kill when the existing latch requires disarming. Menu selections use
fresh availability checks; an outside touch closes the menu without activating
the control underneath. Existing Stop Systems confirmation remains in place.

The flight readout uses `V/S`, chamber diagrams use `^ BOW ^`, debug disk/log
instructions use the approved wording, and the display specification footer is
removed. The bridge package version advances once; rebuilding the same source
does not keep incrementing it. This update changes bridge presentation only.

Version 2.0.0 bundles installed Lua modules by computer. Configuration, saved
learning and recovery records remain separate writable files. The editable
source files in the selected save are preserved.

With the current reference source, core's payload is seven files including two
learning files, STATE is three files, and each of the 14 wireless packages is
three files. Startup/updater support and records created during operation add
to those totals. The exported disk occupies approximately 3.3 MB; use the
exact capacity in the build report.

Bundles preserve named source modules, original error locations, worker entry
points and task-local module caches. Workers continue using the existing
supervision and restart logic. Core retains client source needed to provision
remote computers inside its bundle. Auxiliary transfer destinations remain an
exact allowlist and use the existing checksums, staging, commit and rollback.

The builder verifies and extracts embedded sources when exporting a bundled
ship again. Package recovery is automatic; a media override is optional. Rebuilding
preserves package versions and does not nest bundles. Damaged sources, an
unknown loader or conflicting loose/bundled files stop the export.

Version 2.2.0 adds offline migration of existing loose-file and bundled ships.
Automated Lua 5.2, installation, rollback, worker-loader and rebuild checks cover
the reference source. In-game flight acceptance remains a commissioning step.

## Update an existing ship

Version 2.2.1 corrects the auxiliary startup launcher so it retains CraftOS's
program environment, including shell.run and require. The missing environment
could leave all auxiliary consoles repeatedly reporting an attempt to call a nil
value while core continued to run.

To repair an installation affected by this specific launcher bug, fully close
Minecraft, open **Update existing ship…**, select the target save, and click
**Preview startup repair**. A media folder is unnecessary for this action.
Review the 14 auxiliary startup.lua replacements, choose an external backup
folder, select the closed-game checkbox and click **Apply update**. Core, state,
installed bundles, settings, PID learning and package receipts remain unchanged.
The normal update path also corrects this known launcher when using older media.

1. Build or obtain the installer containing the desired software.
2. Save and fully close Minecraft, including any server using the save.
3. Open **Update existing ship…** in the builder. With a distributed installer,
   run **windows-update/Update Amaryllis.cmd** instead. That helper is included
   in the installer ZIP and works independently of the builder.
4. Select the existing save or its numeric core computer folder.
5. Select the new installer's **media/** folder. The distributed helper selects
   its adjacent media folder automatically. An older installer can also supply
   a bundled release to this updater.
6. Select an existing backup folder outside the save and installer media.
   The utility can create its default **Backups** folder beside itself.
7. Click **Preview update**. Review each Add, Replace, Remove and Keep entry.
8. Select **I have saved and fully closed Minecraft**, then click **Apply update**.
   Confirm the reviewed replacement. The utility also checks running processes.
9. Wait for **Update complete and verified**, then load the world. Existing
   computer IDs and roles are retained. Programs load on the existing computers.

All 16 registered computers are updated together, including core and state.
The same tool supports loose-file migration and later bundled updates. Each
computer has one installed runtime bundle; obsolete loose program files and
core's old package library are removed. The helper does not create extra
computer directories, worker tabs or alternate startup programs.

Existing configuration values take precedence over release defaults. The update
retains PID settings, input tuning, learned corrections, pairings, hardware
bindings, fleet assignments and all files under **avionics/data/** byte-for-byte.
New settings receive release defaults. Transfer size limits increase as needed
to support the bundled packages. The new installer's optional learning defaults
do not replace the target ship's learning. The updater retains the verified
installation's historical receipt identity and updates its package version and
checksum. Runtime authority still requires the normal live core/session checks.

Reserved program locations are **avionics/**/*.lua** outside **avionics/data/**,
installer Lua helpers and staging/backup files, root startup/installer programs,
and core's **packages/** library. These are overwritten or removed according to
the release. Old config/status temporary copies are removed after backup.
Other user files are retained. Keep personal programs outside these reserved
locations. ComputerCraft's computer IDs and block labels are not reassigned.

Each operation creates **Amaryllis-update-.../** outside the save, containing a
verified original snapshot, file hashes, the preview and a transaction journal.
Replacement staging is removed after completion. A write failure restores the original files. After an
interruption, keep Minecraft closed, open **Restore backup…**, and select that
transaction folder. The save's **computercraft/computer/.amaryllis-update.json**
records its location and blocks another update until recovery completes.
Restore checks the backup and target hashes and refuses newer user edits.
Do not delete the transaction folder while an operation needs recovery.

The updater requires a complete registered installation with matching committed
receipts. It refuses unfinished installs, duplicate registered IDs, a package
downgrade, changed files since preview, damaged media and linked/junction paths.
It does not repair incorrect physical computer placement or detect an assembled
duplicate sharing the same ComputerCraft IDs. Unknown registry or bundle formats
require updated support in the utility.

Version 1.6.0 includes automatic lift-handshake recovery in exported core software.
An expired control/probe lease or missed lift-command acknowledgement suspends
feedback, retains the operation and applied lift, and retries after validating
fresh identity, hardware and provider readbacks. During recovery, chambers that
still own control renew their observed targets while expired peers re-probe.
Altitude control resumes after verified acknowledgements. Operator stops, lift
kill and incompatible identity or hardware changes retain their existing guards.
This update does not change PID gains or export a new installer automatically.

Version 1.7.0 separates stale/incomplete vessel telemetry and unavailable vessel
identity from a fresh, valid sample confirming another vessel. Missing data waits
for revalidation and preserves lift. A confirmed identity change remains blocked.
Aborted operations can recover partially applied commands by restoring core's
retained absolute target map after identity, hardware and target-limit checks.

Version 1.7.1 uses computer names in setup choices, confirmations, assignment
reviews and correction plans: `chamber-fr/fl/br/bl`, `thrust-rs/ls/rb/lb`,
`bridge`, `hdg-l/r/m` and `state`. Core and primary computers use `core`,
`primary-l` and `primary-r`. Select names with Up/Down and Enter. These names map to the existing
internal roles and fleet labels.

## Run it

1. Extract the whole utility ZIP to a normal writable folder. Keep `builder.py`,
   `bundling.py`, `presentation.py`, `updater.py`, `Start Builder.cmd`, `cc_settings.py` and the `assets` folder together.
2. Double-click **Start Builder.cmd**.
3. Browse to your Minecraft save, its `computercraft/computer` folder, or the
   exact numeric core computer folder.
   Leave **Package library override** blank for automatic recovery. Select a
   matching media folder there only when the builder cannot recover all sources
   and your media is outside its automatic search locations.
4. Choose an output folder outside the save. The default is `Installers` beside
   the utility.
5. Leave **Include this ship’s saved hover and leveling corrections** checked
   to export its current saved learning.
6. Click **Build installer**. When verification completes, use **Open result**.

The utility needs Python **3.11 or newer with Tcl/Tk**, included with the normal
Windows Python installer. No pip packages, network connection or account are
needed. The launcher tries the Windows Python launcher, an existing local Codex
Python runtime when available, then Python on PATH. That runtime is used as an
ordinary local interpreter; the app does not need to be running or signed in.

For a consistent snapshot, saving and exiting the world before export is best.
Export can also work with the world running, but the build refuses completion
if any file it read changes during the export. Retry after saving/exiting if so.
It exports saved files, which may differ from the code currently loaded in-game.

## What you get

Every build creates a uniquely named `Amaryllis-...` folder containing:

- **amaryllis-installer.zip**: the distributable installer, including media and
  installation instructions.
- **media/**: files to copy onto a fresh, writable in-game installer disk.
- **README.md**: instructions and required disk capacity.
- **windows-settings/**: a standalone Windows capacity/thread editor, also included
  in the distributable ZIP. Keep it on Windows; do not copy it to the in-game disk.
- **windows-update/**: the standalone existing-ship updater and restore utility,
  included in the distributable ZIP. Keep it on Windows.
- **build-report.json**: a local audit report with the selected source path,
  file hashes, package versions, included learning and validation results.

Share the installer ZIP. The local report contains your source path and IDs
and is deliberately omitted from that ZIP. Old outputs are never overwritten.
Failed output stays clearly named `Amaryllis-INCOMPLETE-...`; do not use it.

The bundled installer disk currently needs approximately **3.3 MB** of capacity,
and computers need the supported **4 MB** capacity. Use the actual numbers in
each build report. This utility does not change CC capacity settings.

## What a fresh installer preserves

- Current core code and auxiliary package sources from the selected core.
- Its configured PID gains, input tuning and other portable configuration.
- Optional saved hover-offset bands and leveling bias from that core.
- Labels from the fleet registry. Computer IDs are reassigned during installation.

Learning defaults install only when the new core has no corresponding local
learning file. They continue adapting during flight. Changed loading or balloon
geometry may need further learning.

Logs, restart checkpoints, live PID integrals, kill/armed state, remote pairing
credentials and installed role assignments are excluded. Propulsion and
commissioning begin disabled; hardware discovery and role registration establish
the new installation's connections. The known rear-chamber direction frequencies
are normalized to Amaryllis' physical blueprint convention.

The utility exports packages from an older core's local library or recovers
verified bundles from the registered auxiliary computers. Recovered programs
must match the catalog exactly; mixed versions are refused. Automatic media
discovery and an optional manual override support incomplete and older installs.
Bundled exports use the utility's bootstrap client, which supports the compact
package layout. Loose exports can reuse the registered navigator's compatible
client. The disk's commissioning scripts are bundled support assets.

## Checks and limits

The builder checks the standard 16-role registry, duplicate identities, JSON,
package manifests, missing package files, transfer-size bounds, state-reader
dependencies, saved-learning schemas, output hashes, ZIP contents and source
consistency. It rejects linked/junction source files and output inside the save.

These checks do not compile Lua or prove that a version flies correctly. Test
your version in-game before distributing it. Package semantic compatibility
cannot be established from file hashes alone. If a future Amaryllis release
changes registry, package or learning schemas, update the utility's support code
and assets for that format; it fails rather than guessing unknown formats.

## Setup and mistaken assignments

New installer disks show the current computer ID and its registered role, use
computer names with full descriptions, and ask for confirmation before assignment.
Use Left/Right to open Chambers, Thrust, Displays or State, then select the
computer with Up/Down and Enter. Left and right are defined while facing the bow.
Assigned roles are gray on registration pages and show their owner ID.
Assignments lists all expected computers and their IDs, with a dash for an
unassigned role. This is registration progress, not package verification.

Before importing assignments on core, open Assignments on a registered auxiliary
and select its intended destination role with Enter. An occupied destination creates an explicit two-computer
swap. Carry the same disk to every listed computer, boot from it with runtimes
stopped, and resume the correction there. Core import is blocked until every
step finishes. The disk retains the previous assignment snapshot and progress;
an interrupted step can be repeated. A two-computer plan must be finished,
because setup cannot verify a remote computer's outcome to cancel it safely.

This correction mode applies to registration bootstraps only. It refuses core,
state-reader and already installed packages, pending package transactions,
legacy disks without correction metadata, and assignments already imported into
core. It never changes an installed hardware role by changing its label alone.

Core import requires all 16 roles. After import, choose **Start core with disk** from Setup
and leave the disk connected while core distributes the role packages.
A temporary installation screen on receiving
auxiliaries shows the local computer, role, core and transfer state. After the
durable status and application receipt match, with no unfinished commit, it
deletes its own helper file and reboots into the normal console. The tiny
startup launcher, normal package updater, trust configuration and recovery
records remain. The reusable setup interface stays on the installer disk;
it is never copied onto core.

These changes apply to installers exported with this builder version. Existing
installer disks and installed ships are not retroactively modified.

## Duplicate computer identity warnings

New exports include an onboard advisory for copied computers competing with the
registered ship. It uses existing registry and status traffic, with no additional
sensor polling or periodic network messages. The Windows diagnostic host is not
required for detection.

Core watches for a different active core session using its own computer ID, and
for two boot identities that continue advancing within one assigned computer's
status stream. It requires repeated observations over time. One changed boot,
a burst, replayed sequence or ordinary reboot does not by itself raise a warning.
Separate lift, relayed thrust and role-console identities are tracked separately.

The bridge's Flight and Ship views display **POSSIBLE DUPLICATE ID #...**. Core's
monitor shows the affected role and evidence, and its log records warning onset
and clearance. The warning clears after competing traffic has remained quiet.
Emergency lift and assembly warnings retain their existing Flight-row priority.

This is advisory evidence, not proof of a second physical hull or an authentication
mechanism. It does not shut down, reassign IDs, change sessions, extend leases,
reset controllers or change PID behavior. A copy must be loaded, running and able
to exchange relevant traffic to be detected. An offline or silent copy cannot
be identified this way. A delayed legacy registry stream can warrant a possible-
duplicate warning, so inspect the reported identities before making changes.

When creating another independent Amaryllis, use distinct computer IDs and run
its own role registration. A copied blueprint may retain the original IDs.
This builder update does not install itself onto the running ship.

## Core's installer tab

New exports include the builder's progress display in core's existing installer
tab. It shows all 14 expected wireless package roles, including missing IDs,
waiting computers, sending, verification, completion and faults. The active
transfer shows its acknowledged-byte percentage, file and retry count. A transfer
at 100% is still waiting for commit verification. DONE requires the sender's
validated installed acknowledgement or its existing strict up-to-date check.

The roster retains faults when another computer becomes active, marks all-package
completion explicitly, and rechecks results after identity/session changes.
The state reader uses direct disk setup and is identified separately; this view
does not claim to have verified its wired link or any hardware behavior.

The display reads cached installer state only, redraws at most twice a second,
and does not poll peripherals or add network messages. Existing server behavior
isolates a display failure from the download process. The normal installer
service checks for auxiliary updates while matching media is inserted. Without
media, it idles and displays **Insert matching installer disk**.

The builder overlays the progress display and a read-only disk package adapter,
adds disk-presence checks to the existing sender's authority checkpoints, relocates
core's console to `/avionics/common/console.lua`, and changes core's role-version
lookup to local metadata. It records these overrides in the build report.
The transfer protocol, strict receipts, fleet identity checks and flight controller
come from the selected source save. Unknown sender layouts are refused.

## Removable package library

New cores receive their own flight software, console, installer service and a small
trusted package catalog. They receive **no `/packages` directory**. All auxiliary
program sources stay as verified objects on the installer disk. In our current
source snapshot the core payload is about 1.19 MB and the library is 2.62 MB;
actual figures are recorded in each build report. Objects shared between packages
are stored once on disk.

After installation you may remove the disk. Core's flight software, role health
checks, remote operation and existing auxiliary programs continue without it.
Removing the disk during a transfer retires the transfer before commit; existing
receiver recovery records handle unfinished writes. Reinsert the matching disk
to resume package checking and auxiliary repair. A damaged object, wrong catalog
or several matching disks prevents installation rather than changing flight control.
The package adapter yields while verifying large files and keeps the existing
bounded RAM cache; it does not write a package cache onto core.

For a newer **auxiliary** library, boot core from that disk so its flight runtime
has not started. Choose
**U Adopt auxiliary library**. This explicitly checks the registered fleet,
core runtime compatibility, catalog and every library object before replacing
the local version catalog. Then choose **S** to start core with that disk.
Changing a core/state program is outside this action: a different core runtime
is refused and needs an offline software upgrade. Saved calibration, flight
settings, fleet IDs and pairings are preserved by library adoption.

Keep media available when you need in-game installation or repair. Complete
ships built with 2.4.0+ can be exported again without the old media. The builder
checks all recovered source files and any media it used for changes during export. This change applies to
new installations; exporting does not migrate or delete an existing ship's
`/packages` folder. Do not delete that folder manually on an older core: its
startup and version checks still depend on it.

## ComputerCraft capacity and threads

Use **ComputerCraft settings…** in the builder, or **Configure ComputerCraft.cmd**
in an exported installer's `windows-settings` folder. The latter works without
the builder or this chat, using the same Python 3.11+ runtime requirement.

Select the actual **computercraft-server.toml**, load it, choose capacities in MB
and a thread count, then preview the exact values and scope before applying.
Common locations include an instance's `config` folder or a world's `serverconfig`
folder. If several candidates exist, choose the active file explicitly. JSON,
client settings and unknown layouts are refused rather than guessed.

The editor changes only `computer_space_limit`, `floppy_space_limit` and
`execution.computer_threads`. It preserves unrelated settings, comments, HTTP
rules and line endings. Capacity changes only increase limits and require at least
4,000,000 bytes. Higher existing capacities stay as the defaults. Threads default
to their current value, with 1–64 supported by this utility. Raising threads can
affect lag and mod compatibility; no thread count is inferred from CPU count.
The main-thread time budgets are not altered.

Minecraft/server must be fully closed. Apply requires your acknowledgement and
also checks running Java processes for Minecraft/instance indicators. This process
check is conservative and cannot establish every possible custom launch method;
the closed-game acknowledgement remains necessary. Close the game yourself and
restart after editing. Exporting an installer never invokes the settings writer.
If command-line inspection is restricted, a native Windows fallback permits
changes only when no Java process is running; other Java applications must then
be closed too.

Each actual change saves a verified `.amaryllis-...bak` beside the selected file,
with a small JSON hash record, before an atomic file replacement. New edits are
refused if the file changed after preview. **Restore backup…** verifies both the
backup and current file before restoring the exact earlier settings. It refuses
to overwrite newer manual edits. Restoring also returns the old capacity limits;
do it before relying on increased storage for additional files.

The settings file's scope is shown in the preview. An instance-wide file affects
all worlds using that instance. The editor does not change the running instance
or upload a mod configuration from an in-game ComputerCraft program.

## Command-line use

```text
py -3 builder.py --source "D:\Minecraft\saves\My Amaryllis" --output "D:\Amaryllis Installers"
py -3 builder.py --source "D:\Minecraft\saves\My Amaryllis" --output "D:\Amaryllis Installers" --without-learning
py -3 builder.py --source "D:\Minecraft\saves\My Amaryllis" --library "D:\Previous Installer\media" --output "D:\Amaryllis Installers"
py -3 updater.py --source "D:\Minecraft\saves\My Amaryllis" --media "D:\New Installer\media"
py -3 updater.py --source "D:\Minecraft\saves\My Amaryllis" --media "D:\New Installer\media" --apply --backup "D:\Amaryllis Backups" --minecraft-closed
py -3 updater.py --restore "D:\Amaryllis Backups\Amaryllis-update-..." --minecraft-closed
py -3 updater.py --source "D:\Minecraft\saves\My Amaryllis" --repair-startup
```

The output parent folder must exist. The graphical interface creates its own
default `Installers` folder if needed. Keep the entire utility folder when
moving it to another PC; no paths or usernames from this development workspace
are required.
