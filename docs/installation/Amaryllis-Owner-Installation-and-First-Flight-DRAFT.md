# A.E.V. AMARYLLIS
## Owner's installation and first-flight guide

**Draft for a distribution containing the schematic and a ready-made installer.**

### Publisher preparation notes

The computer-installation procedure below follows the current installer. Before publishing, complete these release-specific items:

1. Supply the exact tested Minecraft, loader, mod and dependency versions, plus any required configuration.
2. Add an annotated computer-location diagram showing all 16 computer names and suitable temporary disk-drive connections. Verify each thrust computer's location against its peripheral network.
3. Add the actual cockpit control/key-binding card and an illustrated powerplant/assembly checklist. The sources inspected do not establish the locations and operating sequence of every fuel valve, boiler control, mechanical drive and physics-assembler switch.
4. Record the schematic dimensions, installation orientation, supported docking arrangement and expected hardware inventory. The current reference software expects 32 steam vents and one trim burner per lift chamber.
5. Test the final schematic and installer together in a fresh destination world. Check that all 16 computers have distinct IDs and pass the installer's fresh-computer check. Supply a clean installer export.

Square-bracketed publisher inserts below must be completed before this becomes an owner-ready manual. These notes can then be removed from the customer edition.

---

## Welcome aboard, Captain

Amaryllis is a large vessel with a distributed computer system. Before her first departure, you will install the avionics, prepare the machinery and test her controls. Together, these steps are her commissioning procedure.

The schematic supplies the physical ship. The installer loads her avionics and records which computer performs each job.

This guide takes you through preparing Minecraft, building the ship, installing all computers, checking the machinery and making a short first flight. Begin in a backed-up test world with room to work.

## 1. Check your delivery

You need:

- The Amaryllis schematic for this release, normally a Create `.nbt` file.
- The matching `amaryllis-installer.zip`.
- This release's mod/version list, computer-location diagram, control card and powerplant/assembly checklist.
- Permission to edit the world's files and ComputerCraft configuration. On multiplayer, the server owner must perform the server-side file steps.
- One writable ComputerCraft floppy disk and one ComputerCraft disk drive. Supply these for installation; the auxiliary computers have no built-in disk drives. Move the drive and disk between computers as instructed below.

Extract the installer ZIP on your PC. Its contents include `README.md`, `media/` and `windows-settings/`.

The `media/` folder contains the files for the in-game floppy disk. The `windows-settings/` folder contains an optional Windows configuration helper that runs on your PC.

**Release card:** [PUBLISHER: insert schematic filename/revision, matching installer release ID, tested modpack/version and schematic dimensions.]

## 2. Prepare the Minecraft instance

Install the supported modpack and version specified on the release card, or install every listed mod and dependency at its specified version.

Open this modpack's instance folder through your launcher. Use that folder for the configuration and schematic steps below.

With Minecraft and the server completely closed, locate the active `computercraft-server.toml`. Depending on the installation, it may be in the instance's `config/` folder or the world's `serverconfig/` folder. When several copies exist, establish which file the running server uses before editing.

**Option A: use the supplied Windows helper.**

Open `windows-settings/Configure ComputerCraft.cmd`. This optional helper requires Python 3.11 or newer with Tcl/Tk. Select the configuration file, load its values, preview the changes and apply them. It saves a verified backup beside the file.

**Option B: edit the configuration manually.**

Back up the file, open it in a text editor and set these existing entries to at least:

```toml
computer_space_limit = 4000000
floppy_space_limit = 4000000
```

These values are byte counts. Preserve any existing value above 4,000,000. Check the supplied installer's README for its minimum media capacity and use the larger requirement. Edit each existing key in place.

In the existing `[execution]` section, set:

```toml
[execution]
computer_threads = 2
```

Preserve the other settings.

Reopen Minecraft after saving. On a server, restart the server after the administrator applies its configuration.

**Continue when:** the correct modpack loads and the destination's ComputerCraft storage limits have been increased.

## 3. Place the physical ship

Back up your destination world before construction. Choose a clear site large enough for the entire schematic and a clear departure path. During computer installation, keep the ship unassembled: leave her blocks in the world and the physics assembler inactive.

For a Create `.nbt` schematic:

1. Put the downloaded file in the instance's `schematics/` folder.
2. In-game, place a Schematic Table and insert an Empty Schematic.
3. Select the Amaryllis file and confirm the upload. Wait for it to finish.
4. Take the written schematic and position its preview at the installation site.
5. Orient the preview exactly as shown in the supplied orientation drawing.
6. Place the structure using the supported creative placement workflow, or build it with a Schematicannon. For a cannon, supply gunpowder and the materials requested by its material list.
7. Check the finished structure for missing blocks, incomplete machinery and unintended connections to surrounding construction.

