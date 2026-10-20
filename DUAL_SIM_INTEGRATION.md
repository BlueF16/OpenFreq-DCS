# OpenFreq dual-simulator client — experimental DCS F-14 adapter

**Source baseline:** UOAF/OpenFreq `1.1.5`. Existing BMS, GCI, RTC/signalling, frequency-slot engine, and original OpenFreqAudio implementations are retained. The new DCS adapter is **not based on SRS for audio**. The unchanged F-14 Lua exporter v0.7.0 is bundled under `DCS-F14-Exporter`.

## What is implemented

- A third **DCS** mode appears beside **BMS** and **GCI** in the **same** OpenFreq client. Select manually **before connecting**. Switching simulator source while connected is intentionally blocked to avoid cross-simulator channel leakage. Automatic detection is *not yet implemented*.
- Existing BMS shared-memory and RCC services, auto-connect, radio import, hotkeys and F-16 positioning are retained. DCS mode stops BMS services and **does not acquire the BMS radio mutex**.
- `DcsTelemetryService.cs` reads JSON schema `openfreq.dcs.telemetry.v1` from **loopback UDP 127.0.0.1:29340**. Unsupported aircraft and malformed frames are ignored. The decoder retains `null` for unknown states, checks frequency and volume ranges, deduplicates UDP sequence values, and expires stale data after 1.5 seconds.
- `ChannelCardListViewModel.cs` creates separate **F-14 UHF1** and **UHF2** radio slots. The slots track DCS frequencies, AM modulation, power and pilot volume; their native microphone PTT press/release drives the original OpenFreq `StartTransmissionAsync`/`StopTransmissionAsync` calls. Retuning and PTT changes run sequentially, preventing stranded frequencies or stuck TX.
- Lost telemetry stops TX and drops each DCS frequency membership. Reconnecting the OpenFreq client resynchronizes the radio slots from current DCS telemetry.
- DCS `LoGetSelfData().Position` axes are mapped to an OpenFreq position as north/east/altitude for **same-terrain DCS peers**. Velocity is not exported and is deliberately unknown. No DCS-specific heightmap or spatial propagation solver is included. This means **3D/terrain RF physics is NOT validated**; OpenFreq's existing fallback audio parameters apply where physics data is unavailable.
- The native F-14 Lua exporter (validated for native PTT by the project user) remains unchanged, including ICS/hot-mic reporting. **ICS voice networking and RIO are excluded from this C# stage.**

## Known limitations and compatibility

1. **No Windows binary is provided.** This environment lacks the .NET 10 SDK and the upstream `libs/OpenFreqAudio` git submodule. The changes are source-level integration code, not a compiled/flight-tested client. The existing BMS path has not been live-regression-tested against BMS here.
2. **Only AM channels** are joined for DCS. The existing OpenFreq protocol keys network channels by frequency (kHz), not modulation; joining FM to a same-frequency AM channel would be misleading. FM support requires adding modulation to the network/channel model.
3. Cross-simulator DCS/BMS spatial simulation is **not physically meaningful yet** because DCS and BMS have different world coordinate frames and terrain. Same-frequency network messaging is possible, but cross-simulator RF propagation must be designed/tested separately.
4. The code has no automatic DCS/BMS process selection yet. Explicit mode selection avoids conflict and makes BMS compatibility simpler to validate.
5. DCS pilot PTT and exporter were previously validated live; **this C# client integration is not yet live-validated**. Verify live tuning, power, gain, TX and RX with two clients.
6. Do not simultaneously run `udp_monitor.py` or `f14_ptt_probe.py` on the same machine while the OpenFreq client DCS mode is listening on UDP 29340.

## Compile on Windows

This ZIP includes the OpenFreq 1.1.5 source as a **convenience snapshot**, but its source tarball omits the upstream `libs/OpenFreqAudio` submodule. Preferred route:

```powershell
# Clone the ORIGINAL OpenFreq repository with its AUDIO submodule:
git clone --recursive https://github.com/UOAF/OpenFreq.git
cd OpenFreq
# Prefer checking out the upstream 1.1.5 tag/commit before copying the patched source.
# Extract the supplied PATCH-OVERLAY.zip onto this matching source checkout.
# Install the .NET 10 SDK, then:
dotnet restore OpenFreq.sln
dotnet test OpenFreq.Client.Tests/OpenFreq.Client.Tests.csproj
dotnet build OpenFreq.Client/OpenFreq.Client.csproj -c Release
```

You can build directly from the bundled source instead if you supply the matching `libs/OpenFreqAudio` directory from upstream and restore the .NET dependencies. No compiled EXE is included; if upstream master diverged from 1.1.5, **use a matching 1.1.5 checkout**.

## DCS installation

1. Copy `DCS-F14-Exporter/OpenFreqDCSExport.lua` to `Saved Games\\DCS\\Scripts\\OpenFreqDCSExport.lua`.
2. Preserve all existing Export.lua exporters and make sure the following line is present **once**:

```lua
dofile(lfs.writedir() .. 'Scripts/OpenFreqDCSExport.lua')
```

3. Enter the F-14B pilot cockpit in DCS (native radio PTT already verified with exporter v0.7.0).
4. Start the rebuilt OpenFreq **client**, choose **DCS**, enter server address and display name; connect. When a DCS F-14 snapshot arrives, the client creates UHF1/UHF2 slots and joins powered AM frequencies.
5. Tune both clients to the same AM frequency, use existing native F-14 UHF1/UHF2 PTT to transmit. Observe OpenFreq's radio cards and server transmission indicators.
6. On DCS exit, wait about 1.5s: the client should automatically release PTT and leave both radios.
7. For BMS, disconnect, select **BMS**, and connect using the original BMS workflow. No new BMS binds required.

### Verification checklist

- [ ] Same OpenFreq executable offers **BMS / DCS / GCI** modes.
- [ ] BMS mode still obtains RCC/SHMEM, tunes radios, and controls native PTT.
- [ ] DCS mode does not attempt to acquire the BMS radio mutex.
- [ ] DCS F-14 UHF1/UHF2 channel membership changes with radio frequencies/power.
- [ ] DCS UHF1 and UHF2 native PTT cause correct OpenFreq transmit indicators and received voice on second client.
- [ ] Releasing PTT, powering off a radio, retuning, closing the mission, or interrupting UDP leaves no stuck transmission.
- [ ] Both DCS peers receive audio and gain follows radio volume.
- [ ] Cross-sim interoperability tested separately before enabling RF realism claims.

## File changes

- `OpenFreq.Client/Services/DcsTelemetryService.cs` (new)
- `OpenFreq.Client.Tests/DcsTelemetryServiceTests.cs` (new)
- `OpenFreq.Client/Services/ServiceCollectionExtensions.cs`
- `OpenFreq.Client/Services/OpenFreqService.cs`
- `OpenFreq.Client/Services/Interfaces/IOpenFreqService.cs`
- `OpenFreq.Client/Models/RadioStationData.cs`
- `OpenFreq.Client/ViewModels/SettingsViewModel.cs`
- `OpenFreq.Client/ViewModels/MainWindowViewModel.cs`
- `OpenFreq.Client/ViewModels/ChannelCardListViewModel.cs`
- `OpenFreq.Client/Views/MainWindow.axaml`
- `OpenFreq.Client/Views/ChannelCardView.axaml`
