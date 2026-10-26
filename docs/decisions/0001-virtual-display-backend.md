# Virtual-display backend: Phase 0 decision

Date: 2026-10-26. Tracks #52; part of #27.

## Decision

**Go for the isolated Phase 1 host service, using an experimental CoreGraphics runtime
backend with explicit capability/ABI checks. No go for a generally supported public feature
yet.** The experiment proves one configuration, not an Apple-supported API or fleet-wide
compatibility. Neither PocketDesk app links the prototype product.

We identified no documented display-creation API in the checked public CoreGraphics and
ScreenCaptureKit SDK headers or Apple material. ScreenCaptureKit captures existing sources;
it does not provide this prototype's display-creation mechanism. DriverKit's documented
device families do not establish a suitable virtual framebuffer API/entitlement. Do not
build a plan around an assumed DisplayDriverKit entitlement.

The isolated backend discovers four undocumented CoreGraphics classes at runtime. It checks
the signatures of every nonstandard message it sends, bounds the mode, retains one owned
display, and releases it explicitly. Missing classes or mismatched signatures disable the
backend. These checks cannot guarantee the semantics of an undocumented API across updates.

## Why not depend on DeskPad?

DeskPad is useful primary-source prior art, not a PocketDesk dependency. Its repository was
not archived when checked, but its latest release was v1.3.2 (2024-10-04), and its latest
commits were dated 2026-02-28. Its license is MIT. No DeskPad source or private header is
vendored here; this bridge was written independently from runtime inspection and API behavior.
Any future code reuse must preserve the applicable license/copyright notices.

The investigation found an actual header/runtime difference: DeskPad's reference header
declares mode width/height as `NSUInteger` (64-bit here), while this Mac reports
`@32@0:8I16I20d24`: two unsigned 32-bit dimensions and a double refresh rate. Our first
guard rejected the mismatch before creation and successfully captured the existing display
as fallback. The probe now explicitly checks the measured 32-bit signature. This is why an
old sample compiling is insufficient compatibility evidence.

## Native evidence and qualified configuration

[Committed evidence](../evidence/virtual-display-phase-0.json) records results from the exact
Developer ID-signed, notarized app bundle:

- Apple M1, MacBookPro17,1; macOS 26.3, build 25D125; Xcode 26.2/Swift 6.2.3.
- Two pre-existing displays: built-in 1440×900 points / 2880×1800 backing pixels, and a
  second non-built-in 2048×858 display. No claims about that second display's hardware type.
- Three create/capture/input/remove cycles, each requesting a 1280×800, 1×, 60 Hz SDR mode.
  The existing capture engine delivered 1280×800 buffers with a configured 30 fps ceiling.
  This is a first-frame/mode proof, not a sustained 30/60 fps performance benchmark.
- Every cycle extended the desktop without mirroring or making the new display primary.
  A scratch window moved onto the new display; normalized input through the existing
  InputInjector hit its button exactly once; release removed the display and rehomed the window.
- Both SIGTERM and SIGKILL were tested with ScreenCaptureKit active. A separate process's
  scratch window survived its display owner and became visible on a pre-existing display.
- A simulated unavailable backend created no display and retained ordinary display capture.
- Original display IDs, geometry, backing sizes, mirroring and primary selection matched
  the baseline after cleanup. No user-owned windows were moved or inspected by the probe.

The capture engine intentionally excludes its own app windows. The scratch-window check
establishes placement and event delivery; the capture check establishes frames from the
selected virtual display. This does not claim a pixel comparison of that scratch window.

Unqualified: other OS builds, Intel Macs, other Apple Silicon models, Retina modes, HDR,
120 Hz, monitorless boot/login, closed-lid behavior, Spaces/full-screen/custom app window
recovery, and sleep/wake. These remain explicit Phase 1–4/5 qualification work, not supported
product promises. Removing one ordinary scratch window safely does not prove every app's
window restoration behavior.

## Signing and distribution

The probe uses the existing release team's Developer ID Application signing and hardened
runtime configuration. Apple's notarization service accepted submission
`09e8ca65-388a-42b6-ab7f-ba1345df77e3`; stapling and ticket validation succeeded, and
Gatekeeper assessment returned `accepted`, `source=Notarized Developer ID`.

Notarization acceptance is malware/signing-distribution evidence, not API support or App
Store approval. App Review guideline 2.5.1 requires public APIs. The private backend must
stay out of the iPhone app and is unsuitable for a public-API-only Mac App Store build.
PocketDesk's existing direct/notarized Mac distribution is the route qualified here.
The prototype was not uploaded to App Store Connect or published as an app release.

Normal signed Mac and iPhone builds succeeded after the package change. Their executables
contain neither `PDVDCreate` nor the backend's descriptor class name. The app dependency
graphs do not include the developer executable or its C bridge.

## Reproduce

Build/sign locally; identities and credentials stay in environment/Keychain, not source:

```sh
export PD_PROBE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
bash scripts/build-virtual-display-probe.sh
python3 scripts/virtual-display-proof.py \
  --binary .build/virtual-display-proof/package/PocketDeskDisplayProbe.app/Contents/MacOS/PDVirtualDisplayProbe \
  --out .build/virtual-display-proof/local
```

Add `--notarize` to the build script only when testing distribution, with
`PD_PROBE_NOTARY_PROFILE` set to an existing notarytool Keychain profile. The ordinary build
does not submit anything. The scripts create temporary displays and manipulate only
probe-owned scratch windows/processes. They never request permissions programmatically;
Screen Recording and Accessibility must already be granted to the execution context.

The supervisor has bounded waits, terminates its own helper/owner in failure paths, and
records intermediate/final inventories. The backend's global handle is confined to the
probe actor's calls. This is deliberately not the production concurrency/lease design.

## Phase 1 requirements carried forward

Use a host-owned service with stable logical identity, scoped session leases, explicit Mac
authorization, generation-safe teardown and error rollback. Avoid accumulating per-run
display identities in production. Keep a reliable physical-display fallback and never
change physical display modes/primary selection as a side effect. Preserve the capability
gate and repeat OS/hardware qualification after updates. Do not expose this developer probe
as the phone's virtual-display feature.

## Sources

- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Apple DriverKit](https://developer.apple.com/documentation/driverkit)
- [App Review guideline 2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements)
- [DeskPad repository](https://github.com/Stengo/DeskPad), commit `c3349f0e`
- [Reference header](https://github.com/Stengo/DeskPad/blob/c3349f0e/DeskPad/CGVirtualDisplayPrivate.h)
- [DeskPad MIT license](https://github.com/Stengo/DeskPad/blob/c3349f0e/LICENSE.md)
