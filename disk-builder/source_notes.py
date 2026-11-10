"""Lexical Lua documentation pass with byte-stable executable tokens."""
import re

LONG=re.compile(r"\[(=*)\[")
WORD=re.compile(r"[A-Za-z_][A-Za-z_0-9]*")

# Family membership spans package groups where the implementation is shared.
PACKAGE_FAMILIES = {
    **{"chamber-" + name: ["packages/chamber/" + role + "/" + name + ".lua"
                           for role in ("fl", "fr", "bl", "br")]
       for name in ("hardware", "lift", "main", "thrust", "relay")},
    "chamber-link": ["packages/common/chamber_link.lua"] +
        ["packages/" + group + "/" + role + "/chamber_link.lua"
         for group, roles in (("chamber", ("fl", "fr", "bl", "br")),
                              ("thrust", ("lb", "rb", "ls", "rs"))) for role in roles],
    **{"thrust-" + name: ["packages/thrust/" + role + "/" + name + ".lua"
                          for role in ("lb", "rb", "ls", "rs")]
       for name in ("hardware", "thrust")},
    "heading-main": ["packages/heading/" + role + "/main.lua" for role in ("left", "main", "right")],
    **{"primary-" + name: ["packages/primary/" + role + "/" + name + ".lua"
                           for role in ("left", "right")] for name in ("main", "hardware")},
}
BYTE_IDENTICAL_FAMILIES = {"chamber-lift", "chamber-link"}


def expand_shared_modules(files, mappings):
    """Expand canonical package implementations into their registered role destinations."""
    if not isinstance(mappings, dict):
        raise ValueError("sharedModules must be an object")
    result = {name: data for name, data in files.items() if name not in mappings}
    assigned = set()
    for source, destinations in mappings.items():
        if (not isinstance(source, str) or not source.startswith("packages/common/") or
                not source.endswith(".lua") or ".." in source.split("/") or "\\" in source or source not in files):
            raise ValueError("Invalid shared implementation source: " + str(source))
        if not isinstance(destinations, list) or not all(isinstance(name, str) for name in destinations):
            raise ValueError("Invalid shared implementation destinations: " + source)
        members = set(destinations)
        if len(members) != len(destinations) or not any(members == set(group) for group in PACKAGE_FAMILIES.values()):
            raise ValueError("Shared implementation must map one complete registered family: " + source)
        for name in destinations:
            if name in assigned or name in result:
                raise ValueError("Duplicated shared implementation destination: " + name)
            result[name] = files[source]
            assigned.add(name)
    return result


def validate_package_families(files):
    """Reject executable drift across explicit sibling families before packaging."""
    for family, members in PACKAGE_FAMILIES.items():
        for name in members:
            if name not in files:
                raise ValueError(f"Package family {family}: missing {name}")
        reference = members[0]
        expected = tokens(files[reference].decode("utf-8-sig"))
        for name in members[1:]:
            actual = tokens(files[name].decode("utf-8-sig"))
            for index in range(max(len(expected), len(actual))):
                left = expected[index] if index < len(expected) else ("<EOF>", 0, 0, 0)
                right = actual[index] if index < len(actual) else ("<EOF>", 0, 0, 0)
                if left[0] != right[0]:
                    raise ValueError(f"Package family {family}: {reference}:{left[3]} token {left[0]!r} "
                                     f"differs from {name}:{right[3]} token {right[0]!r}")
            if family in BYTE_IDENTICAL_FAMILIES and files[reference] != files[name]:
                raise ValueError(f"Package family {family}: normalized comments/bytes differ: {reference}, {name}")
    return len(PACKAGE_FAMILIES)

def tokens(text, comments=False):
    """Scan Lua tokens while preserving source offsets and line numbers."""
    out=[];i=0;line=1;n=len(text)
    while i<n:
        start=i;at=line;c=text[i]
        if c.isspace():
            i+=1
            if c=="\n":line+=1
            continue
        if text.startswith("--",i):
            opening=LONG.match(text,i+2)
            if opening:
                close="]"+opening[1]+"]";end=text.find(close,opening.end())
                i=n if end<0 else end+len(close)
            else:
                end=text.find("\n",i);i=n if end<0 else end
            if comments:out.append(("comment",start,i,at))
        elif c in ("'",'"'):
            quote=c;i+=1
            while i<n:
                if text[i]=="\\":i+=2
                elif text[i]==quote:i+=1;break
                else:i+=1
            out.append((text[start:i],start,i,at))
        else:
            opening=LONG.match(text,i)
            word=WORD.match(text,i)
            if opening:
                close="]"+opening[1]+"]";end=text.find(close,opening.end())
                i=n if end<0 else end+len(close)
            elif word:i=word.end()
            else:i+=1
            out.append((text[start:i],start,i,at))
        line+=text.count("\n",start,i)
    return out

def functions(text, min_lines=8):
    """Find named function spans using Lua block nesting."""
    seq=tokens(text);stack=[];result=[]
    for index,token in enumerate(seq):
        value,start,end,line=token
        if value=="function":
            name=[];j=index+1
            while j<len(seq) and seq[j][0]!="(":
                if re.fullmatch(r"[\w.:]+",seq[j][0]):name.append(seq[j][0])
                else:break
                j+=1
            qualified="".join(name)
            if not qualified and index and seq[index-1][0]=="=":
                j=index-2
                while j>=0 and seq[j][3]==line and (WORD.fullmatch(seq[j][0])or seq[j][0]in(".",":")):j-=1
                qualified="".join(v[0] for v in seq[j+1:index-1])
            stack.append({"kind":"function","name":qualified,"start":start,"line":line})
        elif value in ("if","for","while","repeat"):
            stack.append({"kind":value,"pending":value in ("for","while")})
        elif value=="do":
            if stack and stack[-1]["kind"] in ("for","while") and stack[-1].get("pending"):
                stack[-1]["pending"]=False
            else:stack.append({"kind":"do"})
        elif value in ("end","until"):
            if not stack:continue
            frame=stack.pop()
            if frame["kind"]=="function" and frame["name"]:
                frame.update(end=end,endline=line)
                if line-frame["line"]>=min_lines-1:
                    result.append(frame)
    return sorted(result,key=lambda item:item["start"])

def canonical(path):
    """Group identical role implementations under one documentation key."""
    return re.sub(r"/(fl|fr|bl|br|left|right|main|lb|rb|ls|rs)/","/*/",path)

PURPOSES={}
SUMMARIES={}

SHORT_SUMMARIES = {'/avionics/common/console.lua#requestRegistry': 'Request fleet assignments from the selected core and boot '
                                                 'session.',
 '/avionics/common/console.lua#startWorker': 'Reuse a live service tab or start and register its '
                                             'replacement.',
 '/avionics/control_presets.lua#Presets:cancelRestore': 'Cancel pending preset restoration and release its '
                                                        'resume gate.',
 '/avionics/flight.lua#Flight:cancelLateral': 'Cancel lateral guidance, set its manual mode and apply the '
                                              'requested stop lock.',
 '/avionics/lateral.lua#Lateral:cancel': 'Clear lateral demand and guidance history; strafe input acts from the next sample.',
 '/avionics/main.lua#request': 'Dispatch the paired remote packet to remote AP request handling.',
 '/avionics/motion_warnings.lua#M:reset': 'Clear obstruction tracking and establish the current measurement '
                                          'gate.',
 '/avionics/pid.lua#PID:reset': 'Clear integral and derivative state and seed the previous measurement.',
 '/avionics/remote_ap.lua#Ops:setEnabled': 'Change remote AP permission for this boot and advance its '
                                           'command generation.',
 '/avionics/remote_install.lua#save': 'Atomically persist the paired-remote registry.',
 '/avionics/remote_install.lua#write': 'Write and close the selected file, then verify its stored bytes.',
 '/avionics/storage.lua#readDocument': 'Read and decode JSON through the configured filesystem.',
 '/avionics/storage.lua#readState': 'Resolve current core state and recover a verified backup with conservative authority.',
 '/avionics/storage.lua#writeDocument': 'Verify a JSON replacement and retain the previous valid document.',
 '/avionics/storage.lua#importState': 'Import legacy core records and their backups into independent sections.',
 '/avionics/restart.lua#Restart:cancel': 'Clear the restart job and persist its inactive checkpoint.',
 '/avionics/restart.lua#Restart:write': 'Persist a coordinated-restart checkpoint and return its storage '
                                        'result.',
 '/avionics/thrust.lua#Thrust:resetHeadingLoop': 'Clear heading-loop integral and rate-derivative history.',
 '/avionics/thrust.lua#Thrust:resetManualAccelerationLoop': 'Clear both primary acceleration integrals and '
                                                            'derivatives.',
 '/avionics/thrust.lua#Thrust:resetSpeedLoop': 'Clear speed-loop integral and derivative history for the '
                                               'next transfer.',
 '/avionics/thrust.lua#Thrust:setHeadingUnavailable': 'Reset heading feedback and publish unavailable '
                                                      'heading-control status.',
 '/avionics/thrust.lua#Thrust:setSpeedUnavailable': 'Reset speed feedback and publish the unavailable '
                                                    'measurement or target reason.',
 '/avionics/thrust.lua#clearPropulsionIssue': 'Clear the recorded propulsion issue and publish its recovery '
                                              'log entry.',
 '/installer/server.lua#setState': 'Persist the installation phase, optional message and current timestamp.',
 '/packages/chamber/*/hardware.lua#Hardware.setPeripheralApi': 'Set the peripheral facade used for chamber '
                                                               'hardware discovery and calls.',
 '/packages/chamber/*/lift.lua#clearControlContext': 'Disarm local control ownership and clear its accepted '
                                                     'sequence.',
 '/packages/chamber/*/lift.lua#clearIdleProbeFault': 'Clear the recorded idle-probe fault after verified '
                                                     'recovery.',
 '/packages/common/console.lua#requestRegistry': 'Request fleet assignments from the selected core and boot '
                                                 'session.',
 '/packages/common/console.lua#startWorker': 'Reuse a live service tab or start and register its '
                                             'replacement.',
 '/packages/navigation/storage.lua#Storage.saveSettings': 'Validate display settings and save them through '
                                                          'JSON replacement.',
 '/packages/thrust/*/hardware.lua#Hardware.setPeripheralApi': 'Set the peripheral facade used for thrust '
                                                              'hardware discovery and calls.'}

def prior_summary(text, start):
    """Read an existing positive function description immediately above it."""
    line=text.rfind("\n",0,start)+1
    previous=text[:line].rstrip().splitlines()
    lines=[]
    for item in reversed(previous):
        if not item.strip().startswith("--"):break
        lines.insert(0,item.strip()[2:].strip())
    summary=" ".join(lines)
    if len(summary)<25 or re.search(r"\b(no|not|never|cannot|instead|would|don't|doesn't|without)\b",summary,re.I):
        return None
    return summary

def summary_for(path, frame, text):
    """Resolve a reviewed summary or an existing positive description."""
    name=frame["name"];short=re.split(r"[.:]",name)[-1]
    return SHORT_SUMMARIES.get(canonical(path)+"#"+name) or SUMMARIES.get(canonical(path)+"#"+name) or SUMMARIES.get(name) or SUMMARIES.get(short) or prior_summary(text,frame["start"])


