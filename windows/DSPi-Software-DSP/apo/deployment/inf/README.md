# Unsigned APO package engineering review

These sources prepare a Windows 10 x64 workstation SoftwareComponent and separate
USB Extension package. They are **unsigned, unvalidated and not installable**.
No install, signing, registry, file-permission, service or security-policy action
is provided. Preparation only writes a new child folder of this project's build/.
The catalog references describe future required artifacts; no catalog is supplied.
PETrust=true retains the protected-audio trust requirement; it does not confer trust.

Run scripts/build-apo-package.ps1 with the selected target plan. Output contains
component/ (DLL and component INF), extension/ (profile-specific extension INF),
manifest.json, target-evidence.json, source licenses and provenance. Review file
hashes against the manifest. Hashes provide integrity bookkeeping, not authenticity.
DLL registration mirrors native version 0.1, flags 0xE, one input/output connection,
unlimited instances, and four public APO interfaces. The private isolated-test
control interface is intentionally not in the registration interface list.
Driver-store DIRID 13 supersedes the older plan's ProgramFiles binary proposal.

Models are bounded by x64 workstation build 19041 and an empty closest-match build
22000 section. Windows 11 is excluded; older Windows 10 is not claimed supported.
The floor is a deliberately narrow review target, not a compatibility certification.

Only USB VID_2E8B/PID_FEAA function MI_00 hardware IDs are matched. A hardware ID is
model-wide: the package cannot distinguish the selected unit by endpoint hash,
serial, or instance. The endpoint hash embedded in the extension is specific to
this machine's selected endpoint and must never be shipped as a generic default.

Read-only COM topology and SetupAPI confirm the selected speaker reaches the
recorded KSCATEGORY_AUDIO GLOBAL interface and its speaker connector subtype.
Existing effects come from MSFX/0; no FX/0 exists yet. The new FX/0 uses the observed
specific speaker association and carries the exact inspected Windows SFX/MFX,
mode sets and UI metadata forward. It does not modify any MSFX key. The builder
requires matching mapping/source-store evidence and rejects changed Windows values.
Runtime coexistence and complete endpoint/unit scope remain unproven; current
single-interface evidence is not a model-wide installation guarantee.

The store includes the Windows chain above plus EFX CLSID, EFX DEFAULT modes and
the DSPi profile key. FX stores outrank inbox MSFX stores as a whole; merely leaving
MSFX values present would not preserve the active chain. NOCLOBBER does not provide
atomic installation or conflict-aware recovery. Endpoint friendly names are not
changed. Recheck source values and destination absence before future installation;
EFX and all original effects still need to be tested together.

The original review bundle records WDK checks as NotRun. Run
`scripts/validate-apo-package.ps1 -ToolsRoot <tools> -PackageRoot <review>` to create
a separate WDK-checked copy with unsigned catalogs; its report does not promote it
to installable. `scripts/get-wdk-validation-tools.ps1` caches pinned Microsoft
NuGet tools locally and verifies package hash/signature; it installs no SDK.

Blocking review gates include validation of the particular artifact, full interface
association and endpoint scope, trusted DLL plus signed catalogs accepted by the
protected audio process, profile/telemetry permission provisioning, conflict-aware
recovery and actual audiodg load/processing evidence. No certificate is bundled.
No change to protected audio, test signing or other security policy is proposed.
An enabled AudioSrv SID token observation does not itself provision file access.

## Provenance and licenses

INF patterns were adapted from the two Microsoft SYSVAD samples retained unchanged
in provenance/. Retrieved 2026-11-17 from:

- https://raw.githubusercontent.com/microsoft/Windows-driver-samples/main/audio/sysvad/TabletAudioSample/ComponentizedApoSample.inx
- https://raw.githubusercontent.com/microsoft/Windows-driver-samples/main/audio/sysvad/TabletAudioSample/ComponentizedAudioSampleExtension.inx
- https://raw.githubusercontent.com/microsoft/Windows-driver-samples/main/LICENSE

The repository's actual upstream license is Microsoft Public License (MS-PL),
Copyright (c) 2015 Microsoft; its full text accompanies these derived INF sources.
They are not labelled MIT. The original templates are provenance only and must
never be installed. DSPi DLL and preparation scripts remain GPL-3.0 under the
project LICENSE. Distribution-license review remains required before shipping.

Official component-class and model-decoration references:
https://learn.microsoft.com/en-us/windows-hardware/drivers/install/using-a-component-inf-file
https://learn.microsoft.com/en-us/windows-hardware/drivers/install/inf-manufacturer-section
