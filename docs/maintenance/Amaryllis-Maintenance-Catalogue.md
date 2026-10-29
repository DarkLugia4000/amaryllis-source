# Amaryllis maintenance catalogue

Updated 28 October 2026 for builder 2.8.0 export behavior, with the existing
installed-runtime inventory retained for the other maintenance paths. This catalogue introduces no code changes.
A ship has the features of its applied release. Updating the builder alone does
not update an existing ship or disk.

## Installation and package delivery

| Path | How it starts | What it handles | Requirements / limits |
|---|---|---|---|
| Fresh installation | Installer disk: Setup and role pages | Installs core and state directly; registers the other computers and supplies their downloader/commissioning screen. | Writable installer disk and temporary drive access at each computer. The disk accumulates assignments. |
| Assignment review/correction | Disk: Assignments | Lists all 16 expected computers and IDs; previews a move or swap for the computer holding the disk. | Supported during commissioning before import/application installation. Core/state have separate restrictions. A swap must visit both computers. |
| Pending registration resume | Reopen setup on the original computer | Resumes interrupted installation for the same computer, role and release. | Requires the matching pending record. |
| Fleet import | Disk: Import assignments into core | Copies completed registrations into core's fleet registry. | Correct registered core and no unfinished correction plan. |
| Wireless package delivery | Core installer service after import | Serves the 14 auxiliary packages from matching media; receivers stage, verify and commit them. | Core, media, communications and registered receivers. State is installed directly from disk. Core keeps no auxiliary package library. |
| Transfer/commit recovery | Receiver and server retry/restart paths | Retries transfers; recovers or rolls back interrupted managed commits. | Limited to installer transactions. Unresolved recovery is reported for attention. |
| Explicit auxiliary reinstall | Authenticated remote administration; internally /installer/reinstall | Requests the registered role package again. | Functioning receiver, core package service and matching media. This receiver path does not reinstall core. |
| Auxiliary library adoption | Disk: Adopt auxiliary package library | Adopts a compatible auxiliary catalogue/library reference. | Core runtime stopped; compatibility checks pass. Full core/state/fleet changes use the Windows updater. |
| Installation monitoring | Core Home > Installation; temporary auxiliary screen | Shows checking, waiting, sending, verification, completion and errors. | Package completion does not establish hardware readiness. |
| Installer pause/resume | Create/remove /installer/paused on core | Pauses package work while runtime workers continue. | Advanced shell control; removing the marker resumes a responsive running installer loop. |

The disk setup UI stays on the disk. Each auxiliary commissioning helper removes
itself after strict receipt/application verification, then reboots into the normal
console. Transaction owners clean completed staging, temporary rollback copies
and journals. Startup, receivers, trust settings and required receipts remain.
Core runs without the disk after installation; inserted matching media keeps the
existing package service available.

## Automatic operational recovery

These mechanisms do not require the installer disk.

| Path | Trigger | Response | Recovery conditions |
|---|---|---|---|
| Lift authority / ACK recovery | Expired probe/control authority, probe-required status or missed acknowledgement | Suspends feedback, retains lift intent, re-probes expired peers and renews controlled peers at verified targets. | Fresh identity, compatible hardware/providers, valid observations, permitted targets and verified ACK/readback. PID integration pauses during recovery. |
| Vessel telemetry recovery | Missing, stale or incomplete vessel data/identity | Waits for evidence while retaining lift intent; reconciles partially applied targets through the guarded coordinator. | Fresh vessel data and compatible hardware. During assembler uncertainty, a fresh changed Sable UUID updates retained control references and triggers source-calibration validation. |
| Assembly verification | State cannot establish a fresh Sable association | Checks the fresh physics-assembler state and continues available peripheral fallback. After five minutes unresolved, publishes a yellow operator-check warning. | Only fresh explicit disassembled evidence closes the gate; verified association or assembler state clears the uncertainty warning. Applied lift remains retained. |
| Sampling retry/rediscovery | Failed or expired reader attempt | Retries sampling and schedules rediscovery after repeated failures. | Working peripherals must return valid readings. Failed reads never refresh data age. |
| Independent sensor fallback | Primary field unavailable or a supported alternate source is preferable | Selects valid per-field sources with calibration/identity checks; the physics monitor can prefer the alternate pressure source when supported by its consistency check. | Requires supported, fresh alternative readings. |
| State-computer failover | State frames remain absent and core event lag permits takeover | Core starts local readers; hands back after sustained fresh state frames, with longer handback after flapping. | Core must reach the sensors. Event backlog can defer takeover to avoid extra load. |
| Role/component supervision | Supervised application or chamber lift/relay component exits/errors | Logs and retries the component through its supervisor. | Supervisor and dependencies still running. Persistent faults can keep failing. |
| Propulsion/debug worker watchdogs | Worker completion heartbeat stalls | Replaces worker context and relaunches with retry pacing. Propulsion uses its existing stop path on a stall. | Core supervisor/scheduler responsive. |
| Bridge command queue | Request awaits core response | Queues/retries pilot UI requests and matches acknowledgements. | Current identity/session/sequence checks and command validation still apply. |
| Console presentation recovery | Panel drawing failure | Restarts presentation while healthy workers continue. Reopening startup reuses workers. | F2 provides the host recovery shell independently of drawing. |
| Duplicate-ID advisory | Repeated competing registered identities in existing traffic | Reports POSSIBLE DUPLICATE ID and competing claims; expires after conflict goes quiet. | Operator resolves loaded duplicates/IDs. Advisory does not choose a winning ship or reassign identities. |