SUMMARIES.update({
 'AP:resetDriftTrend': "Clear drift qualification while retaining the route's learned heading bias.",
 'AP:resetGuidance': 'Restart heading acquisition and route capture from fresh observations.',
 'AP:guidanceControls': "Copy pilot selections into the current route's transient propulsion demands.",
 'AP:updateRouteLateral': "Slew route-normal correction and project it onto the vessel's lateral axis.",
 'refreshLiveUpdateStatus': 'Refresh the stored release version and checksum from the committed receipt after a live update replaced the program.',
 'rebootForStatusMismatch': 'Reboot a peripheral computer that stays stuck on a receipt or status mismatch, at most twice per hour.',
 'ventBalloonIssue': 'Word a balloon attachment fault from the trim probe reading and send vent faults to the boiler check.',
 'autoEnablePropulsion': 'Enable a disabled propulsion once per start sequence after the READY altitude hold has stayed settled for 10 s.',
 'IO:staleStatusText': 'Word the fault for a silent chamber with its silent time, once that time passes the 10 s notice threshold.',
 'disablePropulsionForStop': 'Save propulsion as disabled when STOP SYSTEMS is confirmed, cancelling AP and the anchor.',
 'rawThrustIssue': 'Find the first propulsion issue from the cached thrust snapshot before lease wording is simplified.',
 'AP:updateHeadingBias': 'Learn a rate-limited heading bias from a consistent fresh-sample cruise correction.',
})
SUMMARIES['speedOutputSlew']='Limit thrust release during selected-speed overspeed correction in either travel direction.'
SUMMARIES['controlMode']='Resolve controller operating mode, then effective authority and pilot selections.'
SUMMARIES.update({'AP.new': 'Construct route guidance with its saved draft and destination-library access.',
 'AP:cancel': "End route guidance and hand live demands back to the pilot's levers at their current position.",
 'AP:engage': 'Capture route-start observations and initialize heading/speed acquisition.',
 'AP:ready': 'Check destination, vessel and propulsion readiness for route engagement.',
 'AP:restore': 'Validate and restore the retained route into its recovery phase.',
 'AP:snapshot': 'Build current route progress, destination and engagement availability.',
 'AP:suspend': 'Retain the route and schedule the next counted recovery attempt.',
 'AP:update': 'Advance route heading, speed and arrival guidance from fresh vessel observations.',
 'Anchor:cancel': 'Release position guidance and hold every lever until it reads neutral.',
 'Anchor:engage': 'Capture the current world position and initialize anchor braking.',
 'Anchor:suspend': 'Retain the anchor point and schedule the next counted recovery attempt.',
 'Anchor:telemetry': 'Validate current world position, velocity and vessel orientation for position '
                     'guidance.',
 'Anchor:update': 'Compute bounded braking and return demand toward the retained anchor point.',
 'Controls:clear': 'Reset live input history while retaining selected pilot modes and targets.',
 'Controls:decorate': 'Add selected modes, target values and cockpit readiness to the display snapshot.',
 'Controls:fresh': 'Validate the age, identity and completeness of the cockpit sample.',
 'Controls:mode': 'Validate and apply an explicit cockpit-mode selection.',
 'Controls:update': 'Interpret fresh cockpit inputs into selected targets and live propulsion demands.',
 'Flight.new': 'Construct altitude-control state, PID loops and runtime operation records from '
               'configuration.',
 'Flight:check': 'Validate vessel, cockpit and chamber observations for altitude-control authority.',
 'Flight:decorate': 'Add flight, maintenance, recovery and systems information to a cached display snapshot.',
 'Flight:engage': 'Capture a verified hover baseline and engage the altitude PID loops.',
 'Flight:request': 'Validate a pilot action and dispatch it to the corresponding flight operation.',
 'Flight:stop': 'Disengage altitude feedback while retaining applied provider settings.',
 'Flight:update': 'Update cockpit state, retained intent and the current altitude-control lifecycle.',
 'IO.new': 'Construct core hardware, network and sensor state from the configured fleet.',
 'IO:loadRoleManifests': 'Read expected package identities from the local installer catalog.',
 'IO:setRegistry': 'Apply the configured role-to-computer registry to core routing state.',
 'Inbox:pop': 'Select the next queued item using cockpit and ship-service priorities.',
 'Inbox:push': 'Validate packet shape and enqueue or coalesce its bounded work item.',
 'Inbox:snapshot': 'Report bounded inbox depth, drops and service counters.',
 'Lateral:evaluate': 'Compute sideways demand and braking from the current offset and velocity.',
 'Lateral:input': 'Interpret lateral pilot input into bounded displacement and braking intent.',
 'Lateral:select': 'Start selected sideways travel at zero offset from the current position.',
 'Lateral:telemetry': 'Validate the vessel observations used for sideways position guidance.',
 'Metrics:measure': 'Record elapsed work time and return the measured operation result.',
 'N.ensure': 'Validate and populate supported navigation configuration defaults.',
 'PID:step': 'Advance the PID terms using elapsed time, measured derivative and bounded integration.',
 'Presets.new': 'Construct the persisted mode/target store and load its saved record.',
 'Presets:update': 'Restore or persist pilot selections once the core identity matches and vessel data is fresh, rereading SEL targets for a new vessel ID.',
 'Presets:valid': 'Validate a stored mode/target record against the supported schema and bounds.',
 'Restart:ack': 'Validate the navigator acknowledgement for the pending restart.',
 'Restart:capture': 'Capture current systems, selections and navigation state for restart.',
 'Restart:load': 'Load and validate a pending one-shot restart checkpoint.',
 'Restart:request': 'Save the restart checkpoint and request the navigator restart handshake.',
 'Restart:restore': 'Revalidate fresh vessel data and restore retained systems through recovery.',
 'Restart:tick': 'Advance restart handshakes and reboot core after their guards succeed.',
 'Sampling.run': 'Supervise a sampling attempt with deadline, progress and cancellation tracking.',
 'Sources.sample': 'Read configured fallback sensor fields with independent completion tracking.',
 'Sources:sample': 'Read configured fallback sensor fields with independent completion tracking.',
 'T.ensure': 'Validate and populate selected-target input response settings.',
 'Watchdog:observe': "Record a worker's completion progress for stall detection.",
 'Watchdog:update': 'Evaluate worker progress and advance the paced restart decision.',
 'Wire.inputFrame': 'Build a bounded cockpit input frame with observation timestamps.',
 'Wire:accept': 'Validate a state frame, preserve source ages and compose accepted vessel data.',
 'Wire:context': 'Build the configuration and chamber context supplied to the state reader.',
 'Wire:run': 'Receive state frames and periodically publish core sensor configuration.',
 'Worker.step': 'Run one propulsion-control step and publish its completion heartbeat.',
 'abortRecoveryState': 'Record a terminal recovery guard result while retaining applied lift intent.',
 'acceptInput': 'Validate and apply a cockpit frame from the assigned state reader.',
 'acceptPrimary': 'Validate and timestamp a primary Sable observation.',
 'acceptRoleStatus': "Validate and cache a registered computer's runtime report.",
 'acceptSubsystemStatus': 'Validate and cache a registered subsystem report.',
 'adoptVesselIdentity': 'Adopt a fresh Sable UUID across retained control references and persistent '
                        'selections.',
 'airPressureAtWorldY': 'Resolve the available pressure observation for the requested world altitude.',
 'asQuaternion': 'Validate and normalize a quaternion-shaped observation.',
 'assemblerJobs': 'Build independent assembler identity, mass and centre-of-mass reader jobs.',
 'assemblyBlocked': 'Suspend assembly-gated flight operations and retain their last applied lift settings.',
 'assemblyGate': 'Verify Sable association first, then assembler state, and time unresolved assembly '
                 'warnings.',
 'authoritativeTargetMaps': 'Resolve physical target maps suitable for retained-run reconciliation.',
 'autoResumeSystems': 'Attempt validated recovery or airborne adoption while retained running intent is '
                      'active.',
 'axis': 'Calculate a bounded axis correction from position and velocity error.',
 'balancedLiftModel': 'Calculate balanced chamber support bounds from verified provider capacity.',
 'balancedTargetsFit': 'Check requested chamber targets against the balanced capacity model.',
 'beginSystemsBatch': 'Stage a complete chamber target batch with its command stage and trim allocation.',
 'bridgeRequest': 'Correlate navigator requests with the current core session and dispatch accepted actions.',
 'broadcastDisplayStatus': 'Publish cached display data to navigator and heading receivers.',
 'broadcastFleetRegistry': 'Publish the current registry to the configured fleet.',
 'buildSnapshot': 'Build the timestamped vessel, controls, role-health and lift display snapshot.',
 'buildSubsystems': 'Assemble subsystem availability and reasons from registered role reports.',
 'cancelTuning': 'Release the chamber tuning lease for the current session.',
 'capBalancedTargets': 'Clamp requested chamber target maps to the balanced provider bounds.',
 'capSeededStartupSupportTargets': 'Limit startup fill targets against the measured support envelope.',
 'captureSystemsBaseline': 'Capture stable hover targets and transition the systems run to READY.',
 'checkpoint': 'Capture the resumable operation state for an intentional systems restart.',
 'chooseWired': 'Select the wired modem that exposes the configured peer computer.',
 'coarseTrimSamplesAligned': 'Check that chamber observations are aligned closely enough for trim '
                             'calculations.',
 'cockpitLines': 'Format raw and accepted cockpit readings with input ages and configured frequencies.',
 'cockpitPanel': "Refresh state's cockpit diagnostic terminal and handle input selection.",
 'commandWasApplied': "Match a chamber's acknowledged applied sequence with the requested command.",
 'commitInput': 'Validate and apply the newest cockpit observations to core input state.',
 'complete': 'Commit verified recovery targets and resume the retained control phase.',
 'compose': 'Select fresh primary and calibrated fallback values for each vessel field.',
 'configureEmergencyLock': 'Load the persisted Kill Lift latch and prepare its verification state.',
 'configureHoverMemory': 'Load learned hover offsets and configure their persistence.',
 'configureLevelMemory': 'Load the stored leveling bias and its persistence dependencies.',
 'confirmShutdown': 'Accept the matching stop confirmation and start probe-preserving main-lift shutdown.',
 'copyBridgeAction': 'Copy a permitted navigator action into a bounded core request.',
 'disarmLiftKill': 'Start the confirmed disarm operation against the retained emergency latch.',
 'distributeInitialGasTotal': "Allocate a chamber's initial gas request across its permitted providers.",
 'edit': 'Apply a permitted destination edit or saved-destination selection.',
 'emergencyKillLift': 'Latch the accepted Kill Lift action and start its dedicated shutdown sequence.',
 'emergencyLiftState': 'Build the current kill, verification and disarm state for displays.',
 'emergencyLiftStopStateVerified': "Check a chamber's emergency-stop latch and zero-output readbacks.",
 'emergencyLiftStopWasApplied': "Correlate a chamber's verified emergency stop with the sent sequence.",
 'findLink': "Attach state's wired modem to the configured core peer.",
 'finishActive': 'Complete the active recovery stage using verified physical target maps.',
 'finishTuning': 'Store the PID test measurements and its baseline-restoration result.',
 'handleRegistryRequest': 'Validate a registry request and reply with the current core identity and '
                          'assignments.',
 'headingFromForward': 'Convert the horizontal forward vector into a normalized compass heading.',
 'isFloorOnlyTargets': 'Recognize target maps at the configured provider floors and fine-provider state.',
 'job': 'Run a named sensor sampling operation with its deadline and repeat interval.',
 'learnedHoverOffset': 'Interpolate the learned hover offset for the current altitude.',
 'legacyInputs': 'Convert existing vessel/sensor observations into independent source records.',
 'loadCalibration': 'Load the sensor-frame calibration that matches vessel identity and hardware bindings.',
 'localModems': 'Inspect attached modems and separate wired from wireless interfaces.',
 'logState': 'Emit a log entry when the named cached state changes.',
 'maintenanceAck': 'Correlate a chamber maintenance reply with the active operation.',
 'maintenanceRequest': 'Validate and stage chamber restart, hardware-recheck or probe-restart maintenance.',
 'manualTrimAvailability': 'Evaluate whether the current vessel observations permit a manual fore/aft bias '
                           'edit.',
 'manualTrimRequest': 'Apply an accepted fore/aft trim adjustment and persist the selected bias.',
 'mapsEqual': 'Compare complete provider target maps.',
 'mul': 'Multiply quaternion components in the required composition order.',
 'network': 'Publish timestamped state frames and accept current core configuration.',
 'newReader': "Construct state's independent sensor caches and sampling contexts.",
 'nodeBootState': 'Validate a changed chamber boot against registry, bindings and recent core Hello.',
 'observePidMeasurement': 'Refresh PID measurement history using the observed elapsed sample time.',
 'observeSystemsDynamics': 'Estimate lift response, vertical acceleration and drag from successive '
                           'vessel/chamber samples.',
 'observeSystemsPidAfterAck': 'Update altitude and attitude PID measurements after target acknowledgement.',
 'openModems': 'Open the configured network channels on discovered modems.',
 'persistCalibration': 'Persist the current vessel sensor-frame calibration.',
 'persistEmergencyLock': 'Write the accepted Kill Lift latch to its persistent record.',
 'primaryView': 'Build a primary vessel-source view from timestamped readings and metadata.',
 'probe': 'Report state-link freshness and reader availability from cached observations.',
 'processMessage': 'Validate an incoming fleet packet and dispatch it to its role-specific receiver.',
 'readInputs': 'Read each configured cockpit frequency pair and publish a timestamped input batch.',
 'readOnlyPeripheral': 'Expose the configured sensor getter methods to the state reader.',
 'reanchor': 'Reset recovery measurements to the newly verified physical targets.',
 'receive': 'Receive a packet matching the current protocol and peer context.',
 'receiveInputs': 'Receive and validate cockpit frames on the wired state channel.',
 'recordRole': "Add one role's validated cached report to the subsystem snapshot.",
 'recoverSystems': 'Reconstruct altitude control from retained target maps and fresh provider observations.',
 'recoveryProbeMaps': 'Construct probe recovery maps from the retained chamber targets.',
 'recoveryStageMode': "Classify the chambers' current probe/control lease stages.",
 'registryPacket': 'Build a bounded fleet-registry announcement for the current core session.',
 'rememberHoverOffset': 'Update learned hover offsets from stable measured hover conditions.',
 'rememberLevelBias': 'Persist the current leveling bias at the configured save cadence.',
 'renewLiftControlContext': 'Publish the validated altitude/input authority context to chamber controllers.',
 'resetTrim': 'Reset trim PID state and optionally retain the coarse trim allocation.',
 'restore': 'Validate and restore the retained operation record.',
 'retainActiveBulk': 'Retain observed bulk-vent targets while constructing a probe-stage recovery map.',
 'rotate': 'Rotate a vector using the supplied quaternion.',
 'sameProviderSignature': 'Compare observed provider identities, roles and bounds with the retained '
                          'signature.',
 'sampleAssembler': 'Read assembler identity, mass and centre of mass with independent result ages.',
 'sampleAssembly': 'Read the available physics assemblers and retain their explicit assembled result.',
 'sampleCockpit': 'Read and publish a complete cockpit input sample.',
 'sampleVessel': 'Read Sable vessel fields and configured sensors with per-observation timestamps.',
 'sanitizeBalloon': 'Validate and bound a received chamber envelope observation.',
 'sanitizeProviders': 'Validate and bound a received provider-readback map.',
 'saveDraft': 'Persist a validated navigator destination draft.',
 'scanCore': 'Attach the state link to its configured wired peer.',
 'scanHardware': 'Discover configured sensor, monitor and modem interfaces and record their bindings.',
 'seedHoverOffset': 'Apply the learned hover offset to the altitude-control baseline.',
 'sendAltitudeCommand': 'Validate and send a chamber altitude-control command.',
 'sendEmergencyLiftDisarm': 'Send a session-bound emergency-latch disarm request.',
 'sendEmergencyLiftKill': 'Send the active emergency-stop request to each required chamber.',
 'sendLiftControlContext': 'Publish the current selected-altitude and control-activity lease to a chamber.',
 'sendLiftMaintenance': 'Send a validated chamber maintenance request with current session correlation.',
 'sendRecoveryBatch': 'Stage the next verified probe/control recovery batch.',
 'sendRegistry': 'Send the current fleet registry to one destination.',
 'sendSystemsNext': 'Send the next pending chamber target and record its acknowledgement deadline.',
 'sendSystemsStop': 'Send a systems lease release or explicitly requested main-lift shutdown.',
 'sendTuningCommand': 'Send bounded tuning targets under the current test authority.',
 'sendTuningTargets': 'Send the bounded test target maps to their configured chambers.',
 'setSystemsIntent': "Persist a change to the operator's systems-running intent.",
 'setting': 'Validate a settings edit, save its configured value and update the affected live controller.',
 'snapshot': 'Return the current bounded operation state and available status details.',
 'startSystems': 'Validate startup and initialize its probe, target and retained-identity state.',
 'startSystemsAirborne': 'Adopt verified existing lift into an airborne altitude-control run.',
 'startupTargets': 'Build bounded startup provider targets from the configured vent request.',
 'stopSystems': 'Release the renewable systems lease and retain the applied provider ceilings.',
 'supportStepFor': 'Calculate a bounded provider change from measured support error and actuator limits.',
 'suspend': 'Retain current operation intent and expose its retry state.',
 'systemsAcquisitionControl': 'Compute bounded vertical-speed and lift-ratio demand from altitude error and '
                              'measured dynamics.',
 'systemsBulkCeilingSum': 'Sum configured bulk-vent ceilings across the selected target maps.',
 'systemsBulkTargetsChanged': 'Compare the requested bulk-vent target maps with the applied maps.',
 'systemsCaptureReady': 'Measure stable hover duration near the selected altitude and report capture '
                        'readiness.',
 'systemsControlTargets': 'Allocate bounded provider targets from the requested support ratio and trim '
                          'corrections.',
 'systemsEnvelopeReady': 'Check chamber envelope composition and lift observations for startup.',
 'systemsGuard': "Revalidate the active run's observations, identities and configured provider boundaries.",
 'systemsHoldTargets': 'Combine trim and altitude demand into the next hold target maps.',
 'systemsIntent': 'Load and return the persisted operator intent to keep systems running.',
 'systemsPreflight': 'Collect verified vessel, cockpit, provider and chamber identity for a systems run.',
 'systemsProjectedClimbDistance': 'Estimate climb distance from current velocity and the observed lift '
                                  'response.',
 'systemsProjectedSupportRatio': 'Project the lift-to-weight support ratio over the measured response '
                                 'horizon.',
 'systemsProviderTargetTotals': 'Sum the provider target amounts for each chamber.',
 'systemsStartupAcceleration': 'Bound startup acceleration using configured limits and measured '
                               'command/response delay.',
 'systemsStartupGasSeedTargets': 'Calculate initial fill targets from configured gas demand and verified '
                                 'capacity.',
 'systemsTarget': 'Resolve and validate the selected startup altitude.',
 'systemsWarning': 'Describe observed provider-capacity and efficiency limitations during lift acquisition.',
 'tuningReady': 'Check telemetry, hover stability and vent headroom for a bounded PID test.',
 'tuningRequest': 'Review, confirm, cancel or stop a bounded PID test.',
 'updateEmergencyLiftKill': "Retry emergency shutdown and verify each chamber's stop readback.",
 'updateLiftDisarm': 'Track disarm acknowledgements and clear the completed core latch.',
 'updateMaintenance': 'Advance the current chamber maintenance operation through acknowledgement and '
                      'reconnect.',
 'updateShutdown': 'Send the confirmed probe-preserving shutdown and track each chamber acknowledgement.',
 'updateStartup': 'Track vent-start acknowledgements and report the completed startup operation.',
 'updateSystems': 'Advance startup, acquisition, recovery and altitude-hold target batches.',
 'updateSystemsRecovery': 'Reconcile physical targets, renew authority and resume the retained systems run.',
 'updateTrim': 'Compute bounded roll and pitch corrections from chamber heights and the selected trim bias.',
 'updateTuning': 'Advance the active PID test and restore its captured provider ceilings.',
 'validDraft': 'Validate destination text, coordinates, cruise speed and altitude bounds.',
 'validateBindings': "Validate the state reader's bounded sensor-binding description.",
 'validateLiftStatus': "Validate a chamber's lift report before accepting its identity and provider data.",
 'validatedLiftControlContext': 'Resolve a fresh altitude/input authority context for chamber status.',
 'verifyCommand': 'Check recovery acknowledgements and readbacks for the active command stage.',
 'verifyMap': "Compare a chamber's physical provider readback with the retained target map.",
 'vesselState': 'Classify fresh vessel observations against the retained identity.'})

