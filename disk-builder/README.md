# Amaryllis Disk Builder

Build installation media from maintained Amaryllis source and update an existing
installation. The utility works offline on Windows.

Release history is in [CHANGELOG.md](CHANGELOG.md).

## Requirements

- Python 3.11 or newer with Tcl/Tk.
- A writable utility folder. Keep the extracted utility, `assets/` and any
  included `source/` directory together.
- Access to the world's files when updating a ship.

Double-click **Start Builder.cmd**. The launcher uses an available local Python
runtime or the installed Windows Python launcher/PATH. The window title shows
the utility version, and build logs identify the interpreter used.

## Software source

The builder reads programs and configuration from the maintained project source.
The project folder is selected automatically when maintained source is present.
Standalone utility ZIPs include their release's source snapshot and revision
record. Git is optional.

## Build from project source

1. Open **Start Builder.cmd**.
2. Check **Amaryllis project folder**. In the repository, select the folder
   containing `project.py` and `source/`. In a standalone utility, select the
   extracted utility folder containing `source/`.
3. Choose whether to **Include shipped hover and leveling defaults**.
4. Click **Build installer**.
5. Read **Saved to** or click **Open result** to locate the completed build.

The selected project supplies core, state and auxiliary programs. New installs
use its configuration defaults. Included learning seeds missing local learning
files and continues adapting during operation.

Project releases record the source commit, uncommitted-change status and input
fingerprint in release metadata, the generated README and the local build report.
The updater displays this provenance and retains it in installation records.

## Build output

Graphical builds create a separate `Amaryllis-...` folder under `Installers/`
beside the utility.

| Item | Contents |
|---|---|
| `amaryllis-installer.zip` | Distributable installation package |
| `media/` | Files copied onto the installer floppy disk |
| `README.md` | Release instructions and required storage capacity |
| `windows-settings/` | Standalone ComputerCraft settings utility |
| `windows-update/` | Standalone updater and backup restore utility |
| `python/` | Bundled Windows Python with Tcl/Tk used by both helpers (present when built on Windows) |
| `build-report.json` | Local source paths, hashes, versions, learning and verification results |

Share `amaryllis-installer.zip`. The local build report contains source paths
and computer IDs and stays outside that ZIP.

Programs are bundled by computer, with readable embedded source and original
module names. Configuration and persistent records remain separate. Identical
objects shared by packages are stored once in `media/objects/`.

Use the exact floppy disk capacity in the generated README. Current media is
approximately 3.3 MB; supported computer capacity is at least 4,000,000 bytes.
The settings utility applies storage changes separately.

Failed builds remain labelled `Amaryllis-INCOMPLETE-...`. Use the completed build
identified by the verification message.

## Update an existing ship

**Update existing ship...** opens the updater with the maintained project folder
selected. **Preview update** bundles the current source in a temporary workspace
and shows the exact replacement files. No installation disk, distribution ZIP or
Windows helper package is exported for this operation. Applying checks that the
project inputs still match the preview. Source edits require a fresh preview.
Temporary update files are removed after completion, replacement of the preview
or closing the updater.

The distributed `windows-update/Update Amaryllis.cmd` helper uses its adjacent
installer release. An explicit `--media` argument also selects a released installer.

1. Select the destination save or its numeric core folder.
2. Check the Amaryllis project folder, or the release media in a distributed helper.
3. Select a backup folder outside the save and temporary update files. The utility can
   create its default `Backups/` folder.
4. Click **Preview update** and review the Add, Replace, Remove and Keep entries.
5. Click **Apply update** and confirm the reviewed replacement. The world can stay
   open: ComputerCraft supports replacing a running computer's files and every
   write is atomic. Files the running computers rewrite on their own
   (`installer/install_status.json` and everything under `avionics/data/`) are never
   touched, backed up or compared. If a program or stored setting changes between
   preview and apply, the update stops and names the file; preview again.
6. Wait for **Update complete and verified**. Running computers keep their current
   program until they reboot; reboot each one (or reload the world) to use the new one.

