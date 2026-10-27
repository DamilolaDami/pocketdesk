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

## Now Playing production push acceptance (#39)

Deploy the updated relay before distributing a Mac that sends push priority. Protocol 21
requires updating both native apps. Release builds use `.production`; only `DEBUG` sets
`.sandbox` in `AppModel`. The relay routes production pushes to `api.push.apple.com`.

After `scripts/release-ios.sh --no-upload`, verify the exported IPA (the archive may still
have development entitlements before export):

```sh
scripts/verify-ios-push.sh .build/release/iOS-<build>/PocketDesk.ipa
```

The normal release script uploads to TestFlight. On a real phone using that processed build,
register with the updated Mac, close PocketDesk, then verify start, next-track update, end,
and swipe-away/pause-for-20-seconds/resume. Verify progress moves with no track-time pushes,
pause freezes it, a seek moves it, and sleeping the Mac ends it. Repeat with Show Details in
Pushes off and confirm only the generic title appears until the phone reconnects. Inspect
host `push` logs for delivery status without logging tokens or media details.

Record the build, device/iOS version, APNs environment and any sandbox differences here.
These device checks cannot be established by package tests, simulator builds, or entitlement
inspection. Item 3 (terminated-app media buttons) is excluded from this work per the owner's
completed test; do not repeat it as a prerequisite.

Local verification on 2026-10-26: build 1.0 (79) archived and exported with
`--no-upload`; the exported app reports `aps-environment=production` using
`scripts/verify-ios-push.sh`. It has not been uploaded or tested through TestFlight in this
work. Start, update, end and swipe-away/resume on a real TestFlight device remain pending;
no sandbox/production behavior difference has been established. Relay deployment was explicitly approved and completed on 2026-10-26; the existing
single Fly Machine reports passing readiness after the update.

Live Activity control follow-up, 2026-10-26: development build 80 was installed in place on
the owner's iPhone 14 Pro. The owner confirmed play/pause and next work from the Live
Activity with the iPhone locked. This followed fixes for paired-pin file protection,
cold-start activity adoption, and acknowledged one-shot command delivery. The 24 focused
control/activity/security tests and the signed iPhone build passed. This verifies the
locked-phone development build, not TestFlight or an independently repeated terminated-app
acceptance run.

## Mac updates with Sparkle

The Mac host embeds Sparkle 2.10.0. Its fixed HTTPS feed is
`https://pocketdesk.runmira.dev/updates/appcast.xml`; `site/public/updates/appcast.xml`
is published by the existing website workflow. The initial feed is signed and empty:
adding updater support does not publish or advertise an untested app release.

`SUPublicEDKey` in `project.yml` is the public Ed25519 key. The corresponding private
key stays in the release Mac's login Keychain under Sparkle account `pocketdesk`.
Never commit/export that private key into the repository. On another release machine,
transfer it securely with Sparkle's documented key-management tools. A fork must use
its own key, feed URL and bundle identifier.

The existing Mac menu now includes **Check for Updates…** and automatic-check settings.
A phone's **Update Mac** action requires an existing pairing, honors its local Face ID
lock and the Mac's Ask Before Each Connection policy, and explicitly confirms that
PocketDesk will restart. A remote install uses the fixed signed feed; neither URLs nor
shell commands can be supplied by the phone. macOS may still require authorization if
the installed app isn't writable by the current user.

### Publish an updater-compatible release

1. Build and notarize with `scripts/release-mac.sh`. In addition to the DMG, this creates
   `.build/release/PocketDesk-<version>-<actual-build>-update.zip`, containing the stapled
   app as `PocketDesk.app` with framework symlinks preserved. `--no-notarize` deliberately
   does not create an update archive.
2. Upload that ZIP to the **versioned** GitHub release, alongside `PocketDesk.dmg`. Verify
   the published download, signing, notarization and a real update/relaunch before
   promoting the release. Do not substitute an old archive's build number.
3. Resolve the official Sparkle tools if needed with
   `swift package --package-path Packages/PocketDeskKit resolve`, then run:

   ```sh
   python3 scripts/sparkle-appcast.py \
     .build/release/PocketDesk-<version>-<build>-update.zip \
     https://github.com/DamilolaDami/pocketdesk/releases/download/<tag>/<zip-name>.zip
   ```

   The script reads version/build/minimum macOS from the ZIP, checks its bundled public
   key against the Keychain account, preserves previous feed entries, refuses duplicate
   or older builds, signs the archive and feed, verifies the feed signature and replaces
   the feed only on success. `--sign-tool` can point at another resolved Sparkle tools
   directory. A feed edit, even whitespace, invalidates its signature: re-sign it.
4. Commit the appcast change with the release entry. Merge/push to main to deploy the
   site; verify the live feed and ZIP before declaring the update published.

For the first deployment, install one build containing Sparkle on existing Macs
manually. Earlier hosts neither contain Sparkle nor speak the maintenance protocol;
the phone explains this and links to the Mac download. After that bootstrap, future
streaming protocol mismatches can be repaired through the stable maintenance channel.
A Mac newer than the phone still requires updating the phone. If the compatible Mac
release hasn't been published yet, Sparkle reports no update rather than inventing one.

References: [Sparkle programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/),
[signed appcast and archive publication](https://sparkle-project.org/documentation/publishing/).
