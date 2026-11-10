# Source maintenance delivery record

Updated 1 November 2026. The six deliveries are implemented for offline validation. Physical flight acceptance and the current-game pressure-binding observation remain outstanding. No live-world update, commit or push has been performed for this maintenance work.

Approved sequence: persistence; source guards/documentation/plant model; regression tools/CI; canonical shared source/presentation transformations; configuration registry; staged control refactoring/performance.

## Delivery 1: persistence

Cruise learning uses validated temp/readback/backup replacement. Loading selects a valid primary or backup. Replacing an invalid primary retains the valid backup. A primary-file read failure aborts before rotating saved data. Failed saves keep current in-memory learning and the last valid saved data. The existing JSON path and format remain in use.

Remote provisioning publishes permissions after activation completes. A failed activation retains prior in-memory permissions and restores the registry. Destination replacement and interrupted rename are covered without changing destination behavior. Twelve persistence test methods exercise maintained source and generated bundles, including open, read, write, close, readback, validation and rename failures.

## Delivery 2: source guards, documentation and plant

Eleven explicit package families are checked before project/GUI collection, including the single nine-file chamber-link family. Chamber lift/link comments are normalized. The documentation pass adds purpose summaries and sections, with executable-token comparisons for comment-only changes. Reviewed short mutators have explicit summaries. Long executable lines in control code were expanded without changing their tokens.

The [plant model](FLIGHT-MODEL.md) covers aggregate lift and longitudinal motion, pressure defaults, drag and delayed gas response. It calls maintained acquisition/hold and selected-speed calculations. The profile records pressure source per calibration window, recording hash, ranges, fit method and residual error. Exact windows for the prior drag estimates remain unestablished. Four-corner rotation, endpoint timing and full-supervisor integration are outside this aggregate model; separate component tests cover allocation and recovery.

The slow 300-to-306 acquisition scenario remains a characterization result. No gains were changed to improve that result. Model assumptions and calibration limits are explicit.

The final comment audit finds summaries for all 1,003 named maintained Lua functions spanning at least eight source lines. The three remaining boot-token summaries were added with executable-token equivalence checks.

## Separate corrective change: startup fallback scope

A missing-bulk-data test reproduced `attempt to index global state` in `systemsAcquisitionControl`: a dynamics local declared inside the climb branch was used afterward. That local now has function scope. Existing formulas and provider-write routines remain unchanged. The reproducing test passes. This correction preceded the control extractions and is separate from the token-preserving comment work.

## Delivery 3: regression tools and CI

Current-source recovery tests cover state failover/handback, pressure selection, physics monitoring, heading-center settling, configuration merge-save and LOW PRESS bands. The recording analyzer (`project.py analyze-recording`) handles named columns, source windows, timing gaps, saturation and stall candidates. An 80-row recorded-input replay compares maintained and bundled lift calculations.

The Windows GitHub Actions workflow installs Python 3.12 and pinned dependencies, runs source checks and the maintained suite, and retains test artifacts. It has been exercised locally through its check/test commands; no hosted GitHub Actions run is claimed.

## Delivery 4: canonical shared source and ownership

- Eleven shared package implementations have one maintained file each under `source/library/packages/common/`, mapped to complete role families by `sharedModules` in `source/baseline.json`. Thirty-three redundant maintained files were removed. Expansion reproduces the previous role files byte for byte; role-specific configuration remains in its role directory.
- Canonical-edit tests verify that each shared edit reaches exactly its mapped role packages. Release tests exercise overwrite updates for all 16 roles, obsolete-file removal and stored-data retention.
- Core modules use `avionics/mathx.lua` for shared finite/clamp behavior. Replaced expressions were checked equivalent. The standalone remote AP client retains its local helper.
- Core's console is generated from the package console during collection. A differing maintained core copy is rejected so that an edit cannot silently disappear.
- Systems-menu detection compares executable helper tokens. Historical marker comments and formatting changes are accepted; changed or duplicated helper code is rejected. Maintained comments describe the helpers. Console/remote transformations also recognise applied code and older labels.
- Every shared runtime key is catalogued in [runtime globals](../architecture/RUNTIME-GLOBALS.md). A source/catalogue comparison enforces the inventory.
- `avionics/runtime_state.lua` provides compatible access to the existing os-backed values. Core's propulsion, debug, sampling and failover context groups use it. Other groups keep their current access paths. Tests execute actual source/bundled worker entry points, reject obsolete owner tokens and verify direct-os/accessor interoperation and cleanup.

