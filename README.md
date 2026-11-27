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
- **Autopilot:** single destinations and ordered waypoint routes with configurable
  speed and altitude, heading acquisition, route capture, acceleration, cruise,
  approach and final arrival handover to the position anchor.
  Route tracking and braking are still being refined through flight recordings.
- **Graphical navigator:** CC: Graphics Flight, Navigation, Ship and Settings
  pages, with chamber diagrams, propulsion indicators, route editing and a
  dedicated AP progress display. The navigator requires at least 342 × 216 pixels;
  see the [display requirements](docs/development/CC-GRAPHICS.md).
- **Diagnostics and recovery:** per-computer status, removable-disk debug
  recordings, retained pilot selections and recovery paths for installation
  mistakes and interrupted updates.

For the controls and display labels, see the [pilot reference](docs/installation/PILOT-REFERENCE.md).

## Web install (Pastebin)

**Start with the [owner's installation and first-flight guide](docs/installation/Amaryllis-Owner-Installation-and-First-Flight.md).**
It covers the required ComputerCraft configuration, computer identification,
web installation, registration recovery, hardware checks and first flight.

Launch the in-game installer with:

```text
pastebin run bn1RbWtb
```

Install core first, register the other 15 roles, then review and import all 16
assignments on core. Follow the owner's guide for the complete procedure.
Floppy installation is largely deprecated and retained as a
[legacy fallback](disk-builder/README.md#installer-floppy-disk-deprecated).

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

See [software updates in the owner's guide](docs/installation/Amaryllis-Owner-Installation-and-First-Flight.md#11-update-the-software)
for published web releases, state-reader updates, interrupted-update recovery
and restarting affected computers. For local source deployments, use the
[Windows builder and updater](disk-builder/README.md#update-an-existing-ship).

Pushes to `main` trigger the [release workflow](.github/workflows/release.yml).
After a successful build, installer media is published to the `release` branch
for the Pastebin loader.

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