SUMMARIES.update({'App:activate': 'Handle the selected remote page entry or operation.',
 'App:confirm': 'Submit the confirmed remote command and track its result.',
 'App:draw': 'Render the current remote page from cached core replies.',
 'App:event': 'Process network replies, timers and operator input for the remote application.',
 'App:input': 'Handle remote keyboard and mouse navigation or destination editing.',
 'App:modems': "Discover and open the paired remote's network interfaces.",
 'App:poll': 'Request the active cached status view at the allowed read cadence.',
 'App:send': 'Send a correlated authenticated packet to the paired core.',
 'App:startReview': 'Validate entered destination fields and open the command review.',
 'Cache:get': 'Resolve a verified installer object by its content fingerprint.',
 'Debug:capture': 'Convert the current cached runtime snapshot into buffered debug records.',
 'Debug:media': 'Find removable media eligible for the current debug recording.',
 'Debug:request': 'Stage an operator request to start or stop disk debug recording.',
 'Debug:start': 'Create a recording run and its disk output files.',
 'Debug:step': 'Advance queued recording requests and paced buffer writes.',
 'Debug:write': 'Append the prepared debug data and track the written byte count.',
 'Fleet.new': "Load the fleet registry and resolve this core's identity.",
 'Fleet.validateComputers': 'Validate role labels and unique numeric IDs in the fleet registry.',
 'Fleet:save': 'Persist the accepted role-to-computer registry.',
 'Library.validate': 'Validate a saved destination document and its entries.',
 'Library:change': 'Apply and persist an accepted destination-library edit.',
 'Library:read': 'Read and validate a saved destination file from mounted media.',
 'Library:refresh': 'Refresh the cached destination list and its availability reason.',
 'Library:scan': 'Discover destination documents on currently mounted media.',
 'M.new': "Construct the module's configured operation state and its runtime counters.",
 'M.run': "Run the module's network service and its configured operation loop.",
 'M:emit': 'Record a changed motion advisory with its measured axis and event time.',
 'M:observe': 'Track sustained applied demand with insufficient measured motion on one axis.',
 'M:update': 'Evaluate fresh motion measurements and update impact/obstruction advisories.',
 'Media.new': 'Construct the removable package-media source and its verification cache.',
 'Media:open': 'Open the verified content-addressed package object.',
 'Media:refresh': 'Rediscover matching mounted media and refresh its availability.',
 'Media:valid': 'Verify the mounted media release and expected package catalog.',
 'Monitor.rows': 'Format a selected core diagnostic page from the cached snapshot.',
 'Monitor.run': 'Refresh the selected core diagnostic view and handle its local navigation.',
 'Monitor:update': 'Compare measured motion and lift with the current gravity/pressure model.',
 'Ops:execute': "Apply the queued remote action through core's flight request interface.",
 'Ops:neutral': 'Evaluate the neutral-input gate for the current remote command.',
 'Ops:pilotAction': 'Identify local pilot activity that supersedes a queued remote operation.',
 'Ops:request': 'Validate, correlate and queue an authenticated remote operation.',
 'Ops:status': 'Build bounded remote command and route progress from cached core state.',
 'Ops:step': 'Service the next remote operation after higher-priority ship work.',
 'Payload.heading': 'Build the compact cached status packet consumed by heading displays.',
 'Progress:draw': 'Render cached installation progress on the installer terminal.',
 'Progress:frame': 'Build the terminal rows for the current installation progress.',
 'Progress:setFleet': 'Set the expected role inventory for installer progress.',
 'Progress:update': 'Update cached per-role installation progress from receiver status.',
 'Recorder:open': 'Create the systems-run recording and write its column header.',
 'Recorder:record': 'Append the current systems-run snapshot to the flight recording.',
 'Remote.inspect': 'Inspect the docked computer and its compatible remote installation.',
 'Remote.install': 'Provision the docked remote program and its pairing configuration.',
 'Remote.opsMenu': 'Run the docked remote administration menu.',
 'Remote.run': 'Run the remote provisioning and pairing-management interface.',
 'Remote.setFlightAccess': 'Persist the accepted flight permission for a paired remote.',
 'Storage.defaultSettings': 'Construct the supported initial local display settings.',
 'Storage.loadConfig': 'Read the configuration document and validate its schema and fields.',
 'Storage.loadSettings': 'Read validated display settings or construct the supported initial settings.',
 'Storage.readJson': 'Read and decode a JSON document through the configured filesystem dependency.',
 'Storage.saveConfigChanges': 'Merge accepted settings edits into the current stored configuration.',
 'Storage.validateConfig': 'Validate required configuration objects, frequency pairs and numeric bounds.',
 'Storage.validateSettings': 'Validate the stored display-settings schema and selected page.',
 'Storage.writeJson': 'Serialize and replace a JSON document through its validated storage path.',
 'Thrust.new': 'Construct core propulsion routing, controller caches and feedback-loop state.',
 'Thrust:acceptStatus': "Validate and cache a propulsion endpoint's status and readbacks.",
 'Thrust:decorate': 'Attach propulsion settings, feedback and role status to the display snapshot.',
 'Thrust:send': 'Validate and transmit the current drive target maps.',
 'Thrust:setRegistry': 'Update propulsion role routing from the accepted fleet registry.',
 'Thrust:stop': 'Release active propulsion demand and send endpoint stop commands.',
 'Thrust:update': 'Advance propulsion feedback, reversal handling and endpoint command delivery.',
 'Timing:row': 'Create or return the timing record for a named cockpit path.',
 'Watch:observe': 'Compare competing registered identity claims and update advisory evidence.',
 'Watch:prune': 'Expire old identity claims and enforce the bounded observation history.',
 '_ensureLocalCore': 'Reconcile the local core computer identity with the registry.',
 '_load': 'Load the current registry or its supported fallback record.',
 '_preserveCorrupt': 'Retain an unreadable registry record before writing its replacement.',
 '_read': 'Read and validate the selected registry document.',
 '_write': 'Write the validated registry document through its persistent storage path.',
 'acceptHello': "Validate a propulsion endpoint's Hello and bind its current boot.",
 'activationReady': 'Check configuration, input and controller readiness for propulsion engagement.',
 'activeAuthority': 'Validate the role/core authority associated with the active operation.',
 'adler32': 'Compute the Adler-32 checksum of the supplied byte string.',
 'arrayLength': 'Validate the shape and bounded length of an indexed array.',
 'assemblySample': 'Refresh the current assembler observation in its independent sampling worker.',
 'assistPrimaryTurn': 'Apply the configured primary-propeller turn assistance to mixed demands.',
 'atomic': 'Write a JSON record through the temporary-file replacement path.',
 'authorityCheck': 'Recheck the active session and assigned role before the next transfer step.',
 'bearing': 'Calculate a normalized compass bearing from horizontal displacement.',
 'beginWork': 'Record the start of a measured cockpit service interval.',
 'buildManifest': 'Build the bounded destination, size, checksum and chunk manifest.',
 'buildOffer': 'Build the role package offer with file bounds and transfer correlation.',
 'cached': 'Resolve the cached status page and its source age.',
 'checkMedia': 'Validate the recording disk and current writable output path.',
 'clearOperationIssue': 'Clear the recovered operation issue and record its recovery message.',
 'cockpitSample': 'Read and publish the current cockpit input batch.',
 'colorCode': 'Map a display colour value to its terminal blit digit.',
 'commandGate': 'Validate the live input and vessel context before propulsion commands.',
 'configuredProviderStrength': 'Resolve the configured activation level for a provider role.',
 'configuredSpeedGains': 'Read and validate the configured selected-speed PID gains.',
 'confirm': 'Submit the reviewed operation and track its request acknowledgement.',
 'connectAndServe': 'Connect the read-only diagnostic client and serve correlated host requests.',
 'context': 'Build or validate the runtime configuration context used by the current component.',
 'controllerReady': 'Evaluate controller identity, status freshness and write readiness.',
 'controllerSnapshot': "Build one controller's status, command and readback details.",
 'copy': 'Copy bounded table values into independent operation or transport records.',
 'coreHardwareHealth': 'Build core sensor and modem availability from the latest hardware inventory.',
 'currentCoreSession': 'Resolve the active core session used for transfer authorization.',
 'currentEpoch': 'Return the current epoch timestamp used for request expiry.',
 'debugWatchdog': 'Monitor debug worker completion and schedule paced worker replacement.',
 'debugWorker': 'Run paced removable-media debug writes from cached runtime data.',
 'directConfigReason': 'Validate the configured direct-drive mapping and operating limits.',
 'displayProgress': 'Render the cached transfer progress for the current installer operation.',
 'draw': 'Render the current view into its configured terminal or monitor.',
 'dump': 'Return the bounded timing counters and recorded path measurements.',
 'editComputerID': 'Validate an entered computer ID and save the selected role assignment.',
 'editID': "Validate and stage a role's replacement computer ID.",
 'editRegistry': 'Open the fleet-assignment editor using the current stored registry.',
 'emergencyKillFailureDetails': 'Collect chamber verification details for an incomplete emergency shutdown.',
 'emitCoreLog': 'Write a bounded event to the core log with its operation scope.',
 'execute': 'Validate the selected operation and dispatch its registered handler.',
 'faultList': 'Normalize a received fault list into bounded text entries.',
 'field': 'Add a measured value, source and timestamp to the current vessel snapshot.',
 'fingerprint': 'Build a deterministic identity string from the configured source inventory.',
 'finishWork': 'Record completion timing and elapsed work for the active service interval.',
 'flush': 'Write buffered records and update saved/dropped counters.',
 'handleMessage': 'Dispatch a received packet to the matching protocol/session handler.',
 'headingDriveDemand': 'Compute manual or selected-heading yaw demand from current vessel observations.',
 'lateralPower': 'Resolve verified applied lateral-propeller power for the requested maneuver.',
 'learnSpeedFeedforward': 'Update bounded feedforward bands from current speed-control observations.',
 'liftEvent': 'Append a bounded lift-command or readback event to the debug buffer.',
 'list': 'Render the visible entries for the current selection and scroll position.',
 'listMultishellTabs': 'Collect the available terminal-tab identities for diagnostics.',
 'listPeripherals': 'Collect a bounded inventory of attached peripheral names and types.',
 'loadBundle': 'Read and verify the requested role package from matching installer media.',
 'loadSpeedFeedforward': 'Load the persisted speed-to-drive feedforward calibration.',
 'localIdentity': "Validate this diagnostic client's installed role and computer identity.",
 'logOperationIssue': 'Record the active issue for a flight-operation scope.',
 'logPropulsionIssue': 'Record a changed propulsion issue and its associated controller context.',
 'logSystemsTelemetryRecovery': 'Record a change in the current systems telemetry-recovery state.',
 'makeServerSession': "Create the install server's bounded transfer-session token.",
 'makeTargetConfig': 'Build role configuration with the assigned core/computer identity.',
 'makeTargets': 'Build bounded per-controller drive targets from current cockpit and guidance demand.',
 'manifestChecksum': 'Calculate the ordered transfer-manifest checksum.',
 'manualAccelerationDriveRequest': 'Compute bounded primary-drive demand for the selected manual '
                                   'acceleration.',
 'matchesCorrelation': 'Compare a transfer packet with the current client/server request tokens.',
 'mixLateral': 'Mix yaw and sideways demand into the configured lateral drive targets.',
 'modems': 'Find and open the network modems used by the current client.',
 'mount': 'Resolve the removable-media path used by the destination library.',
 'needsComputerSetup': 'Determine whether required computer assignments need operator setup.',
 'newNode': "Initialize a registered chamber's status, sequence and command state.",
 'newSession': 'Generate the bounded session identifier used to correlate core traffic.',
 'normalizeReadings': 'Validate received propulsion readings and retain their field-validity flags.',
 'normalizedMap': 'Validate the normalized per-drive demand map.',
 'nowSeconds': 'Return the shared runtime clock in seconds.',
 'packageIsCurrent': 'Compare the installed package receipt with the expected package identity.',
 'pause': 'Yield until the requested repeat interval or an incoming runtime event.',
 'pauseRequested': "Check the installer's explicit pause marker.",
 'pick': 'Copy the specified bounded scalar fields into a transport view.',
 'primaryPower': 'Resolve verified applied primary-propeller power for the requested direction.',
 'prompt': 'Read the displayed operator prompt and return the entered value.',
 'propulsionWatchdog': 'Monitor propulsion worker completion and schedule paced worker replacement.',
 'propulsionWorker': 'Run the independent propulsion-control cadence and publish completion progress.',
 'providerTotal': 'Sum valid provider observations for a chamber measurement.',
 'publishRuntime': 'Publish the latest cached runtime snapshot and worker status.',
 'put': 'Write bounded text cells with the selected foreground colour.',
 'quat': 'Validate and normalize an observed quaternion.',
 'read': 'Read and return the selected source value with its associated result.',
 'readConfig': "Load and validate the role's configuration file.",
 'readDiagnosticFile': 'Read a permitted diagnostic file with bounded output.',
 'readFleetRegistry': "Load the installer's current role assignments and core identity.",
 'readJSON': 'Read and decode the selected JSON record.',
 'readJson': 'Read and decode the selected JSON record.',
 'readbackMap': 'Validate the reported drive readback map and its observation values.',
 'rebind': "Update matching retained vessel UUID references through the operation's nested records.",
 'receiveMatching': 'Receive a protocol packet matching the active transfer correlation.',
 'receiver': 'Receive network traffic and enqueue validated work for the runtime supervisor.',
 'registry': 'Load the current trusted fleet and remote-pairing registry.',
 'remove': 'Remove the selected stored entry and update its containing collection.',
 'resolveIdentity': "Resolve and validate the current installation's trusted core identity.",
 'runParallel': 'Run independent getter jobs and collect their completion results.',
 'runPulse': 'Issue and measure the local timing pulse used to observe scheduler delay.',
 'runtime': "Initialize the role's runtime context and start its supervised workers.",
 'safeValue': 'Convert diagnostic values into bounded serializable fields.',
 'sample': 'Perform the selected sensor read and publish its completed observation.',
 'sampler': 'Run the named sensor sampling loop with completion and retry tracking.',
 'saveJSON': 'Serialize and save the selected JSON record.',
 'saveStatus': "Persist the installer's bounded per-role progress record.",
 'send': 'Send the current correlated packet to its configured peer.',
 'sendCurrent': 'Notify the receiver that its verified package is current.',
 'sendStopTo': 'Send the selected propulsion endpoint its current-session stop command.',
 'serviceCockpit': 'Consume the newest cockpit sample and update flight/propulsion demand.',
 'setEnabled': 'Apply the accepted propulsion-enabled state and its control handover.',
 'setManualAccelerationUnavailable': 'Record the observation or configuration reason blocking acceleration '
                                     'feedback.',
 'settingsSnapshot': 'Expose the configured propulsion settings and verified operating limits.',
 'shape': 'Validate the received identity claim and extract its bounded comparison fields.',
 'snapshotMatches': 'Check that the current installed identity still matches the transfer snapshot.',
 'sourcePaths': 'Resolve the verified media source paths for a role package.',
 'speedApplied': 'Resolve the currently observed primary drive output for speed feedback.',
 'speedDriveRequest': 'Compute selected-speed drive demand using measured speed and configured limits.',
 'speedSnapshot': 'Build the current selected-speed control measurements and limits.',
 'startLocal': "Start core's local sensor workers for state-computer failover.",
 'startReview': 'Capture the requested remote destination for operator review.',
 'stateFailoverCheck': 'Evaluate state-frame freshness and coordinate local-reader takeover or handback.',
 'stopLocal': 'Retire the active local sensor workers when state service recovers.',
 'subsetDiffers': 'Compare the requested configuration subset with the stored document.',
 'supervisor': 'Service prioritized requests and advance the current runtime operations.',
 'systemsAbortText': 'Format the retained abort measurements and guard details for diagnostics.',
 'transact': 'Send and acknowledge the verified package files through the install transaction.',
 'typeList': 'Normalize reported peripheral types into a bounded list.',
 'unitSnapshot': "Build one propulsion-data unit's cached reading and freshness report.",
 'updateCommandRecovery': 'Retry pending propulsion commands and reconcile endpoint acknowledgements.',
 'updateSetup': 'Refresh the computer-assignment setup view from the current registry.',
 'updateSpeedLimit': 'Detect sustained selected-speed demand at the configured or maximum thrust limit.',
 'validReadPath': 'Validate a diagnostic file path against the permitted read locations.',
 'validateDrives': 'Check drive names and bounds against the configured controller inventory.',
 'validateFleet': "Validate the installer's role-to-computer registry.",
 'vessel': 'Refresh the local vessel observation in its sampling context.',
 'wait': 'Record the current restore prerequisite and retry it on a later update.',
 'waitFor': 'Wait for the expected transfer response within its request deadline.',
 'waitForFileComplete': "Wait for the receiver's verified file-completion acknowledgement.",
 'woke': 'Record event wake timing for the current cockpit service.',
 'wrap': 'Wrap display text to the available character width.'})

