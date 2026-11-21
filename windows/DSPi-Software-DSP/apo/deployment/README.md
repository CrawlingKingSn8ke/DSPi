# Deployment inspection, installation and recovery

Current status: the machine backend, protected journal and standalone recovery
are implemented and tested in an elevated isolated Windows fixture. See
`../../docs/standalone-apo-machine-backend.md`. The current unsigned package is
still refused before live machine writes. The inspection commands below remain
read-only; historical evidence is retained and is not a live-installation claim.

This is inspection tooling, not an installer. It opens registry keys read-only,
queries PnP and process identity, reads a candidate PE/signature/hash, and writes
one new JSON report to an explicit path below this staging repository's existing
`build` directory. It does not provision ProgramData, register COM, change endpoint
properties, adjust ACLs, change security policy, restart audio or alter the
installed Equalizer APO/Peace installation.

Run from PowerShell on Windows x64:

```powershell
./apo/deployment/Inspect-DspiDeployment.ps1 -DllPath ./build/dspi-apo.dll -OutputPath "$PWD/build/deployment-inspection-unique.json"
./tests/apo_deployment_test.ps1
```

An existing output is refused. Collection errors are evidence, never absence of
effects. `FxReadStatus=Read` includes a confirmed absent effects key; the report
retains the original `FxSnapshot.Status=Absent`. Any existing effects property
blocks this first package conservatively, including an occupied EFX slot.
`CandidateRequiresReview` never means installable. Display names are taken from
the friendly-name property when present, otherwise composed from device
description and interface-name properties; the exact full endpoint ID is always
the identity. Registry hardware/driver snapshots supplement PnP APIs when those
are denied; they do not prove the complete physical-parent relationship.

`Inspection.psm1` exposes pure `Get-DspiEndpointAssessment` and
`New-DspiInspectionReport` functions for fixtures. A fixture passed through
`-FixturePath` is JSON with `SchemaVersion: 1` and `Endpoints: []`; each endpoint
contains `EndpointId`, `FriendlyName`, `DeviceState`, `FxReadStatus`,
`FxProperties` (name/kind/value objects), `Properties`, `Pnp`, and nullable
`EnhancementsDisabled`. Fixture reports still inspect the supplied DLL and never
claim installation. Tests exercise empty/occupied/disabled/unreadable/inactive
judgements, strict endpoint/schema handling and destination guards without system
writes.

## Current inspection evidence

The 2026-11-04 v2 staging report observed Windows 10 Pro x64 build 19045.6466.
The TOPPING endpoint `{0.0.0.00000000}.{2483e5f7-5bf3-4646-8ab6-c57b2c3ca909}`
has no FxProperties key. Its hardware IDs are
`TUSBAUDIO_ENUM\VID_152A&PID_8750&REV_0231&KS` and
`TUSBAUDIO_ENUM\VID_152A&PID_8750&KS`; the driver is Topping
5.74.0.18449, `oem39.inf`, `_Install_0.NTamd64`. This is only an EFX candidate.
DSPi USB and NVIDIA monitor each have seven effects values; Realtek has 150.
Those endpoints require separate coexistence work and remain blocked. Existing
effects, Equalizer APO 1.4.2 and Peace must be preserved.

The staging DLL is x64 and unsigned. It was not installed. Hashes are snapshots
and become stale when the parallel native build changes the DLL. CIM/PnP access
was denied in the current session, and Get-Process observed no audiodg instance;
the actual audio process identity/token remains unverified. An observed
`DisableProtectedAudioDG=1` is not install permission or an acceptable trust fix.

## Package decision and remaining gates

For this Windows 10 19045 target, prepare a **SoftwareComponent** APO package
with a device-specific extension INF adding the component. Windows 11 uses the
separate AudioProcessingObject class. An EFX is an insertion point, while the
extension/component INF is its deployment mechanism; they are complementary.
The TOPPING third-party driver must be checked for extension targeting and
endpoint-property propagation. No reviewed INF/catalog or compatible signed
package exists yet. COM registration alone cannot prove attachment.

Microsoft references:

- [Deploying APOs: OS-specific package classes](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/deploying-audio-processing-objects)
- [Implementing APOs: component registration and protected environment constraints](https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/implementing-audio-processing-objects)
- [Audio processing architecture: EFX placement](https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/audio-processing-object-architecture)
- [Using an extension INF](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/using-an-extension-inf-file)

Before attachment, a separately reviewed installer must:

1. Obtain explicit target approval; re-check exact endpoint, hardware IDs,
   driver version/INF, property value names/types/bytes, key absence and SDDL.
2. Save typed registry backups including absence, endpoint/FX/enhancement state,
   relevant COM/AudioEngine/component registrations, installed package identity,
   binary paths/hashes/signatures and all ACLs the installer will change. This
   report is evidence, not an executable or complete restore backup.
3. Validate extension/component INF syntax/targeting/catalog trust and APO DLL
   signature/protected-audio load independently; never change test signing or
   protected-audio policy to bypass these gates.
4. Verify the real audiodg owner, restricted token and service/group SIDs. Plan
   administrator-owned binary/attachment data, installing-user profile writes,
   actual audio-identity profile reads and telemetry writes with no broad ACLs.
   Profile and telemetry now use separate directories: profile parent read-only
   for the audio identity, `telemetry/` writable by it. The actual process-token
   and restricted-SID access check is still required. Do not assume owner alone
   is sufficient, or grant broad directory write access.
5. Supply an administrator recovery command, scope restarts explicitly and log
   each DSPi-owned mutation with its before/after data. Restore only if current
   data still matches the DSPi-written data; stop on unrelated subsequent edits.
   Remove created keys/directories only when still DSPi-owned and empty; restore
   original absence/ACLs without touching Equalizer APO/Peace or OEM registrations.
6. Prove a signed DLL loads inside audiodg on the chosen endpoint, actual
   processing counters advance for ordinary shared-mode application audio, and
   bypass, Console close/reopen and rollback work. Saved files and harness tests
   are insufficient evidence.
