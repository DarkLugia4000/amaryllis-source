# Git migration

29 October 2026, Europe/Berlin.

The repository records the portable 2.8.0 software baseline, checked builder
assets, current project documents and maintained regression suites. Source
recovery used the existing verified builder and bundle reader.

The original extracted core bundle matched the delivered 2.8.0 SHA-256 exactly.
An obsolete assembler comment was corrected during migration. Executable Lua
token streams were then compared for all 45 embedded core modules and matched
the delivered release. Fingerprints and this evidence are in source/baseline.json.

The source tree contains 127 editable source/configuration/default files.
Five builder-owned modules are supplied from existing assets instead of
duplicated under source/core/. The baseline metadata records their locations.

The included learning data consists of the two already shipped,
schema-validated numeric hover and leveling defaults. Runtime checkpoints,
live PID history, pairing credentials, logs, recordings, installed computer
files and installation receipts are excluded.

## Portable development

The legacy fixture archive preserves pre-builder program hooks with sanitized
portable configuration and shipped numeric learning defaults. Current-source
tests use the actual maintained source tree. Fixtures receive synthetic
computer IDs and are generated under .cache/.

project.py check compares the source inventory and core bundle with the
migration baseline. Later intentional changes can make that historical
comparison false. The command also reports current payload counts.

project.py build creates installers from tracked current software.
project.py test runs the full suite; --quick runs the focused subset.
project.py cobalt extracts the pinned Cobalt engine from a supplied mod JAR
and runs the real Lua information scenarios.

## Existing local material

Release ZIPs, exports, backups, diagnostics, recordings and one-off scripts
remain on disk, ignored by Git. The former root README is preserved as
LEGACY-HISTORY.md. Git history starts with this migration, rather than
reconstructing historical release commits.

The repository uses main and the author identity supplied by the user.
No remote, cloud repository, publication, live-save update or installer
deployment is part of the migration.

The existing source-recovery and guarded builder transformations remain.
Simplifying them is a separate development step.


## Verified migration result

The initial import is commit 428da35. Verification used a fresh local Git clone,
with dependencies supplied separately from the checkout.

- All 104 maintained tests passed in the fresh clone.
- All 14 information scenarios passed under the pinned Cobalt 0.9.9 engine.
- A fresh installer was generated from committed source without a Minecraft save
  or previous media folder.
- Source fingerprints and the migrated core bundle matched baseline metadata.
- Program payload counts remained five on core and three on state and auxiliaries.
- All 45 embedded core Lua token streams matched delivered 2.8.0 behavior.
- Generated outputs, backups, protected instruction files and credential fields
  were excluded from the 175-file initial import.
- Main repository status was clean and no remote was configured.

The migration tag identifies this verified starting point. Detailed machine
results are retained locally under output/git-migration/verification.json.