SUMMARIES.update({'Console.acceptRegistry': 'Validate and apply a registry announcement from the installed core.',
 'Console.dashboard': 'Render fleet program, hardware and issue status from cached reports.',
 'Console.pageRows': 'Format the rows for a selected role diagnostic page.',
 'Console.pages': 'Build the available diagnostic pages for the current role.',
 'Console.roleStatus': 'Build the current program, hardware and issue status for this role.',
 'Console.connectionState': 'Report core reachability from validated incoming traffic on this computer.',
 'Console.rows': 'Format the selected console page from cached runtime state.',
 'Console.runPaged': 'Display a bounded text collection with page navigation.',
 'Console.start': 'Start the role console, registry service and supervised application tasks.',
 'Console.status': 'Refresh the role console using its cached runtime status.',
 'Hardware.activate': 'Apply the validated demand-driven activation and verify the resulting interface '
                      'state.',
 'Hardware.discover': 'Discover and bind the configured role hardware.',
 'Hardware.emergencyStop': 'Apply the emergency stop sequence and verify its configured output readbacks.',
 'Hardware.loadConfig': 'Read the lift/thrust role configuration and validate its structure.',
 'Hardware.remotePeripheral': "Construct the role's configured local/remote peripheral access.",
 'Hardware.saveDiscovered': 'Persist the resolved hardware bindings into role configuration.',
 'Hardware.validateConfig': 'Validate role configuration, provider/drive definitions and their bounds.',
 'Hardware.validateTargets': 'Validate requested provider targets against configured names and numeric '
                             'limits.',
 'Link.child': 'Connect the child component to its configured chamber-side service.',
 'Link.parent': 'Build the chamber-side service for its attached child endpoints.',
 'Link.readCorner': 'Read the cached observation for the selected chamber corner.',
 'Link.unwrap': 'Resolve the underlying peripheral facade used by the chamber link.',
 'Link.waitCorner': 'Wait for the next valid observation from the selected chamber corner.',
 'Main.inspect': 'Inspect role configuration and attached hardware for local diagnostics.',
 'Main.newState': 'Construct chamber lift state from validated configuration and local computer identity.',
 'Main.run': 'Load role configuration and start its network, status and actuator-writer workers.',
 'Panel.computers': 'Map registered computers and relayed thrust status into the fleet overview.',
 'Panel.host': 'Run the adapted terminal host with the current panel and worker tasks.',
 'Panel.hostSource': 'Adapt the supported CraftOS host source for the panel workspace.',
 'Panel.relatedLogs': 'Select bounded log entries associated with the chosen computer.',
 'Panel.start': 'Launch Panel Home and bind its shared runtime context.',
 'Panel:action': 'Handle the selected local panel navigation or utility action.',
 'Panel:draw': 'Render the current cached panel frame to the terminal.',
 'Panel:frame': 'Build the current Panel Home page and its local action regions.',
 'Panel:input': 'Interpret panel keyboard/mouse input against the displayed action regions.',
 'Thrust.controlState': 'Classify endpoint readiness and pending drive application for status.',
 'Thrust.validateTargets': 'Validate the requested drive target map against configured channels and limits.',
 'add': 'Append one bounded entry to the current view or record collection.',
 'addProviderFaults': 'Append provider observation and interface faults to chamber status.',
 'addRecord': 'Add a bounded status/log record to the current collection.',
 'addValues': 'Append the supplied cached status fields to the current diagnostic view.',
 'allowed': 'Validate whether the current identity has permission for the selected operation.',
 'altitudeReceiver': "Receive and cache the chamber's local altitude observation.",
 'api.getNames': 'Return the peripheral names exposed by the configured facade.',
 'api.hasType': "Check the exposed peripheral's reported type.",
 'appTask': "Run the role's supervised application task.",
 'applyCommand': 'Dispatch the queued command to its verified actuator operation.',
 'applyControlContext': 'Apply the accepted core altitude/input context to chamber status.',
 'applyEmergencyStop': 'Apply and verify the latched emergency shutdown through the sole writer.',
 'applyManagedCommand': 'Validate live authority, apply provider targets and verify activation/readbacks.',
 'applyTuningCommand': 'Apply and verify the bounded tuning target map under its current lease.',
 'body': 'Write the page body into the bounded terminal frame.',
 'buildLiftAdapter': 'Build getter/setter bindings for the supported lift hardware interface.',
 'buildStatus': 'Build the bounded chamber lift, thrust and authority status packet.',
 'buildThrustAdapter': 'Build bounded drive/readback operations for the supported thrust interface.',
 'callApi': 'Invoke the selected peripheral method and retain its result or error.',
 'captureOutput': "Wrap terminal output methods to record the role's emitted text.",
 'clearPreviousIdentity': 'Retire cached state associated with the previous core identity.',
 'collectRuntimeFaults': 'Collect active faults from the current runtime components.',
 'commissionZeroAndIncremental': 'Verify configured drive zero and bounded incremental commissioning '
                                 'readbacks.',
 'componentAttempt': 'Run one role component and record its completion or exception.',
 'connectRednet': 'Discover and open role-network modems through rednet.',
 'controllerBindings': 'Resolve the configured controller-to-drive hardware bindings.',
 'controllerStatusReason': 'Resolve the current endpoint configuration, binding or authority issue.',
 'controllerTick': 'Advance endpoint control authority and the current requested drive operation.',
 'currentSystemsCommand': 'Check command sequence, lease, boot and session before a systems write.',
 'currentTimeLabel': 'Format the current clock value for status and log rows.',
 'details': "Format the selected computer's cached status and issue details.",
 'diagnosticsTabExists': 'Find an existing diagnostic task in the terminal host.',
 'dispatch': 'Validate and dispatch received packets for the current role and session.',
 'emitNodeLog': 'Write a bounded chamber component event with its scope.',
 'fail': "Record the active command's rejection and release its in-progress bookkeeping.",
 'faultSummary': "Format the current role's highest-priority reported issue.",
 'files': 'List the permitted installed files for the current role.',
 'findWirelessModems': 'Find attached wireless modem interfaces.',
 'flatten': 'Convert nested cached status fields into bounded display rows.',
 'forceZeroConfiguredDrives': 'Write verified zero demand to each configured propulsion drive.',
 'hasType': 'Check the reported peripheral type against the requested interface.',
 'installedCoreId': "Resolve the role's installed trusted core ID.",
 'interlockTargets': 'Apply the configured direction/neutral interlocks to requested drive targets.',
 'invalidate': 'Revoke the current endpoint command context and record its reason.',
 'inventoryFingerprint': 'Build the deterministic configured hardware identity used by binding checks.',
 'isCore': 'Identify whether this console belongs to the registered core role.',
 'loadProgram': 'Load a role program with the current CraftOS environment and arguments.',
 'logTimestamp': 'Format the current event time for component logs.',
 'clearIdleProbeFault': 'Clear the recovered idle-probe fault while retaining other operation faults.',
 'maintainIdleProbe': 'Retry eligible idle probes and clear their faults after cancellation or recovery.',
 'makeRemotePeripheralApi': 'Construct the configured remote-peripheral facade and its method routing.',
 'makeState': "Construct the endpoint's boot, session, target and readback state.",
 'managedReady': 'Evaluate the configured activation and local startup prerequisites.',
 'methodSet': 'Build the method-name lookup for a peripheral interface.',
 'networkLoop': 'Receive role-protocol packets and queue their validated operations.',
 'neutralSessionWait': 'Evaluate the new-session neutral handover before accepting drive demand.',
 'newBootId': 'Generate the bounded boot identity for this role instance.',
 'observeInstallerStatus': 'Read cached installer progress and report its state transitions.',
 'observeRuntimeFaults': 'Record changed runtime issues and clear recovered issue scopes.',
 'onNetworkMessage': 'Receive a core packet and wake the appropriate status/writer worker.',
 'onWaiting': 'Record the current provider handover prerequisite while its writer waits.',
 'openDiagnosticsTab': "Start or focus the role's diagnostic task.",
 'openNetwork': 'Open the configured modems for role registry and status traffic.',
 'openWirelessModems': 'Open the selected wireless modems through rednet.',
 'parkTrim': 'Place the fine/probe providers in the configured parked state.',
 'primaryDirectionBinding': 'Resolve the configured primary-propeller direction-control link.',
 'printInspection': 'Print the configured hardware inventory and getter observations.',
 'processPendingMaintenance': 'Perform the queued hardware recheck or confirmed controller restart.',
 'processPendingSystemRestart': 'Acknowledge and execute a fresh authorized reboot after writer completion.',
 'providerActivityFault': 'Describe the failed provider observation or activity requirement.',
 'publish': 'Publish the current cached component observations to the configured consumer.',
 'publishLoop': 'Publish cached endpoint status at the configured interval.',
 'queueSystemRestart': 'Validate and queue a core-requested endpoint restart.',
 'queueSystemRestartError': 'Stage a correlated rejection for the current restart request.',
 'readBearing': 'Read and validate one configured propulsion bearing observation.',
 'readBearings': 'Read the configured propulsion bearing observations.',
 'readEmergencyLatch': 'Read the persisted emergency-stop marker and its validation result.',
 'readReadbacks': 'Read and validate the configured controller drive levels.',
 'readSafetyState': 'Collect the configured hardware interlock and output observations.',
 'readShift': "Read the selected gearshift's current drive level.",
 'readbackSnapshot': 'Build the bounded endpoint drive-readback view.',
 'readbackTargets': 'Build the provider target map from validated physical readbacks.',
 'receiptReady': 'Verify the committed installation receipt for this role and computer.',
 'receiveControlContext': 'Validate and receive the chamber control-context lease.',
 'receiveEmergencyStop': 'Latch and queue the authenticated emergency-stop request.',
 'receiveLoop': 'Receive network packets and pass matching requests to the role dispatcher.',
 'receiveSystemRestart': "Validate the role's requested reboot against its current core session and boot.",
 'receiveSystems': 'Validate and queue the current core systems-stage target request.',
 'receiveSystemsStop': 'Validate a core lease release or confirmed probe-preserving shutdown.',
 'receiveTuning': 'Validate and queue a command under the current bounded tuning lease.',
 'record': 'Append a bounded record to the current event collection.',
 'recordConsole': "Append bounded terminal output to the role's console history.",
 'recordError': 'Append a bounded component exception to console history.',
 'refreshBindings': 'Rediscover role hardware and update its binding identity and availability.',
 'refreshPublicArmed': 'Publish the control-activity state derived from current authority and observations.',
 'refreshSnapshot': 'Sample the configured chamber hardware and update cached observations.',
 'refreshStatus': "Refresh the endpoint's configuration, hardware and drive readback status.",
 'registryPump': "Receive and publish the role's current fleet registry and health reports.",
 'relay': 'Forward the permitted chamber-link packet to its registered destination.',
 'reloadTask': "Handle the current role's program reload request.",
 'reportBindingFault': 'Record the current hardware-binding failure reason.',
 'reportBindingIdentityChange': 'Record the changed hardware-binding identity and observation context.',
 'reportComponentStartup': "Record the role component's startup identity and program state.",
 'reportError': 'Publish a component error to the current console issue scope.',
 'restartStillAuthorized': 'Revalidate the pending reboot against its request age, session and local boot.',
 'retireCoreSession': 'Record an obsolete core session in the bounded replay-rejection history.',
 'roleRuntime': 'Start the installed role program after identity and receipt verification.',
 'runConcurrently': 'Run the independent provider operations and collect their completions.',
 'runDiagnostics': 'Start the installed diagnostic client with the current role identity.',
 'runInstaller': 'Start the installed package receiver or core package-service task.',
 'sampleActivation': 'Read the configured provider activation signals.',
 'sampleAltitude': "Read and validate the role's configured altitude observation.",
 'sampleBalloon': 'Read envelope composition, volume, lift and representative-balloon status.',
 'sampleConfigured': "Read the configured providers and retain each getter's validity and result.",
 'sampleHandoverReadiness': 'Read provider/envelope observations required for the next systems-stage '
                            'handover.',
 'selectNames': 'Select discovered peripherals matching the configured role criteria.',
 'sendStatus': 'Send the latest bounded role status to the current core.',
 'sendSystemRestartAck': 'Send the correlated restart acceptance or rejection to core.',
 'sensorRestartLoop': 'Handle the local sensor/endpoint restart request through its current authority.',
 'sensors': 'Publish the available chamber-local sensor observations.',
 'sortedNames': 'Return discovered names in deterministic order.',
 'startCompositionProbe': 'Establish the configured low-probe composition observation.',
 'status': 'Build the selected cached runtime status view.',
 'statusLoop': 'Sample cached hardware status and publish role reports at the configured cadence.',
 'statusPacket': 'Build the bounded current-session endpoint status packet.',
 'statusTask': 'Publish cached role health and refresh its terminal status.',
 'supervise': 'Run a component with logged completion and paced restart.',
 'systemsStartReady': 'Check current provider and envelope observations for systems-stage startup.',
 'systemsSupported': 'Check that the configured hardware exposes the systems-stage operations.',
 'trustedCoreID': 'Resolve the installed trusted core computer ID.',
 'tryOpenWireless': "Discover and open the role's current wireless modem interfaces.",
 'updateReadbacks': 'Read and cache the configured endpoint drive levels.',
 'updateRuntime': "Publish the role's current cached state to the local runtime context.",
 'utility': 'Run the selected local console utility.',
 'validInstalledIdentity': 'Validate the installed core, role and local computer identity.',
 'validateConfig': "Validate the role's required configuration fields and operating bounds.",
 'validateControlContext': 'Validate the selected-altitude/input lease from the current core session.',
 'validateVentStartup': 'Check startup targets against configured provider bounds and current readbacks.',
 'value': 'Read and validate the selected numeric or typed observation.',
 'verifyAll': 'Verify each configured output against the requested target and current authority.',
 'waitReady': 'Wait for the configured installation and identity prerequisites.',
 'wrapLogRows': 'Wrap bounded log records into the available terminal width.',
 'writeDirectionSignal': 'Write the validated direction signal to its configured link.',
 'writeEmergencyLatch': 'Persist or clear the accepted emergency-stop marker.',
 'writerLoop': "Serialize queued hardware operations and maintenance through the role's sole writer."})

