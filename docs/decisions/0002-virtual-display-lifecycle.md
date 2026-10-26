# Virtual display lifecycle — Phase 1

Status: implemented for #53, following #52 / PR #58.

## Ownership and integration

`VirtualDisplayService` in PDHostCore owns one ephemeral display for one authenticated,
approved, streaming connection. Creation is an explicit Mac-owner action; registration,
pairing, catalog requests and reconnecting do not allocate a display. The persisted Mac
capability defaults off. Enabling it does not create a display. The Mac panel lists the
owner and exposes cancellation, End and retry after failed cleanup.

An actor reservation serializes allocation and teardown across suspension points. A stable
logical identity hashes the host UUID and paired peer fingerprint. It is separate from the
lease UUID, backend resource UUID and transient capture ID. Disconnect, revocation,
disable, sleep, cancellation and shutdown invalidate pending requests; late completion
rolls back before another request may begin. A revoked peer cannot register again until
explicitly paired again. UI snapshots carry revisions so delayed events cannot restore
older state.

The C bridge is now `PDVirtualDisplayRuntime`, conditionally linked by the Mac host only;
this supersedes Phase 0's probe-only linkage. The probe uses the same bridge. Runtime ABI
checks remain. Each allocation receives a monotonic process-local token; only that token
can release its retained native object. There is no startup scan or deletion by display
name, vendor ID or persisted capture ID. Process exit releases native references, as
qualified by Phase 0's termination tests. A failed rollback returns its owned resource to
the service and remains visible/retryable, blocking replacement until cleanup succeeds.

Before teardown, active captures of the owned screen return to the physical main display.
If fallback fails, the connection closes. Other connections cannot pick the leased display.
Each native connection now has its own input injector/coordinate frame. This lease controls
resource lifetime and picker access; it does not make separate security desktops for
already trusted Mac-control peers.

No wire changes: protocol 22 and the existing display picker are sufficient for Mac-created
screens. Phone creation and richer workspace controls remain Phase 2 work.

## Qualified mode and safety limits

Phase 1 accepts only 1280×800 at 1× with a requested 60 Hz mode. Creation checks active
inventory, pixel dimensions, mirroring, primary selection, and existing screen bounds/modes.
Unexpected state rolls back only the owned display and reports an error. It never sets a
physical display's mode, origin or primary designation.

A 1920×1080 experiment was rejected: macOS moved the existing secondary display's origin
from x=1440 to x=3360 during allocation. The larger preset was removed instead of accepting
that layout change. Future modes need their own native qualification. macOS can transiently
rearrange screens during allocation before rollback; the service cannot promise private API
behavior on every OS or topology. There is no physical screen blanking, Retina, closed-lid,
Intel, multiple concurrent workspace or headless guarantee.

## Verification

See `docs/evidence/virtual-display-phase-1.json`. The opt-in native test uses the actual
backend and isolated in-memory authorization, not the user's capability preference. It
creates/removes the supported mode three times, checks inventory restoration and stable
logical identity, and verifies a stale lease cannot end the next allocation. A missing
CGDisplayMode object uses CoreGraphics pixel-size queries; refresh is checked only when
macOS reports it. The requested refresh rate is not a measured capture frame rate.

Reproduce the native check separately from other screen tests:

```sh
POCKETDESK_VIRTUAL_DISPLAY_NATIVE=1 swift test --package-path Packages/PocketDeskKit \
  --scratch-path .build/relay-tests --filter VirtualDisplayNativeTests
```

Lifecycle tests inject overlap, cancellation, disconnect, revocation, shutdown, partial
failure, cleanup failure, unsupported runtime, invalid modes and stale snapshots. Loopback
session tests verify authorization, owner filtering and physical fallback before removal.
The connection test exercises independent input frames over real local QUIC.
