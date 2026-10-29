# Amaryllis navigator information and warning plan

Updated 28 October 2026, Europe/Berlin.

Status: implemented in Installer Builder 2.8.0. Release verification and rendered evidence are recorded in the delivery report.
The live installation is unchanged. See the [delivery report](diagnostics/2026-10-28/information-delivery/report.html)
for rendered screens, validation and application instructions.

Related documents:

- [Current navigator state inventory](diagnostics/2026-10-28/navigator-states/README.md)
- [Inventory source expressions](diagnostics/2026-10-28/navigator-states/source-expressions.md)
- [Earlier UI presentation plan](UI-PRESENTATION-PLAN.md)

The inventory describes existing behaviour at the time of inspection. This plan describes intended changes and takes precedence over earlier proposals in this discussion.

## 1. Operating requirements

### Lift retention

Preserving applied gas-provider settings is a requirement of normal operation and maintenance.

- Core activation, Ctrl+R reboot, ordinary updates and recoverable faults must preserve applied lift settings.
- Physical support is not a prerequisite for an ordinary core restart.
- Stop Systems and Kill Lift are explicit operator actions that intentionally remove main lift.
- Assembly uncertainty, warning escalation and elapsed recovery time must not implicitly invoke those actions.
- Assembly lock must preserve applied gas-provider settings.
- Changes to PID calculations or demand shaping must preserve the existing gas-provider retention behaviour unless a deliberate handling change is part of the task.
- Deliberate changes to gas-provider handling, activation, shutdown or retention are permitted when they are the subject of the work.
- Any proposed change that could cause lift loss or a drop requires advance notice, before applying or testing it. The notice must identify the affected behaviour and when the risk applies.
- Correct stale comments when found, including during planning. Protected instruction files remain read-only.

Retaining provider settings is distinct from actively regulating altitude; the former must survive interruptions to the latter.

### Delivery and scope

- Update the builder as needed. A new permanent installer is not required for each development change.
- Keep installed file count low; use existing modules and suitable structured data where possible.
- Computer names remain lowercase.
- This pass covers navigator information, warning navigation, the agreed assembly/identity recovery changes and a broad source-comment pass. It does not introduce general corruption repair.

## 2. Colour meanings

| Colour | Meaning |
|---|---|
| Green | Healthy, successful or operating as intended. |
| Yellow | Transient issue, automatic recovery, pending operation, or a warning that allows normal vessel operation to continue. |
| Red | A condition that makes part or all of normal vessel operation impossible. Operator attention alone is insufficient to make a warning red. |
| Gray | Inactive/neutral information where specified below. |

The armed Kill Lift message is explicitly red. Warning colour is presentation; it must not itself command lift removal.

Routine assembly-verification retries are an exception to visible retry reporting: they belong only in state's logs. Navigator receives the unresolved-assembly warning after five minutes.

The remaining existing states are not all reclassified by this document. Open colour decisions appear in section 9.

## 3. Startup labels

Agreed display sequence:

**OPENING STEAM VENTS -> STATIC INFLATION -> CAPTURING PITCH ZERO -> ACQUIRING SEL ALT -> READY**

| Existing phase/portion | Planned display | Meaning |
|---|---|---|
| CONTROL_START | OPENING STEAM VENTS | Establishing the bulk steam-vent stage. |
| Initial filling and lift establishment | STATIC INFLATION | Initial inflation portion of startup. |
| Existing LAUNCH settling interval | CAPTURING PITCH ZERO | Altitude acquisition is paused while existing trim/leveling continues. |
| Initial startup BUILDING_LIFT after settling, before acquisition display ends | ACQUIRING SEL ALT | Initial acquisition of the startup selected altitude; switches to READY when capture completes or the user changes selected altitude. |
| READY, including user-ended startup acquisition display | READY | Normal altitude control; responding to a user-selected altitude does not imply the vessel has already reached that altitude. |

Implementation requirements:

