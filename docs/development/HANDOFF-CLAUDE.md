# Handoff: work done by Claude (October 31, 2026)

This records everything Claude changed in this repository during the October 31 session, in order, so another agent can continue from it. The delivery-level summary is in [MAINTENANCE-ROADMAP.md](MAINTENANCE-ROADMAP.md). The plan being followed is the six-delivery "Amaryllis Source Maintenance and Regression Plan" (persistence; guards, documentation and plant model; regression tools and CI; shared source; configuration registry; control refactoring).

Nothing has been committed, pushed or applied to a live world. All work was done on a copy of the working tree and the changed files were written back to `amaryllis-source`.

## Environment notes

- Claude ran everything on Linux with Python 3.12 and Lupa 2.6, matching `requirements-dev.txt`. GUI tests ran under a virtual display (`Xvfb :99`, `DISPLAY=:99`).
- Cobalt was not run. Its results in the roadmap come from the earlier agent.
- The Windows shell on the owner's computer was unresponsive during this session, so no command was run there. Run `python project.py check` and `python project.py test` locally before building media.

## 1. Baseline test run

- Ran the full suite on the baseline working tree: 175 tests, 0 failures. Under Python 3.13 without `tkinter`, four GUI tests error; one provenance test fails outside a git checkout. Neither is a code defect.

## 2. Picking up Delivery 4

The earlier agent stopped after replacing every core `local function finite`/`clamp` with `local finite = Mathx.finite` and `local clamp = Mathx.clamp` from the new `avionics/mathx.lua`.

- **Equivalence check.** Compared all helper bodies in the pre-maintenance source: 25 `finite` copies all test `type == "number"`, `v == v` and a finite magnitude; 6 `clamp` copies all use `math.max(low, math.min(high, value))`. The shared versions are identical in behavior. `remote_ap_client.lua` keeps its own copy because it runs on remote computers.
- **Broken test harness.** The agent's patch to `tests/test_repository.py` never applied: its search string used `\n`, and the file uses CRLF. The propulsion endpoint harness therefore rejected `require("avionics.mathx")` and two tests failed. Applied the patch with CRLF. The same harness now also serves `avionics.config_registry` (Delivery 5).

## 3. Delivery 4 additions

### Generated core console guard
- Finding: `source/core/avionics/common/console.lua` is generated. `collect()` discards it, copies `packages/common/console.lua` and applies `presentation.apply_console` and `apply_remote`. A direct edit to the core copy has no effect.
- `disk-builder/builder.py` `collect_project` now rejects a maintained core console that differs from the generated one. The error tells the editor to change the package console and regenerate the core copy.
- Test: `tests/test_source_integrity.py::test_core_console_matches_generated_package_console`.
- To regenerate the core copy after editing the package console, run `apply_console` and `apply_remote` on a payload whose core console is the package console (see `tests/test_presentation.py::PresentationTests.transform`) and write the result to the core path.

### Presentation transformations (`disk-builder/presentation.py`)
- Each overlay now recognizes "already applied" from the code it inserted. The historical labels are still recognized for older sources:

  | Overlay | Structural signature | Historical label still accepted |
  |---|---|---|
  | `apply_console` | `local Panel=require("avionics.panel_console")` followed by `if mode=="panel" then` | `-- Amaryllis Panel Home core console v1` |
  | `apply_remote` | `data.computers=Panel.remoteComputers(` | `-- Amaryllis remote fleet presentation v1` |
  | `apply_remote_reads` | `local pages=last[p.pairID]or{};last[p.pairID]=pages` | `-- Remote cached reads v1` |
  | `apply_remote_transient` | `local form={name="Remote CMD",cruiseSpeed=3}` | `-- Transient Remote CMD compatibility client.` (already descriptive, kept) |