Propulsion lease expiry can ramp drive demand down. Lift-authority recovery
retains applied provider settings while renewed commands are verified. Kill Lift,
operator stop, incompatible hardware and verified disassembly retain their
existing guards.

## Operator-controlled runtime maintenance

| Path | Access | Purpose / boundary |
|---|---|---|
| Start / Stop Systems | Bridge Systems > Options | Runs the guarded start or stop sequence. Stop intentionally changes operating state. |
| Restart Systems | Bridge Systems > Options | Coordinates core/bridge restart with a one-shot checkpoint while chambers stay running. Requires checkpoint/handshake success and revalidates intent after restart. |
| Airborne current-lift adoption | Supported startup/resumption logic | Can adopt verified existing lift without repeating takeoff/build. Requires preflight/identity/provider checks; a raw reboot does not perform every coordinated restart step. |
| Hardware recheck | Bridge Settings > Lift maintenance/recheck | Rediscovers/samples hardware without reboot or activation/gas setters. Requires fresh nodes, disengaged altitude control and no conflicting operation. |
| One/all chamber restart | Bridge Settings > Lift maintenance | Review/confirm one chamber or restart all sequentially, waiting for reconnection. Applies boot/freshness checks and configurable CoM altitude lock with explicit one-operation override. Failure stops the sequence. |
| Kill Lift / Disarm Kill | Bridge Systems > Options and confirmation flow | Dedicated emergency latch/disarm lifecycle. Recovery does not bypass the latch. |
| Current Issues | Touch the current navigator warning, or Settings > Current Issues | Shows active issues, sources, available recovery detail and age. Equal-priority warnings rotate every three seconds; Back returns to the invoking view. |
| Shell / Lua | Core Home > Tools; F2 shell | Manual inspection and troubleshooting. General shell access is not an automatic recovery routine. |
| Fleet ID editor | Core Tools > Full core view / edit IDs | Edits runtime fleet configuration. Registry editing alone does not relocate hardware or update all receiver trust records. |

## Diagnostics, logs and remote access

| Path | Access | Capability / dependency |
|---|---|---|
| Onboard status/errors | Core Home > Status / Computers / Logs | All 16 roles, runtime/hardware state, report age, package and errors/details/related core logs. Cached telemetry only. Reply time appears only when measured; relayed controllers identify their chamber source. |
| Auxiliary console | Local computer | Overview, components, faults, logs, installer status and utilities while its launcher/console works. |
| Debug recording | Bridge Settings > debug recording | Bounded flight/control recording to /amaryllis-logs/ on a writable disk visible to core. Requires a separate recording disk; installer disks are refused. |
| Windows read-only diagnostic bridge | Diagnostic client plus configured Windows host | Registered runtime snapshots, console history and supported timing data. Requires matching host registry, connected clients and authentication. Normal flight does not require this service. |
| Reconnection probe | Existing reconnect-diagnostics helper | One-shot read-only diagnostic probe; does not restart/control flight tasks. |
| Remote provisioning | Core Tools > Install / pair remote | Explicit reviewed installation onto a docked computer, with pairing and original-startup backup. Disk insertion alone does not trigger installation. |
| Authenticated remote administration | Paired management client | Status/log inspection, bounded allowlisted file/config editing, reboot and auxiliary reinstall. Uses trusted admin/token and current boot/request checks. Distinct from read-only Windows diagnostics. |
| Remote flight access | Core Tools > Remote flight access | Explicit grant/revoke of the separate flight capability for paired clients. |

## Windows and maintainer helpers

