# Realtek Audio Restart

**English** | [简体中文](README.zh-CN.md)

Reload the whole Windows audio driver stack in one click — **without rebooting**.

It is built for a very common Windows annoyance: you plug headphones into the 3.5 mm jack and nothing happens — sound keeps coming out of the speakers, or Windows claims there is no audio device at all. A reboot fixes it, every time. This tool performs the same codec re‑enumeration a reboot would do, in about 30 seconds, and touches nothing else.

![status](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D4) ![status](https://img.shields.io/badge/powershell-5.1%2B-5391FE)

## Why plugged-in headphones are not detected

On most modern laptops the codec (Realtek) sits behind an Intel SST / HD Audio controller. Windows detects a jack plug through *jack-presence detection* polled by the codec driver. When that driver chain gets stuck — after sleep/resume, a driver update, a crashed audio engine, or a device that failed to re-enumerate — the trigger never arrives, so Windows keeps the old endpoint ("speakers") and ignores the headphones. A reboot re-enumerates the codec, the poll restarts, and the jack is detected again.

Disabling/re-enabling the device in Device Manager is usually not enough: the parent controller keeps its state. This tool restarts the **parent controller**, which tears down and re-creates the entire audio child chain — the same thing a boot does.

## Quick start

1. Download the folder for your language: `en/` or `zh/`.
2. Double-click **`Start-AudioRestart.cmd`** and accept the UAC prompt (driver reload requires administrator rights).
3. Click **Restart audio** and wait 20–90 seconds. Audio cuts out briefly — that is expected.

No installation, no background service, no registry changes.

## What is inside

| File | Purpose |
|---|---|
| `Start-AudioRestart.cmd` | Double-click entry point (hidden console, GUI only) |
| `AudioRestartTool.ps1` | GUI: button, live status, streaming log |
| `Restart-Audio.ps1` | The engine; also usable from the command line |

`zh/` and `en/` contain the same code with Chinese or English messages — the scripts are line-for-line identical apart from strings, so behaviour is the same in both.

## What it actually does

| Step | Action |
|---|---|
| 1 | Finds the Realtek audio device and walks up the device tree to its real parent controller (`INTELAUDIO\DSP_CTLR_*` on Intel SST platforms, or the HD Audio bus controller) |
| 2 | Stops audio services in reverse dependency order: vendor service → `Audiosrv` → `AudioEndpointBuilder` |
| 3 | Ends user-mode audio processes (`RtkAudUService64`, `RtkNGUI64`, `RtkUWP`, `audiodg`) to release the device |
| 4 | `pnputil /restart-device` on the parent controller; if that fails, falls back to disable → enable |
| 5 | Starts services again in dependency order and waits for the device chain to re-enumerate |
| 6 | Verifies: arrival time refreshed, problem code 0, all services running, active playback/capture endpoints, default endpoint alive |
| 7 | Optional 0.5 s low-volume test tone to prove the audio path end-to-end |

### How it knows the reload really happened

`pnputil` prints "Device restarted successfully" even when it was handed an empty argument, and a device can report `Status = OK` without ever having been reloaded. So the tool checks three things instead of trusting the exit code:

- the `pnputil` echo actually contains the full InstanceId;
- `DEVPKEY_Device_LastArrivalDate` moved from the old timestamp to the current one;
- the endpoint set is active and the default playback endpoint answers.

## Command line

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -TestTone
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -DeviceMatch VEN_10EC
```

| Option | Meaning |
|---|---|
| `-TestTone` | Play a 0.5 s low-volume tone when done |
| `-DryRun` | Detect the device and target controller only; change nothing |
| `-DeviceMatch` | Vendor fragment matched inside the InstanceId. Default `VEN_10EC` (Realtek); use another `VEN_` value for other codecs |

Exit codes: `0` success, `1` environment/permission problem, `2` execution or verification failure.

## Safety and scope

- Only audio devices and audio services are touched. No registry edits, no service start-type changes, no other hardware.
- If the device does not come back within ~25 s, the tool tries to re-enable it and reports loudly instead of failing silently.
- Every run writes `audio_restart_*.log` next to the scripts, so each step can be audited afterwards.
- Nothing is installed, nothing is scheduled, nothing runs at startup.

## Troubleshooting

| Symptom | Next step |
|---|---|
| Jack still not detected after the reload | Open Realtek Audio Console / Realtek Audio Manager and re-check jack detection; if the front-panel detection option is enabled, turn it off. Then reinstall the Realtek driver package. |
| Tool reports "device did not recover" | Reboot Windows once — the driver chain needs a clean start. |
| Script blocked by security software | Add an exclusion, or run the `.ps1` manually with `-ExecutionPolicy Bypass`. |
| No Realtek device found | Pass `-DeviceMatch` with your vendor ID, or open an issue with the output of `-DryRun`. |

## Requirements

- Windows 10 version 1903 or newer, Windows 11 (needs `pnputil /restart-device`)
- Windows PowerShell 5.1 (built into Windows) — no extra runtime
- Administrator rights

Tested on Windows 10 22H2 (10.0.19045) with an Intel SST controller (`PCI\VEN_8086&DEV_06C8`, parent `INTELAUDIO\DSP_CTLR_DEV_06C8`) and a Realtek ALC245 codec (`DEV_0245`).

## Notes

- Classic `HDAUDIO` codec setups are supported through the HD Audio bus controller path.
- The GUI is sized for 125 % DPI scaling and up.
- Logs are excluded via `.gitignore`; delete the oldest ones freely.
