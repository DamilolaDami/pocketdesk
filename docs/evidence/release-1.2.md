# PocketDesk 1.2 (101)

Release source: `2785a2ddfc2271c373aa0064b822939988fddb74` on main.
The source CI run 40479457135 passed. Both app archives retain version 1.2 build 101,
regardless of subsequent release-page commits. App, widgets and share-extension bundle
versions were checked individually; the iPhone archive contains no Sparkle framework.

The iPhone upload succeeded and Apple processed the exact build as VALID. English
What to Test and review notes require Mac 1.2 and link to its versioned download.
Build 101 is associated with the existing beta_testers group, preserving all prior
builds/tester membership. Beta review was submitted and is WAITING_FOR_REVIEW; this
is not external availability. No App Store sale submission was made.

Mac app and DMG are Developer ID signed, notarized and stapled. Deep signature
verification, stapler validation and Gatekeeper assessment passed. The Sparkle ZIP
contains the same stapled app as PocketDesk.app with version 1.2 build 101, embedded
Sparkle and signed-feed enforcement. A staged appcast for its versioned ZIP is signed
and verified; the signed feed is published for the existing versioned ZIP.

Public release: https://github.com/DamilolaDami/pocketdesk/releases/tag/v1.2.0

Published assets were independently downloaded and matched local SHA256 values:

- PocketDesk.dmg: `8ef14986b43e01fa517da5824b1961db380167983c6939a9ef5d04e450d579de`
- PocketDesk-1.2-101-update.zip: `f563eab0a32e0a78e695a3b50da6e42f843e53b86078c0b4c294b8c4f4804034`

The owner explicitly requested shipping the 1.2 page without review-status labels.
The Mac release is stable/latest and its signed Sparkle feed is published. The page
uses generic TestFlight beta links without claiming external 1.2 availability.
The recorded Apple state above remains the actual state at publication; no availability
field was falsified. The user chose to report Apple approval manually; no release watcher
was created or restarted.
