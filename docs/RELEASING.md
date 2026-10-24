# Releasing

Two scripts build what ships: the iPhone app for TestFlight and the App Store, and the Mac
app as a notarized DMG for people to download. Both read `Config/Release.xcconfig`, which is
git-ignored so no team ID ends up in the repo.

## Once per Mac

1. Sign in to the shipping Apple account in Xcode › Settings › Accounts.
2. `cp Config/Release.example.xcconfig Config/Release.xcconfig` and fill in the Team ID and the
   bundle ID prefix (`app.pocketdesk` for the official builds).
3. Get an App Store Connect API key: App Store Connect › Users and Access › Integrations ›
   Team Keys (the account holder makes it, with the Developer role or higher). Put the
   downloaded `AuthKey_<id>.p8` in `~/.appstoreconnect/private_keys/` (`chmod 600`), and its key
   ID and the Issuer ID in `Config/Release.xcconfig`. The scripts sign and upload with it.
4. Store it for notarization too:

   ```sh
   xcrun notarytool store-credentials pocketdesk-notary --key ~/.appstoreconnect/private_keys/AuthKey_<id>.p8 \
       --key-id <id> --issuer <issuer-id>
   ```

   (An Apple ID with an app-specific password also works, but only the team's account holder
   can notarize that way on an individual team.)

## Once per app

Create the iPhone app in [App Store Connect](https://appstoreconnect.apple.com) › Apps › New App:
platform iOS, name PocketDesk, bundle ID `<prefix>.app` (Xcode registers it on the first
archive, so it's in the list), and any SKU. Uploads fail with "Error Downloading App
Information" until this exists.

## Every release

```sh
scripts/release-ios.sh   # archive, sign and upload to App Store Connect for TestFlight
scripts/release-mac.sh   # archive, sign with Developer ID, DMG, notarize and staple
```

- The version is `MARKETING_VERSION` in `project.yml`. The build number is the commit count on
  the current branch, so every commit gives a higher build, as TestFlight requires.
- `release-ios.sh --no-upload` exports the signed build without sending it anywhere.
- `release-mac.sh --no-notarize` stops after signing, for checking the DMG.
- Everything lands in `.build/release/`. The Mac DMG is
  `PocketDesk-<version>-<build>.dmg`.
- Publish the DMG as a GitHub release, uploaded as `PocketDesk.dmg`. The website's Download
  buttons link to `releases/latest/download/PocketDesk.dmg`, so that name has to stay the same:

  ```sh
  cp .build/release/PocketDesk-<version>-<build>.dmg /tmp/PocketDesk.dmg
  gh release create v<version> /tmp/PocketDesk.dmg --title "PocketDesk <version>" --notes "…"
  ```

## What gets signed how

| | Identifier | Signed with |
|---|---|---|
| iPhone app | `<prefix>.app` | Apple Distribution (Xcode manages it) |
| Widgets, share extension | `<prefix>.app.widgets`, `<prefix>.app.share` | Same |
| App group | `group.<prefix>.app` | Registered by Xcode |
| Mac app | `<prefix>.host` | Developer ID Application, hardened runtime |
| Now Playing helper | inside the Mac app | Developer ID Application |

The Mac app is not sandboxed: it posts input events and reads the screen, which needs
Accessibility and Screen Recording. That's why it ships outside the Mac App Store.
