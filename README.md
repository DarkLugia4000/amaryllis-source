# Amaryllis

Maintained source and development tools for Amaryllis's ComputerCraft control
software. The Git baseline imports the delivered 2.8.0 behavior on 29 October 2026.

## Project layout

| Location | Purpose |
|---|---|
| source/core/ | Editable core and state-shared Lua modules and portable configuration. |
| source/library/ | Editable navigator, heading, chamber and propulsion packages. |
| source/calibration/ | The two explicitly shipped numeric hover/level default records. |
| source/baseline.json | Source fingerprints, role labels, asset ownership and migration evidence. |
| Amaryllis Installer Builder/ | Windows Disk Builder, updater and checked installer/UI assets. |
| tests/ | Maintained Python regression suites, Java harness and isolated fixtures. |
| tools/ | Maintained development utilities, including builder ZIP packaging. |
| releases/builders/ | Versioned builder ZIPs, preserved locally; future builder packages are written here. |
| archive/scripts/ | Historical Python, Lua and PowerShell scripts, preserved locally. |
| project.py | Source verification, source builds, tests and Cobalt validation. |
| docs/ | Topic folders and a documentation index in docs/README.md. |
| output/ and .cache/ | Generated files and disposable test ships; ignored by Git. |

Logs, recordings, installer exports, release ZIPs, backups and older one-off
scripts remain available locally and are excluded from the repository. The
existing Windows builder folder keeps its current name and launcher. The
top-level Git allowlist is explicit: add new maintained directories or root
tools to .gitignore when extending the project layout.

Browse the [documentation index](docs/README.md) for guides, architecture, plans and history.

## Development setup

Use Python 3.12 for the validated development environment. The builder itself
retains its existing supported Python versions.

    python -m venv .venv
    .\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
    .\.venv\Scripts\python.exe project.py check
    .\.venv\Scripts\python.exe project.py test --quick

The test dependency is pinned to Lupa 2.6 and its Lua 5.2 engine. Test fixtures
use synthetic computer assignments under .cache/fixtures. They require no
Minecraft save, previous installer folder or account credentials.

## Authoritative source, installation disks and updates

The maintained software is this repository. Edit Lua under `source/core/` and
`source/library/`; shipped hover/level defaults live under `source/calibration/`.
Five shared modules have one editing location in the builder's `assets/` folder:
`core-progress.lua`, `core-media.lua`, `identity-watch.lua`, `panel-console.lua`
and `remote-panel.lua`. Their installed paths are mapped by `source/baseline.json`.
The migration fingerprints in that file are historical reference values.

### Windows interface

Open `Amaryllis Installer Builder/Start Builder.cmd`. **Project source** is
selected automatically when maintained source is present. Select the project
folder and choose:

- **Build installer** to create a new commissioning disk package.
- **Update existing ship…** to build current project software and open the
  updater with that release already selected. Select the target save, choose
  an external backup folder, and review the update before applying it.

Both actions read software from the project. A world folder is needed only as
the update destination. Existing IDs, stored settings, PID configuration,
learning and restart records are retained by the updater. Managed programs are
overwritten and obsolete managed files are removed after an external backup.
Minecraft must be fully closed before applying an update under the updater's
current process checks. Building and previewing are read-only with respect to saves.

**Saved ship export** is a separate mode for capturing the software and portable
configuration currently installed on a ship. Its source is that saved installation.

### Project commands

    python project.py build
    python project.py update --target "D:\Minecraft\saves\Amaryllis"
    python project.py gui

`build` creates a verified installer under `output/installers/`. `update` builds
from the same source and prints a preview; it leaves the target unchanged.
To apply that replacement with an external backup:

    python project.py update --target "D:\Minecraft\saves\Amaryllis" --apply --backup "D:\Amaryllis Backups" --minecraft-closed

Project builds read maintained inputs directly and use a temporary compatibility
adapter for the existing packager. The adapter is removed after collection.
Production builds do not use the test fixture cache. Installed program payloads
remain five files on core and three on state and each auxiliary.

### Release provenance

Project releases record their source commit, whether the working tree contained
uncommitted changes, and a fingerprint of the source and builder inputs. This
record is included in `media/release.json`, the shared README and the local
build report. The updater shows it in the preview and retains it in each
computer's existing installation record. The floppy disk's installer also
records it during fresh installation.

The local build report lists individual input fingerprints and source paths;
it remains outside the distributable installer ZIP. Source changes during a
build prevent that output from being published as complete.

Standalone Disk Builder ZIPs include a release snapshot of the maintained source
and its revision record. They can build installers without a Minecraft save or
Git. Their source snapshot represents that packaged release. Work on future
software in this repository and create a new utility snapshot when distributing it.

The builder's guarded compatibility transformations remain in place. Changes
to guarded helper sections may require corresponding builder/asset updates.

## Validation

    .\.venv\Scripts\python.exe project.py test

Run an individual maintained suite from the repository root with:

    .\.venv\Scripts\python.exe -m unittest tests.test_information

The full suite covers builder failure paths, bundle installation and recovery,
legacy source formats, navigator presentation, information/assembly behavior,
persistent pilot modes and current-source packaging. Results are written to
output/tests/. Quick checks include current-source compilation and bundle
round trips.

Cobalt is extracted from an explicitly selected CC:Tweaked mod JAR:

    .\.venv\Scripts\python.exe project.py cobalt --cc-mod "<cc-tweaked.jar>" --java "<java.exe>"

The pinned dependency is Cobalt 0.9.9, with its expected checksum in
tests/fixtures/cobalt.json. The Java engine and Minecraft binaries stay outside
Git. Upstream is https://codeberg.org/SquidDev/Cobalt.

## Git workflow

The main branch tracks origin/main at git@github.com:DarkLugia4000/amaryllis-source.git.

    git status
    git diff
    git add <reviewed-files>
    git commit -m "Describe the resulting change"

Keep generated outputs and private ship data outside commits. Preserve shipped
ZIPs as immutable releases. Git source history starts at this migration; the
older narrative remains in docs/history/LEGACY-HISTORY.md.

## Operating contracts

Ordinary core restarts and recoverable faults preserve applied lift settings.
Stop Systems and Kill Lift retain their deliberate operator-controlled shutdown
paths. Selected pilot modes and values survive supported restarts and recovery.
Assembly uncertainty continues checking and warns after five minutes.
Computer names remain lowercase. Major functions receive concise purpose
summaries, and source comments stay aligned with implemented behavior.

See [the information plan](docs/plans/NAVIGATOR-INFORMATION-PLAN.md),
[maintenance catalogue](docs/maintenance/Amaryllis-Maintenance-Catalogue.md) and
[core responsibilities](docs/architecture/Amaryllis-Core-File-Responsibilities.md).

See [migration details](docs/development/GIT-MIGRATION.md) for source provenance and scope.
