# Amaryllis chamber hardware setup

The split-controller revamp supersedes the original sensor/wiring layout below:
all chamber gas networks now use back; altitude sensors and transmissions belong
to dedicated thrust computers. See Amaryllis-chamber-thrust-migration.md for the
current wiring and loading procedure. Gas count and frequency editing still apply.

Each updated chamber reads `/avionics/config.json` for its installer identity and
`/avionics/data/chamber-hardware.json` for user hardware settings. The second file
is created on first startup using that chamber's existing packaged settings.
Normal fleet package updates leave this data file alone.

## Editing

On the chamber computer, select **Utilities > H: Edit chamber hardware JSON**.
The editor opens in a separate tab. Alternatively, use its Shell tab:

```text
edit /avionics/data/chamber-hardware.json
```

Edit the existing file. Do not replace it with an incomplete snippet. Preserve
`schemaVersion: 1` and the chamber's `role`. Do not copy another chamber's role
or frequencies without deliberately adapting them.

Edits apply on the chamber runtime's next startup. They are not applied mid-flight.
Commission a changed physical layout with the vessel supported. Restart Systems
on the bridge does not itself reboot chamber computers.

## Changing from eight to sixteen vents

Change `providerDiscovery.steamCount` from `8` to `16`. Keep
`providerDiscovery.trimCount` at `1`. Supported range is 1 through 63 steam vents
plus exactly one trim burner per chamber. The total provider limit is 64.

Keep `providerDiscovery.networkSide` set to the computer-relative side containing
the chamber's gas peripheral network: currently `back` on FL/FR and `front` on
BL/BR. Its network must contain the configured vent count, one hot-air burner,
one altitude sensor and one Redstone Link Bridge when using automatic discovery.

The total requested chamber gas target retains its existing meaning. Adding
vents does not multiply the initial chamber gas target. Targets are distributed
over the configured provider set, within individual limits.

## Frequencies and limits

`activationFrequency.first` and `.second` are the ordered item IDs for the steam
activation link. All chamber vents receive that same link. Leave the existing
values unchanged for the current build.

`trimActivationFrequency.first` and `.second` configure the separate trim-burner
activation link. Steam and trim must have different ordered frequency pairs.
Use full item IDs such as `minecraft:yellow_wool`.

`providerDiscovery.bulk` and `.fine` contain target bounds. Current defaults are
steam minimum nonzero 50, maximum 5000, and trim minimum nonzero 5, maximum 500.
Targets use integer steps of 1. Changing vent count does not require changing
these bounds. The startup and probe logic still requires the supported 50/5 floors.

## Peripheral assignments

The editable `peripherals` object defaults to:

```json
{
  "steamVents": [],
  "trimBurner": "",
  "activationBridge": "",
  "altitudeSensor": ""
}
```

Empty values enable automatic discovery on the configured gas network. This is
recommended when peripheral names change during assembly or rebuilding.

After successful discovery, `discovered` in the same JSON file lists the actual
steam vent, burner, bridge and sensor names. This is a reference inventory, not
an authoritative binding. Do not edit `discovered` to assign hardware.

For an explicit assignment, copy exact names from `discovered` into
`peripherals`. `steamVents` must list the full configured number of vent names.
Other entries take one exact name. Names may include a route prefix such as
`@remote:back:steam_vent_12`; preserve the full name.

Explicit bindings do not silently substitute a different peripheral if the named
one disappears. Clear the relevant assignment to restore automatic discovery.

The file also preserves propulsion `bindings`, `networks`, and rear-controller
`primaryDirection` settings. Lift and thrust read the same user overrides.

## Checks after startup

1. Installer reports the current package for core and all chambers.
2. Hardware discovery resolves sixteen vents and one trim burner in each chamber.
3. The `discovered` inventory matches that chamber's actual hardware.
4. Both activation links reach their intended recipients.
5. Start Systems completes probe verification and acknowledges a complete target
   map for every chamber. Core learns each chamber's configured vent count from
   its registered status report. Older status senders default to eight.
6. Verify normal stop and KILL LIFT on the commissioned layout. Offline tests do
   not establish that the physical receivers or steam supply are wired correctly.

Malformed JSON, wrong role, invalid counts, missing assigned peripherals and
ambiguous automatic discovery report an error. They do not erase user settings.
Writes use a temporary file and retain the previous file as `.bak`. An interrupted
write with no main file reports recovery required rather than reseeding defaults.

The existing eight-vent configuration remains the migration default. Select 16
when the new physical layout is installed; no computer has been rebooted or any
live gas target changed by this update.
