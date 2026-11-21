# Standalone native APO core

Development module, not installed in the Windows audio engine. No registry or endpoint registration is performed by its build/test scripts.

Build the existing engine first, then run `scripts/build-apo.ps1 -Compiler <zig.exe> -SampleFile <sample-12s.wav>`. The native COM harness loads `build/dspi-apo.dll` directly and compares DSP output to the existing engine. It opens no audio device.

The private SetRecipe interface is for the isolated harness and only accepts configuration while unlocked. Cross-process profiles, native-worker telemetry and live Console controls are implemented below. Installation/trust and real audiodg validation remain outstanding. The COM entry points are DllGetClassObject and DllCanUnloadNow; the embedded host API is also exported. There is no self-registration function.

`scripts/get-apo-headers.ps1` retrieves two unchanged Microsoft SDK interface headers to ignored `build/windows-sdk`, with a pinned source revision and SHA256 checks. Their original SDK terms apply; Microsoft explicitly says its win32metadata repository license does not relicense original SDK headers. They are local build inputs and are not copied into the source/distribution package. Source: https://github.com/microsoft/win32metadata/blob/043261f38d94d53b2438b0ffadb836f194c34a73/LICENSE

Processing uses Windows' negotiated float32 rate/channel format. It adds no sample-rate conversion. GetLatency reports common algorithmic lookahead (input adapter/leveller plus limiter), excluding intentional per-channel alignment delays. Reset requests are consumed at the next processing callback using preallocated state. Setup, unlock and release must be serialized by the host against audio callbacks, as with other non-real-time lifetime operations.

## Live profile worker (unregistered harness supported)

A locked, bound instance polls `<ProgramData>/DSPi/Profiles/<key>/profile.bin`
every 50 ms on its worker. The key comes only from `VT_LPWSTR` property
`{67fe7ad1-1232-4c16-94ce-83a4f63be981},1` and must be lowercase 64-hex.
The worker never creates directories. Unbound instances have no worker.
The private harness interface appends `BindProfile(root,key)` after `SetRecipe`;
call before LockForProcess to use a test directory. This is not an IPC server.

The fixed 64-byte profile / 192-byte status format is specified in
`docs/superpowers/plans/2026-11-04-standalone-apo-live-control.md`. CRC, exact
length, UTF-8, token bounds, recipe NUL/trailing newline, reserved bytes and
physical format are validated before graph preparation. A full saved profile
is loaded at lock; same-latency edits warm/fade live. A latency-changing edit
stays pending until a new lock and leaves existing audio active.

`acceptedRevision` means submitted, while `appliedRevision` comes from the
runtime atomic updated when the audio caller actually switches graphs.
Heartbeat advances without processing; `lastProcessed` advances only when
processed frame count changes. Each instance has its own atomically replaced
status file, and publishes a final stopped state before worker join.
Status files live in `<profile-directory>/telemetry/` so the eventual installer
can grant the audio process profile-read access and separate telemetry-write
access. Neither worker nor client provisions these directories automatically.
`UnlockForProcess` requires processing stopped, then joins the worker before
destroying its runtime. Reset requests are consumed by the runtime's audio
caller and reset only runtime-owned active/candidate graphs, without retaining
a borrowed graph pointer across retirement.

Run `scripts/build-apo.ps1 -Compiler <zig.exe>` for real unregistered COM/live
worker tests, or pass `-SampleFile <PCM16 stereo WAV>` for sample reference
comparison. These tests do not attach an endpoint, restart audio, register COM,
or modify device/security settings.

The Console menu is **Processing Backend → Windows Audio (standalone APO)**.
It lists real active playback devices, connects to provisioned endpoint profiles,
forwards the existing controls and presets, and reads meters from native
telemetry. Saved or connected controls are not presented as proof of audio
processing. Closing the Console does not remove the saved endpoint profile.

Run `scripts/verify-standalone-apo.ps1 -Compiler <zig.exe> -SampleFile <sample>`
for native, managed, existing Console and separate-process bridge tests. The
bridge starts a headless native COM host, edits settings through the actual
Console backend and verifies processed samples and meters; it is not audiodg.