- Inserted comments are now descriptive: `-- Panel Home core entry: ...`, `-- Remote fleet page: ...`, `-- Cached remote reads: ...`. Matching comments were updated in `source/core/avionics/common/console.lua` and `source/core/avionics/remote_install.lua`.
- Not changed: the systems-menu `-- Amaryllis systems menu presentation v1 BEGIN/END` lines. They are part of the hash-locked asset `disk-builder/assets/systems-menu.lua`, which installed media also carry, and `presentation.apply` matches that asset's text.
- New `tests/test_presentation.py`: package console transforms to the maintained core console; applying twice changes nothing; historical labels do not cause a second insertion; an unsupported console shape is rejected; the intended package/core console difference is asserted.

### Shared-source propagation
- New `tests/test_project_release.py::test_shared_source_edits_reach_every_mapped_role`. It inserts a probe line into each of the 11 canonical files under `source/library/packages/common/`, builds media from the project source, decodes each role's bundles (`bundling.unpack` with `assets/runtime-loader.lua`), and requires each probe in exactly the role packages mapped in `source/baseline.json` `sharedModules`.
- Note: the media library bundles several sources per role, so tests must decode bundles rather than look for file names such as `/packages/chamber/fl/hardware.lua`.
- Overwrite updates across all 16 roles, removal of obsolete files and retention of stored data were already covered by `test_direct_source_update_applies_current_edits_and_cleans_staging`.

### Runtime globals
- New `docs/architecture/RUNTIME-GLOBALS.md`: all 28 `os.__amaryllis*` values with owner, other writers, readers, lifetime and cleanup. Each "cleared" entry was checked against the code that clears it; other lifetimes follow from where the value is written.
- New test `test_runtime_global_catalogue_matches_source` fails when source (including builder assets) and the catalogue disagree.
- Deliberately not done: a runtime accessor module. Five writers are hash-locked assets on installed media, and the values cross program boundaries, so an accessor would add a compatibility layer without changing behavior. Raise it with the owner before doing it.

### Suite registration
- `tests/test_presentation.py` was not running at first because `project.py` lists suites explicitly in `SUITES`. Added it, and added `test_every_test_module_is_in_the_project_suite`, which fails when a `tests/test_*.py` file is missing from `SUITES`.

## 4. Delivery 5: settings registry

### New files
- `source/core/avionics/config_registry.lua`: 92 entries, one per `altitude_control` or `thrust` setting, keyed `"<section>.<path>"` (for example `thrust.heading_control.rate_pid.kp`). Fields: `kind`, `min`, `max`, `minExclusive`, `maxExclusive`, `bound` (`schema` / `runtime` / `none`), `required`, `fallbacks`, `unit`, `effect`, `evidence`, `note`. Functions: `Registry.entry(id)`, `Registry.check(entry, value)` and `Registry.number(node, id)`.
- `tools/config_registry.py`: loads the registry through Lupa, extracts inline numeric fallbacks from `flight.lua`, `thrust.lua` and `anchor.lua`, reads shipped values, and renders the tuning reference tables (`--write` updates the document).
- `tests/test_config_registry.py` (9 tests, listed in `SUITES`).

### How entries were derived
- The settings are every scalar shipped under `altitude_control` and `thrust` in `config.json`, plus the settings that only the code reads: `altitude_control.vertical_drag_support_per_bps`; `thrust.drag_time_constant_seconds`, `reverse_brake_margin_bps`, `speed_feedforward_per_bps`, `speed_integrate_band_bps`, `speed_lead_seconds`, `speed_trim_down_limit`, `zero_brake_gain`, `zero_hold_capture_speed`.
- Not registered individually: tables validated as groups (`lateral_mixer.*`, `verified_gas_lift_strengths.*`, `primary_rpm_limits`, `acceleration_drive_limits`).
- Schema bounds were read from `Storage.validateConfig`. The test then probes each one: just outside fails, at the bound passes (or fails for an open end). Runtime bounds are the clamps in the consuming code.
- `required` was found by removing each shipped setting and running `validateConfig` on the shipped config (51 required). It reflects the shipped configuration; some requirements are conditional (for example, `command_ttl_seconds` becomes required when thrust is enabled).
- `thrust.command_ttl_seconds` has a cross-setting constraint: validation allows up to `network.node_stale_seconds` (6 shipped), and `directConfigReason` in `thrust.lua` refuses commands above 3 s. The registry records `max=3` with a note, and the probe test skips its upper bound.
- `thrust.lateral_max_rpm` has no registered fallback. The code's `or 1` applies to the derived ratio `lateral_max_rpm/256`, which corresponds to 256 RPM; the extractor skips fallbacks on derived values.