The additional source helpers are embedded in the existing runtime bundles. Installed program payloads remain five files on core and three on state and each auxiliary.

## Delivery 5: configuration registry

`avionics/config_registry.lua` records all 92 altitude-control and thrust settings: kind, unit, accepted bounds, enforcement location, required flag, fallback, effect and evidence. Twelve call sites for ten single-fallback runtime-clamped settings use `Registry.number`. Equivalence checks cover 18 inputs per replaced expression.

`Storage.saveConfigChanges` validates registered edits before writing and names a rejected setting. Loading retains its existing schema validation. Context-dependent fallbacks remain at their call sites and are documented. Explicit installed values, including zero and false, are preserved.

The [tuning reference](TUNING-REFERENCE.md) tables are generated by `python tools/config_registry.py --write`. Tests compare registry entries with shipped settings, validation boundaries, required flags, cockpit editor ranges and generated documentation.

## Delivery 6: staged control extraction

The six entries were extracted one at a time: `speedDriveRequest`, `sampleVessel`, `systemsControlTargets`, `systemsAcquisitionControl`, `updateSystemsRecovery` and `updateSystems`. Each stage was compared against saved pre-extraction traces before the next extraction.

See [control refactoring evidence](CONTROL-REFACTOR-EVIDENCE.md) for function boundaries, 121 sampling/allocation/recovery/dispatch observations, model/replay comparisons and measured costs. Provider allocation and acquisition each add one transient demand table, approximately 1.3 KiB per call in the measured Lua engine. Other measured paths retain their allocation totals. No speculative performance optimization or tuning change was applied.

These are offline refactor checks. Physical flight validation has not been performed, and no live installation was changed.

## Final verification

The full regression run passes all 245 tests with zero failures and zero errors (624.954 seconds), using Python 3.12.14, Lupa 2.6 and Lua 5.2. `project.py check` passes with 97 source inputs, five core payload files and three state payload files. Cobalt 0.9.9 passes 33 scenarios. Compilation and source/bundle round-trip assertions pass in the regression suite; the standalone builder's report records its own object/archive/source-stability validation separately. Detailed machine-readable results are written to `output/tests/results.json` and `output/tests/cobalt/results.json`; the full log is `output/tests/results.log`.

Installer release `amaryllis-6612927561c5` was built and verified from source fingerprint `402388e3e7ccdddac23acb39de72dd6ffb2254d48b39cbc8f346a61118a3b20d`. Its output is `output/installers/Amaryllis-20261101-233834-6612927561c5-d403be41/`, including `media/`, the distributable ZIP and the build report. The build includes the eight shipped hover bands and roll/pitch leveling bias.

The ZIP's 62 entries pass its integrity check. Archive SHA-256: `58ba1b4083eccf9def317e48bcf68f4aad9e51770e6db65131ca1e663052f18c`. The built input inventory and fingerprint match the final maintained source and builder files.

The first 240-test run found one test-cleanup error: a simulated open world still held its Windows lock when temporary-directory cleanup ran. Cleanup now releases the lock-holder before removing the directory; all five world-lock tests pass in the focused rerun. The updater's refusal behavior is unchanged.

Export/rebuild checks caught a descriptive helper header being stripped as a generated section comment. The header now uses a regular descriptive comment. Both loose and bundled disk re-export checks pass with byte-identical libraries. The 11-test focused rerun also passes the updater GUI source-preview/apply workflow, which had encountered a Windows access error during a staging-directory rename in the previous run.

A Tcl `poll` callback diagnostic appeared during GUI window teardown in the final run. The GUI workflow assertions passed. This observation is separate from the control and persistence results.

## Pressure integration investigation

See [pressure evidence](../diagnostics/PRESSURE-EVIDENCE.md). Historical recordings select Sable pressure. The current binding's argument acceptance still requires an in-game observation. No pressure-call correction is included here. Any correction enabling target-altitude pressure must test LIMITED/target-unreachable behavior at Y 280, 290, 300, 306 and 310 in the plant and in physical flight before deployment.

## Delivery constraints

Stored tuning, learned values, selected modes, installed role handling and lift-provider retention are preserved. Unrelated working-tree edits remain in place. Protected instruction files are unchanged. The generated installer is for review and subsequent use through the existing source-based build/update workflow.
