# Amaryllis Disk Builder

Build installation media from maintained Amaryllis source, export a configured
ship, and update an existing installation. The utility works offline on Windows.

Release history is in [CHANGELOG.md](CHANGELOG.md).

## Requirements

- Python 3.11 or newer with Tcl/Tk.
- A writable utility folder. Keep the extracted utility, `assets/` and any
  included `source/` directory together.
- Access to the world's files when exporting or updating a ship.

Double-click **Start Builder.cmd**. The launcher uses an available local Python
runtime or the installed Windows Python launcher/PATH. The window title shows
the utility version, and build logs identify the interpreter used.

## Choose the software source

| Mode | Program and configuration source | Learning defaults |
|---|---|---|
| **Project source** | Maintained Lua and configuration in the selected project | Optional shipped hover and leveling defaults |
| **Saved ship export** | Software and portable configuration in the selected saved installation | Optional learning saved by that ship |

Project source is selected automatically when maintained source is present.
Standalone utility ZIPs include their release's source snapshot and revision
record. Git is optional.

## Build from project source

1. Open **Start Builder.cmd** and select **Project source**.
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

## Export a saved ship

1. Set **Software source** to **Saved ship export**.
2. Select the save containing the configured Amaryllis. The chooser also accepts
   its ComputerCraft directory, computer directory or numeric core folder.
3. Choose whether to **Include this ship's saved hover and leveling corrections**.
4. Click **Build installer**, then open the result.

The exporter captures saved programs, PID configuration, input tuning, portable
settings and the selected learning. It reads core's package library or recovers
auxiliary sources from verified installed bundles. Recovered packages must match
core's catalogue and their committed role receipts.

If installed recovery is incomplete, the exporter searches saved floppy disks
and installer directories for matching media. The command-line `--library` option
supplies another matching location. Catalogue identities and object hashes are
checked before accepting recovered files.

Save and exit the source world before export for a consistent snapshot. The
exporter reads saved files and stops if its inputs change during the build.

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

In **Project source** mode, **Update existing ship...** builds the selected
project and opens the updater with that release's media selected.

To use an existing installer, open the updater from **Saved ship export** mode
and select its media, or run `windows-update/Update Amaryllis.cmd` from the
installation package. The distributed helper selects adjacent media automatically.

1. Select the destination save or its numeric core folder.
2. Check the selected installer media.
3. Select a backup folder outside the save and installer media. The utility can
   create its default `Backups/` folder.
4. Click **Preview update** and review the Add, Replace, Remove and Keep entries.
5. Save and fully close Minecraft and any server using the save.
6. Select **I have saved and fully closed Minecraft**, click **Apply update**
   and confirm the reviewed replacement.
7. Wait for **Update complete and verified**, then reopen the world.

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

To restore, close Minecraft, select **Restore backup...** and choose the transaction
folder. Restore verifies the backup and checks for newer target edits. Interrupted
updates are recorded in `computercraft/computer/.amaryllis-update.json`; use its
named backup to finish recovery before applying another update.

### Startup launcher repair

**Preview startup repair** prepares the supported launcher replacement for the
14 auxiliary computers. It uses the same preview, external backup and closed-game
workflow. Installed bundles, settings and learning are retained. It uses the
utility's launcher asset and requires no installer media.

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

Close Minecraft/server fully before applying and acknowledge this in the
interface. Each change creates a verified `.amaryllis-...bak` and JSON hash
record beside the configuration. **Restore backup...** verifies the saved copy
and current file before restoring it. Restart Minecraft/server after editing.

## Verification and troubleshooting

Build verification covers supported source layouts, JSON, roles, package
manifests, transfer bounds, state-reader dependencies, learning records, object
checksums, source consistency and ZIP contents. Lua compilation, regression tests
and in-game acceptance are separate project checks.

| Result | Action |
|---|---|
| Source changed during build | Finish source edits, or save and exit the source world, then build again. |
| Missing or mismatched package source | Restore matching source or provide matching media through `--library`. |
| Incomplete installation or transaction | Finish the recorded operation before export or update. |
| GUI build error | Read the message and its private traceback report under `Logs/` beside the utility. |
| Unsupported schema or bundle format | Use builder support that matches the source format. |

## Command-line use

Run these commands from the utility directory. The output parent must exist.

```text
py -3 builder.py --project "D:\Amaryllis Source" --output "D:\Amaryllis Installers"
py -3 builder.py --project "D:\Amaryllis Source" --output "D:\Amaryllis Installers" --without-learning
py -3 builder.py --source "D:\Minecraft\saves\My Amaryllis" --output "D:\Amaryllis Installers"
py -3 builder.py --source "D:\Minecraft\saves\My Amaryllis" --library "D:\Previous Installer\media" --output "D:\Amaryllis Installers"
py -3 updater.py --source "D:\Minecraft\saves\My Amaryllis" --media "D:\New Installer\media"
py -3 updater.py --source "D:\Minecraft\saves\My Amaryllis" --media "D:\New Installer\media" --apply --backup "D:\Amaryllis Backups" --minecraft-closed
py -3 updater.py --restore "D:\Amaryllis Backups\Amaryllis-update-..." --minecraft-closed
py -3 updater.py --source "D:\Minecraft\saves\My Amaryllis" --repair-startup
```

From the repository root, `python project.py build` builds current source and
`python project.py update --target "D:\Minecraft\saves\My Amaryllis"` builds
and previews an update. See the [project README](https://github.com/DarkLugia4000/amaryllis-source/blob/main/README.md)
for development commands and the [owner's guide draft](https://github.com/DarkLugia4000/amaryllis-source/blob/main/docs/installation/Amaryllis-Owner-Installation-and-First-Flight-DRAFT.md)
for vessel installation and operation.
