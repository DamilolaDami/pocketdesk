# Bounded workspace sizing and stream generations

Phase 3 of #27 / #55, based on merged Phase 2 (#60).

Logical desktop size, backing sharpness and encoded stream resolution are independent.
The qualified catalogue is deliberately small: 1024×768, 1280×800 and 1280×960, plus
portrait counterparts. Landscape supports 1×/2× and portrait supports 2×, all at 30/60 Hz.
That is 18 combinations, at most 2560 pixels per side and 4,915,200 backing pixels. Four
NV12 capture buffers at that area are nominally about 29.5 MB; this is not a total GPU/process
memory bound. Decoder, encoder, renderer and OS allocations are measured separately.

## Native selection and ownership

The existing runtime bridge owns the native object under an exact process token. No helper
app/library dependency was added. Logical identity, lease UUID, resource UUID and capture ID
survive successful reconfiguration. The actor reserves the complete pause/apply/restore/resume
operation; disconnect, revoke, disable, cancellation and shutdown cannot be overtaken.

Experiments showed that mixed landscape/portrait mode tables contain unusable portrait GUI
modes. A bounded table is now published for the requested orientation, and retained while
switching sizes, backing scale or refresh within that orientation. An orientation transition
replaces the bounded table on the same object; the existing display is never removed/recreated.
Mode selection polls for the real table/geometry, since WindowServer can publish asynchronously.
Physical bounds, resolution, mirroring and primary choice must still match the baseline.
Only the owned display receives mode selection. A failed change restores the previous table
and mode; an un-restorable object is released under the existing lifecycle with visible retry
if cleanup fails. The bridge never sweeps resources by name, vendor or old numeric IDs.

The signed NSApplication proof is authoritative for Retina validation: an unbundled test
runner can have stale AppKit screen caches. Pixel fallback now uses screen backing scale
and accounts for rotated bounds. Native proof captures real SCK frames at the accepted
backing dimensions, animating only its own scratch window for frame-rate measurement.

## Rotation, quality and input

The default desktop stays fixed. Follow Rotation is explicit and uses interface orientation,
not transient content size. A 450 ms debounce coalesces scene changes. The controller keeps
the latest desired mode during an outstanding request, then sends at most the next necessary
change after the host acknowledges. A rejected/timed-out request does not loop automatically.
The keyboard, split view, quality presets and weak links can change presentation/encoded
resolution without changing the logical Mac desktop. The stream FPS ceiling is the minimum
of mode limit, quality, adaptation and host limit; nothing offers 120 fps.

Protocol 24 also closes the old-input race across source changes. Configurations carry a
generation; pointer/scroll packets, reliable keyboard and committed text carry that same
generation. The client waits for a decoded keyframe before acknowledging readiness. The
host drops stale/unscoped input and releases held inputs before applying new coordinates.
The renderer rejects old configs/video/audio and flushes/reanchors the audio timebase.

## Evidence and remaining qualification

See `docs/evidence/virtual-display-phase-3.md`. The signed native matrix, negative-origin
loopback/HEVC tests, cancellation/rollback tests and paired device check serve different
purposes; synthetic tests are not presented as real-device thermal/power measurements.
The optional development trace records 120 seconds of local counters only when explicitly
launched with POCKETDESK_SIZING_TRACE=1. It contains no screen content, text, host names or
unique device identifiers and never uploads. Whole-machine GPU counters are labelled as such.

Private APIs remain experimental and Mac-only. No public readiness, Intel, headless,
closed-lid, constant 60 fps, or long-run battery/thermal guarantee follows from this change.
Requalification is needed after OS/hardware updates.

Sources consulted for API comparison:

- [Apple display mode selection](https://developer.apple.com/documentation/coregraphics/cgdisplaysetdisplaymode(_:_:_:))
- [Chromium virtual-display test helper](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm)
- [DeskPad mode setup](https://github.com/Stengo/DeskPad/blob/main/DeskPad/Frontend/Screen/ScreenViewController.swift)

No third-party implementation or private header was vendored. Runtime signature checks and
local native evidence take precedence over reference declarations.