Create's official [schematic-loading](https://github.com/Creators-of-Create/Create/wiki/Loading-a-Schematic) and [printing](https://github.com/Creators-of-Create/Create/wiki/Printing-a-Schematic) guides explain those tools. Use the controls presented by the supported Create version.

**Continue when:** the complete ship is accessible, unassembled, and positioned according to the release's support and clearance diagram.

## 4. Identify her computers

Stand facing the bow, the front of the vessel. Left means port; right means starboard. Front is bow; rear is stern.

Amaryllis has **16 computer roles**:

| Computer name in setup | Job |
|---|---|
| core | Central flight controller and package distributor |
| state | Vessel and cockpit reader, connected to core by wired modems |
| bridge | Bridge navigator and main operating display |
| hdg-l | Left instrument display |
| hdg-r | Right instrument display |
| hdg-m | Main instrument display |
| chamber-fl | Front-left lift chamber |
| chamber-fr | Front-right lift chamber |
| chamber-bl | Rear-left lift chamber |
| chamber-br | Rear-right lift chamber |
| thrust-lb | Rear-left thrust |
| thrust-rb | Rear-right thrust |
| thrust-ls | Left-side thrust |
| thrust-rs | Right-side thrust |
| primary-l | Left primary-propeller bearing sensor/interface |
| primary-r | Right primary-propeller bearing sensor/interface |

Locate each computer using the computer-location diagram. Match its position to the **Computer name in setup** column above.

Open each computer and run `id` at its shell. Record the returned ID beside its role on your diagram.

Check that the diagram contains **16 distinct computer IDs**. Each computer must also pass the installer's fresh-computer check. Replace computers with duplicate IDs or inherited operating files, preserving their documented orientations and connections. Run `id` again on each replacement and update the diagram.

**Computer map:** [PUBLISHER: insert the annotated 16-role diagram and drive-attachment locations.]

## 5. Turn a floppy into the installer disk

Use an empty writable floppy. For this preparation, connect just one disk drive to a fresh computer and insert the floppy.

At the computer shell, enter:

```text
lua
```

At the Lua prompt, run these lines individually:

```lua
print(peripheral.find("drive").getDiskID())
print(peripheral.find("drive").getMountPath())
exit()
```

Write down both results:

- **Disk ID:** identifies the floppy's folder in the world's files on your PC or server.
- **Mount path:** identifies the floppy inside the in-game computer, such as `disk` or `disk2`.

CC's [disk-drive documentation](https://tweaked.cc/peripheral/drive.html) describes both values.

Continue once both results are present. If either is missing, check the drive connection and insert a writable data floppy, then repeat the commands.

Save and close Minecraft. On your PC, open:

```text
<instance>/saves/<world>/computercraft/disk/<disk ID>/
```

On multiplayer, the server administrator must open `computercraft/disk/<disk ID>/` inside the server's world folder and perform the copy below.

Copy the **contents** of the extracted `media/` folder into that disk-ID folder. The result should contain these files directly:

```text
<disk ID>/
  startup.lua
  setup.lua
  release.json
  library.json
  objects/
```

Check that `startup.lua` is directly inside `<disk ID>/`, as shown above.

Retain a clean extracted copy of the installer. During setup, the working floppy gains deployment records for this ship. Start another ship or world from the clean copy on a separate disk.

## 6. Install CORE first

Return to the world. Keep the vessel unassembled and all operating inputs neutral.

1. Take the installer disk to the computer marked CORE. Attach the setup drive without disconnecting required vessel hardware.
2. Insert the disk and start setup. It may appear on boot. If it does not, run:

```text
/disk/startup.lua
```

Replace `disk` with the mount path recorded in section 5. For a mount path of `disk2`, enter `/disk2/startup.lua`.

3. Confirm that the setup screen shows the intended computer's ID.
4. Choose **C: Install core**.
5. Read the confirmation, then type **YES**.
6. Wait for the message that core is installed with propulsion disabled.

Leave core's operating runtime stopped. Eject the disk and remove the temporary drive. Take both to the next computer.

## 7. Register STATE and the other 14 roles

Carry the **same drive and working disk** to every remaining computer. The disk records the assignments for this ship.

At each computer:

1. Attach the temporary drive at the connection shown on the computer-location diagram, insert the disk and open setup from it.
2. Check the computer ID against your location diagram.
3. Choose **A: Register auxiliary**.
4. Choose its group, then type the full computer name shown in the menu. Either letter case is accepted.

