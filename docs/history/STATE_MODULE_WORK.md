# ama-state implementation work in progress

User moved core's sensors/peripherals to new computer **68**, label **ama-state**, in New World. Core35 initially had only wireless modem back, drive bottom, and adjacent computer left. Computer blocks were touching, so I instructed wired modems/cable. User has confirmed **wired link ready**. No pending questions. User expects implementation, not another plan. No subagents permitted.

Prior v122 is built/staged in both worlds, with compact heading packets and bounded radio inbox. Wireless-removal test confirmed all five local readers and Sable recovered with radio off, diagnostic status0.17sec, cockpit0.038sec, assembler/vessel0.10sec. Raw capture: diagnostics/2026-10-20/core-wireless-off.json. Most recent release v122 passed369 tests. Core remains flight authority. Do not reset user's settings/other role IDs. New World2 has no state hardware and must retain old local sampling mode until state assigned.

Current implementation decision:

- Optional fleet role `state`, default label ama-state, no ID until assigned. Assign only New World ID68, preserve all other assignments.
- Dedicated raw wired-modem protocol (not rednet) with fixed separate request/frame channels. Core binds expected state ID from fleet, helper binds core ID from its installed config. Envelopes pin core session, helper boot and monotonic frame sequence; reject replay/old-session/other-peer/wireless transport. No arbitrary Lua or setters in protocol.
- Core continues receiving wireless chamber reports but **does not query sensors locally** in state mode, even though shared wired network makes peripherals visible.
- Core sensor polling jobs replaced with one wired-receive/link worker when state ID assigned; local-mode behavior stays unchanged for older installations/world2.
- Helper reuses read-only IO sampling methods (IO sampleVessel/Fallback/Assembly and Sources.sampleAssembler). Create a lightweight IO object with fields/config/peripheral/sublevel/aero/fs/vector/now/nodes/sampling; do not instantiate core Flight or call IO control/send/activation methods. IO sampleVessel needs nodes' quadrant altitude summaries to learn body bow; core sends small node altitude context.
- Frames carry raw primaryReadings (six keys), fallbackReadings (fixed sensor keys), primaryVessel metadata (attitudeBow/axisSource/environment and at), inputs (one coherent nine-input batch with actual timestamps), assemblyTrack, bindings/fingerprint, small sampler summaries, and bounded pressure cache. Core ingests vetted fields into its IO and runs existing Sources.compose. Preserve timestamps, never refresh them on packet receipt.
- Add Sources.acceptBackup helper to validate each incoming raw key (vectors/quaternion/numeric/identity/axis readings). Primary data uses existing Sources.acceptPrimary with original timestamp.
- Reader reboot clears manual neutral gates before accepting demands; retain control presets and normal identity/kill rules. Link loss expires original measurements and assembler18sec gate; no local sampling fallback or implicit authority from heartbeat.
- Target-altitude air-pressure queries must also move to helper: IO.airPressureAtWorldY in state mode returns cached helper result or records a request for next wired context, never calls aero on core. Helper queries requested/current selected target through existing cache.
- Core scanHardware in state mode must only inspect local modem/drive sides and avoid enumerating sensor methods across wired network. Keep IO inventory.modems/wirelessModems valid for radio. State wired link opens only dedicated channels on wired modem. Do not open wireless on helper.

Installer approach planned to limit bootstrap complexity:

- State is an optional **direct disk-installed** role, not the existing radio bootstrap. Portable release gets `state` payload (state_reader app plus exact needed read-only dependency files). Setup.installAuxiliary branches to installState for role state, writes dedicated startup and helper config pinned to deployment core ID/new state ID, registers role on deployment disk. Returning disk/importing fleet enables delegation. Existing radios unchanged. Document state updates via disk until wired auto-update is explicitly supported.
- Fleet DEFAULTS/ROLE_ORDER add optional state. Installer server registry validator must accept optional state key (otherwise core registry becomes invalid), but state need not join wireless package check-in loop. Could define ROLE_FILES.state for package manifest future use or simply allow role state in registry validator and ensure it isn't treated as a radio-installed required role.
- Add state to portable release.roles even when source fleet lacks ID, no hardcoded68 in installer. Build state payload from current core reader dependencies; source-world live install can be staged directly into68 after backup of its current files.
- Required dependencies for helper sampling: io.lua (requires thrust,fleet,vessel_sources), thrust.lua (no requires), fleet.lua, vessel_sources.lua (requires storage), storage.lua (requires navigation_settings), navigation_settings.lua, sampling.lua, state_wire.lua, state_reader.lua. No Flight/main control loop.

Source paths: core = the test world's computer 35 (`saves/New World/computercraft/computer/35`). Project Amaryllis-portable. Python = the agent's bundled Python runtime; Lupa in temp/amaryllis-thrust-live-runtime. Tests/check_vessel_sources.py copy core avionic Lua to validation-v45 tree. Existing regression scripts documented in conversation.

Files inspected in this turn, no production edits yet at note creation:

- fleet.lua has ROLE_ORDER/DEFAULTS whitelist (15 roles), validateComputers accepts missing roles.
- io.lua IO.new invokes Thrust.new/Fleet/setRegistry, so helper should use lightweight setmetatable reader rather than pretending its physical ID is core.
- IO.scanHardware/readInputs/sampleVessel/sampleFallback/sampleAssembly/readSensor are reusable getters. IO.sampleVessel commits Sources.acceptPrimary per getter; independent flag uses cached backup reads. Needs nodes for attitude alignment, environment cache/vector API, and source calibration.
- IO.airPressureAtWorldY queries aero unless cache hit. Must delegate in state mode.
- main.lua io initialization and jobs for vessel/cockpit/assembly/fallback/assembler; multishell jobs and basic parallel branch both need conditional remote mode. publishRuntime uses os globals; snapshot has `readers` summaries.
- installer/server.lua validator rejects unlisted role keys; REQUIRED_ROLES 15. ROLE_FILES packages. Do not add state to required radio recipients by accident.
- setup.lua installAuxiliary currently bootstrap allroles, importFleet builds all release roles. preflight is fresh-only unless matching pending journal. state needs direct payload path and startup.
- build_release.py ROLES10; finalize appends other roles. State should use explicit state payload creation, avoid existing folder map falling through to chamber/state. Portable test_release loops bootstrap roles from mapping; extend for direct state install rather than forcing state through existing radio-client fixtures.
- helper68 currently exists with avionics directory. Inspect contents and back up before staging. Never touch protected AGENTS/.agents.

Tests needed: frame source/session/boot/seq binding, malformed/nonfinite/future/stale timestamps, no renewal by replay/heartbeat, inputs retain/neutral on helper reboot, field loss/assemblerfalse, safe local-mode compatibility, no core sensor API calls in delegated mode, read-only helper, wired-only transport, installer remapping IDs and direct state install, full previous source/controller/restart/installer regression checks. Then build v123 and stage core/state68 in New World; sync compatible code to world2 without assigning nonexistent state. Update user with concrete setup/reload steps. No live flight commands/reboots through diagnostics; user does in-world loading.