SUMMARIES.update({'Receiver:accept': 'Validate and accept the newest navigator snapshot from the trusted core.',
 'Receiver:setRegistry': 'Update navigator routing from the accepted fleet registry.',
 'Requests:enqueue': 'Queue a pilot action and supersede older replaceable requests.',
 'Requests:step': 'Send or retry the active navigator command within its session and expiry.',
 'UI.new': 'Construct renderer navigation, editor, cache and monitor state.',
 'UI:draw': 'Build and flush the current cached navigator display.',
 'UI:editorKey': 'Apply local settings-editor input and return a validated save action.',
 'UI:input': 'Route keyboard input to the active local editor or navigation context.',
 'UI:navEditorKey': 'Apply local destination-editor input and return a validated navigation action.',
 'acceptStatus': 'Validate and cache a fresh status packet from the configured core.',
 'addHeader': 'Render the common heading, mode selectors and Systems control.',
 'altitudeAbortMessage': 'Format the retained systems-abort reason for the Flight warning area.',
 'altitudeHoldIndicator': 'Format the current altitude-control indicator and its display colour.',
 'altitudeHoldIndicatorRaw': 'Resolve the altitude-control indicator from current systems/control state.',
 'appliedThrottleReadback': 'Format the measured left/right primary drive output.',
 'assemblySurface': 'Render the current vessel assembly status and its blocked-operation context.',
 'attachMonitor': 'Bind the selected monitor and apply the configured text scale.',
 'balancedLift': 'Resolve the cached balanced-capacity model exposed by systems control.',
 'balancedLiftWarning': 'Format the active chamber capacity or provider-floor limit.',
 'bestEffortErrorFrame': 'Render the current display error using the available monitor methods.',
 'bind': 'Resolve the current monitor or network attachment for the role.',
 'bridgeAckMatches': 'Match a navigator command acknowledgement to its active request.',
 'button': 'Render a bounded action label and record its touch region.',
 'clampText': 'Bound display text to the available character count.',
 'clearMonitor': 'Clear the monitor and reset its drawing state.',
 'compass': 'Format the compass labels and markers for the observed heading.',
 'controlUnavailable': "Check the selected feedback controller's reported availability.",
 'controllerDriveReadback': "Format a controller drive's requested demand and measured level.",
 'dataReadout': "Format the endpoint's raw speed, thrust, vector or assembly observation.",
 'displayIssue': 'Resolve the current display availability, assembly or role-status issue.',
 'displaySnapshot': 'Resolve the current status snapshot and its stale-display treatment.',
 'drawAltitudeTape': 'Render the altitude scale and selected-altitude marker; levels above the altitude ceiling stay blank.',
 'drawAssemblyPanel': 'Render assembly status and the operator instruction.',
 'drawButton': 'Render the label using its selected, enabled, disabled or danger style.',
 'drawCenter': 'Render the center heading/altitude display from the cached snapshot.',
 'drawCenterHeading': 'Render heading, altitude and selected targets on the center instrument.',
 'drawCompass': 'Render the compass scale and observed-heading marker.',
 'drawFleetBootPanel': 'Render the fleet operation phase, current role and progress.',
 'drawFlight': 'Render speed, vessel motion, propulsion feedback and chamber control tiles.',
 'drawHeading': 'Render the configured heading-display layout.',
 'drawHeadingTape': 'Render the horizontal heading tape and selected-heading marker.',
 'drawHorizontalHeading': 'Render the wide heading display and its status labels.',
 'drawMain': 'Compose the common header, selected page, modal reviews and warning area.',
 'drawNavigation': 'Render destination editing, active route guidance or digital-anchor status.',
 'drawPlainRow': "Write one character row through the monitor's plain-text methods.",
 'drawQuadrantTiles': 'Render the four chamber control states and measured outputs.',
 'drawSettings': 'Render the selected settings page, editor or maintenance review.',
 'drawShip': 'Render the selected Ship lift, propulsion or trim subsection.',
 'drawShipFaults': 'Render the highest-priority cached ship fault.',
 'drawShipLift': 'Render vessel lift and per-chamber envelope/provider observations.',
 'drawShipPropulsion': 'Render configured propulsion endpoints and their readbacks.',
 'drawShipTabs': 'Render the Ship subsection labels and selection.',
 'drawShipTrim': 'Render manual fore/aft bias, measured attitude difference and trim status.',
 'drawSurface': 'Flush changed character rows to the configured display.',
 'drawSystemsMenu': 'Render the current Systems dropdown and its available actions.',
 'drawTabs': 'Render the page tabs and return their current touch regions.',
 'drawToMonitor': 'Write the prepared character frame to the configured monitor.',
 'drawTooSmall': 'Render the required monitor dimensions for the bridge display.',
 'emergencyLift': 'Resolve kill/disarm progress text, availability and message-specific colour.',
 'errorSurface': 'Build a bounded error display surface for the current monitor.',
 'fillRect': 'Fill the bounded surface rectangle with the selected cell colours.',
 'findMonitor': 'Select the configured monitor from the attached peripheral inventory.',
 'finishSurface': 'Convert the surface cells into terminal text and blit rows.',
 'firstThrustIssue': 'Resolve the current propulsion, endpoint or cockpit-feedback issue.',
 'fleetActionAllowed': 'Evaluate the selected action against the current fleet startup gate.',
 'fleetBootSurface': 'Render cached fleet startup progress and the current role prerequisite.',
 'frame': 'Build the current bounded display frame from cached status.',
 'handleRestart': 'Acknowledge and execute the validated role restart request.',
 'headingErrorSurface': "Build the heading display's unavailable-data surface.",
 'headingFeedbackDetail': 'Format current heading/yaw feedback and its availability reason.',
 'headingIssue': 'Validate the observations required by the configured heading display.',
 'loadConfig': 'Read and validate the current role configuration.',
 'resetLeveling': 'Return learned leveling to the saved level bias, or to zero when none is saved, during the altitude hold.',
 'makeSurface': 'Allocate a character-cell display surface with foreground and background colours.',
 'GLYPH.cells': 'Split text into monitor cells: printable ASCII and the delta and degree glyphs as themselves, any other character as one question mark.',
 'manualAccelerationDetail': 'Format measured acceleration feedback and its availability reason.',
 'monitorSize': "Read and validate the monitor's current character dimensions.",
 'newSurface': "Allocate the main renderer's character, foreground and background cells.",
 'nodeSummary': "Format a chamber's link, control, lift, gas and target observations.",
 'nodeTileMeasurements': 'Resolve the chamber gas, target and lift values for its tile.',
 'nodeTone': 'Choose the chamber status colour from link/readiness and reported faults.',
 'openWirelessModems': 'Find and open wireless modems for fleet status reception.',
 'propulsionModeDetail': 'Format propulsion-mode feedback, calibration and thrust-limit information.',
 'propulsionRequestText': 'Format the requested acceleration, selected speed or direct drive value.',
 'readbackRaw': 'Read a validated raw value from the cached propulsion endpoint.',
 'render': 'Build and flush the selected cached display view.',
 'reportHeadingIssue': 'Record changes in heading-display availability.',
 'roleCounts': 'Count the ready/live endpoints in the selected role group.',
 'roleDisplayStatus': 'Classify endpoint discovery, link, freshness and control readiness.',
 'roleFaultText': "Extract a bounded issue message from the endpoint's cached fault data.",
 'roleIssue': 'Resolve the first reported fault or availability issue in a role group.',
 'run': 'Initialize the role and run its configured display/network service.',
 'sanitizeSnapshot': 'Validate and bound the received vessel/display snapshot.',
 'sensorAvailable': "Validate a vessel field's availability within the current display snapshot.",
 'shipTabRegions': 'Calculate the local Ship subsection touch rectangles.',
 'shortRoleStatus': 'Map detailed endpoint status into the compact tile label.',
 'speedControlStatus': 'Resolve the supported selected-speed feedback state for display.',
 'speedTarget': 'Resolve the current selected-speed target from feedback or pilot selection.',
 'speedTrend': 'Filter successive speed observations into an increasing/decreasing trend marker.',
 'syncRegistry': 'Reconcile the current role identity with a trusted registry announcement.',
 'tabRegions': 'Calculate the current page-tab touch rectangles.',
 'touchSystemsMenu': "Resolve dropdown touches against the current snapshot's action availability.",
 'validateRestart': 'Validate a requested reboot against the configured core, session and local boot.',
 'vesselReason': 'Resolve the current vessel-data availability reason.',
 'wrapErrorText': 'Wrap an availability or error message into bounded display rows.',
 'wrapWords': 'Wrap message words to the available character width.'})