| Tool / path | Audience | Purpose / result | Boundary |
|---|---|---|---|
| Build installer | Maintainer | Exports a saved installation into media, distributable ZIP, README, Windows helpers and private build report; optionally includes saved learning. | Reads saved inputs; refuses completion if source files change during export. |
| Runtime bundler: bundling.py | Builder internal / maintainer | Packs named Lua modules into few installed runtime files; verifies/extracts embedded sources for rebuilds. | Windows packaging step, not an onboard service. Config and persistent JSON remain separate. |
| Automatic package-source reconstruction | Builder internal | Reconstructs exact package sources from installed bundles and metadata; searches known disk/export locations for matching media if necessary. | Verifies catalogue, receipts and source matches. Recovers build inputs, not a running ship. Manual library override optional. |
| Update existing ship | Owner / maintainer | Previews Add/Replace/Remove/Keep, backs up externally, overwrites all 16 existing installations and removes obsolete managed code. | Fully closed Minecraft/server; complete supported fleet/receipts. Preserves IDs, existing stored values and all avionics/data bytes. No parallel installation. Distributed entry: windows-update/Update Amaryllis.cmd. |
| Update rollback / Restore backup | Owner / maintainer | Failed-write rollback and interrupted-update recovery from external transaction folder. | Game closed, transaction backup retained. Hash checks refuse overwriting newer edits. |
| Preview startup repair | Owner / maintainer | Narrow replacement of known faulty auxiliary launchers from the earlier shell-environment defect. | Specific compatibility migration, closed game and external verified backup. Not a general corruption repair utility. |
| ComputerCraft settings editor | Owner / maintainer | Preview/apply computer capacity, disk capacity and Lua execution threads, with backup/restore. | Selected TOML only, game closed, unrelated settings preserved. Does not change general task budgets. Available in distributed windows-settings helper. |
| Saved-learning export | Maintainer build option | Validated hover-offset.json and level-bias.json defaults seed missing fresh-core files. | Existing learning wins. Updates preserve target data. No live PID history, sessions or credentials exported as learning defaults. |
| tools/package_windows_builder.py | Maintainer | Verifies asset hashes and packages a versioned builder ZIP. | Does not build an in-game installer or update a ship. |
| Tests, renderers and analysers | Maintainer | Simulated input, CC UI rendering, transaction/recovery validation and recording/performance analysis. | Historical stage/apply/incident scripts are not supported general owner entry points. |

Recipients receive the installer ZIP and its Windows helpers. They do not need
the maintainer's builder.

## Persistent pilot modes, builder 2.7.0

Heading/throttle selections use the existing avionics/data/control-presets.json.
Core restores validated same-vessel selections through the existing neutral and
readiness gates. Navigator remains a view of core's selection. AP cancellation,
anchor release and transient input/identity faults do not force a different mode.
Explicit mode changes are saved before acknowledgement; setpoint saves retain
their existing coalesced cadence.

## Persistent records and cleanup

- Fleet configuration, IDs, pairings and hardware bindings identify the ship.
- avionics/data JSON stores learning, calibration and supported runtime/checkpoints.
  Windows updates preserve these bytes.
- Trust configuration, receipts and commit journals support managed installation.
- External Windows update backups include originals, hashes, preview and journal.
  Settings edits have their own backup/restore path.
- Flight recordings stay on the recording disk; analysis/UI evidence stays in the
  maintainer workspace.
- Each transaction cleans its temporary files. No general arbitrary-file purge
  runs on core.

## Scope

Corruption detection and repair are outside the project. Existing checksums
protect release creation, transfers and managed updates. They are not a
continuous installed-file scanner or damaged-file replacement service.

Operational recovery covers supported transients when valid evidence returns.
Confirmed identity changes, incompatible hardware, operator stop and kill remain
guarded. Duplicate identities require operator resolution.

## Source references

- [Current builder documentation](../../Amaryllis%20Installer%20Builder/README.md)
- [Disk setup](../../Amaryllis%20Installer%20Builder/assets/setup.lua)
- [Receiver transactions](../../Amaryllis%20Installer%20Builder/assets/installer.lua)
- [Commissioning helper](../../Amaryllis%20Installer%20Builder/assets/auxiliary-startup.lua)
- [Core media adapter](../../Amaryllis%20Installer%20Builder/assets/core-media.lua)
- [Panel UI/host](../../Amaryllis%20Installer%20Builder/assets/panel-console.lua)
- [Identity advisory](../../Amaryllis%20Installer%20Builder/assets/identity-watch.lua)
- [Windows updater](../../Amaryllis%20Installer%20Builder/updater.py)
- [Bundler/source reconstruction](../../Amaryllis%20Installer%20Builder/bundling.py)
- [Settings editor](../../Amaryllis%20Installer%20Builder/cc_settings.py)
- [Lift recovery](../../diagnostics/2026-10-26/lift-handshake-recovery.md)
- [Vessel recovery](../../diagnostics/2026-10-26/vessel-telemetry-recovery.md)
- [Package reconstruction](../../diagnostics/2026-10-27/package-recovery/README.md)
- [Updater report](../../diagnostics/2026-10-27/existing-install-update/README.md)
- [Specific launcher fix](../../diagnostics/2026-10-27/bundled-startup-fault/README.md)

Also checked installed core modules for sampling, vessel sources, failover,
restart, watchdogs, remote management and console supervision, plus chamber-fl's
lift/component supervisor. Older reports describe their release at the time;
current builder sources take precedence over old UI instructions/file counts.