### Code changes
- **`Registry.number` replaces these inline expressions.** Each one was `finite(x) and <clamp> or <fallback>`:

  | File | Setting | Clamp | Fallback |
  |---|---|---|---|
  | flight.lua | `altitude_control.vertical_drag_support_per_bps` | [0, 0.05] | 0.019 |
  | thrust.lua | `thrust.zero_brake_stop_bps` | >= 0 | 2 |
  | thrust.lua | `thrust.zero_brake_gain` | [0, 1] | 0.06 |
  | thrust.lua (2 sites), anchor.lua | `thrust.drag_time_constant_seconds` | [1, 60] | 5.5 |
  | thrust.lua | `thrust.speed_lead_seconds` | [0, 5] | 2 |
  | thrust.lua | `thrust.speed_integrate_band_bps` | none | 2 |
  | thrust.lua | `thrust.speed_trim_down_limit` | [0, 1] | 0.3 |
  | thrust.lua | `thrust.reverse_brake_margin_bps` | >= 0 | math.huge (disabled) |
  | thrust.lua | `thrust.speed_feedforward_per_bps` | none | 0.031 |
  | thrust.lua | `thrust.zero_hold_capture_speed` | >= 0 | 0.1 |
  | anchor.lua | `thrust.zero_brake_gain` (anchor brake default) | [0, 1] | 0.06 |

  `test_registry_number_reproduces_replaced_expressions` keeps the old expressions verbatim and compares them with `Registry.number` for nil, NaN, ±inf, a string and 14 numbers.
- **Save validation.** `Storage.saveConfigChanges` checks each registered path with `Registry.check` before applying it. Removing a required setting is rejected. The message names the setting in capitals (for example `THRUST.ZERO_BRAKE_GAIN MUST BE AT MOST 1`). `validateConfig` still runs on the merged result afterwards. Load-time validation is unchanged, so an installed config that loads today still loads.
- **`flight.lua` exposes `Flight._settingsFields`** (the settings editor `FIELDS`) for the editor-range test, following the existing `Flight._...` convention for test access.
- **Summary catalog.** `disk-builder/source_notes.py` gained entries for `config_registry.lua`. The build strips every `-- Summary:` / `-- Section:` line and re-inserts them from `PURPOSES` and `SUMMARIES` in `source_notes.py`, so any new function of eight or more lines needs a catalog entry, or `project.py check` fails with "Missing function summaries".

### Left as they were (recorded for a separate decision)
These settings keep their inline fallbacks because the fallback has several values or differs from the shipped value. The generated table "Fallbacks that differ from the shipped value" in the tuning reference lists them:
- Reachable when the setting is removed: `altitude_control.climb_trim_boost` (shipped 2, fallback 1; the same `or 1` also means "no boost while not climbing"), `altitude_control.level_damping_gain` (3 vs 1), `thrust.direct_max_request` (1 vs 0.25).
- Not reachable while the config is valid (required): `max_vertical_speed` (5 vs 1), `trim_ceiling_per_block` (5 vs 0), `trim_slew_ceiling_per_second` (1 vs 0).