PURPOSES.update({
 "/avionics/flight.lua":"Altitude authority | Startup, retained lift, PID demand and operator lifecycle.",
 "/avionics/io.lua":"Core boundary | Hardware observations, trusted fleet packets and bounded commands.",
 "/avionics/thrust.lua":"Propulsion authority | Drive discovery, feedback, interlocks and command delivery.",
 "/avionics/vessel_sources.lua":"Vessel observations | Timestamped Sable fields and calibrated peripheral fallback.",
 "/avionics/state_reader.lua":"State service | Independent sensor workers and wired telemetry publication.",
 "/avionics/state_wire.lua":"State transport | Correlated wired frames, source ages and core configuration.",
 "/avionics/telemetry_recovery.lua":"Lift recovery | Retained target reconciliation and authority renewal.",
 "/avionics/controls.lua":"Cockpit interpretation | Selected targets, pilot modes and lever handover.",
 "/avionics/autopilot.lua":"Route guidance | Destination acquisition, cruise and arrival control.",
 "/avionics/anchor.lua":"Position guidance | Captured world point, braking and return demand.",
 "/avionics/lateral.lua":"Sideways guidance | Selected displacement, braking and pilot handover.",
 "/avionics/storage.lua":"Persistent configuration | JSON validation, settings edits and file replacement.",
 "/avionics/restart.lua":"Systems restart | One-shot checkpoints, acknowledgements and retained-run restore.",
 "/avionics/control_presets.lua":"Pilot selections | Persistent modes and selected values.",
 "/avionics/pid.lua":"Feedback primitive | Elapsed-time PID with bounded integration.",
 "/avionics/main.lua":"Core runtime | Role setup, prioritized supervision and independent workers.",
 "/avionics/panel_console.lua":"Core console | Cached fleet pages, issue details and local navigation.",
 "/avionics/common/console.lua":"Role console | Application supervision, registry health and local tools.",
 "/packages/common/console.lua":"Role console | Application supervision, registry health and local tools.",
 "/packages/navigation/ui.lua":"Navigator presentation | Character frames, warning selection and pilot input.",
 "/packages/navigation/main.lua":"Navigator service | Status reception and acknowledged cockpit requests.",
 "/packages/navigation/storage.lua":"Navigator preferences | Validated display configuration and JSON persistence.",
 "/packages/heading/*/main.lua":"Heading display | Cached compass/altitude instruments and status reception.",
 "/packages/chamber/*/main.lua":"Chamber coordinator | Supervised lift, propulsion relay and shared observations.",
 "/packages/chamber/*/lift.lua":"Chamber lift | Lease validation, physical readbacks and serialized provider writes.",
 "/packages/chamber/*/thrust.lua":"Chamber propulsion | Endpoint commands, readbacks and local session handover.",
 "/packages/chamber/*/hardware.lua":"Chamber hardware | Discovered provider/drive bindings and validated peripheral operations.",
 "/packages/chamber/*/chamber_link.lua":"Local chamber link | Parent/child transport and shared sensor observations.",
 "/packages/chamber/*/relay.lua":"Chamber relay | Local propulsion and sensor publication entry point.",
 "/packages/thrust/*/thrust.lua":"Thrust endpoint | Session-bound drive requests and physical readbacks.",
 "/packages/thrust/*/hardware.lua":"Thrust hardware | Configured controller bindings and peripheral operations.",
 "/packages/primary/*/main.lua":"Primary propulsion | Direction interlocks, drive commands and endpoint status.",
 "/packages/primary/*/hardware.lua":"Primary hardware | Bearing/gearshift discovery and readback verification.",
 "/packages/common/thrust_main.lua":"Thrust entry point | Start the installed endpoint service.",
 "/avionics/remote_client.lua":"Remote panel | Paired cached views, command review and input navigation.",
 "/avionics/remote_ap_client.lua":"Remote AP client | Reviewed destinations and correlated command progress.",
 "/avionics/remote_ap.lua":"Remote command service | Authenticated requests serviced by core's supervisor.",
 "/avionics/remote_install.lua":"Remote provisioning | Docked installation, pairing and flight permission.",
 "/avionics/diagnostics.lua":"Diagnostic client | Bounded inventory, cached status and permitted read requests.",
 "/packages/common/diagnostics.lua":"Diagnostic client | Bounded inventory, cached status and permitted read requests.",
 "/avionics/debug_recorder.lua":"Debug recording | Removable-media capture and paced buffered writes.",
 "/avionics/recorder.lua":"Systems recording | Cached startup/hold observations appended to CSV.",
 "/avionics/destinations.lua":"Destination library | Mounted-media validation, listing and accepted edits.",
 "/avionics/fleet.lua":"Fleet registry | Role assignment validation and stored computer IDs.",
 "/avionics/motion_warnings.lua":"Motion advisories | Measured impact and sustained-obstruction evidence.",
 "/avionics/physics_monitor.lua":"Physics observations | Consistency of measured acceleration, lift and pressure.",
 "/avionics/cockpit_timing.lua":"Timing evidence | Input completion, service intervals and scheduler pulses.",
 "/avionics/runtime_metrics.lua":"Runtime metrics | Bounded elapsed-work observations.",
 "/avionics/progress_watchdog.lua":"Worker supervision | Completion tracking and paced replacement decisions.",
 "/avionics/propulsion_worker.lua":"Propulsion worker | Independent control cadence and completion heartbeat.",
 "/avionics/radio_inbox.lua":"Prioritized inbox | Bounded packet coalescing and next-work selection.",
 "/avionics/sampling.lua":"Sampling lifecycle | Attempt deadlines and observed completion progress.",
 "/avionics/navigation_settings.lua":"Navigation configuration | Defaults, editable fields and numeric bounds.",
 "/avionics/input_tuning.lua":"Input response | Selected-target rates and held-input acceleration.",
 "/avionics/identity_watch.lua":"Identity advisory | Bounded observations of competing registered claims.",
 "/avionics/display_payload.lua":"Display transport | Compact cached fields for heading instruments.",
 "/installer/server.lua":"Package service | Trusted removable-media offers and acknowledged transfer.",
 "/installer/progress.lua":"Installation progress | Cached per-role state and terminal frames.",
 "/installer/media.lua":"Package media | Matching release discovery and verified object reads.",
 "/installer/bundle_cache.lua":"Package cache | Verified source-object lookup by fingerprint.",
 "/startup.lua":"Boot entry | Load the installed console and role application environment.",
 "/avionics/reconnect-diagnostics.lua":"Diagnostic entry | Launch the configured read-only connection probe."
})
SUMMARIES.update({
 "packageState":"Resolve the role's expected package identity and installed status.",
 "/avionics/motion_warnings.lua#M.new":"Validate motion-advisory settings and initialize measurement history.",
 "/installer/server.lua#M.run":"Run the core package service against current fleet authority and removable media.",
 "/avionics/diagnostics.lua#execute":"Dispatch a validated diagnostic request to its bounded read handler.",
 "/packages/common/diagnostics.lua#execute":"Dispatch a validated diagnostic request to its bounded read handler.",
 "/avionics/vessel_sources.lua#read":"Collect the selected sensor getter result and its completion timestamp."
})

REVISIONS=[
 ("-- Cockpit interpretation only. This module NEVER writes an actuator.",
  "-- Interpret cockpit inputs into selected targets and live propulsion demand."),
 ("-- Source ages are never renewed by a composite publication or a failed getter.",
  "-- Source ages record successful getter completion times."),
 ("-- ama-state: sensor getters only. No flight controller or actuator writer runs here.",
  "-- ama-state samples independent sensor fields and publishes timestamped frames to core."),
 ("-- Disengagement deliberately retains the applied caps and activation.\n    -- Removing lift is not an emergency stop. No authority restores on boot.",
  "-- Disengagement retains applied caps and activation.\n    -- Retained systems intent governs validated resumption after reboot."),
 ("-- This module only draws snapshots and reports page-tab touches. It never\n-- writes redstone, changes a target, or operates a lift/propulsion peripheral.",
  "-- Render cached vessel snapshots and return locally selected operator actions."),
 ("--   true                   ASSEMBLED, gate open\n--   false                  DISASSEMBLED\n--   missing/failed/stale   ASSEMBLED but unverified, gate stays open",
  "--   fresh Sable UUID       association verified, gate open\n--   Sable unavailable       consult the fresh assembler result\n--   assembler false         disassembled when Sable association is unavailable\n--   unresolved observations gate open, warn after five minutes"),
 ("-- A definite true/false answer is used at once (false blocks immediately).",
  "-- The Sable-first gate evaluates each timestamped assembler result."),
]

def revise(payload, reverse=False):
    """Apply reversible corrections to existing comment tokens."""
    pairs=[(new,old)for old,new in REVISIONS]if reverse else REVISIONS
    for path,data in list(payload.items()):
        if not path.endswith(".lua"):continue
        text=data.decode("utf-8")
        original=[token[0]for token in tokens(text)]
        for old,new in pairs:
            if old not in text:continue
            candidate=text.replace(old,new)
            if [token[0]for token in tokens(candidate)]==original:text=candidate
        payload[path]=text.encode("utf-8")

def section_name(path,name):
    """Choose a section heading from the module's actual function groups."""
    key=canonical(path);short=re.split(r"[.:]",name)[-1]
    if key.endswith("/flight.lua"):
        if any(part in short.lower()for part in ("emergency","kill","disarm")):return "Emergency lift | Latched operator shutdown and verified disarm."
        if any(part in short.lower()for part in ("recover","verify","finishactive")):return "Recovery | Physical target reconciliation and retained-run resumption."
        if any(part in short.lower()for part in ("tuning",)):return "Bounded tests | Captured baselines, bounded demand and result persistence."
        if "maintenance" in short.lower():return "Maintenance | Reviewed chamber rechecks and restarts."
        if any(part in short.lower()for part in ("trim","level")):return "Leveling | Chamber-height feedback and retained trim allocation."
        if any(part in short.lower()for part in ("system","startup","support","balanced","gas","capture","bulk","seeded")):return "Systems control | Startup, measured dynamics and bounded provider demand."
        if any(part in short.lower()for part in ("config","remember","learned","hover","persist")):return "Persistent learning | Validated calibration and retained operating records."
        return "Flight lifecycle | Operator actions, runtime gates and cached presentation."
    if key.endswith("/io.lua"):
        if any(part in short.lower()for part in ("snapshot","status","subsystem","recordrole","packagestate")):return "Status | Validate incoming observations and publish cached fleet state."
        if any(part in short.lower()for part in ("send","command","cancel","controlcontext")):return "Commands | Correlated bounded requests and acknowledged application."
        if any(part in short.lower()for part in ("sample","attitude","pressure","quaternion")):return "Observations | Independent sensor completion and vessel geometry."
        return "Core context | Registry, hardware discovery and protocol identity."
    if "/navigation/ui.lua" in key:
        if short.startswith("draw"):return "Page rendering | Cached character-cell views and action regions."
        if any(part in short.lower()for part in ("touch","key","input","new")):return "Operator navigation | Local selection, editing and returned actions."
        if name.startswith("Info."):return "Current issues | Active warnings, rotation and local issue navigation."
        return "Display data | Field validity, formatting and status selection."
    if key.endswith("/thrust.lua")or key.endswith("/hardware.lua"):
        if any(part in short.lower()for part in ("speed","heading","acceleration","mix","turn")):return "Drive demand | Bounded feedback and maneuver mixing."
        if any(part in short.lower()for part in ("read","sample","snapshot","status")):return "Readbacks | Timestamped physical observations and status."
        if any(part in short.lower()for part in ("write","apply","send","zero","stop","activate")):return "Output operations | Verified targets applied under current authority."
        return "Endpoint context | Configuration, discovery and command identity."
    return PURPOSES.get(key,"Module operations | Configured inputs, cached state and operation results.")


def annotate(payload, strict=True):
    """Add reviewed section/function summaries and verify executable tokens."""
    revise(payload)
    coverage=[];missing=[]
    for path,data in list(payload.items()):
        if not path.endswith(".lua"):continue
        text=data.decode("utf-8")
        if any(marker in text for marker in ("-- Summary:", "-- @ama-summary:")):continue
        frames=[f for f in functions(text, min_lines=1)
                if f["endline"]-f["line"]>=7 or canonical(path)+"#"+f["name"] in SHORT_SUMMARIES]
        insertions={};last_section=None
        for frame in frames:
            summary=summary_for(path,frame,text)
            if not summary:
                missing.append((path,frame["name"],frame["line"],frame["endline"]));continue
            line=text.rfind("\n",0,frame["start"])+1
            indent=re.match(r"[ \t]*",text[line:])[0]
            lines=insertions.setdefault(line,[])
            section=section_name(path,frame["name"])
            if not indent and section!=last_section:
                lines.append("-- Section: "+section+"\n");last_section=section
            lines.append(indent+"-- Summary: "+summary+"\n")
        purpose=PURPOSES.get(canonical(path))
        if purpose:insertions.setdefault(0,[]).insert(0,"-- Section: "+purpose+"\n")
        for offset,lines in sorted(insertions.items(),reverse=True):
            text=text[:offset]+"".join(lines)+text[offset:]
        assert [token[0]for token in tokens(data.decode("utf-8"))]==[token[0]for token in tokens(text)],path
        payload[path]=text.encode("utf-8")
        coverage.append({"path":path,"majorFunctions":len(frames),"summarized":len(frames)-sum(m[0]==path for m in missing)})
    if missing and strict:raise ValueError("Missing function summaries: "+repr(missing[:15]))
    return coverage,missing