| Group | Roles |
|---|---|
| C | chamber-fl, chamber-fr, chamber-bl, chamber-br |
| T | thrust-lb, thrust-rb, thrust-ls, thrust-rs, primary-l, primary-r |
| D | bridge, hdg-l, hdg-r, hdg-m |
| S | state |

5. Read the proposed assignment and type **YES** only when it matches this physical computer.
6. Wait for installation/registration to finish. Eject the disk, remove the temporary drive and reboot the computer. Take the drive and disk to the next computer.

To reboot from a shell, enter:

```text
reboot
```

STATE receives its reader software directly from the disk. Keep its wired connection to core in place when removing the temporary drive.

The other 14 computers initially receive a bootstrap and wait for core to supply their full packages. A waiting-for-core screen at this stage is expected.

## 8. Review assignments before importing them

At setup, choose **V: View assignments**. The list should reach **16/16 roles registered**. Compare every ID with your physical diagram.

Complete any assignment corrections before importing the list into core.

For a registration-only correction on an ordinary auxiliary:

1. Attach the temporary drive to the wrongly assigned computer, insert the same disk and boot into setup with its runtime stopped.
2. Choose **R: Correct assignment**.
3. Select its correct group and computer name, review the plan and confirm.
4. If the destination role belongs to another computer, setup creates a swap. Move the drive and disk to the other computer listed in the plan.
5. On that computer, choose **R**, then **F: Finish here**, and confirm.
6. Repeat every listed visit until the correction is complete. Review **V** again.

**R: Correct assignment** supports auxiliary computers that have only their bootstrap installed, before core imports the assignments. Corrections involving CORE, STATE, full packages or an imported assignment list require the release's repair procedure. Keep commissioning stopped until those corrections are complete.

**Continue when:** all 16 IDs are correct and no correction plan remains unfinished.

## 9. Import the fleet and distribute packages

1. Reattach the temporary drive to CORE and insert the working installer disk.
2. Run disk setup with core's operating runtime still stopped.
3. Choose **I: Import on core**, review the confirmation and type **YES**.
4. Return to setup's main menu.
5. Choose **S: Start core with disk**.
6. Leave the drive attached to core and the disk inserted until package installation completes. Make sure STATE and all registered auxiliary computers are powered on.
7. Open core's **installer** tab and watch the roster.

Core distributes **14 wireless packages**. STATE is installed directly and is checked separately.

A transfer percentage measures acknowledged file bytes. At **100%**, the installer still has to verify the committed package. **DONE** confirms that verification passed. Wait until all 14 package roles show **DONE**. Receiving computers may show a temporary installation interface and reboot into their normal console after installation.

While unassembled, flight-readiness messages such as `VESSEL NOT ASSEMBLED` can be expected. They are separate from package-installation progress.

**Continue when:** all 14 packages are verified, each computer is running its intended role, and STATE's wired link reaches core.

Eject the installer disk and remove the temporary drive. All computers now run from their installed files. Store the drive and disk for later installation, updates or repair.

## 10. Check the machinery before assembly

Complete the release's powerplant checklist:

**[PUBLISHER INSERT: name and illustrate the fuel/water filling points, required starting inventory, valves and enable controls, mechanical-drive startup, expected boiler indications, transmission input conditions and physics-assembler control. Provide the actual operating order. This information has not been verified from the software.]**

Then inspect the computer status pages:

- Every chamber discovers the expected gas hardware. For the current reference build, that is **32 steam vents and one trim burner per chamber**.
- Each dedicated thrust controller sees its intended transmissions and corner altitude sensor.
- Both primary bearing interfaces report their expected hardware.
- All four corner altitude readings reach core through the chamber/thrust links.
- The cockpit reader identifies all nine intended inputs and their neutral values.
- Bridge and instrument monitors display live information.
- Wireless modems, wired links and redstone frequencies match the release drawings.

Resolve missing hardware, count mismatches, conflicting frequencies and ambiguous discovery before proceeding.

## 11. Assemble and verify live readiness

Check the hull's clearance and the assembler's selected structure against the release diagram. Assemble the ship using the release's illustrated physics-assembler procedure.

Wait for the system to establish vessel identity and fresh telemetry. Confirm that the displayed heading corresponds to the bow's actual direction and that altitude/vertical-speed readings are plausible.

Release every cockpit control. Neutral input is part of the control handover after startup or a communication interruption.

Verify the control card one input at a time before applying operating thrust. The software distinguishes heading left/right, lateral left/right, forward/reverse, altitude up/down and an AP-disconnect/throttle-shortcut input. The actual keys and cockpit actions are release-specific.

