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

## Editing and building current software

Edit the appropriate maintained Lua module under source/. Five asset-backed
modules have their single editing location in the builder's assets directory;
source/baseline.json records that mapping. The source loader supplies them when
creating a synthetic build input.

    .\.venv\Scripts\python.exe project.py build

This builds current repository software and the shipped learning defaults into
a new installer folder under output/installers/. It uses the existing builder,
bundle format and installer verification. Program payload counts remain five
on core and three on state and each auxiliary.

The Windows Disk Builder exports saved ships into its local Installers directory. For
software edited in this repository, use project.py build so that the current
source tree supplies the programs. An existing ship receives a generated
release through the normal Update existing ship workflow and external backup.

The builder's guarded compatibility transformations remain in place. Changes
to guarded helper sections may require corresponding builder/asset updates.
Simplifying those transformations is a separate development step.

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
