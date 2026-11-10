# Pressure integration evidence

Investigation updated 2026-10-31. Current in-game argument acceptance remains unresolved. The historical recordings establish that Sable pressure was selected in those flights.

## Recorded in-game evidence

| Recording | Samples | Active source | Numeric Sable values |
| --- | ---: | --- | ---: |
| 2026-10-24/hold-v145-0-1792843960200 | 627 | SABLE AERO in every sample | 627 |
| 2026-10-24/hold-sway-0-1792842062868 | 135 | SABLE AERO in every sample | 135 |
| 2026-10-22/35-1792693709364 | 881 | SABLE AERO in every sample | 881 |

The October 24 hold and October 22 runs have selected `air_pressure` equal to `air_pressure_sable` in every sample. The October 24 hold run spans altitude 222.930–262.524 with selected pressure 0.450194–0.527010. Its metadata build is `amaryllis-debug-disk-v145-lift-ack-priority`, schema 5. It is the latest recording found in the repository diagnostics directory. The recordings do not identify the current pressure-call shape or installed mod version by themselves.

Raw recordings remain in ignored `diagnostics/`. The checked-in plant profile records the hold CSV SHA-256, timestamps, pressure-source window and fit provenance.

## Installed binary observation

Artifact: `cc_sable-neoforge-1.3.4.jar` from the local CreateAeronautics instance.
SHA-256: `7504abc1666a03e25ee2b8f99c352571b84edc5f85db24fa492d7b70d77adfeb`.

Reproduce with `javap -classpath <artifact> -p io.github.techtastic.cc_sable.apis.AerodynamicsAPI`.

The class implements `ILuaAPI`, exposes names `aero` and `aerodynamics`, and declares `public final double getAirPressure(double, double, double)`. The inspected bytecode constructs a Vector3d from those coordinates and delegates to DimensionPhysicsData.

Maintained IO passes a ComputerCraft vector through safeCall at the current-world-CoM and requested-world-Y query sites. Java signature inspection alone does not establish the behavior of the active Lua binding. A mock rejecting vector arguments cannot prove that behavior either.

Required next observation: record current code/build/mod identity; inspect current Sable/source columns; perform read-only current-pressure and target-Y queries through the active binding. Match the contract test to that observation. Keep historical and current results separate.

## Pressure curve and sampling location

Sable 2.0.5 default pressure is cubic interpolation approximating capped exponential decay, followed by a 40-block taper to zero. Standard Overworld parameters give Y 280–320. Default examples: P(280)=0.419790291, P(300)=0.306447, P(306)=0.237081, P(310)=0.180509825, P(320)=0.

The cached upstream source pin is Sable commit 227077f7f528c9beab1336a9fad2e27b754e4e70. Installed bytecode was inspected alongside it. Active dimension overrides remain unverified. Balloon centres, vessel CoM and altitude-sensor centres can be at different heights.

## Behavioral consequence of a query change

A successful target-Y pressure query sets targetSupportKnown and computes maximum balanced raw lift multiplied by target pressure divided by mass. A ratio below one sets LIMITED and targetUnreachable. Those flags affect warning publication and acquisition/progress handling.

Before deploying a correction, compare unavailable/available target queries at Y 280, 290, 300, 306 and 310, with capacity below, at and above required support. Trace target acceptance, retained selection, acquisition, warning, command output and any refusal or termination. Require both model and physical-flight validation. No such correction or deployment has occurred here.

## Calibration pressure basis

Each calibration window records active pressure source, selected and alternate values, timestamps and sampling-location knowledge. Split at source transitions. Exclude unknown-source windows from the default calibrated profile. Fits based on sensor pressure must preserve that basis or be refitted before combining with Sable pressure. The 0.019 drag estimate's exact fitting window remains unestablished; source code links it to October 22 observations, whose available recording selects Sable.