### Documentation
- `docs/development/TUNING-REFERENCE.md`: the hand-written tables and the line-numbered "contextual fallback locations" lists (whose line numbers had already gone stale) are replaced by a generated block between `<!-- BEGIN generated settings tables ... -->` and `<!-- END generated settings tables -->`. The prose sections above it are unchanged apart from the opening paragraph. After any registry or `config.json` change, run `python tools/config_registry.py --write`; `test_tuning_reference_tables_are_generated_from_registry` fails until you do.

## 5. Verification at handoff

- `python project.py check`: passes; core payload 5 files, state payload 3 files.
- `python project.py test`: 225 tests, 0 failures, 0 errors (Linux, Python 3.12, Lupa 2.6, virtual display).
- Not verified: Cobalt, Windows, and physical flight. Delivery 5 changes the read path of the settings above, with identical results in tests, and adds save-time validation. Fly a short test (climb and hold, a SEL 0 stop, one anchor hold) before starting Delivery 6.

## 6. Conventions and traps found

- Many files use CRLF. Patch scripts must match the file's line endings (`'\r\n' if b'\r\n' in data else '\n'`), and an `assert old in text` guard should run before any write.
- `project.SUITES` lists test modules explicitly; the new suite-registration test enforces it.
- `source/core/avionics/common/console.lua` is generated; edit `source/library/packages/common/console.lua`.
- Function summaries live in `disk-builder/source_notes.py`; comments written in source are replaced at build.
- `docs/development/MAINTENANCE-ROADMAP.md` still shows Delivery 2 as "in progress" from the earlier agent's notes. The summary audit it mentions now holds at build time: `project.py check` runs `annotate(strict=True)`, which fails on any function of eight or more lines without a catalog summary. Claude did not review the remaining Delivery 2 scenario-coverage items.

## 6a. Test runner progress

`project.py test` prints one line per test to the console (`[n/total] ok|FAIL|ERROR|skip name (seconds)`), plus a line for each failing subtest, through `ProgressResult`. The detailed log in `output/tests/results.log` and `results.json` are unchanged. The full suite takes about four minutes.

## 6b. Live updates

- `disk-builder/updater.py`: `apply` and `restore` run while the world is open. ComputerCraft supports replacing a running computer's files, every write is atomic, and running computers keep their current program until they reboot. The update marker (`.amaryllis-update.json`) stops two updaters working on one save. The update dialog shows a short instruction label.
- Unchanged: the ComputerCraft settings tool (`cc_settings.py`) still requires Minecraft to be fully closed, because it edits configuration the game reads at launch and may rewrite on exit.
- Tests: `tests/test_world_lock.py` covers an update proceeding while a helper process holds `session.lock` as Minecraft does, the excluded runtime files and save-folder resolution.

## 6c. Installer disk: "Start core with disk" crashed

- Symptom: `/disk/setup.lua:571: attempt to index global 'shell' (a nil value)` from **Start core with disk**.
- Cause: the disk's `startup.lua` loaded `setup.lua` with `loadfile(path)`. ComputerCraft's `loadfile` without an environment loads into `_G`, which lacks `shell` and `multishell`; only the running program's environment has them. `Setup.startCore` is the one path that calls `shell.run`.
- Fix: `disk-builder/assets/startup.lua` passes `_ENV` to `loadfile`. `asset-hashes.json` updated for `startup.lua` only.
- Why tests missed it: `tests/test_disk_setup.py` sets `shell` as a global. New `tests/test_disk_launcher.py` runs `startup.lua` with `shell` only in the program environment, as ComputerCraft does; it fails on the old launcher and passes on the new one.
- Existing installer disks keep the bug until rebuilt.

## 6d. Core propulsion refusals are recorded (primaries stuck at WAIT)

