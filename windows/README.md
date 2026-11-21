# DSPi for Windows

DSPi for Windows applies parametric EQ and other DSPi effects to shared-mode audio on a selected Windows playback device. You can use it with a USB DAC or another eligible speaker output. Windows runs the DSP on the PC, so a Pico, virtual audio cable, and Equalizer APO are optional for other workflows and unnecessary for this setup.

## Install and check playback

This is an **unsigned x64 development preview**. The PC must already allow the local audio development configuration checked by Setup. If Windows rejects the APO, leave its protection settings in place. Administrator approval is required for attachment and removal.

1. Download the Windows preview ZIP from the [Windows preview release](https://github.com/CrawlingKingSn8ke/DSPi/releases/tag/windows-preview-2026-11-21) and extract the entire folder. Keep `DSPi Setup.exe`, `PowerShell-runtime.zip`, and the `Console` folder together.
2. Open **DSPi Setup.exe**, select the output your Windows apps will use, and choose **Attach and open Console**.
3. Approve the Windows administrator prompt. Setup briefly restarts Windows Audio and opens the Console. The tested install path needs no PC reboot.
4. In Windows Sound settings, route playback to the selected device. Play audio and check the Console meters or spectrum display. For a quick check, try a gentle EQ cut and toggle **Bypass**.

Setup bundles the APO and the required PowerShell runtime. It offers active physical speaker outputs with an available effects configuration. Outputs with existing effects may be ineligible. Closing the Console leaves the APO and last applied settings active.

## What you can adjust

- Independent input and output EQ, input preamp, delay, channel routing, linked output pairs, and crossovers.
- Loudness compensation, headphone crossfeed, volume levelling, limiting, tube modelling, psychoacoustic bass, subharmonics, and stereo upmix where the output layout allows it.
- Named presets, quick recall, per-output startup presets, and preset import/export.
- Real-time spectrum and RTA, plus a signal generator for tones, noise, sweeps, and channel checks.

Start with a low level when using the signal generator. A stereo Windows output carries two physical channels. Separate centre, surround, or subwoofer signals require an output that exposes those channels to Windows.

## How it works

```text
Windows apps → Windows shared audio engine → DSPi APO → selected playback output
                                                ↑
                                    Console settings and presets
```

The APO (Audio Processing Object) loads inside the Windows audio engine for the selected output and uses DSP routines adapted from the [Weeb Labs DSPi firmware](https://github.com/WeebLabs/DSPi). The Console saves settings for that endpoint and reads live processing data. During playback, the APO crossfades compatible settings with a fixed processing delay of about 7 ms. Windows volume is used to calculate the loudness curve without applying the Windows gain a second time. At lower listening levels, the curve adds more low-frequency compensation.

Applications that use exclusive playback or a path outside the Windows shared audio engine can bypass the effect.

## Bypass or remove

- Choose **Bypass** in the Console to temporarily bypass DSPi processing.
- For an output attached by Setup, open **DSPi Setup.exe**, select the same output, and choose **Remove DSPi**. Setup uses the saved recovery record to restore the prior endpoint state and restarts Windows Audio.

If you hear audio but see no meters, confirm that Windows and the Console point to the same output and that the app uses shared playback. If Setup does not offer an output, it may already have audio effects or may not be an active physical speaker output.

## Build and test from source

The folders in this directory must sit alongside each other. Use x64 Windows, PowerShell 7, the .NET 8 SDK with the Windows build tools required by WinUI, and Zig 0.15.2.

```powershell
Push-Location .\DSPi-Software-DSP
.\build.ps1 -Compiler 'C:\path\to\zig.exe'
.\scripts\build-apo.ps1 -Compiler 'C:\path\to\zig.exe'
Pop-Location

dotnet publish .\DSPi-Console-Windows\DSPiConsole\DSPiConsole.csproj -c Release -r win-x64 --self-contained true -p:Platform=x64 -p:PublishProfile= -o .\out\Console
```

The native build generates the engine used by the Console. The APO build also runs the Windows COM and DSP harness. An optional input WAV can be passed to the APO harness via `-SampleFile`.

To build Setup, place the official x64 PowerShell ZIP expected by `Bootstrap.ps1` in the Setup project as `PowerShell-runtime.zip`. The preview uses PowerShell 7.6.9. The archive checksum must match the value pinned in the bootstrap. If you produce a different APO binary, update the approved APO hash in `Admin.ps1` and add the new hash to `Worker.ps1` before publishing. [PowerShell 7.6.9 official downloads](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.9)

```powershell
dotnet publish .\DSPi-Console-Windows\Setup\DSPi.EndpointSetup\DSPi.EndpointSetup.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableSingleFileAnalyzer=false -p:IncludeNativeLibrariesForSelfExtract=true -o .\out
```

The local preview was tested with the Weeb Labs DSPi USB output and TOPPING DX5 II. The Weeb Labs live check measured the change in the 80 Hz loudness boost as Windows volume moved, and the bundled registration and recovery path was verified in an isolated test.

## Credits and licence

This Windows port uses the open-source [DSPi Console for Windows](https://github.com/WeebLabs/DSPi-Console-Windows) and [DSPi firmware](https://github.com/WeebLabs/DSPi). See the licence files included with the [Console](DSPi-Console-Windows/LICENSE) and [engine](DSPi-Software-DSP/LICENSE) and the engine’s [upstream source record](DSPi-Software-DSP/vendor/dspi/UPSTREAM.md).