**Control card:** [PUBLISHER: insert the verified physical controls and key bindings, including how to select each operating position and return it to neutral.]

Test small thrust and steering requests only under the release's supported commissioning arrangement. Check actual propeller response and vessel direction, then return the request to neutral. Complete the direction checks before making an unrestricted flight.

**Continue when:** the vessel is assembled, all essential data is fresh, inputs respond correctly, hardware directions are verified and no unresolved essential-system fault remains.

## 12. Understand the bridge controls

The main display has **FLIGHT**, **NAV**, **SHIP** and **SETTINGS** pages.

Speed is displayed in **b/s**, meaning blocks per second.

| Control or mode | What it does |
|---|---|
| Heading MANUAL | Cockpit steering requests turning directly |
| Heading SEL | Cockpit steering changes the selected heading; the controller turns toward it |
| Throttle MAN | Cockpit input requests acceleration/deceleration |
| Throttle SEL | Cockpit input changes the selected signed speed; releasing the input leaves that selection active |
| Throttle DIRECT | Cockpit input directly requests drive output within configured limits |
| Altitude up/down | Changes the selected altitude target |
| NAV → ANCHOR | Uses propulsion to hold a captured horizontal position |
| NAV → AUTOPILOT | Plans and operates a route to a destination X/Z |

In throttle **SEL**, the selected speed remains active after you release the input. Set the selection to **0** to request a stop.

Displayed altitude is the world-Y coordinate of the vessel's altitude reference. Use the release's docking-height reference to account for the hull below that point and maintain ground clearance.

## 13. Start lift and make the first departure

1. Keep the departure area clear. Confirm fuel, water, mechanical power and fresh readings.
2. Use the release's docking-height reference to select an initial altitude that clears the entire hull and lies within the displayed operating limits.
3. Open **SETTINGS → NEXT PAGE > → START SYSTEMS**. The Start Systems control is also available under **LIFT MAINTENANCE**.
4. Wait while startup verifies the lift hardware, establishes command authority, builds lift and begins altitude capture. Watch the displayed phase and any blocking reason.
5. Watch FLIGHT and SHIP. All four chambers must acknowledge control and provide sensible gas/lift readings.
6. Wait for active altitude control and observe actual altitude and vertical speed. `READY` describes the control phase; compare actual and selected altitude to establish whether she has settled.
7. In **SETTINGS → PROPULSION**, choose **ENABLE PROPULSION** when available. Keep the controls neutral during enable. If it is unavailable, read its displayed reason and resolve it.
8. On **FLIGHT**, select throttle **SEL**. Use the cockpit's forward input to increase the selected speed to **1 b/s**, then release it. Follow a clear straight path and confirm that actual speed increases in the intended direction.
9. Use the cockpit input to return selected speed to **0**. Watch actual speed as the ship decelerates.
10. Select heading **SEL**. Use the steering input to select a small heading change, then release it. Confirm that the ship turns toward the selected heading and let the turn settle before selecting another.

Gas takes time to build and decline. After each altitude selection, observe actual altitude and vertical speed until the response settles before selecting another target.

**First-flight checks complete when:** the ship climbs toward the selected altitude, settles under altitude control, moves and turns in the requested directions, and returns to a controlled stop without an unresolved essential-system fault.

## 14. Use autopilot after manual checks pass

1. Establish working lift, heading and propulsion control in clear air.
2. Open **NAV → AUTOPILOT**.
3. Enter the destination **X** and **Z**, cruise speed and flight altitude. Destination name is optional identification.
4. Check the entered X/Z coordinates against the intended destination, including minus signs. Confirm the cruise speed and altitude.
5. Choose a short, unobstructed first route at low speed. Release the digital anchor if it is active.
6. Select **ENGAGE**. If it is blocked, resolve the displayed reason.
7. Observe heading acquisition, travel, deceleration and arrival behavior. Use **DISENGAGE AUTOPILOT** to cancel the route when required.

Choose a route with clearance for the whole hull and monitor the flight. Possible-impact and possible-obstruction warnings respond to measured motion changes or a failure to move under power. They provide reactive warnings; route clearance requires the operator's assessment.

The digital anchor uses active propulsion to hold horizontal position while altitude control maintains lift.

Commission remote AP after onboard operation passes these checks. It requires a separately provisioned and authorized remote. For unattended operation, provide and test chunk loading for the vessel's computers and physics throughout the route.

## 15. Arrive, land and shut down

