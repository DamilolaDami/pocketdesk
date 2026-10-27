#!/usr/bin/env bash
# Archives the Mac app, signs it with Developer ID, packs a DMG, notarizes it and staples the
# ticket. Usage: scripts/release-mac.sh [--no-notarize]
source "$(dirname "$0")/release-common.sh"

ARCHIVE=$OUT/PocketDesk-Mac-$BUILD.xcarchive
xcodebuild archive -scheme PocketDeskHost -destination 'generic/platform=macOS' \
    -xcconfig "$CONFIG" -archivePath "$ARCHIVE" -derivedDataPath .build/release-dd \
    CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} -quiet

cat > "$OUT/ExportOptions-Mac.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
EXPORT=$OUT/Mac-$BUILD
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "$OUT/ExportOptions-Mac.plist" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} -quiet
APP=$EXPORT/PocketDeskHost.app
codesign --verify --deep --strict "$APP"

# The app gets its own ticket first, so it opens offline once it's out of the DMG.
if [[ ${1:-} != --no-notarize ]]; then
    ditto -c -k --keepParent "$APP" "$OUT/PocketDesk-$BUILD.zip"
    xcrun notarytool submit "$OUT/PocketDesk-$BUILD.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$OUT/PocketDesk-$BUILD.zip"
fi

# A DMG with the app and a link to Applications, to drag across.
STAGE=$OUT/dmg-$BUILD
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PocketDesk.app"
ln -s /Applications "$STAGE/Applications"
DMG=$OUT/PocketDesk-$VERSION-$BUILD.dmg
rm -f "$DMG"
hdiutil create -volname PocketDesk -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
IDENTITY=$(security find-identity -v -p codesigning | sed -nE "s/.*\"(Developer ID Application: .*\($TEAM_ID\))\"/\1/p" | head -1)
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ ${1:-} == --no-notarize ]]; then
    echo "Signed, not notarized: $DMG"
    exit 0
fi
# Then the DMG, so it opens without a warning too.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
# Sparkle updates preserve the shipped app name and framework symlinks.
UPDATE_ZIP=$OUT/PocketDesk-$VERSION-$BUILD-update.zip
ditto -c -k --sequesterRsrc --keepParent "$STAGE/PocketDesk.app" "$UPDATE_ZIP"
echo "Notarized: $DMG"
echo "Sparkle archive: $UPDATE_ZIP"
echo "Upload the ZIP to the versioned release before adding it to the signed appcast (docs/RELEASING.md)."
