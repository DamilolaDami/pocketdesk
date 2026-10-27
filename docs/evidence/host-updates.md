# Sparkle and mobile-requested host updates

Development build 87, stream protocol 25, based on merged Phase 3.

- Signed Mac and iPhone builds succeeded. The Mac app embeds Sparkle 2.10.0 and passes
  `codesign --verify --deep --strict`. The iPhone dylib does not link Sparkle.
- Build 87 was installed/launched on the paired iPhone 14 Pro and matching Mac host.
  The user confirmed the mobile update screen opens and displays Mac version 1.1 (87),
  verifying the real-device authenticated maintenance status path.
- 79 Swift regression tests passed (host transport, update trust/approval, workspace
  lifecycle/input generations and sizing). An additional real-QUIC phone-client test
  passed afterward: status query → one install request → terminal status, with no capture.
- Maintenance tests prove an existing pairing is required, Mac approval is respected,
  the stable ALPN works when `pocketdesk/999` fails, and a wrong-version streaming hello
  remains rejected over the maintenance transport. A frozen JSON fixture protects the
  maintenance v1 envelope across future streaming protocol changes.
- Six publication-tool tests passed: actual archive metadata, wrong bundle/download URL,
  duplicate build rejection, prior-entry preservation/newest-first ordering and atomic
  failure handling. The real Sparkle signing tool verifies the committed empty feed;
  a modified copy fails verification. The bundled public key matches the release
  Keychain account. No private key was exported.
- Website tests (4) and production build passed; release shell syntax passed.

The initial signed feed is empty and was deployed by Website workflow 40476363647
following merge of PR #62. The public HTTPS endpoint returned 200, matched the committed
file byte-for-byte and passed Sparkle signature verification. The user confirmed a
fresh update check works after deployment.
No public app release, notarized updater ZIP, production app replacement or actual
Sparkle installation/relaunch was published/exercised in this change. That acceptance
requires the next signed/notarized release and versioned ZIP, followed by the documented
appcast publication process. Existing hosts without maintenance/Sparkle require one
manual bootstrap installation. macOS may require local authorization for unwritable
applications; updates do not bypass that requirement.

## Mac card menu follow-up

Build 88 on the paired iPhone 14 Pro isolates the menu and its content from live
playback/latency redraws, keys cards by persistent host UUID across rediscovery, and
limits list animations to actual identity changes. The menu trigger no longer replays
interactive glass effects. The user confirmed the menu remains stable while open and
the update check works. The iPhone build succeeded; three updater tests passed,
including actionable feed errors without masking signature validation failures.
