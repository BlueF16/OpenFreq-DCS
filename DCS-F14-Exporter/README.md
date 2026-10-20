# OpenFreq DCS — F-14 Native PTT Exporter v0.7.0

**Status:** Offline Lua/Python mock tests passed. Native F-14 PTT **has not yet been validated in live DCS**. This is a radio-state exporter, **not yet microphone/audio transport**.

## Overview

This release replaces the v0.6.0 F-14 cockpit-argument PTT scanner with Heatblur's **native F-14 radio-device methods**. The exact PTT method pattern is used in the aircraft adapter in DCS Simple Radio Standalone (SRS), inspected as a DCS API reference only. **SRS does not need to be installed or running**; all eventual radio simulation/audio will remain OpenFreq's.

| Native F-14 device | Lua method | OpenFreq output |
|---|---|---|
| `GetDevice(3)` ARC-159 (UHF1) | `is_ptt_pressed()` | `selected_tx_radio=1`, `ptt_pressed=true` |
| `GetDevice(4)` ARC-182 (UHF2) | `is_ptt_pressed()` | `selected_tx_radio=2`, `ptt_pressed=true` |
| `GetDevice(2)` Intercom | `intercom_transmit()` | `selected_tx_radio=0`, `ptt_pressed=true` (cold-mic only) |
| Pilot ICS function selector | Cockpit argument `2044` | `cockpit.ics_hot_mic` boolean; ICS hot mic **does not** force PTT |

Priority when multiple radio PTT states are active is UHF2 > UHF1 > ICS, matching the SRS F-14 reference implementation.

**No raw HOTAS scanning, separate keybinds, or PTT command injection**. The data reflects the actual DCS F-14 cockpit radio device states if those methods are accessible from your Export.lua environment.

### Safeguards

- If a required state is unavailable or raises an error, `ptt_pressed` remains JSON `null`, not `false` (unless other available states conclusively establish release). This prevents a false claim about PTT.
- ICS hot mic is reported separately as `cockpit.ics_hot_mic`; it is **not** interpreted as a held PTT button.
- Local **pilot** cockpit only for this initial test. RIO seat/ICS handling is **not** implemented.
- `radio_export_status`, aircraft position, frequency, power and AM/FM telemetry retain the `openfreq.dcs.telemetry.v1` wire schema and UDP `127.0.0.1:29340` at ~10 Hz.
- Radio and ICS receive volume are read from device `get_volume()` first, with the F-14 pilot cockpit arguments 2031, 2038, 2048 as fallbacks. Real DCS volume readings require verification.
- No voice audio is sent and **no OpenFreq C# radio/audio engine changes** are made in this release.

## Install

1. Back up your active `Saved Games\DCS\Scripts\Export.lua`. For Open Beta your active folder may differ.
2. Copy the included `OpenFreqDCSExport.lua` into that `Scripts` directory, replacing the previous OpenFreq exporter file.
3. **Keep your existing** OpenFreq loader line, ideally at the end of `Export.lua`:

   ```lua
   dofile(lfs.writedir() .. 'Scripts/OpenFreqDCSExport.lua')
   ```

   Do **not** duplicate the `dofile` line. Preserve other exporter callbacks, such as Tacview.
4. In DCS, consider **Options > Special > F-14 > Radio Menu and PTT Behavior** and select the external radio priority setting so the mic buttons work without opening the radio menu. Heatblur's option names can vary by version. Use the **actual DCS Mic Button UHF1 / UHF2 / ICS bindings** already configured for the F-14. No OpenFreq HOTAS bindings are needed.
5. Restart the DCS mission, join **F-14B pilot**, and make sure no other utility is listening to UDP port 29340.

## Quick test

In a terminal from the extracted ZIP folder:

```cmd
py udp_monitor.py
```

Press/release the **pilot's UHF1**, **UHF2**, then **ICS** microphone switches.

Expected example **if the Heatblur native methods work in your DCS install**:

```text
F-14B | UHF1 ARC-159: 251.000 MHz AM [ON] VOL=62% | UHF2 ARC-182: 124.800 MHz AM [ON] VOL=45% | TX=None PTT=False (heatblur_native_devices) | PTT_STATE[UHF1=False, UHF2=False, ICS=False]
F-14B | UHF1 ARC-159: 251.000 MHz AM [ON] VOL=62% | UHF2 ARC-182: 124.800 MHz AM [ON] VOL=45% | TX=UHF1 PTT=True (heatblur_native_devices) | PTT_STATE[UHF1=True, UHF2=False, ICS=False]
F-14B | UHF1 ARC-159: 251.000 MHz AM [ON] VOL=62% | UHF2 ARC-182: 124.800 MHz AM [ON] VOL=45% | TX=UHF2 PTT=True (heatblur_native_devices) | PTT_STATE[UHF1=False, UHF2=True, ICS=False]
F-14B | UHF1 ARC-159: 251.000 MHz AM [ON] VOL=62% | UHF2 ARC-182: 124.800 MHz AM [ON] VOL=45% | TX=ICS PTT=True (heatblur_native_devices) | PTT_STATE[UHF1=False, UHF2=False, ICS=True]
```

Values and success above are illustrative, **not yet confirmed in live DCS**. `TX=ICS` uses ID **0**, while radio IDs remain **1** and **2**.

For raw diagnostics:

```cmd
py udp_monitor.py --json
```

If it prints `native_ptt_unavailable` or `PTT=None`, the DCS device methods were absent/failed or returned unexpected types. This does **not** mean the buttons are not physically pressed.

## Record native PTT for five seconds

Stop `udp_monitor.py` (the tools share the same UDP port) and run:

```cmd
py f14_ptt_probe.py
```

Press Enter, return to DCS during the 3-second countdown, then hold UHF1, UHF2 and ICS in sequence for ~0.6–1.0 seconds each. The program captures the actual native API values at the export rate and saves `f14_native_ptt_capture.json`. Share this JSON if any PTT reading fails.

It can also record for a longer period if helpful:

```cmd
py f14_ptt_probe.py --duration 10
```

## Offline tests

```cmd
py -m unittest discover -s tests -p "test_*.py"
```

The bundled `tests/run_lua_mock.py` uses `liblua5.4.so.0` on Linux (e.g. our test environment) to exercise the Lua exporter with simulated Heatblur devices. It tests all native PTT directions, release, radio-priority handling, hot-mic ICS suppression, missing/exception APIs, volumes, and unsupported-aircraft isolation.

## Sources / attribution

- **OpenFreq** (implementation's radio/voice engine): https://github.com/UOAF/OpenFreq
- **SRS F-14 module** (technical **reference only** for Heatblur DCS API): https://github.com/ciribob/DCS-SimpleRadioStandalone/blob/master/Scripts/DCS-SRS/Scripts/DCS-SRS-Modules/F14.lua
- Heatblur F-14 Special Options: https://freeproject089.github.io/f-14-manual/en/f14ab/dcs/special_options.html

This is original OpenFreq integration code which calls the documented DCS APIs. It does not copy or run SRS's audio transport, modulation, server or client.
