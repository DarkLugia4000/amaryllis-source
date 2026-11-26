# A.E.V. Amaryllis

## Owner's installation and first-flight guide

This guide covers preparing the ship, installing its 16 computers through
Pastebin, checking the hardware, making a first flight and maintaining the
installation. It applies to the Amaryllis vessel and its matching mod environment.
Computer IDs and peripheral bindings belong to each installation.

[Preparation](#1-prepare-the-instance) · [Computer map](#3-identify-the-computers) ·
[Web installation](#4-install-through-pastebin) · [Recovery](#5-correct-registration-mistakes) ·
[First flight](#8-start-lift-and-make-a-first-flight) · [Updates](#11-update-the-software) ·
[Troubleshooting](#12-troubleshooting-and-recordings)

## 1. Prepare the instance

You need the Amaryllis schematic, the matching mod environment, and permission to
edit the active ComputerCraft server configuration. The project targets Minecraft
1.21.1 / NeoForge with CC: Tweaked, Create Aeronautics, Sable, CC: Sable,
CC: Avionics and the vessel's other hardware integrations. Use the mod versions
supplied with the schematic or its matching modpack.

Web installation requires access to Pastebin and GitHub from the computers.
No installer floppy is required. A separate writable data disk and disk drive
are useful later for debug recordings.

### ComputerCraft configuration

With Minecraft and the server completely closed, locate and back up the active
`computercraft-server.toml`. Depending on the installation, it may be in the
instance's `config/` folder or the save/server's `serverconfig/` folder. Establish
which file the server actually uses if several copies exist. On multiplayer,
the server administrator applies these settings.

Edit existing keys and sections in place:

```toml
computer_space_limit = 4000000
floppy_space_limit = 4000000

[execution]
computer_threads = 2

[http]
enabled = true
```

- **Storage:** the values are bytes. Make sure each limit is at least 4,000,000
  bytes, preserving higher existing values. If a generated installer's README
  specifies a larger media requirement, use that value. Debug recordings need
  additional free disk space.
- **Execution:** **2 computer threads** is the documented setup baseline. Keep
  a deliberately configured higher worker count if appropriate for the server;
  increasing it further can be done at user discretion.
- **HTTP:** HTTP access is required for the Pastebin installer to work. Preserve
  the other HTTP rules and unrelated settings. `[http] enabled = true` is the
  TOML form of `http.enabled`; do not duplicate existing tables.

Alternatively, use **ComputerCraft settings…** in the Windows builder, or
`windows-settings/Configure ComputerCraft.cmd` in a generated installation
package. Load the active configuration, select the capacities and worker count,
preview the changes and apply them. The helper backs up the file; it initially
shows the existing worker count, so select 2 when applying the baseline.

Restart Minecraft/server after editing. See the
[configuration helper guide](../../disk-builder/README.md#computercraft-settings)
for its backup and restore procedure.

## 2. Place and inspect the vessel

Back up the destination before placing the schematic. Choose a site with room
for the whole hull, an unobstructed departure path and suitable physical support
for commissioning. Keep the physics assembler inactive during computer setup.

For a Create `.nbt` schematic:

1. Put the file in the instance's `schematics/` folder.
2. Use a Schematic Table and Empty Schematic to select and upload it.
3. Position the preview with enough clearance for the hull and moving machinery. 
   DO NOT ROTATE THE SCHEMATIC.
4. After placing, inspect for missing blocks, disconnected machinery and unintended attachments
   to surrounding structures.

## 3. Identify the computers

Every computer aboard Amaryllis is marked with a sign showing the label to
select in the installer.

Facing the bow, left is port and right is starboard. FL/FR are the bow chambers;
BL/BR are the stern chambers.

| Name shown in setup | Internal role | Responsibility |
|---|---|---|
| core | `core` | Central flight controller and package distributor |
| state | `state` | Vessel and cockpit reader |
| bridge | `navigator` | Interactive bridge interface |
| hdg-l | `heading-left` | Left flight instrument display |
| hdg-m | `heading-main` | Main flight instrument display |
| hdg-r | `heading-right` | Right flight instrument display |
| chamber-fl | `chamber_fl` | Front-left lift chamber |
| chamber-fr | `chamber_fr` | Front-right lift chamber |
| chamber-bl | `chamber_bl` | Rear-left lift chamber |
| chamber-br | `chamber_br` | Rear-right lift chamber |
| thrust-lb | `thrust-lb` | Front-left thrust controller |
| thrust-rb | `thrust-rb` | Front-right thrust controller |
| thrust-ls | `thrust-ls` | Rear-left thrust and left primary actuation |
| thrust-rs | `thrust-rs` | Rear-right thrust and right primary actuation |
| primary-l | `primary_l` | Left primary-propeller bearing readback |
| primary-r | `primary_r` | Right primary-propeller bearing readback |


## 4. Install through Pastebin

Run the following at each computer's shell:

```text
pastebin run bn1RbWtb
```

The loader is published at [pastebin.com/bn1RbWtb](https://pastebin.com/bn1RbWtb).
It downloads the web setup file from a published release. Computers registering with a
core use that core's release, even if a newer release is available elsewhere.

### Install core first

1. On the computer marked core, run the command.
2. Choose **1 Install core on this computer**.
3. Check and confirm the displayed computer ID.
4. Wait for the download and installation to finish. Core opens its registration
   screen; leave that screen running.

Until assignments are imported, rebooting core returns to registration. Do not
start flight systems during commissioning.

### Register the other 15 computers

1. Run the command on the next computer and choose **2 Register this computer
   with core**.
2. If several cores answer, select the intended one.
3. Use the up/down keys to select the role on the computer's sign. The list also
   shows each role's current holder. Press **Enter** and confirm the role.
4. Wait for the payload installation and automatic reboot.
5. Repeat for all remaining roles.

State installs its reader programs immediately. The other 14 computers receive
commissioning receivers and wait for core to distribute their full packages.
Connect state to core with its wired modems before checking operational readiness.

### Review, import and start core

1. Return to core. Confirm the registration screen reaches **16/16**.
2. Compare every role and ID with your computer map. Correct mistakes before
   importing; see section 5.
3. Press **Enter** and confirm **Import assignments and start core?**
4. Core will restart, boot into the standard UI and begin to distribute the **14 wireless auxiliary packages** from
   its pinned release. Keep those computers powered and reachable.
5. Wait for core's status to switch to "READY". A transfer reaching 100% still needs package
   verification; wait for successful completion and normal role startup.

While the vessel is unassembled, a flight-readiness message such as
`VESSEL NOT ASSEMBLED` can be expected. It is separate from package installation.
Continue when every computer runs its intended role and state telemetry reaches
core. Web installation does not require leaving an installer floppy inserted.

## 5. Correct registration mistakes

For a commissioning screen, hold **Ctrl+T** to return to the shell, then rerun
`pastebin run bn1RbWtb`. Avoid terminating an operating flight controller merely
to inspect setup; perform maintenance with the vessel supported and systems stopped.

| Situation | Recovery |
|---|---|
| Wrong ordinary auxiliary role before import | Rerun web setup on that computer and select the correct role. Core moves the assignment when the change is permitted. |
| Intended role belongs to another ID | Select that role on core's registration screen, press **Backspace**, confirm clearing it, then register the intended computer. |
| Remove this computer's registration | Choose **3 Remove this computer's registration** on that computer. It removes the commissioning receiver or state-reader programs and asks core to clear the role. An installed auxiliary package is retained. |
| Assignments already imported and need a reset | Press **R** on core's setup screen and confirm. Core restarts into registration with assignments cleared. Programs and settings remain; register the fleet again. |
| Uninstall core before import | Press **U** on core's setup screen and confirm deletion of core's files. Imported installations require a reset before this action. |
| Core/state role change is refused | Read the refusal and use the installer removal/reset path; these roles cannot be moved through the ordinary auxiliary role-change operation. |

After corrections, review all 16 assignments again. Never resolve a role conflict
by assigning the same ComputerCraft ID to multiple physical computers.

## 6. Check machinery and hardware bindings

Before assembly or starting lift:

- Check diesel fuel, lava/heat supply, boiler water and required mechanical power.
  Trace feeds to both sides; a healthy combined fuel total does not prove that
  each engine or chamber has supply.
- Inspect each chamber's balloon and gas hardware. The reference arrangement uses
  **32 steam vents and one trim burner per chamber**; compare discovery with the
  hardware configuration shipped with the vessel.
- Verify each thrust controller discovers its transmissions and corner altitude
  sensor, and each primary reader discovers the intended bearing.
- Check that the four corner altitude readings reach core through their relays.
- Confirm the cockpit bridge and its nine frequency pairs are readable on state.
- Check bridge and heading monitors show advancing information.

Resolve missing hardware, ambiguous discovery, supply faults and conflicting
frequencies before commissioning. Software bindings do not verify that a fuel
valve is open or a propeller's physical direction is correct.

## 7. Assemble and verify controls

Assemble the vessel using its physics assembler after checking the selected
structure. Wait for the VESSEL DISASSEMBLED status to disappear on all monitors, and confirm 
the telemetry is active and filled.
. Confirm heading agrees with the bow's
actual direction and altitude/vertical speed are plausible. On first assembly, this should be 90.0 (east). If this is not the case, you likely rotated the schematic, return to "placing the schematic". 

Check cockpit inputs individually, beginning from neutral. The nine signals are
heading left/right, strafe left/right, forward/reverse propulsion, altitude
up/down and AP disconnect. State's cockpit reader shows raw values from 0 to 15,
measurement ages, the configured frequency pair and read errors.

The schematic's control bindings determine the actual keys. Verify them against
the raw inputs before using operating thrust. Settings can change selector steps
and hold rates, so use the configured values rather than assuming a fixed step.

| Control mode | Input behavior |
|---|---|
| Heading MANUAL | Steering requests a turn directly. |
| Heading SEL | Steering changes the retained heading target. Holding both heading inputs for the configured centering time selects the measured heading. |
| Throttle MAN | Forward/reverse inputs request acceleration or deceleration. |
| Throttle SEL | Inputs change the retained signed speed target. Set it to zero to request braking. |
| Throttle DIRECT | Inputs request drive output within configured limits. |
| Strafe MANUAL | Strafe input requests sideways thrust while held. |
| Strafe SEL | Input changes a sideways offset; both inputs brake and return to manual strafe. |
| Altitude | Up/down changes the retained altitude target, with configured tap and hold behavior. |

Levers act at their current positions after ordinary handovers. A held throttle
can produce **THRUST NOT NEUTRAL**. Anchor release requires every lever to return
to neutral before cockpit input acts again. See the
[pilot reference](PILOT-REFERENCE.md) for readouts and advisories.

## 8. Start lift and prepare first flight

1. Confirm the departure path, fuel/water supply, mechanical power, hardware
   readiness and fresh telemetry. Keep inputs neutral.
2. Select an initial altitude within the configured limits and sufficient for
   the entire hull. Displayed altitude is the vessel's reference Y coordinate,
   not the clearance beneath its lowest block.
3. Open **SETTINGS** and choose **START SYSTEMS**, also available under
   **LIFT MAINTENANCE**. Read any blocking reason.
4. Observe startup verification, inflation and altitude acquisition. All four
   chambers must respond. `READY` identifies the control phase; compare actual
   altitude, target and vertical speed to assess settling.
5. Check propulsion availability under **SETTINGS → PROPULSION**. Enabling it
   requires Start Systems readiness. If disabled, read the displayed reason
   before proceeding; settled startup can enable it automatically.
6. On **FLIGHT**, select throttle **SEL**, request approximately **1 b/s** and
   release the input. Confirm forward motion in a clear direction.
7. Return selected speed to **0** and observe the complete stop. Main propellers
   take time to reverse and wind down; a zero command is not an immediate stop.
8. Select heading **SEL** and make a small heading change. Confirm the correct
   turn direction and allow it to settle.
9. Test a small lateral movement and stop. Then test a small altitude change,
   observing actual altitude and vertical speed until the response settles.

First-flight checks pass when lift, forward/reverse response, heading and lateral
control act in the intended directions and the vessel settles without an
unresolved essential-system fault. Increase speed only after these checks.

## 9. Use autopilot and the anchor

After onboard manual checks pass:

1. Open **NAV → AUTOPILOT** and enter destination X/Z, cruise speed and altitude.
   A destination name is optional.
2. Review coordinate signs, altitude, speed and clearance for the full hull.
3. Choose a short, unobstructed low-speed route for the first AP test. Release
   an active digital anchor and return controls to neutral.
4. Select **ENGAGE** and resolve any displayed blocking reason.
5. Observe **ACQ → CAPTURE → ACCEL / CRUISE / DECEL**. ACQ aligns heading;
   CAPTURE settles onto the route before powered travel. The speed phases follow
   the selected cruise speed and approach envelope, so a short route can go
   directly into DECEL even while speed is initially increasing.
6. At arrival AP disengages and engages the position anchor at the destination.
   Check actual motion and position as the anchor finishes stopping the vessel.

Use the onboard disengage control or the configured AP-disconnect input to cancel
AP. The digital anchor uses active propulsion for horizontal positioning;
altitude control still supplies lift. Release the anchor and neutralize inputs
before resuming cockpit commands.

AP does not plan terrain clearance or automatic landing. Impact/obstruction
warnings react to measured behavior. Monitor route deviation and actual motion;
route-tracking and braking tuning remain under refinement. Remote AP requires a
separately paired and authorized computer. Unattended travel also requires
verified chunk loading for the vessel's computers and physics along the route.

## 10. Dock and stop systems

Reduce selected speed to zero and verify actual speed. Use the anchor where
appropriate, then lower the altitude in small steps while observing hull
clearance. Establish physical support before deliberately removing lift.

Choose **STOP SYSTEMS**, review the screen and confirm only when shutdown is
intended. **STOP SYSTEMS removes main steam lift and can cause a rapid descent.**
It retains trim probes for telemetry. Complete the vessel's fuel, boiler and
mechanical shutdown only after support and the software stop are established.

| Interruption | Meaning |
|---|---|
| Telemetry/command loss | Recovery attempts to preserve established lift where supported and revalidate control. Read the cause and actual motion. |
| STOP SYSTEMS | Deliberate removal of main lift and running intent. |
| KILL LIFT | Emergency lift removal with a latched restart lock. Inspect the cause, then use **DISARM KILL** before a deliberate restart. |
| RESTART SYSTEMS | Reloads core and navigator; it does not reboot the entire chamber/propulsion fleet. |

## 11. Update the software

### Web-installed systems

1. Support the vessel and stop flight systems before opening update setup.
2. Run `pastebin run bn1RbWtb` on core.
3. If a newer release is available, core's setup screen offers **W**. Select it,
   review the release and confirm the update. Import assignments first if setup
   says they have not been imported.
4. Core stages the new release and restarts to complete installation. It requests
   a state-reader update over the wired link and serves updated wireless packages.
5. Check state and all auxiliaries for successful installation and role startup.
   If state did not update, run the loader on state and use **4 Update this state
   reader to the newest release**, after updating core.
6. Verify versions and fresh telemetry before recommissioning the affected controls.

Core retains package objects for its pinned release. Do not reset registrations
just to perform an ordinary supported update. Read displayed retry/failure
messages and allow interrupted update recovery to finish.

### Local source updates

Use the Windows builder's **Update existing ship…** action to select the target,
preview changes and apply them with an external backup. IDs, stored settings,
learning and runtime data are preserved by the managed updater.

Replacing program files does not reload a running program. Restart affected
computers, including both propulsion controllers when a change spans main-engine
control. **RESTART SYSTEMS** alone reloads core and navigator. Follow the
[builder/updater guide](../../disk-builder/README.md#update-an-existing-ship).

The [floppy installer](../../disk-builder/README.md#installer-floppy-disk-deprecated)
is largely deprecated. Existing disk installations use their matching disk or
managed update path; web setup does not automatically convert a disk-installed
core into a web installation.

## 12. Troubleshooting and recordings

| Symptom | First checks |
|---|---|
| HTTP disabled or loader cannot download | Confirm the active config enables HTTP, restart the server after editing, and check Pastebin/GitHub access and the configured HTTP rules. |
| No core found | Leave core on registration, check power and modem range, and select the intended core if several answer. |
| Role taken or wrong role | Use section 5; compare role signs, physical computers and distinct IDs. |
| Import blocked | All 16 roles must be assigned correctly. Complete corrections before confirming import. |
| Not enough space | Check computer/floppy limits, free space and the package's stated requirement. |
| Fresh-computer/preflight refusal | Inspect existing installation state. Use a fresh computer for a new installation or the supported update/reset path for an existing one. |
| Auxiliary waiting for core | Verify its ID/role, core's running installation service, package source and modem connection. A web install does not need an installer floppy. |
| State disconnected | Check its registration, power, wired modem/cable connection and sensor network. |
| Stale readings or missing controller | Inspect actual motion, then source ages, peripheral availability, controller power, links and server lag. A heartbeat alone does not prove fresh measurements. |
| THRUST NOT NEUTRAL | Throttle was held during handover. Release it if the resulting demand was unintended. |
| ANCHOR RELEASED: SET … TO NEUTRAL | Neutralize the named input; all levers must be neutral before cockpit control resumes. |
| START SYSTEMS NOT READY | Read startup's phase/blocking reason before attempting propulsion enable. |
| Probe or vent fault | Inspect balloon integrity, the trim probe and the affected vent's boiler/water/heat supply. |
| POSSIBLE DUPLICATE ID | Check copied computers or vessel copies sharing IDs, including loaded copies elsewhere. |
| Update/receipt mismatch | Allow the supported update recovery to finish; inspect the affected role's installation status and exact error before resetting. |

For a debug recording, insert a separate writable data disk in a drive accessible
to core. Open **SETTINGS → DEBUG MODE → START DEBUG RECORDING**, reproduce the
behavior, then stop recording. Preserve the CSV, event CSV and run metadata under
`/amaryllis-logs/` on that disk. Leave sufficient free space for the run.

When reporting a fault, include the software release, schematic revision,
affected roles/IDs, exact messages, screenshots, whether the vessel was assembled
and supported, and the relevant recording. Verify that updated programs actually
restarted before treating a run as validation of a new version.
