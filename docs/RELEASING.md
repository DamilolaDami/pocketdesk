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

### Prepare the notes once

The files in `releases/*.json` are the shared source for the website and GitHub notes.
The Releases page imports them automatically; no JSX edits or manual latest-version labels
are needed. Create an entry from the repo root:

```sh
node scripts/releases.mjs new                  # current project version and commit count
node scripts/releases.mjs new 1.0 75           # or an explicit archive version/build
```

This creates a **draft**, hidden from the website. Fill in `title`, `summary` and
`changes` in the new JSON file. Each change has `platform` (`mac` or `iphone`), `title`
and `text`; see `releases/1-0-74.json` for a complete example. Use the build number
from the archive you actually ship: another commit changes the scripts' next build number.
The command refuses to overwrite an existing entry.

### Build and publish the apps

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
  node scripts/releases.mjs notes <release-id> > /tmp/pocketdesk-release-notes.md
  gh release create v<tag-version> /tmp/PocketDesk.dmg --title "PocketDesk <version>" --notes-file /tmp/pocketdesk-release-notes.md
  ```

### Publish the website entry

After verifying the download, set `macURL` to the versioned GitHub DMG URL and `source`
to the GitHub release page. Keep the `PocketDesk.dmg` asset name. For iPhone changes,
set `iphoneStatus` to `awaiting-review` until Apple approves the build and it is added
to the public beta, then change it to `available`. The website shows the pending status;
the public TestFlight link can still serve the previously approved build.

Change `status` from `draft` to `published` when the notes are ready to be public, then run:

```sh
node scripts/releases.mjs check
npm --prefix site test
npm --prefix site run build
```

Commit the release JSON file and push to `main`. The Website workflow now watches
`releases/**` as well as `site/**`, so a notes-only edit redeploys the page. It validates
metadata before building. Public entries appear newest first by date and numeric build;
the Mac download comes from the newest entry with a Mac download, even for iPhone-only
updates. Dates use `YYYY-MM-DD`; the draft command uses Africa/Lagos time.

This automates notes reuse and website updates. Signing, notarization, GitHub publication
and Apple's public-beta approval still use the steps above; the JSON does not query Apple
or assert that an uploaded artifact is ready by itself.

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
