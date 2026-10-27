# Phase 3: sizing and rotation evidence

## Scope

Implementation for #55, based on merged Phase 2. Protocol 24 requires matching Mac
and mobile apps. Development build 86 contains the sizing controls and generation
barrier. This is experimental virtual-display support, not a public release claim.

## Signed native matrix

Hardware: MacBookPro17,1 (Apple M1), macOS 26.3 (25D125), built-in display awake and
unlocked. The signed NSApplication proof animated its own scratch window and captured
real ScreenCaptureKit frames. Run `PocketDeskDisplayProbe --sizing-matrix` from the
signed probe bundle produced by `scripts/build-virtual-display-probe.sh`.

All 18 catalogue combinations passed: landscape 1024×768, 1280×800 and 1280×960 at
1×/2×; portrait counterparts at 2×; each at 30/60 Hz. All changes retained one native
capture ID. Actual capture dimensions matched backing dimensions. Separate direct
portrait creation passed. Removing the owned display restored the exact physical
inventory, including main display, bounds, backing resolution and mirror state.

The maximum backing allocation is 2560×1920 (or its portrait transpose), 4,915,200
pixels. Four NV12 capture buffers nominally require 29.5 MB; other OS, codec and
renderer allocations are additional. No 120 fps mode is offered.

Each mode had approximately two seconds of animated capture. Observed 30 fps modes
provided 28.5–29.5 fps; 60 fps modes provided 31.0–37.2 fps. These are short capture
observations, not sustained end-to-end decoder/presentation frame-rate qualification.
Mode transitions took 176–697 ms. Where timestamps yielded valid capture-delivery
samples, per-mode mean delivery age was 1.1–10.1 ms, maximum 33.7 ms. This measures
capture delivery only, not glass-to-glass latency; missing samples remain absent.

Probe CPU was 10.1–17.9% of one core per mode and peak RSS was 56.2 MB. The overlapping
whole-machine GPU trace reported 5–42% device utilization. GPU counters include other
applications and WindowServer and cannot be attributed solely to PocketDesk. This
probe bypasses the network/encoder/client: it is not total production host CPU cost.
Raw mode measurements and sanitized GPU samples are in
[virtual-display-phase-3-native.json](virtual-display-phase-3-native.json).

## Automated coverage

47 focused Swift Testing tests passed, covering the bounded catalogue, wire encoding,
rotation opt-in, stale config/keyframe/input rejection, lifecycle cancellation,
rollback and ownership, UI report ordering, frame assembly and rate adaptation.
Real HEVC loopback sessions exercise each Best/Balanced/Battery Saver preset with
30/60 fps workspace limits, portrait Retina backing, negative display origins,
new-generation keyframes/audio and viewport-only stream changes. Viewport changes
must not invoke native display reconfiguration or recreate the resource.

The signed native probe is used for Retina geometry; an unbundled test runner's
AppKit display cache is not sufficient evidence for it.

## Build and device checks

Mac host, signed iPhone and arm64 iPad simulator builds succeeded. All 18 isolated
HostService QUIC regression tests also passed, in addition to the 47 focused tests.
The iPhone binary contains no CGVirtualDisplay/PDVDConfigure/MPDisplayMgr markers.
The iPad Pro 11-inch M4 simulator (iOS 26.2) installed and launched successfully;
its setup screen rendered. This is launch coverage, not a paired iPad session.

The final UI cleanup keeps the display picker compact: a workspace header, one
settings summary and workspace actions. Desktop size, picture and orientation
controls live on a dedicated Workspace Settings screen. Manual functional
confirmation below predates this presentation-only cleanup.

Development build 86 was installed and launched on the paired iPhone 14 Pro
(iPhone15,2), with the matching signed host running on the M1 MacBook Pro.
The user confirmed Retina on/off, Follow Device Rotation, typing and 30/60 fps
switching all work and the workspace remains usable. This is a manual functional
confirmation; it does not establish sustained frame rate or power use.

## Device qualification limits

The iPhone and iPad checks below must be distinguished from synthetic loopback and
native capture. Prior Phase 2 phone confirmation only covered Add/End Workspace.
It does not qualify Phase 3 rotation or Retina behavior.

Outstanding: full iPhone readability testing with every quality preset,
constrained-link end-to-end measurements, physical iPad,
long-duration mobile battery/thermal behavior and sustained 60 fps. iPad simulator
checks do not establish physical tablet power/performance. No headless, closed-lid,
Intel or other macOS version qualification is claimed.

For a bounded local mobile trace, launch a development app with
`POCKETDESK_SIZING_TRACE=1`. It records up to 120 one-second samples in app Documents
as `PocketDesk-Workspace-Performance.json`, including hardware model, accepted mode,
encoded size, received frame rate/bandwidth, control RTT, process CPU/peak RSS,
battery level, low-power and thermal state. No screen content or unique identifiers
are included and nothing uploads. `scripts/sample-host-performance.py` samples a
specified host PID and labels machine GPU counters separately.
