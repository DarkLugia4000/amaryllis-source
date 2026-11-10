# Shared runtime values (`os.__amaryllis*`)

ComputerCraft programs on one computer share the `os` table, so Amaryllis uses `os.__amaryllis*` fields to pass state between the console, its worker tabs, the installer and diagnostics. These values live in memory only. A reboot or shutdown clears all of them; none is written to disk.

The test `tests/test_source_integrity.py` checks this table against the source: a new `os.__amaryllis*` name, or a name listed here that no longer exists, fails the check until this document is updated.

Core's propulsion, debug, sampling and failover worker contexts use `avionics/runtime_state.lua` to read and publish these same keys. The accessor reads the current `os` table and preserves table identity, owner comparisons and existing cleanup points. Programs using direct `os` access continue to share the values. Other ownership groups retain their existing access paths.

"Cleared" lists where code sets the value back to `nil`. "Replaced" means each new owner overwrites the previous value without clearing it first.

| Name | Owner and creation point | Other writers | Readers | Lifetime and cleanup |
|---|---|---|---|---|
| `__amaryllisCoreAction` | Core `avionics/main.lua` supervisor, after an `amaryllis_core_action` event | none | `panel-console.lua` asset (Fix gas mix lag page) | Core program session. Holds the last console action: type, accepted, reason, time. |
| `__amaryllisPersistentStateWrite` | Core storage while committing a state section | none | Core storage workers | Held for the read, merge and write transaction, then cleared. |
| `__amaryllisRuntime` | Each role's main program publishes its runtime snapshot: core `avionics/main.lua`, state `state_reader.lua`, chamber, thrust, primary, heading and navigator packages | `chamber_link.lua` (link status) | consoles, diagnostics, `reconnect-diagnostics.lua`, `chamber-hardware.lua`, `panel-console.lua` asset | Program session. Replaced on each publish and restart. |
| `__amaryllisLog` | Console (`common/console.lua`) installs the shared logger | Console restores the previous logger when its capture ends | Most core modules, `chamber-lift.lua` | Console session. Restored to the previous logger on exit. |
| `__amaryllisDiagnostics` | Console capture | none | diagnostics modules, `main.lua`, `panel-console.lua` asset | Console session. Replaced. |
| `__amaryllisCapturedPrinters` | Console | none | none (held to keep printer captures alive) | Console session. Replaced. |
| `__amaryllisDiagnosticTabLaunched` | Console | none | Console (launch guard) | Computer boot. Never cleared, so the diagnostic tab opens once per boot. |
| `__amaryllisCloseDiagnostic` | `diagnostics.lua` (core and package copies) | none | diagnostics shutdown | Diagnostic socket session. Replaced. |
| `__amaryllisFleetRegistry` | Console or `auxiliary-startup.lua` asset when a core session is accepted; core `main.lua` on start | none | installer, setup, `server.lua`, diagnostics, `chamber_link.lua`, heading and navigator packages | Core session. Cleared when a session is retired. |
| `__amaryllisCoreLink` | Auxiliary console after a validated registry reply; state after a validated wired context | none | console reachability status | Incoming core traffic. Expires after ten seconds and is replaced on recovery. |
| `__amaryllisCoreConnectionState` | Shared console module | none | console status and chamber child-link presentation | Console session. Reports CONNECTED or CORE UNREACHABLE for auxiliaries; core is exempt. |
| `__amaryllisIdentity` | Same acceptance paths as the fleet registry; core `main.lua`; `state_reader.lua` | Console fresh-install path | diagnostics | Core session for auxiliaries; boot for core and state. Cleared with the fleet registry. |
| `__amaryllisRetiredCoreSessions` | Console and `auxiliary-startup.lua` asset | none | Session acceptance (rejects obsolete core sessions) | Computer boot. Replaced with the updated list. |
| `__amaryllisCoreWorkerTabs` | Console or `panel-console.lua` asset when worker tabs launch | none | `reconnect-diagnostics.lua` | Console session. Replaced on relaunch. |
| `__amaryllisPagedConsole` | Console or `panel-console.lua` asset | none | `main.lua` | Computer boot. Set once, never cleared. |
| `__amaryllisPanelOwner` | `panel-console.lua` asset | none | Console (focus an existing panel) | Panel session. Replaced. |
| `__amaryllisPanelView` | `panel-console.lua` asset | none | none outside the panel | Panel session. Replaced. |
| `__amaryllisInstallerProgress` | `core-progress.lua` asset | none | `panel-console.lua` asset | Installer run. Replaced. |
| `__amaryllisInstallerProbe` | `installer/server.lua` | none | diagnostics | Installer session. Replaced. |
| `__amaryllisCoreMonitorOwner` | Core `main.lua` monitor | none | Core monitor (single-owner guard) | Monitor session. Cleared when the monitor stops. |
| `__amaryllisRemoteAP` | Core `main.lua` | none | consoles, `remote_install.lua` | Core session. Replaced. |
| `__amaryllisCockpitTiming` | Core `main.lua`; `state_reader.lua` | none | diagnostics | Program session. Replaced. |
| `__amaryllisPropulsionContext` | Core `main.lua` propulsion worker | none | none outside the worker | Worker session. Replaced on each launch; cleared if the worker tab fails to open. |
| `__amaryllisDebugContext` | Core `main.lua` debug worker | none | none outside the worker | Worker session. Replaced. |
| `__amaryllisSamplingContext` | Core `main.lua` sampling worker | none | none outside the worker | Worker session. Replaced on each launch; cleared if a reader tab fails to open. |
| `__amaryllisFailoverContext` | Core `main.lua` state-failover sampler | none | none outside the sampler | Failover session. Cleared when state frames recover; each failover reader then exits after its current read. |
| `__amaryllisStateWorkers` | `state_reader.lua` | none | none outside the reader | State reader session. Replaced. |
| `__amaryllisRecoveryProbe` | `reconnect-diagnostics.lua` | none | diagnostics | Probe run. Replaced. |
| `__amaryllisRemoteInstallLock` | `remote_install.lua` | none | `remote_install.lua` (re-entry guard) | Install attempt. Cleared on success and failure. |
| `__amaryllisRemotePermissions` | `remote_install.lua` after a completed activation | none | `remote_ap.lua` | Core boot. Replaced after each successful activation. |
| `__amaryllisCornerAltitude` | `chamber_link.lua` on each altitude frame | none | `chamber-hardware.lua`, `thrust-hardware.lua` | Child boot. Cleared when the child computer reports a new boot. |

## Notes for changes

- `panel-console.lua`, `auxiliary-startup.lua`, `core-progress.lua`, `installer.lua` and `setup.lua` are hash-locked builder assets, also present on installed media. A rename here must keep the old name working for those files.
- Several values are written by both the core console and the package console. Those two consoles are one source: the core copy is generated from `packages/common/console.lua` during collection, and the build rejects a core copy that differs.