- Preserve the existing actuator sequence, provider retention, trim and PID behaviour.
- Introduce a presentation distinction where the current phase combines multiple portions of startup.
- The existing settling interval was configured for 10 seconds in the inspected Trial Journeys installation; keep its configured duration.
- Settling-stage presentation takes precedence over an ascent-based label. The vessel can begin moving during settling.
- ACQUIRING SEL ALT is exclusive to initial startup acquisition. End this presentation at normal capture completion or immediately when the user changes selected altitude, whichever occurs first; show READY. Once ended, further target changes, drift correction and recovery of that run must not restore the startup label.
- A core-accepted user change to a different selected altitude ends the startup presentation only. Continue controlling toward the new selection through the existing control logic, without an added PID reset, gas-provider change or assumption that the new altitude has already been reached.
- Do not add a physical stop, new wait interval or forced target change to make a label fit.
- CAPTURING PITCH ZERO names the settling operation. The existing timer does not guarantee exactly zero pitch or zero vertical motion at completion.
- Settle the precise initial-fill/acquisition display boundary from existing verified startup observations during implementation. The earlier proposal to switch solely after a 0.1-block rise is not a final transition specification.
- Existing PROBING and VERIFYING labels have no approved changes in this pass.
- Reboot/adoption/recovery of an already flying vessel should continue using its existing path; the displayed sequence does not require repeating ground startup.

Earlier labels INITIAL LIFT and LEVELING are superseded.

## 4. Other label changes

| Current wording | Agreed replacement | Treatment |
|---|---|---|
| MAX CLIMB | MAX CLB | Preserve contextual treatment unless separately approved. |
| LIFT SUPPORT | V/S DEMAND LIM | Describes vertical-speed demand limited while measured balloon lift develops. |
| HOLD OFF | ALT OFFLINE | Gray. Describes inactive altitude control while lift settings may remain applied. |

NO LIFT is superseded by ALT OFFLINE. The label must not imply that disabling altitude control removes gas or lift.

## 5. Kill Lift and disarm information

| Current/planned message | Planned colour |
|---|---|
| KILL LIFT ARMED; DISARM BEFORE START | Red |
| KILL LIFT PENDING | Yellow |
| KILL REQUEST ACCEPTED | Yellow |
| KILL LIFT INCOMPLETE <reason> | Yellow |
| KILL NOT CONFIRMED; CHECK CORE | Yellow |
| DISARMING KILL; SYSTEMS STOPPED | Yellow |

The main message KILL LIFT ARMED; DISARM BEFORE START replaces LIFT KILL LATCHED; DISARM BEFORE START.

Implementation requirements:

- Honour message-specific colours in the final Flight warning selector.
- Show the specific pending, incomplete or disarming message when applicable.
- Prevent the general armed/latch branch from hiding those more specific states.
- Keep the stable armed state red.
- Preserve existing kill, disarm, confirmation and retention behaviour.

KILL LIFT FAILED <reason> has no separately approved colour change yet.

## 6. Recovery wording and attempt count

Applies to lift recovery, autopilot and digital anchor.