- Symptom: both primaries installed and running, but the core lists them as WAIT; `components/units/primary-left/discovered: NO` means the core never accepted a hello from #16. #17 held a session from the current core session but stopped receiving session refreshes after its first one. Core radio handling was not overloaded (receive average 0.2 ms).
- Cause not yet identified: every refusal path in `Thrust:acceptHello` and `Thrust:acceptStatus` returned `false` silently.
- Change: each refusal now calls `Thrust:rejected(io, kind, role, sender, reason)`, which stores the latest refusal per role (`self.rejections`), logs it once through `io:logState("propulsion hello|status <role>", reason)`, and is exposed as `lastRejected` in unit and controller snapshots (visible under the role page's More details). An accepted message clears the logged state. Controller-status field checks share one reason, "CONTROLLER STATUS FAILED VALIDATION".
- `processMessage` now returns `false, reason` for refusals; its only caller (`IO:processMessage`) uses the result in an `if`.
- Test: `tests/test_propulsion_rejections.py`.
- Next step for the owner: update the core, reboot the primaries, then read `lastRejected` on the primary-l / primary-r pages.

## 6e. Root cause of the primaries' silence: rednet message-ID collisions

- Found by reading the "Ama Test 2" world files directly: the core had the refusal-logging update, yet recorded no refusal for primary-left, so #16's hellos never arrived as rednet messages.
- Cause: `bootToken()` in `primary-main.lua`, `thrust-controller.lua` and `chamber-thrust.lua` called `math.randomseed(epoch + computerID)`. rednet draws message IDs from the same global generator and silently drops IDs it has seen recently. Computers that boot a few milliseconds apart (as on world load) can get the same seed (for example #16 at T and #12 at T+4 ms), then emit identical ID sequences; the busier computer uses each ID first and every message from the other is discarded before any program sees it. This explains #16 never being heard and #17 being heard once.
- Fix: removed the reseed; ComputerCraft seeds `math.random` per computer. The boot token format is unchanged.
- Guard: `test_no_program_reseeds_the_shared_random_generator` in `tests/test_source_integrity.py` fails on any `math.randomseed(` call in maintained source or builder assets.

## 7. Files changed by Claude in this session

- Modified: `disk-builder/builder.py`, `disk-builder/presentation.py`, `disk-builder/source_notes.py`, `project.py`, `source/core/avionics/anchor.lua`, `source/core/avionics/common/console.lua`, `source/core/avionics/flight.lua`, `source/core/avionics/remote_install.lua`, `source/core/avionics/storage.lua`, `source/core/avionics/thrust.lua`, `tests/test_project_release.py`, `tests/test_repository.py`, `tests/test_source_integrity.py`, `docs/development/MAINTENANCE-ROADMAP.md`, `docs/development/TUNING-REFERENCE.md`.
- Also modified: `disk-builder/updater.py`, `README.md`, `disk-builder/README.md`.
- Also modified: `disk-builder/assets/startup.lua`, `disk-builder/assets/asset-hashes.json`.
- Also modified: `source/core/avionics/thrust.lua` (refusal reasons); `source/library/packages/common/primary-main.lua`, `thrust-controller.lua`, `chamber-thrust.lua` (no reseed).
- Added: `tests/test_propulsion_rejections.py`, `tests/test_disk_launcher.py`, `tests/test_world_lock.py`, `source/core/avionics/config_registry.lua`, `tools/config_registry.py`, `tests/test_config_registry.py`, `tests/test_presentation.py`, `docs/architecture/RUNTIME-GLOBALS.md`, `docs/development/HANDOFF-CLAUDE.md`.

## 8. Next

Delivery 6, after a test flight: extract stages from one function at a time, in the order `Thrust:speedDriveRequest`, `IO:sampleVessel`, `Flight:systemsControlTargets`, `Flight:systemsAcquisitionControl`, `Flight:updateSystemsRecovery`, `Flight:updateSystems`. Compare recorded-input replay traces and closed-loop model results before and after each extraction. When a stage reads one of the contextual-fallback settings above, keep its inline fallback unless the owner decides otherwise.