1. Reduce selected speed to zero and allow time for deceleration. Verify actual speed.
2. Use the digital anchor when appropriate to hold a horizontal position over the prepared docking area.
3. Reduce the selected altitude in small steps while observing whole-hull clearance. Use the release's docking reference and support arrangement.
4. Establish physical support before deliberately removing main buoyancy.
5. Use **STOP SYSTEMS**, read the review screen, then choose **CONFIRM STOP** when a shutdown is intended.

STOP SYSTEMS removes main steam lift, **causing the vessel to drop rapidly.** It retains the small trim probes for telemetry. Confirm physical support before selecting **CONFIRM STOP**.

Complete the remaining machinery shutdown steps in the powerplant checklist.

## 16. Know the three different interruption paths

| Situation | Meaning and response |
|---|---|
| Telemetry/command interruption | The system preserves applied lift where supported, suspends or limits control, and attempts revalidation/recovery. Read the cause and actual motion. |
| Confirmed STOP SYSTEMS | Deliberately removes main steam lift and clears running intent. Use after the ship is supported. |
| KILL LIFT | Emergency removal of main lift. Latches a restart lock. |

After a kill, inspect the vessel and resolve the cause. Select **DISARM KILL** to clear the lock. The systems remain stopped until you select **START SYSTEMS**.

**RESTART SYSTEMS** reloads core and navigator while the chamber and thrust computers keep running. Core restart handling is designed to retain existing lift while core revalidates command authority. Monitor actual altitude and vertical speed throughout the interruption.

If automatic recovery stops, inspect the displayed fault and resolve its cause. Open **SETTINGS → RECOVER LIFT**. Select it when available; otherwise, follow its displayed blocking reason.

## 17. Troubleshooting

| What you see | First check |
|---|---|
| `No such program` after typing a menu choice | You are probably at the shell. Run the disk's `startup.lua`, then choose the setup letter and computer name inside setup. |
| `/disk/startup.lua` cannot be found | Check the actual mount name and that `startup.lua` is at the disk root, not inside an extra `media/` folder. |
| Not enough space | Confirm that the active server configuration has adequate computer/floppy capacity and was restarted. Check this installer's exact media requirement. |
| `Fresh computers only` | Setup found existing operating files. For a new installation, fit a fresh computer in the documented orientation, restore its connections and record its ID. For an existing installation, follow the release's repair instructions. |
| Role already assigned | Review **V: View assignments**. Before import, use **R: Correct assignment** as described in section 8. |
| Import is blocked | Find the missing role or unfinished correction. All 16 registrations are required. |
| Auxiliary waits for core | Check its ID/role, core startup, power, wireless modems and the matching installer disk in core. |
| Core requests matching installer media | Reinsert the working installer disk used for this installation. |
| STATE is disconnected | Check STATE power, its registration and the wired modem/cable link to core. |
| `RETURN CONTROLS TO NEUTRAL` | Release the relevant controls and wait for a fresh neutral sample. |
| A vessel/chamber reading is stale | Check actual motion. Inspect server lag, reader health and links. Confirm that the measurement's sample age returns to a fresh value. |
| `VESSEL IDENTITY CHANGED` | Check that the vessel and corner sensors are connected to the intended assembled ship. Monitor core's recovery status after correcting the connection or identity issue. |
| `POSSIBLE DUPLICATE ID` | Check for a copied ship or computer using the same IDs. Loaded copies can interfere even when one is not being piloted. |
| `POSSIBLE OBSTRUCTION` | Inspect the path and actual movement before increasing thrust. |

For a report, include the schematic revision, installer release ID, affected computer ID/role, exact message, screenshot and whether the vessel is assembled and supported.

For a debug recording, insert a separate writable data disk into a drive visible to core. Open **SETTINGS → DEBUG MODE → START DEBUG RECORDING**. Reproduce the event and stop recording. Keep the resulting `/amaryllis-logs/` files on that data disk.

## 18. Keep the service disk

After installation, the ship operates with the temporary drive and installer disk removed. Core's installer tab waits for media when the disk is absent.

Keep the drive, working disk and clean exported installer. The auxiliary package library resides on the installer disk. For auxiliary installation, update checks or repair, reconnect the drive to core and insert that disk.

For an existing ship, follow the new release's upgrade instructions. **U: Adopt auxiliary library** changes the auxiliary package library and requires matching core code. Core and STATE updates require their own release-specific instructions.

The supplied profile may include learned hover and leveling defaults. They seed missing local learning files; the ship continues adapting. Changed cargo, balloons or machinery can require further settling and commissioning.

After commissioning, use sections 13–15 for departure, flight and docking. Keep the release card, control card, powerplant checklist and service disk with the ship's records.