# Installer export documentation shares the runtime lexical-equivalence check.
SUMMARIES.update({'/disk/auxiliary-startup.lua#Installer.setApplicationState': 'Update the receiver with the application '
                                                              'lifecycle and current errors.',
 '/disk/auxiliary-startup.lua#Setup.adoptLibrary': 'Verify the mounted library and publish its trusted '
                                                   'metadata on core.',
 '/disk/auxiliary-startup.lua#Setup.cancelRepair': 'Cancel the pending assignment correction and preserve '
                                                   'its recorded outcome.',
 '/disk/auxiliary-startup.lua#Setup.importFleet': 'Import a compatible installed fleet into the disk '
                                                  'assignment record.',
 '/disk/auxiliary-startup.lua#Setup.installAuxiliary': 'Register an auxiliary role and install its bootstrap '
                                                       'receiver.',
 '/disk/auxiliary-startup.lua#Setup.installCore': 'Register core and install its verified payload and '
                                                  'configuration.',
 '/disk/auxiliary-startup.lua#Setup.main': 'Run keyboard page navigation, role selection and installation '
                                           'review.',
 '/disk/auxiliary-startup.lua#Setup.overview': 'Collect assignment and installation progress for every '
                                               'expected computer.',
 '/disk/auxiliary-startup.lua#Setup.planRepair': 'Build a reviewed role-reassignment plan from current fleet '
                                                 'records.',
 '/disk/auxiliary-startup.lua#Setup.resumeRepair': 'Resume the verified assignment operation and record its '
                                                   'completion.',
 '/disk/auxiliary-startup.lua#Setup.startCore': 'Launch installed core services after setup completes.',
 '/disk/auxiliary-startup.lua#acceptRegistry': 'Validate the core registry and bind the bootstrap to its '
                                               'assigned role.',
 '/disk/auxiliary-startup.lua#activeBinding': 'Read the current installed role binding used for request '
                                              'authority.',
 '/disk/auxiliary-startup.lua#actualComputerId': 'Read and validate the actual ComputerCraft ID.',
 '/disk/auxiliary-startup.lua#assignedRole': 'Resolve the current computer role from its validated '
                                             'registration.',
 '/disk/auxiliary-startup.lua#basicJSON': 'Encode the small installer status record with supported JSON '
                                          'values.',
 '/disk/auxiliary-startup.lua#checkedPlan': 'Validate a stored assignment plan against the current disk and '
                                            'computer state.',
 '/disk/auxiliary-startup.lua#cleanupJournalFiles': 'Remove transaction staging and backup files after '
                                                    'completion.',
 '/disk/auxiliary-startup.lua#clockNow': 'Obtain the runtime clock used for installer request timing.',
 '/disk/auxiliary-startup.lua#commit': 'Verify staged files, replace programs and publish the installation '
                                       'receipt.',
 '/disk/auxiliary-startup.lua#completed': 'Check the installed receipt and application binding for setup '
                                          'completion.',
 '/disk/auxiliary-startup.lua#coreEntries': 'Select core payloads and merge retained configuration and '
                                            'learned defaults.',
 '/disk/auxiliary-startup.lua#correctAssignment': 'Review and submit an assignment change for the current '
                                                  'computer.',
 '/disk/auxiliary-startup.lua#deleteJournal': 'Remove the completed replacement journal and its bookkeeping.',
 '/disk/auxiliary-startup.lua#deployment': 'Load the disk deployment record and validate its fleet '
                                           'assignments.',
 '/disk/auxiliary-startup.lua#dialog': 'Render a bounded keyboard confirmation and return the selected '
                                       'response.',
 '/disk/auxiliary-startup.lua#ensureNetwork': 'Open the configured modem network and report attachment '
                                              'errors.',
 '/disk/auxiliary-startup.lua#finishIfComplete': 'Remove temporary commissioning state once installation is '
                                                 'confirmed.',
 '/disk/auxiliary-startup.lua#helloPacket': 'Build a hello request with current role, package and session '
                                            'metadata.',
 '/disk/auxiliary-startup.lua#installFiles': 'Write the selected verified payload files and report '
                                             'installation progress.',
 '/disk/auxiliary-startup.lua#installedReceipt': 'Read or create the verified package receipt for '
                                                 'installation acknowledgement.',
 '/disk/auxiliary-startup.lua#jsonDecode': 'Decode JSON through the selected runtime API with validation '
                                           'errors.',
 '/disk/auxiliary-startup.lua#localRepairCheck': 'Check the selected core and role metadata for the '
                                                 'supported assignment operation.',
 '/disk/auxiliary-startup.lua#makePreparedFiles': 'Prepare package files and retained configuration before '
                                                  'commit.',
 '/disk/auxiliary-startup.lua#makeSession': 'Construct the current computer installation session identifier.',
 '/disk/auxiliary-startup.lua#nextCounter': 'Advance the persistent correlation counter for an installation '
                                            'session.',
 '/disk/auxiliary-startup.lua#normalizeConfig': 'Validate installer role, protocol, retry and package '
                                                'settings.',
 '/disk/auxiliary-startup.lua#operation': 'Run a selected setup operation and display its progress and '
                                          'result.',
 '/disk/auxiliary-startup.lua#pendingCorrection': 'Display the stored correction plan and handle resume or '
                                                  'cancellation.',
 '/disk/auxiliary-startup.lua#preflight': 'Validate destination paths, available capacity and installation '
                                          'metadata.',
 '/disk/auxiliary-startup.lua#preserveInstalledStatus': 'Retain verified installed progress when receiving a '
                                                        'new service observation.',
 '/disk/auxiliary-startup.lua#processOffer': 'Receive verified package chunks and coordinate their staged '
                                             'installation.',
 '/disk/auxiliary-startup.lua#readFile': 'Read a bounded installer file and return its content or read '
                                         'error.',
 '/disk/auxiliary-startup.lua#readJournal': 'Read and validate a pending replacement journal.',
 '/disk/auxiliary-startup.lua#readStatus': 'Read and validate the installed status record.',
 '/disk/auxiliary-startup.lua#receivePacket': 'Receive and validate the next protocol envelope.',
 '/disk/auxiliary-startup.lua#recoverPending': 'Resume or roll back the recorded interrupted installation '
                                               'transaction.',
 '/disk/auxiliary-startup.lua#register': 'Store the computer ID assigned to a selected role on the disk.',
 '/disk/auxiliary-startup.lua#registrationAvailability': 'Resolve whether the current role selection is '
                                                         'already assigned.',
 '/disk/auxiliary-startup.lua#reloadApp': 'Restart the installed application after a successful replacement.',
 '/disk/auxiliary-startup.lua#replaceFiles': 'Replace staged program files under the current transaction '
                                             'journal.',
 '/disk/auxiliary-startup.lua#restoreLabel': 'Restore the previous computer label from transaction metadata.',
 '/disk/auxiliary-startup.lua#rollbackJournal': 'Restore files and labels recorded by the replacement '
                                                'transaction.',
 '/disk/auxiliary-startup.lua#rowsFor': 'Build the role menu and assignment rows for the selected installer '
                                        'page.',
 '/disk/auxiliary-startup.lua#sendPacket': 'Send an installation protocol packet to its selected recipient.',
 '/disk/auxiliary-startup.lua#sendRegistryRequest': 'Ask the assigned core for the current fleet registry.',
 '/disk/auxiliary-startup.lua#showPlanRows': 'Present the affected roles and computer IDs in a correction '
                                             'review.',
 '/disk/auxiliary-startup.lua#validCurrent': 'Verify that the installed application matches its expected '
                                             'package.',
 '/disk/auxiliary-startup.lua#validateChunk': 'Check chunk identity, index and size against the accepted '
                                              'offer.',
 '/disk/auxiliary-startup.lua#validateOffer': 'Validate offered package identity, paths, sizes and '
                                              'checksums.',
 '/disk/auxiliary-startup.lua#write': 'Commit verified content through a temporary sibling and preserve its '
                                      'prior copy.',
 '/disk/auxiliary-startup.lua#writeJournal': 'Persist the replacement transaction and its rollback metadata.',
 '/disk/auxiliary-startup.lua#writeStatus': 'Persist bounded installation phase and progress metadata.',
 '/disk/auxiliary-startup.lua#writeVerifiedStage': 'Write a staged payload and verify its stored checksum.',
 '/disk/installer.lua#Installer.setApplicationState': 'Update the receiver with the application lifecycle '
                                                      'and current errors.',
 '/disk/installer.lua#Setup.adoptLibrary': 'Verify the mounted library and publish its trusted metadata on '
                                           'core.',
 '/disk/installer.lua#Setup.cancelRepair': 'Cancel the pending assignment correction and preserve its '
                                           'recorded outcome.',
 '/disk/installer.lua#Setup.importFleet': 'Import a compatible installed fleet into the disk assignment '
                                          'record.',
 '/disk/installer.lua#Setup.installAuxiliary': 'Register an auxiliary role and install its bootstrap '
                                               'receiver.',
 '/disk/installer.lua#Setup.installCore': 'Register core and install its verified payload and configuration.',
 '/disk/installer.lua#Setup.main': 'Run keyboard page navigation, role selection and installation review.',
 '/disk/installer.lua#Setup.overview': 'Collect assignment and installation progress for every expected '
                                       'computer.',
 '/disk/installer.lua#Setup.planRepair': 'Build a reviewed role-reassignment plan from current fleet '
                                         'records.',
 '/disk/installer.lua#Setup.resumeRepair': 'Resume the verified assignment operation and record its '
                                           'completion.',
 '/disk/installer.lua#Setup.startCore': 'Launch installed core services after setup completes.',
 '/disk/installer.lua#acceptRegistry': 'Validate the core registry and bind the bootstrap to its assigned '
                                       'role.',
 '/disk/installer.lua#activeBinding': 'Read the current installed role binding used for request authority.',
 '/disk/installer.lua#actualComputerId': 'Read and validate the actual ComputerCraft ID.',
 '/disk/installer.lua#assignedRole': 'Resolve the current computer role from its validated registration.',
 '/disk/installer.lua#basicJSON': 'Encode the small installer status record with supported JSON values.',
 '/disk/installer.lua#checkedPlan': 'Validate a stored assignment plan against the current disk and computer '
                                    'state.',
 '/disk/installer.lua#cleanupJournalFiles': 'Remove transaction staging and backup files after completion.',
 '/disk/installer.lua#clockNow': 'Obtain the runtime clock used for installer request timing.',
 '/disk/installer.lua#commit': 'Verify staged files, replace programs and publish the installation receipt.',
 '/disk/installer.lua#completed': 'Check the installed receipt and application binding for setup completion.',
 '/disk/installer.lua#coreEntries': 'Select core payloads and merge retained configuration and learned '
                                    'defaults.',
 '/disk/installer.lua#correctAssignment': 'Review and submit an assignment change for the current computer.',
 '/disk/installer.lua#deleteJournal': 'Remove the completed replacement journal and its bookkeeping.',
 '/disk/installer.lua#deployment': 'Load the disk deployment record and validate its fleet assignments.',
 '/disk/installer.lua#dialog': 'Render a bounded keyboard confirmation and return the selected response.',
 '/disk/installer.lua#ensureNetwork': 'Open the configured modem network and report attachment errors.',
 '/disk/installer.lua#finishIfComplete': 'Remove temporary commissioning state once installation is '
                                         'confirmed.',
 '/disk/installer.lua#helloPacket': 'Build a hello request with current role, package and session metadata.',
 '/disk/installer.lua#installFiles': 'Write the selected verified payload files and report installation '
                                     'progress.',
 '/disk/installer.lua#installedReceipt': 'Read or create the verified package receipt for installation '
                                         'acknowledgement.',
 '/disk/installer.lua#jsonDecode': 'Decode JSON through the selected runtime API with validation errors.',
 '/disk/installer.lua#localRepairCheck': 'Check the selected core and role metadata for the supported '
                                         'assignment operation.',
 '/disk/installer.lua#makePreparedFiles': 'Prepare package files and retained configuration before commit.',
 '/disk/installer.lua#makeSession': 'Construct the current computer installation session identifier.',
 '/disk/installer.lua#nextCounter': 'Advance the persistent correlation counter for an installation session.',
 '/disk/installer.lua#normalizeConfig': 'Validate installer role, protocol, retry and package settings.',
 '/disk/installer.lua#operation': 'Run a selected setup operation and display its progress and result.',
 '/disk/installer.lua#pendingCorrection': 'Display the stored correction plan and handle resume or '
                                          'cancellation.',
 '/disk/installer.lua#preflight': 'Validate destination paths, available capacity and installation metadata.',
 '/disk/installer.lua#preserveInstalledStatus': 'Retain verified installed progress when receiving a new '
                                                'service observation.',
 '/disk/installer.lua#processOffer': 'Receive verified package chunks and coordinate their staged '
                                     'installation.',
 '/disk/installer.lua#readFile': 'Read a bounded installer file and return its content or read error.',
 '/disk/installer.lua#readJournal': 'Read and validate a pending replacement journal.',
 '/disk/installer.lua#readStatus': 'Read and validate the installed status record.',
 '/disk/installer.lua#receivePacket': 'Receive and validate the next protocol envelope.',
 '/disk/installer.lua#recoverPending': 'Resume or roll back the recorded interrupted installation '
                                       'transaction.',
 '/disk/installer.lua#register': 'Store the computer ID assigned to a selected role on the disk.',
 '/disk/installer.lua#registrationAvailability': 'Resolve whether the current role selection is already '
                                                 'assigned.',
 '/disk/installer.lua#reloadApp': 'Restart the installed application after a successful replacement.',
 '/disk/installer.lua#replaceFiles': 'Replace staged program files under the current transaction journal.',
 '/disk/installer.lua#restoreLabel': 'Restore the previous computer label from transaction metadata.',
 '/disk/installer.lua#rollbackJournal': 'Restore files and labels recorded by the replacement transaction.',
 '/disk/installer.lua#rowsFor': 'Build the role menu and assignment rows for the selected installer page.',
 '/disk/installer.lua#sendPacket': 'Send an installation protocol packet to its selected recipient.',
 '/disk/installer.lua#sendRegistryRequest': 'Ask the assigned core for the current fleet registry.',
 '/disk/installer.lua#showPlanRows': 'Present the affected roles and computer IDs in a correction review.',
 '/disk/installer.lua#validCurrent': 'Verify that the installed application matches its expected package.',
 '/disk/installer.lua#validateChunk': 'Check chunk identity, index and size against the accepted offer.',
 '/disk/installer.lua#validateOffer': 'Validate offered package identity, paths, sizes and checksums.',
 '/disk/installer.lua#write': 'Commit verified content through a temporary sibling and preserve its prior '
                              'copy.',
 '/disk/installer.lua#writeJournal': 'Persist the replacement transaction and its rollback metadata.',
 '/disk/installer.lua#writeStatus': 'Persist bounded installation phase and progress metadata.',
 '/disk/installer.lua#writeVerifiedStage': 'Write a staged payload and verify its stored checksum.',
 '/disk/setup.lua#Installer.setApplicationState': 'Update the receiver with the application lifecycle and '
                                                  'current errors.',
 '/disk/setup.lua#Setup.adoptLibrary': 'Verify the mounted library and publish its trusted metadata on core.',
 '/disk/setup.lua#Setup.cancelRepair': 'Cancel the pending assignment correction and preserve its recorded '
                                       'outcome.',
 '/disk/setup.lua#Setup.importFleet': 'Import a compatible installed fleet into the disk assignment record.',
 '/disk/setup.lua#Setup.installAuxiliary': 'Register an auxiliary role and install its bootstrap receiver.',
 '/disk/setup.lua#Setup.installCore': 'Register core and install its verified payload and configuration.',
 '/disk/setup.lua#Setup.main': 'Run keyboard page navigation, role selection and installation review.',
 '/disk/setup.lua#Setup.overview': 'Collect assignment and installation progress for every expected '
                                   'computer.',
 '/disk/setup.lua#Setup.planRepair': 'Build a reviewed role-reassignment plan from current fleet records.',
 '/disk/setup.lua#Setup.resumeRepair': 'Resume the verified assignment operation and record its completion.',
 '/disk/setup.lua#Setup.startCore': 'Launch installed core services after setup completes.',
 '/disk/setup.lua#acceptRegistry': 'Validate the core registry and bind the bootstrap to its assigned role.',
 '/disk/setup.lua#activeBinding': 'Read the current installed role binding used for request authority.',
 '/disk/setup.lua#actualComputerId': 'Read and validate the actual ComputerCraft ID.',
 '/disk/setup.lua#assignedRole': 'Resolve the current computer role from its validated registration.',
 '/disk/setup.lua#basicJSON': 'Encode the small installer status record with supported JSON values.',
 '/disk/setup.lua#checkedPlan': 'Validate a stored assignment plan against the current disk and computer '
                                'state.',
 '/disk/setup.lua#cleanupJournalFiles': 'Remove transaction staging and backup files after completion.',
 '/disk/setup.lua#clockNow': 'Obtain the runtime clock used for installer request timing.',
 '/disk/setup.lua#commit': 'Verify staged files, replace programs and publish the installation receipt.',
 '/disk/setup.lua#completed': 'Check the installed receipt and application binding for setup completion.',
 '/disk/setup.lua#coreEntries': 'Select core payloads and merge retained configuration and learned defaults.',
 '/disk/setup.lua#correctAssignment': 'Review and submit an assignment change for the current computer.',
 '/disk/setup.lua#deleteJournal': 'Remove the completed replacement journal and its bookkeeping.',
 '/disk/setup.lua#deployment': 'Load the disk deployment record and validate its fleet assignments.',
 '/disk/setup.lua#dialog': 'Render a bounded keyboard confirmation and return the selected response.',
 '/disk/setup.lua#ensureNetwork': 'Open the configured modem network and report attachment errors.',
 '/disk/setup.lua#finishIfComplete': 'Remove temporary commissioning state once installation is confirmed.',
 '/disk/setup.lua#helloPacket': 'Build a hello request with current role, package and session metadata.',
 '/disk/setup.lua#installFiles': 'Write the selected verified payload files and report installation '
                                 'progress.',
 '/disk/setup.lua#installedReceipt': 'Read or create the verified package receipt for installation '
                                     'acknowledgement.',
 '/disk/setup.lua#jsonDecode': 'Decode JSON through the selected runtime API with validation errors.',
 '/disk/setup.lua#localRepairCheck': 'Check the selected core and role metadata for the supported assignment '
                                     'operation.',
 '/disk/setup.lua#makePreparedFiles': 'Prepare package files and retained configuration before commit.',
 '/disk/setup.lua#makeSession': 'Construct the current computer installation session identifier.',
 '/disk/setup.lua#nextCounter': 'Advance the persistent correlation counter for an installation session.',
 '/disk/setup.lua#normalizeConfig': 'Validate installer role, protocol, retry and package settings.',
 '/disk/setup.lua#operation': 'Run a selected setup operation and display its progress and result.',
 '/disk/setup.lua#pendingCorrection': 'Display the stored correction plan and handle resume or cancellation.',
 '/disk/setup.lua#preflight': 'Validate destination paths, available capacity and installation metadata.',
 '/disk/setup.lua#preserveInstalledStatus': 'Retain verified installed progress when receiving a new service '
                                            'observation.',
 '/disk/setup.lua#processOffer': 'Receive verified package chunks and coordinate their staged installation.',
 '/disk/setup.lua#readFile': 'Read a bounded installer file and return its content or read error.',
 '/disk/setup.lua#readJournal': 'Read and validate a pending replacement journal.',
 '/disk/setup.lua#readStatus': 'Read and validate the installed status record.',
 '/disk/setup.lua#receivePacket': 'Receive and validate the next protocol envelope.',
 '/disk/setup.lua#recoverPending': 'Resume or roll back the recorded interrupted installation transaction.',
 '/disk/setup.lua#register': 'Store the computer ID assigned to a selected role on the disk.',
 '/disk/setup.lua#registrationAvailability': 'Resolve whether the current role selection is already '
                                             'assigned.',
 '/disk/setup.lua#reloadApp': 'Restart the installed application after a successful replacement.',
 '/disk/setup.lua#replaceFiles': 'Replace staged program files under the current transaction journal.',
 '/disk/setup.lua#restoreLabel': 'Restore the previous computer label from transaction metadata.',
 '/disk/setup.lua#rollbackJournal': 'Restore files and labels recorded by the replacement transaction.',
 '/disk/setup.lua#rowsFor': 'Build the role menu and assignment rows for the selected installer page.',
 '/disk/setup.lua#sendPacket': 'Send an installation protocol packet to its selected recipient.',
 '/disk/setup.lua#sendRegistryRequest': 'Ask the assigned core for the current fleet registry.',
 '/disk/setup.lua#showPlanRows': 'Present the affected roles and computer IDs in a correction review.',
 '/disk/setup.lua#validCurrent': 'Verify that the installed application matches its expected package.',
 '/disk/setup.lua#validateChunk': 'Check chunk identity, index and size against the accepted offer.',
 '/disk/setup.lua#validateOffer': 'Validate offered package identity, paths, sizes and checksums.',
 '/disk/setup.lua#write': 'Commit verified content through a temporary sibling and preserve its prior copy.',
 '/disk/setup.lua#writeJournal': 'Persist the replacement transaction and its rollback metadata.',
 '/disk/setup.lua#writeStatus': 'Persist bounded installation phase and progress metadata.',
 '/disk/setup.lua#writeVerifiedStage': 'Write a staged payload and verify its stored checksum.'})