All 16 registered computers are updated together. Programs are overwritten and
obsolete managed files are removed. IDs and assignments are retained. Stored
configuration takes precedence over release defaults; new settings receive their
release defaults. PID settings, input tuning, pairings, hardware bindings and all
`avionics/data/` files are preserved. The target ship retains its own learning.

Managed locations include program files under `avionics/` outside `avionics/data/`,
installer helpers and staging records, root startup/installer programs, and the
old `packages/` library. Keep personal programs outside those locations.

Preview requires a complete registered installation with matching committed
receipts. Checks cover role identities, package versions, object hashes,
unfinished transactions and target changes since preview.

### Restore a backup

Each update creates an `Amaryllis-update-...` folder outside the save containing
the originals, hashes, preview and transaction journal. A write failure restores
the originals. Replacement staging is removed after successful completion.

To restore, select **Restore backup...** and choose the transaction
folder. Restore verifies the backup and checks for newer target edits. Interrupted
updates are recorded in `computercraft/computer/.amaryllis-update.json`; use its
named backup to finish recovery before applying another update.

## Web install (Pastebin)

Every push to `main` on GitHub runs `.github/workflows/release.yml`, which builds
the media folder from the repository source and publishes it on the `release`
branch. The Pastebin loader (`media/loader.lua`, with the repository filled in)
looks up the newest release commit and runs `web-setup.lua` from it, so every
computer of one installation uses the same build. Computers need HTTP (on by
default) and a modem. The loader is published at
[pastebin.com/bn1RbWtb](https://pastebin.com/bn1RbWtb); its source is
`tools/pastebin/loader.lua`.

1. On core, run `pastebin run bn1RbWtb` and choose **1 Install core**. Core
   downloads its programs, installs, and opens its registration screen. Until
   the assignments are imported, core boots back into this screen.
2. On each other computer, run `pastebin run bn1RbWtb` and choose **2 Register
   this computer**. It finds core over rednet, downloads core's release, and
   lists the roles with their holders. Pick a role: core records it, and the
   computer installs its wireless receiver (the state reader installs its own
   programs) and reboots to wait for core.
3. Back on core, once all 16 roles are registered, press **Enter** to import
   the assignments. Core restarts with its own startup and installs each
   computer's role package over wireless, fetching the packages from its
   pinned web release.

Fixing mistakes:

- A computer's screen after registering is its commissioning screen. Hold
  Ctrl+T to stop it, then run the loader again.
- Wrong role, before import: run the loader on that computer and pick the
  right role; core moves its assignment. Backspace on core's screen clears the
  selected role.
- **3 Remove this computer's registration** on a computer deletes its receiver
  (or the state reader's programs) and asks core to clear its role. A computer
  that already runs its role package keeps it; use a reset instead.
- **R** on core's screen resets the installation: core restarts into
  registration with every assignment cleared. Computers keep their programs
  and settings and register again with the same roles.
- **U** on core's screen uninstalls core before import and deletes its files. Package objects stay on the `release` branch across releases,
so an installed core keeps serving its own release. The floppy-disk route below
still works and is kept as a fallback.

## Installer floppy disk

Copy the **contents** of `media/` onto a writable ComputerCraft floppy disk.
Its root contains `startup.lua`, `setup.lua`, `release.json`, `library.json`
and `objects/`.

1. Install core first, then carry the same floppy disk and temporary disk drive
   between the other 15 computers to register their roles.
2. Review **Assignments** and complete any corrections before import.
3. Return the floppy disk to core and select **Import assignments into core**.
4. Select **Start core with disk** and leave the floppy disk inserted while core
   distributes packages.
5. Open core's **Installation** page and wait for all 14 wireless packages to
   verify. Check state's wired connection separately.
6. Remove the installer floppy disk and temporary disk drives after completion.

The installer records the existing ComputerCraft IDs for the selected roles.
Core keeps its own software and a package catalogue. Auxiliary package sources
remain on the floppy disk. Installed computers run from their local programs.
A receiving auxiliary's temporary installation helper removes itself after a
verified package receipt and reboots into its normal console.

### Navigation and assignment corrections

- Left/Right changes pages; Up/Down selects; Enter activates; Escape goes back.
- Confirmations initially select NO. Left selects YES, Right selects NO, and
  Enter confirms the selected choice.
- Assigned registration rows are gray and show their owner ID. The current
  computer's row is yellow in Assignments.
- To correct a bootstrap assignment, visit that computer with the same floppy
  disk and select its intended role in Assignments. An occupied role creates
  a swap; visit both listed computers to finish it.

Corrections are available before core import for auxiliary registration
bootstraps. Core, state and computers with full packages use their corresponding
installation or update procedures. Interrupted registration can resume on its
original computer.

### Reset commissioning

After core installation, the red **Unassign core** action opens a confirmation
that defaults to **CANCEL**. **RESET INSTALLATION** clears the floppy disk's
assignments, import status and correction plan, and removes core's fleet registry
and its automatic recovery copies.

Run reset on the registered core with its runtime closed. Re-registering the
same computers retains their programs, configuration and learned data. Use the
original core for retained auxiliaries. Register all 16 roles and import the
assignments again. **Resume installation reset** continues interrupted cleanup.

### Adopt an auxiliary package library

Boot core from the desired floppy disk with its runtime stopped. Select
**Adopt auxiliary package library**, review the confirmation, then select
**Start core with disk** after adoption.

Adoption verifies the fleet, catalogue, objects and compatibility with core's
installed runtime before replacing the trusted catalogue. Stored settings and
learning are retained. Use the Windows updater to replace core or state software.

## ComputerCraft settings

Open **ComputerCraft settings...** or run the installation package's
`windows-settings/Configure ComputerCraft.cmd`.

Select the active `computercraft-server.toml`, click **Load settings**, choose
capacities and a worker count, preview the values and their scope, then apply.
The worker count initially shows the existing value. The utility edits:

```text
computer_space_limit
floppy_space_limit
execution.computer_threads
```

Capacity changes only increase limits and require at least 4,000,000 bytes.
Use the larger requirement from the generated installer README. The worker
selector supports 1-64. Unrelated settings, comments and line endings are preserved.

Minecraft/server must stay fully closed while applying (unlike ship updates), and
the interface asks you to acknowledge this. Each change creates a verified `.amaryllis-...bak` and JSON hash
record beside the configuration. **Restore backup...** verifies the saved copy
and current file before restoring it. Restart Minecraft/server after editing.

## Verification and troubleshooting

Build verification covers the project source layout, JSON, roles, package
manifests, transfer bounds, state-reader dependencies, learning records, object
checksums, source consistency and ZIP contents. Lua compilation, regression tests
and in-game acceptance are separate project checks.

| Result | Action |
|---|---|
| Source changed during build | Finish source edits, then build again. |
| Missing or mismatched package source | Restore the project's package source files. |
| Incomplete installation or transaction | Finish the recorded operation before updating. |
| GUI build error | Read the message and its private traceback report under `Logs/` beside the utility. |
| Unsupported schema or bundle format | Use builder support that matches the source format. |

## Command-line use

Run these commands from the utility directory. The output parent must exist.

```text
py -3 builder.py --project "D:\Amaryllis Source" --output "D:\Amaryllis Installers"
py -3 builder.py --project "D:\Amaryllis Source" --output "D:\Amaryllis Installers" --without-learning
py -3 updater.py --source "D:\Minecraft\saves\My Amaryllis" --media "D:\New Installer\media"
py -3 updater.py --source "D:\Minecraft\saves\My Amaryllis" --media "D:\New Installer\media" --apply --backup "D:\Amaryllis Backups"
py -3 updater.py --restore "D:\Amaryllis Backups\Amaryllis-update-..."
```

From the repository root, `python project.py build` builds current source and
`python project.py update --target "D:\Minecraft\saves\My Amaryllis"` builds
and previews an update. See the [project README](https://github.com/DarkLugia4000/amaryllis-source/blob/main/README.md)
for development commands and the [owner's guide draft](https://github.com/DarkLugia4000/amaryllis-source/blob/main/docs/installation/Amaryllis-Owner-Installation-and-First-Flight-DRAFT-v3.md)
for vessel installation and operation.
