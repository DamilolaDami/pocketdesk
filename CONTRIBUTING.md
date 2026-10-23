# Contributing to PocketDesk

Thanks for helping. PocketDesk is a macOS host and an iOS client for using your Mac from your
phone. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before any structural change.

## What you need

- A Mac on macOS 26 with Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- To try it end to end: an iPhone on iOS 26 (or the iOS Simulator) on the same Wi-Fi as the Mac

## Build

The Xcode project is generated from `project.yml`. Never commit `PocketDesk.xcodeproj`.

```bash
xcodegen
open PocketDesk.xcodeproj
```

Or from the command line:

```bash
xcodebuild -scheme PocketDesk -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme PocketDeskHost -destination 'platform=macOS' build
```

### Signing the Mac host

Run the Mac host signed with a stable identity, such as your own Apple Development certificate.
Ad-hoc signatures change on every build, and macOS then asks for the keychain key again and
silently drops the Screen Recording permission. Pass the identity on the command line rather
than committing it:

```bash
xcodebuild -scheme PocketDeskHost -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" build
```

The host needs Screen Recording and Accessibility permission (System Settings › Privacy &
Security). The phone and the Mac must run the same protocol version (`protocolVersion` in
`PDProtocol`), so update both together.

## Test

All logic lives in `Packages/PocketDeskKit`, with tests in Swift Testing:

```bash
cd Packages/PocketDeskKit
xcodebuild test -scheme PocketDeskKit-Package -destination 'platform=macOS' -derivedDataPath ../../.build/xcode
```

`swift test` works too, but builds everything a second time. The tests:

- use the login keychain (items labelled `com.pocketdesk.tests.*`, always deleted afterwards)
- run QUIC on 127.0.0.1 and use Bonjour, so allow them through any firewall prompt
- skip the screen-capture tests unless the test runner has Screen Recording permission

CI runs the same tests and builds both apps on every push and pull request.

## Code rules

- Apps (`Apps/*`) stay thin. All logic goes in `Packages/PocketDeskKit`.
- `PDProtocol` imports no Apple frameworks. Bump `protocolVersion` on any wire change.
- Side effects go in actors, UI state in one `@MainActor @Observable` store per app, and
  transitions in pure reducers with tests.
- Never send per-frame data through an observable store.
- Swift 6 strict concurrency, with no `@unchecked Sendable` unless a comment says why.
- New behaviour comes with tests (`import Testing`, not XCTest).
- Match the surrounding code: naming, comment density, plain-English comments that say why.

## Security

PocketDesk is open source, so its security must hold with the code public. Nothing secret goes
in the repo: no team IDs, keys or certificates. Read the Security section of
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before touching `PDSecurity` or the TLS setup in
`PDTransport`. To report a vulnerability, see [SECURITY.md](SECURITY.md); don't open a public
issue.

## Pull requests

- One change per pull request, with a description of what it does and how you checked it.
- Link the issue it closes (`Closes #12`).
- CI must pass. Say what you tested by hand, especially on a real iPhone or Mac.

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
