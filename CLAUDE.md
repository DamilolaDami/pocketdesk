# CLAUDE.md

PocketDesk: a macOS host and an iOS client for using your Mac from your phone. Read
`docs/ARCHITECTURE.md` before any structural change.

## Rules
- Apps (`Apps/*`) stay thin. All logic goes in `Packages/PocketDeskKit`.
- `PDProtocol` imports no Apple frameworks. Bump `protocolVersion` on any wire change.
- Side effects go in actors, UI state in one `@MainActor @Observable` store per app, and
  transitions in pure reducers with tests.
- Never send per-frame data through an observable store.
- Swift 6 strict concurrency, with no `@unchecked Sendable` unless there's a comment on why.
- Tests use Swift Testing (`import Testing`), not XCTest.
- Never commit the generated `.xcodeproj`. Edit `project.yml`.
- Open source: nothing secret in the repo (no team IDs, keys, certificates). Security must
  hold with the code public. Read the Security section of `docs/ARCHITECTURE.md` before
  touching `PDSecurity` or the TLS setup in `PDTransport`.

## Verify
- `cd Packages/PocketDeskKit && xcodebuild test -scheme PocketDeskKit-Package -destination 'platform=macOS' -derivedDataPath ../../.build/xcode`
  (shares the apps' build tree; `swift test` also works but builds everything a second time). Tests touch the real login keychain
  (labels `com.pocketdesk.tests.*`, always deleted afterwards), use QUIC on 127.0.0.1 and
  Bonjour. Screen-capture tests run only if the process has Screen Recording permission.
- `xcodegen && xcodebuild -scheme PocketDesk -destination 'generic/platform=iOS Simulator' build`
- Run the Mac host signed with a stable identity, e.g. `CODE_SIGN_IDENTITY="<your Apple Development
  cert>" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""` (see Gotchas in `docs/ARCHITECTURE.md`).
- In zsh `log` is a builtin: read system logs with `/usr/bin/log show`.
