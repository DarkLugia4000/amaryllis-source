# A.E.V. Amaryllis Source Code & Release Repo

Distributed flight-control software for **A.E.V. Amaryllis**, a steam/diesel
hybrid airship built with Create Aeronautics and controlled through CC: Tweaked.
This repository contains the Lua programs, in-game installer, Windows builder
and updater, and regression tests.

The system is built around Amaryllis's hardware, her multi-chamber system and measured handling.
Installing it on a different vessel is not recommended, as this would require substantial changes to peripheral bindings,
propulsion arrangement, lift management and control tuning.

[Installation](#web-install-pastebin) · [Computer roles](#computer-roles) ·
[Updates](#updating-an-existing-installation) · [Development](#development) ·
[Documentation](docs/README.md) · [Changelog](disk-builder/CHANGELOG.md)

## What it does

- **Integrated fly-by-wire control:** 16 computers coordinate bridge inputs,
  altitude, heading, speed, propulsion and stabilization.
- **Selectable handling:** manual and selected heading/speed modes, direct
  primary-propeller control, and adjustable heading and speed response through
  the onboard monitor interface.
- **Flight management:** four independently controlled lift chambers, leveling,
  lateral positioning and a digital position anchor.
- **Point-to-point autopilot:** configurable route speed and altitude, heading
  acquisition, route capture, acceleration, cruise, approach and arrival handover.
  Route tracking and braking are still being refined through flight recordings.
- **Diagnostics and recovery:** per-computer status, removable-disk debug
  recordings, retained pilot selections and recovery paths for installation
  mistakes and interrupted updates.

For the controls and display labels, see the [pilot reference](docs/installation/PILOT-REFERENCE.md).

## Web install (Pastebin)

**Use Pastebin for new installations.** Floppy-disk installation is largely
[deprecated](disk-builder/README.md#installer-floppy-disk-deprecated) and retained
as a legacy fallback.

### Before starting

- Use the Amaryllis vessel and its matching mod environment. The project is
  developed for Minecraft 1.21.1 / NeoForge, with CC: Tweaked, Create Aeronautics,
  Sable, CC: Sable, CC: Avionics and the vessel's other hardware integrations.
- Apply the ComputerCraft storage, execution-thread and HTTP settings below
  before running the installer.
- Have core and the registering computers able to communicate over wireless
  rednet. The state computer uses a wired connection to core during normal
  operation; see the [state wiring guide](docs/architecture/STATE_MODULE.md#wiring).
- Match each computer to the role written on its sign. Each role must have a
  distinct ComputerCraft ID; copied computers sharing an ID must be corrected
  before registration.

### Required ComputerCraft configuration

With Minecraft and the server completely closed, back up the active
`computercraft-server.toml`. Depending on the installation, it may be in the
instance's `config/` folder or the save/server's `serverconfig/` folder. Establish
which file the server actually uses when several copies exist.

Edit the existing keys and sections in place:

```toml
computer_space_limit = 4000000
floppy_space_limit = 4000000

[execution]
computer_threads = 2

[http]
enabled = true
```

- **Storage:** the values are bytes. Use at least **4,000,000 bytes** for each
  capacity and retain any higher existing limits. If the generated installer's
  README specifies a larger media requirement, use that larger value. Allow
  additional disk space for debug recordings.
- **Execution:** **2 computer threads** is the documented setup baseline. Keep
  a deliberately configured higher worker count if appropriate for the server;
  increasing it further is a separate performance-tuning decision.
- **HTTP:** `[http] enabled = true` is the TOML form of `http.enabled`. Preserve
  the other HTTP rules and unrelated settings. Do not duplicate existing tables.

Restart Minecraft/server after saving. The builder's **ComputerCraft settings…**
tool, or `windows-settings/Configure ComputerCraft.cmd` in a generated package,
can preview these changes and create a backup. Select **2** execution threads
when applying the baseline; the tool initially displays the existing count.
See the [configuration helper guide](disk-builder/README.md#computercraft-settings).

### Install core, register the fleet, then import

Run this in the ComputerCraft shell:

```text
pastebin run bn1RbWtb
```

1. **Install core first.** On the core computer, choose **1 Install core** and
   confirm the computer ID. It downloads its programs and opens the registration
   screen. Until assignments are imported, rebooting core returns to this screen.
2. **Register the other 15 computers.** Run the same command on each and choose
   **2 Register this computer**. It finds core, loads core's release and lists
   the roles and their current holders. Select the role on the computer's sign.
   The computer installs its commissioning receiver, or the state reader's own
   programs, and reboots. Keep core on its registration screen while registering
   the fleet. Connect the state reader to core with wired modems for operation.
3. **Review all 16 assignments on core.** Correct any mistakes, then press
   **Enter** and confirm **Import assignments and start core?** Core restarts
   and distributes the 14 wireless auxiliary role packages from its pinned
   release.

The loader is published at [pastebin.com/bn1RbWtb](https://pastebin.com/bn1RbWtb).
Its maintained source is [tools/pastebin/loader.lua](tools/pastebin/loader.lua).
Computers joining an installation use core's release so that its packages stay
consistent across the fleet.

### Fixing registration mistakes

| Situation | Action |
|---|---|
| Need to reopen setup on a registered computer | Hold **Ctrl+T** to stop its commissioning screen, then run the Pastebin command again. |
| Wrong role selected before import | Run setup on that computer and select the correct role. Core moves the assignment. **Backspace** on core clears the selected role. |
| Remove a registration | Choose **3 Remove this computer's registration**. This removes its commissioning receiver or state-reader programs and asks core to clear the role. An already-installed auxiliary role package is retained. |
| Reset registration | Press **R** on core's setup screen. Assignments are cleared; computer programs and settings remain for registration again. |
| Uninstall core before import | Press **U** on core's setup screen to uninstall core and delete its files. |

See the [full installer guide](disk-builder/README.md#web-install-pastebin) for
additional setup and recovery details, and the
[owner installation and first-flight guide](docs/installation/Amaryllis-Owner-Installation-and-First-Flight-DRAFT-v3.md)
for commissioning guidance. The owner guide is a draft; use the current installer
screens for menu choices.

## Computer roles

Computer IDs are assigned during installation. The role names describe what
each computer does; they are not fixed numeric IDs.

| # of Computers | Roles | Responsibility |
|---:|---|---|
| 1 | `core` | Flight-control decisions, pilot selections, AP, anchor, stabilization and commands to the fleet. |
| 1 | `state` | Vessel and cockpit sensor sampling, sent to core over the wired link. |
| 1 | `navigator` | Interactive bridge management interface and requests to core. |
| 3 | `heading-left`, `heading-main`, `heading-right` | Heading and flight instrument displays. |
| 4 | `chamber_fl`, `chamber_fr`, `chamber_bl`, `chamber_br` | Independent lift-chamber control. |
| 4 | `thrust-lb`, `thrust-rb`, `thrust-ls`, `thrust-rs` | Propulsion actuator control; the `ls` and `rs` controllers also operate the main propellers. |
| 2 | `primary_l`, `primary_r` | Primary-propeller bearing readback. |

Core interprets pilot input and computes commands. The state computer supplies
measurements, while the propulsion and chamber computers apply commands locally
and report their status. The navigator presents the management interface.

See [core responsibilities](docs/architecture/Amaryllis-Core-File-Responsibilities.md)
and [state telemetry](docs/architecture/STATE_MODULE.md) for the implementation.

## Updating an existing installation

### Published web releases (recommended)

Run `pastebin run bn1RbWtb` on a web-installed core. When setup detects a newer
published release, its core screen offers **W** to update. Follow the displayed
instructions and check that the state computer and auxiliary packages have
completed their updates.

Pushes to `main` trigger the [release workflow](.github/workflows/release.yml).
After a successful build, installer media is published to the `release` branch.
The loader selects a release commit; existing core installations retain their
pinned package objects across later releases.

### Local source updates with the Windows builder

Open [Start Builder.cmd](disk-builder/Start%20Builder.cmd), choose **Update existing
ship…**, and select the target save and an external backup folder. **Preview
update** prepares the current source; **Apply update** installs that snapshot.

The updater preserves computer IDs, stored settings, PID configuration, learned
values and restart records. It backs up managed files before replacing them.
Running computers keep their loaded programs until they restart, so replacing
files alone does not confirm the new code is running. Update and restart related
computers together when a change spans core and its controllers.

See the [builder and updater instructions](disk-builder/README.md) for details.

## Development

Use **Python 3.12**. From the repository root:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe project.py check
.\.venv\Scripts\python.exe project.py test --quick
```

Run the full regression suite with:

```powershell
.\.venv\Scripts\python.exe project.py test
```

The Lua tests use Lupa 2.6 with its Lua 5.2 engine. Synthetic computer assignments
allow the regression suites to run without a Minecraft save. In-game recordings
are still needed to validate physical handling and tuning.

| Location | Contents |
|---|---|
| [source/core/](source/core/) | Core and state-shared Lua modules and portable configuration. |
| [source/library/](source/library/) | Navigator, display, chamber and propulsion packages. Shared implementations live under `packages/common/`. |
| [source/calibration/](source/calibration/) | Shipped hover and leveling default records. |
| [source/baseline.json](source/baseline.json) | Source fingerprints, role labels, shared-module mappings and migration evidence. |
| [disk-builder/](disk-builder/) | Builder, updater and installer/console assets. |
| [tests/](tests/) | Regression suites and runtime harnesses. |
| [tools/](tools/) | Development and packaging utilities. |
| [project.py](project.py) | Verification, builds, updates, tests and Cobalt validation. |
| [docs/](docs/) | Architecture, installation, maintenance, diagnostics and development guides. |

Edit the maintained source and shared implementations, then build or update from
this repository. The builder expands shared modules into their role packages.
Generated output, recordings, world data and private backups stay outside Git.

The [development workflow](docs/development/WORKFLOW.md) covers source ownership,
build/update commands, release provenance, Cobalt validation and Git practices.

## Further documentation

- [Documentation index](docs/README.md)
- [Pilot reference](docs/installation/PILOT-REFERENCE.md)
- [Maintenance catalogue](docs/maintenance/Amaryllis-Maintenance-Catalogue.md)
- [Flight and thrust tuning](docs/development/TUNING-REFERENCE.md)
- [Primary-engine braking model and validation limits](docs/architecture/PRIMARY-BRAKING-MODEL.md)
- [Changelog](disk-builder/CHANGELOG.md)