- Replace time-only FAILED / RECOVERY_FAILED presentation while automatic retries continue with RETRYING (#).
- # is the number of actual recovery attempts for the current incident.
- Count an attempted recovery, not a draw, update tick, elapsed second or repeated log of the same attempt.
- Reset the count after successful recovery or when a distinct new incident begins.
- Keep elapsed time available in details if useful.
- A long-running retry must not be labelled a terminal failure solely because 120 seconds elapsed.
- Genuine blocking conditions remain distinguishable from continuing automatic recovery.
- Use the same wording and counting semantics across all three systems.

Assembly-verification retries stay in state's logs and do not produce this navigator banner.

## 7. Assembly verification and peripheral fallback

### Agreed sequence

1. State checks its own Sable association.
2. If state cannot establish that association, state checks the physics assembler.
3. If and only if a fresh, successful assembler read explicitly reports disassembled, the system enters the assembly lock.
4. Otherwise, state continues the checks until it can verify a condition. During unresolved verification, it uses available peripheral sensors for vessel data.
5. After five continuous minutes unresolved, state reports an assembly warning through core to navigator. Systems keep running, applied lift settings remain retained, and verification attempts continue.

An assembler being missing, disconnected from the peripheral network, unreadable, stale or timed out is not an explicit disassembled result. Here, disassembled means a successful isAssembled() == false observation.

### Outcomes

| Observation | Outcome |
|---|---|
| Fresh expected Sable association | Verified; normal vessel-data path. |
| Sable association unavailable; assembler explicitly true | Assembly verified; use available peripheral fallback while Sable recovers. |
| Sable association unavailable; assembler explicitly false | Assembly lock, retaining applied provider settings. |
| Sable association unavailable; assembler cannot provide a conclusive reading | Continue verification and peripheral fallback. |
| Verification unresolved for five minutes | Yellow navigator warning; no assembly lock or systems shutdown. |

During an unreadable-assembler incident, expect the last known Sable vessel UUID to remain the association. If a fresh valid Sable observation establishes a different UUID, update the previous vessel UUID and continue, propagating the new association to dependent computers and state as necessary. A changed vessel UUID alone must not leave normal operation in a permanent identity-change lock.

This replaces the earlier rule treating every fresh different UUID as a blocking identity conflict. Computer IDs, registered roles, trust/session checks and duplicate-computer detection remain separate from the vessel UUID.

### Warning and logging

- Routine checks, retries, read errors and fallback details belong in state's logs.
- Do not show ASSEMBLY CHECK RETRYING (#), or another routine assembly-check warning, on navigator.
- At five continuous minutes unresolved, navigator shows:
  **ASSEMBLY UNVERIFIED; OPERATOR CHECK REQUIRED**
- Colour: **yellow**.
- The timeout requests operator intervention; it must not lock systems, stop systems or remove lift.
- Continue checking after the warning.
- Successful assembly verification clears the incident timer and warning automatically.
- Another failed attempt or packet arrival does not reset the timer. Fresh, conclusive assembly evidence does.

### Architecture

- The previous proposal to request an independent Sable check from core is superseded. This sequence does not require that extra request.
- State remains the normal sensor reader; core remains flight/control authority.
- State reports the verification outcome and supporting observation to core, which publishes the appropriate navigator information.
- Apply existing identity/session/freshness validation to those reports.
- Peripheral fallback supplies only measurements the available sensors can establish. Absolute-position-dependent AP/anchor guidance may pause if absolute position is unavailable, while other systems continue.
- Review the existing combined vessel-data selector, which currently clears selected identity when assembler verification becomes stale even if fresh Sable identity exists. That dependency must not defeat the agreed Sable-first verification sequence.
- A fresh explicit false may produce the assembly lock. Uncertainty alone must not become false.

### Vessel UUID continuity and update

- While the assembler is unreadable and no fresh Sable identity is available, retain the previous expected vessel UUID.
- Retaining that association does not refresh a sensor timestamp or turn missing measurements into valid data. Continue using valid peripheral fallback fields.
- When a fresh valid Sable observation reports a different UUID, adopt it as the new vessel association and continue the existing operation under its normal measurement/authority checks.
- State publishes the observed identity; core coordinates adoption and propagates the current association to computers that need it. Core must not keep restoring an obsolete UUID into state.
- Update dependent expected/retained UUID references consistently: active systems, cockpit selections, AP/anchor operation, sensor-source selection and caches, saved control presets, and restart/recovery checkpoints, where those records actually bind to vessel identity.
- Preserve selected modes, targets and appropriate learned values. Revalidate coordinate-frame-dependent calibration and measurements against the new association; replacing a UUID string is not evidence that every cached measurement or transform is current.
- Review actual receivers before adding propagation. Computers without vessel-UUID state do not need a new copy or an extra file.
- This is Sable vessel UUID adoption, not reassignment of ComputerCraft IDs, fleet roles, pairing credentials or trusted command sessions.
- A delayed packet from an obsolete association must not overwrite a newer accepted identity. Retain the existing sender/session/freshness checks around observations.
- No adopted identity change may itself issue a zero-lift command or discard retained lift intent.

The precise handling of a previously confirmed disassembly lock on reassembly remains an open decision. UUID adoption addresses a changed association during the unreadable-assembler path; it does not imply an unrequested Stop Systems or Kill Lift.

The earlier 120-second assembly-escalation proposal and the proposed red operator-check warning are superseded by this five-minute yellow warning.

## 8. Completed maintenance correction

Three stale assembly-gate comment blocks have already been corrected in the builder's IO export path.

They now describe existing behaviour:

- Missing, failed or stale assembler reads leave the current gate open but unverified.
- Verification-age expiry does not stop systems.
- Explicit false blocks the gate until a later true reading.

Validation confirmed that non-comment Lua content remained byte-identical and the replacements are idempotent. The live save and existing installer ZIPs were unchanged. Future builder exports contain the corrected comments.

This comment-only correction did not implement the new verification sequence in section 7.

## 9. Open decisions

### RPM labels

Current labels:
- DIRECT RPM SCALE VERIFIED
- RPM SCALE UNVERIFIED

Existing verification is derived from configured primary input RPM, not a live calibration test or confirmation of measured shaft RPM.

Candidates discussed but not approved:
- RPM SCALE CONFIGURED
- RPM SCALE UNAVAILABLE

### Remaining severity and visibility review

These existing inconsistencies still need decisions; do not silently treat a proposal as approved:

- Equivalent recoverable AP reasons are yellow while anchor reasons can be red.
- SYSTEMS ABORTED is red even when retained intent can recover.
- Compact controller status collapses missing/stale/unavailable conditions into FAULT.
- Background recovery can be hidden by retained display information.
- Capacity-limit and high-altitude air-pressure warnings are currently red.
- Assembly/fleet messages can have different colours in header, panel and Flight warning row.
- General PROP STATUS severity currently depends on whether its text contains FAULT.
- Final colour/treatment of KILL LIFT FAILED <reason>.
- Exact initial-fill/acquisition presentation boundary within the existing startup sequence.
- Release/resumption policy after a previously confirmed disassembly lock and subsequent reassembly.
- Exact dwell interval for cycling equal-priority warnings.

## 10. Warning rotation and Current Issues

### Main warning text

- Equal-priority active warnings cycle through the existing warning area. Replace the current first-offer-wins behaviour for equal-priority warnings.
- Keep severity precedence: higher-priority warnings take the main area; rotate among warnings at that priority. Current Issues still exposes active warnings of other priorities.
- Use a readable dwell interval. The exact interval remains to be chosen.
- Repeated telemetry updates must not continually restart the rotation and starve another warning.
- Remove resolved issues from the active rotation and Current Issues automatically; their history remains in logs.
- Keep normal healthy information outside the actionable warning list.
- Keep routine assembly retries exclusively in state's logs. Only the five-minute unresolved assembly warning becomes a navigator issue.
- Give an issue a stable identity so text updates and retry counters do not create duplicate issues.

### Clickable warning text

- The displayed warning text is directly clickable/touchable. Do not add a separate button, border or button-style background around it.
- Touching a warning opens a page titled Current Issues.
- Focus or identify the warning that was touched within that page.
- Resolve the touch against the warning actually drawn, so cycling cannot route the user to an unrelated issue.
- Opening Current Issues is a local navigation action and must not enqueue a ship command or trigger a sensor probe.

### Current Issues page

- Provide a Current Issues entry in Settings as an additional route to the same page.
- List all currently active issues, with severity, message and affected system/computer where known.
- Include available recovery state/count, age or last-update information, and relevant detail without inventing measurements.
- Preserve computer names in lowercase.
- Make long lists accessible through pagination or scrolling within the supported monitor footprint.
- Show a clear no-active-issues state when the list is empty.
- Keep this page current using the available status data.
- Back returns to the invoking page: the previous navigator page for a warning touch, or the parent Settings page for the Settings entry. Preserve the previous view context.

## 11. Broad source-comment pass

Add clear sections and purpose explanations across the maintained runtime and supporting builder/installer code.

Scope includes core control and telemetry paths, state readers, navigator presentation/input, chamber and propulsion components, remote paths, and relevant builder/installer support.

Comment requirements:

- Divide long modules into coherent sections without splitting them into extra installed files merely for presentation.
- Explain each section's responsibility and why it exists.
- Add a short summary immediately above every major function, including major local helpers, methods and worker entry points. Explain its purpose and important effects; mention inputs/outputs, yielding, state mutation, persistence or hardware writes when needed to understand the function. Keep summaries accurate and concise.
- Describe who owns data, who may command hardware, and how telemetry/requests flow between computers.
- Explain lifecycle transitions, retention, recovery and deliberate operator shutdown.
- Explain timing, freshness, retry, yielding/concurrency and checkpoint behaviour where those details affect correctness.
- Document the difference between an expected/retained identity and a freshly observed identity.
- Correct stale or contradictory comments as they are found.
- Keep comments concise and precise. Describe actual purpose, behaviour, conditions and effects directly. Base failure/recovery explanations on implemented paths; do not invent hypothetical failure states, use negative examples, or explain a function by listing what it does not do. Choose wording specific enough to stand on its own.
- Keep historical assumptions and superseded behaviour out of current comments unless required to explain compatibility.
- Keep the comment pass semantically neutral. Any executable change belongs to a separately identified planned behaviour change.
- Keep AGENTS.md and all .agents files read-only.
- Maintain comments in the builder's maintained sources/assets or export handling as appropriate, so future bundles retain them.

Validation must check summary coverage for major functions, distinguish comment-only edits from behaviour changes, preserve executable semantics, and check that extra source text still fits package/computer/disk capacity constraints.

## 12. Configurable cockpit input frequencies

- Validate each frequency item as a string in namespace:item form: one colon with non-empty text on both sides.
- Do not require the minecraft namespace or a concrete item suffix. The namespace can belong to another mod and the item can be any applicable frequency item.
- Use config.json input_frequencies as the source of the expected ordered pair for each cockpit input.
- Remove the additional hardcoded expected-pair enforcement from the validator. Keep the existing concrete pairs as shipped configuration defaults.
- Retain required-input coverage, pair validation, ordering and duplicate-pair rejection.
- Validate identifier shape locally. A correctly shaped string is not proof that the item exists in the installed mod set; bridge compatibility/read failures remain reported through the existing reader path.
- Update the validation message to refer to item IDs in namespace:item form.
- State uses the configuration supplied by core so both readers interpret the same frequency pairs.
- This change does not itself alter the configured pairs or the physical cockpit links.

## 13. Implementation acceptance checks

When implementation is authorized:

- Check the agreed wording, readable fit and per-message colours on supported CC display sizes.
- Check startup labels against actual phase/observation fixtures, including movement during settling and airborne adoption. Verify a user change to selected altitude immediately replaces ACQUIRING SEL ALT with READY and the startup label stays cleared for that run.
- Verify no incidental changes to provider output retention or control calculations.
- Check kill progress/latch message selection without altering the kill/disarm lifecycle.
- Exercise real retry counting and reset semantics for lift, AP and anchor.
- Exercise Sable success, assembler true/false, missing assembler, read exceptions, stale data, timeouts and restored verification.
- Verify five-minute unresolved warning timing without resets from repeated failed attempts.
- Verify routine assembly checks are logged on state without navigator retry warnings.
- Verify the yellow timeout warning leaves systems running and checks active.
- Verify successful evidence clears the warning and unverified observations cannot become disassembly.
- Verify fresh changed Sable UUID adoption in the unreadable-assembler path updates dependent runtime/persistent references and necessary receivers, without a permanent identity-change dead end.
- Verify missing identity retains the previous association without refreshing measurement age, and late old observations cannot reverse an adopted identity.
- Check equal-priority warning rotation, severity precedence, changing issue lists and lack of starvation from repeated snapshots.
- Touch a cycling warning and verify Current Issues identifies the warning actually displayed.
- Check Settings access, parent Back navigation, empty/list-overflow states and automatic removal of resolved issues.
- Verify warning navigation does not send ship commands or invoke hardware probes.
- Validate the broad comment pass separately for executable equivalence, section accuracy and source/package size.
- Preserve sender/session/freshness checks around vessel-identity adoption; do not fabricate fresh vessel data for presentation.
- Check vanilla and modded namespace:item frequency values, malformed identifiers, missing required inputs, duplicate ordered pairs, and the unchanged default cockpit mapping. Verify configured pairs are passed unchanged to the reader.
- Provide rendered UI evidence and a validation report when the implementation is complete.

Implementation was subsequently authorized in this conversation. Delivery updates the builder and its
export handling. Applying a generated release to a ship remains a separate update operation.

## 14. Implementation choices and retained decisions

- Equal-priority warning dwell is three seconds.
- Current Issues shows four active entries per page, with source, available detail
  and time first observed by the renderer. A warning touch focuses its entry.
- Heading displays receive the acquisition-complete presentation state.
- Installed program counts remain five payload files on core, three on state
  and three on each auxiliary computer, plus their existing persistent records.
- The five-minute verification rule supersedes the earlier 120-second proposal.
- Proposed RPM labels and other unapproved severity reclassifications retain
  their existing wording and behavior.
- The existing confirmed-disassembly/reassembly lifecycle is retained. This pass
  changes how disassembly evidence is established and presented.
- Gas-provider shutdown and PID executable code is compared separately from
  documentation and the approved assembly/identity changes.