PURPOSES.update({"/disk/setup.lua":"Disk setup | Keyboard role assignment, reviewed installation and progress.", "/disk/installer.lua":"Installer receiver | Verified transfer, replacement journal and role acknowledgement.", "/disk/auxiliary-startup.lua":"Commissioning | Temporary assignment display and completion cleanup."})

# Keep migrated assembly documentation consistent across older source exports.
REVISIONS.append(('-- A read that gives no answer (call failed, non-boolean, assembler briefly\n-- missing from the wired network) does NOT replace the last definite answer;\n-- a true answer loses verification after the assembly freshness window,\n-- but uncertainty keeps the gate open. A false answer stays blocking until\n-- a later true read. Failed reads do not change applied lift settings.', '-- Successful boolean responses carry their getter completion time.\n-- Read errors retain the last definite response and its original timestamp.\n-- assemblyGate checks fresh Sable association before fresh assembler evidence.\n-- Unresolved verification keeps the gate open and warns after five minutes.\n-- Applied lift settings remain retained through verification uncertainty.'))

# Commissioning reset preserves installed programs and retained operating records.
SUMMARIES.update({
    "Storage.readValidatedJson": "Load a validated primary JSON document, then its retained backup.",
    "validFeedforward": "Validate persisted pressure-normalised cruise gains and speed bands.",
    "/avionics/remote_install.lua#atomic": "Replace a verified file through a temporary sibling and retain its backup.",
})

SUMMARIES.update({
    "/disk/setup.lua#Setup.unassignCore": "Clear disk and core fleet assignments and retain the roster for recommissioning.",
    "/disk/setup.lua#Setup.installCore": "Install a fresh core or register its retained installation after an assignment reset.",
    "/disk/setup.lua#preflight": "Validate payloads and authorize a fresh, interrupted or explicitly reset registration.",
})

# Delivery 5 settings registry.
PURPOSES.update({"/avionics/config_registry.lua": "Settings registry | Units, bounds and fallbacks for altitude_control and thrust settings."})
SUMMARIES.update({
    "/avionics/config_registry.lua#Registry.check": "Check a candidate value against the setting's kind and bounds.",
    "/avionics/config_registry.lua#Registry.number": "Read a runtime-bounded setting with its registered clamp and fallback.",
})

SUMMARIES.update({
    "/avionics/thrust.lua#Thrust:rejected": "Record why a propulsion hello or status was refused, for the role page and the core log.",
})

SUMMARIES.update({
    "/packages/chamber/*/thrust.lua#bootToken": "Create this boot's node token from the current clock and a per-computer random value.",
    "/packages/thrust/*/thrust.lua#bootToken": "Create this boot's node token from the current clock and a per-computer random value.",
    "/packages/primary/*/main.lua#bootToken": "Create this boot's node token from the current clock and a per-computer random value.",
})

# Selected-speed stages retain the existing equations and sampling rules.
SUMMARIES.update({
    '/avionics/thrust.lua#zeroSelectedSpeedDrive': 'Apply SEL 0 coast hysteresis and speed-proportional braking through the output slew.',
    '/avionics/thrust.lua#advanceSpeedGoal': 'Advance retained speed-output slew between distinct measurements and publish its status.',
    '/avionics/thrust.lua#updateSpeedFeedback': 'Transfer speed feedback history, calculate bounded drive and update steady-cruise learning.',
})

# Vessel sampling stages preserve getter order and clock reads.
SUMMARIES.update({
    '/avionics/io.lua#readVesselWindow': 'Collect Sable and peripheral readings within their existing read window and deadlines.',
    '/avionics/io.lua#resolveVesselAttitude': 'Resolve configured and observed bow axes, heading, pitch and roll from the sampled transforms.',
    '/avionics/io.lua#resolveVesselVelocity': 'Resolve body axes and verified world velocity into horizontal forward and vertical speed.',
    '/avionics/io.lua#readVesselEnvironment': 'Read or reuse gravity, drag and world-CoM pressure with the existing cache limits.',
})

# Per-batch support demand is transient; provider allocation preserves the original equations.
SUMMARIES.update({
    '/avionics/flight.lua#systemsSupportDemand': 'Calculate projected support error, correction direction and control horizons.',
    '/avionics/flight.lua#systemsBrakingBudgets': 'Calculate altitude, vertical-speed and lift headroom plus release urgency.',
    '/avionics/flight.lua#systemsMotionProgress': 'Track demonstrated acquisition motion and its permitted acceleration progress.',
    '/avionics/flight.lua#systemsProviderTargets': 'Allocate per-provider ceiling changes, trim and fractional correction remainders within current limits.',
})

# Acquisition PID and support stages preserve established calculation order.
SUMMARIES.update({
    '/avionics/flight.lua#acquisitionVerticalDemand': 'Shape altitude-loop demand using measured lag, approach braking and startup motion limits.',
    '/avionics/flight.lua#acquisitionSpeedEffort': 'Calculate vertical-speed feedback and gate startup integration on supply observations.',
    '/avionics/flight.lua#acquisitionSupportDemand': 'Combine hover feedforward and speed effort within the existing support and acceleration bounds.',
    '/avionics/flight.lua#acquisitionStallCorrection': 'Apply measured acquisition shortfall and retained hover-drift corrections, then finalize anti-windup.',
})

SUMMARIES.update({
    '/avionics/flight.lua#systemsRecoveryOperations': 'Bind retained-map verification, batch renewal and completion to the current recovery run.',
})

# Systems dispatch retains entry guards and delegates the existing phase bodies.
SUMMARIES.update({
    '/avionics/flight.lua#systemsAcknowledgeBatch': 'Verify pending command results and transfer acknowledged startup or control maps.',
    '/avionics/flight.lua#systemsVerifyStartup': 'Wait for boiler readiness, verify the startup envelope and send the initial control map.',
    '/avionics/flight.lua#Flight:systemsBoilersReady': "Check every steam vent's boiler reading against full startup efficiency.",
    '/avionics/flight.lua#systemsLaunchSettling': 'Maintain leveling and retained targets through the configured startup settling interval.',
    '/avionics/flight.lua#systemsActiveControl': 'Advance altitude guidance on fresh control intervals, cap provider targets and issue the next batch.',
})


# Worker accessors retain the existing shared os keys across program environments.
SHORT_SUMMARIES.update({
    '/avionics/runtime_state.lua#RuntimeState.get': 'Read the current shared value under its existing os-table key.',
    '/avionics/runtime_state.lua#RuntimeState.set': 'Publish or clear a shared value under its existing os-table key.',
})
SUMMARIES.update({
    '/packages/navigation/ui.lua#systemsMenuItems': 'Build Systems menu actions and availability from the current core snapshot.',
})

# Web installer-disk downloader (download.lua on the media folder and the disk).
PURPOSES.update({"/disk/download.lua": "Disk download | Fill an attached installer disk from a release published on the web."})
SUMMARIES.update({
    "/disk/download.lua#writeFile": "Write through a temporary sibling, verify it and replace the target.",
    "/disk/download.lua#validIndex": "Accept a release index with safe relative paths, sizes, checksums and startup.lua last.",
})

# Web install (web-setup.lua, run by the Pastebin loader from the GitHub release).
PURPOSES.update({"/disk/web-setup.lua": "Web setup | Core install and registration over rednet from a pinned web release."})
SUMMARIES.update({
    "/disk/web-setup.lua#adler": "Compute the Adler-32 checksum, yielding on large files.",
    "/disk/web-setup.lua#installCore": "Download the release into core, install core and open its registration screen.",
    "/disk/web-setup.lua#pickRole": "Let the operator choose this computer's role from core's current assignments.",
    "/disk/web-setup.lua#registerComputer": "Find core, take its release, register the chosen role and install its payload.",
    "/disk/web-setup.lua#main": "Continue core registration, or offer core install and computer registration.",
})
SUMMARIES.update({
    "/disk/setup.lua#payload": "Read one release object, from the disk or through Setup.readObject, and verify it.",
    "/disk/setup.lua#writeRoleConfig": "Write the state reader config, or the receiver config bound to core.",
    "/disk/setup.lua#Setup.registerRole": "Record a role for a computer in core's deployment record (web registration).",
    "/disk/setup.lua#Setup.clearRole": "Clear one role from core's deployment record before import (web registration).",
    "/disk/setup.lua#Setup.installRegistered": "Install the payload for a role that core has accepted (web registration).",
    "/installer/media.lua#Media:openWeb": "Fetch one package object from the web release and check it against the trusted catalog.",
})

# Fix gas mix lag: restart each chamber's trim probe link.
SUMMARIES.update({
    "/packages/chamber/*/hardware.lua#Hardware.cycleProbeLink": "Turn the trim probe link off and back on, then verify its readback.",
})
