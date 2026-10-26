# Virtual display Phase 2 validation

Date: 2026-10-27 (Africa/Lagos). Base: merged Phase 1 / PR #59 (`54b1989`).
Internal/beta milestone for #54, not a public-readiness qualification.

## Implemented flow

Displays → Virtual Display → Add Workspace requests an extra desktop over the existing
approved streaming connection. The Mac permission remains authoritative. The host negotiates
the qualified 1280×800 1× mode, automatically selects it, and reports requested/accepted mode,
actual capture geometry, stable identity, lease, owner and typed errors. The UI explains the
current mode limit instead of claiming a portrait/Retina desktop. End Workspace confirms
removal, returns capture to the main display and retains the authenticated connection.
Mac-local lifecycle changes are pushed to the phone. Physical-display selection stays usable
when creation is unavailable or denied. Returning to a physical display alone keeps the
workspace; ending it or disconnecting removes it.

Protocol 23 requires updating both apps together. The Mac runtime remains absent from the
signed iPhone binary. No TestFlight/public release was submitted.

## Results

- Signed macOS host build 85: passed, macOS 26.3 / Xcode 26.2.
- Signed iPhone build 85: passed, installed on paired iPhone 14 Pro.
- User tested Add Workspace and End Workspace on that real iPhone and answered “Both work”.
  This verifies the happy-path creation, streaming and return flow; it does not independently
  qualify every peripheral, audio route or thermal condition.
- arm64 iPad simulator build 85: passed; installed and launched on an iPad Pro 11-inch (M4)
  simulator, iOS 26.2. A physical iPad was unavailable; the user chose a simulator instead.
  The development bundle identifier was read from the built Info.plist before successful
  launch. Full hands-on iPad pairing/workspace/window use remains unverified. Computer-use
  screenshot/state capture timed out, so no rendered picker screenshot is claimed.
- 59 feature/protocol tests in 16 suites: passed. Includes wire round trips, bounded device
  requests, revisions/request correlation, connection reset, lifecycle races, catalog denial,
  owner authorization, stale end rejection and Mac-local end notifications.
- 18 real local QUIC HostService tests, run separately: passed.
- Loopback end-to-end tests run both iPhone and iPad viewports through actual HEVC encoding.
  They check a fresh keyframe/generation, negative-origin capture metadata/input frame,
  pointer/scroll delivery, committed text, clipboard, audio-generation configuration,
  workspace removal and a subsequent ping over the same connection. These use synthetic
  capture and are not substitutes for real-device audio/keyboard qualification.

The optional native display test was not rerun during the Phase 2 selection. Actual native
creation/removal was exercised by the user on iPhone and previously qualified in Phase 1.

## Reproduction and limits

```sh
swift test --package-path Packages/PocketDeskKit --scratch-path .build/relay-tests \
  --filter 'VirtualDisplay|DisplaySelection|PDProtocolTests'
swift test --package-path Packages/PocketDeskKit --scratch-path .build/relay-tests \
  --filter '^PDHostCoreTests.HostServiceTests/'
```

Build/test work initially hit disk exhaustion. Only regenerable compiler, index and old
build caches were cleared; release archives and unrelated working files were preserved.
The final builds above passed. A broader concurrent local test selection encountered
intermittent POSIX 57 QUIC disconnects, a desktop AVSampleBufferDisplayLayer that never
entered rendering, and a system Shortcuts negative test that did not throw. These are
recorded rather than represented as a passing full-suite run; the feature and isolated host
results above are the confirmed passing scope. CI must be assessed independently.

Local logs: `.build/virtual-display-phase2-feature-tests.log`,
`.build/virtual-display-phase2-host-tests.log`, `.build/virtual-display-phase2-regression.log`,
and `.build/virtual-display-phase2-{host,ios,sim}-build.log`.

Remaining manual qualification: a complete iPad session with a window moved onto the new
workspace, external keyboard/trackpad/clipboard/audio on each device, and the recovery matrix.
Retina sizing, rotation-following desktops and performance/power measurements remain Phase 3.
Physical displays are not hidden; closed-lid/headless use is not promised.
