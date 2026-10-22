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

## Verify
- `cd Packages/PocketDeskKit && swift build && swift test`
- `xcodegen && xcodebuild -scheme PocketDesk -destination 'generic/platform=iOS Simulator' build`
