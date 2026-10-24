#!/usr/bin/env bash
# Archives the iPhone app (with its widgets and share extension) and uploads it to App Store
# Connect for TestFlight. Usage: scripts/release-ios.sh [--no-upload]
source "$(dirname "$0")/release-common.sh"

ARCHIVE=$OUT/PocketDesk-iOS-$BUILD.xcarchive
xcodebuild archive -scheme PocketDesk -destination 'generic/platform=iOS' \
    -xcconfig "$CONFIG" -archivePath "$ARCHIVE" -derivedDataPath .build/release-dd \
    CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} -quiet

DESTINATION=upload
[[ ${1:-} == --no-upload ]] && DESTINATION=export
cat > "$OUT/ExportOptions-iOS.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$DESTINATION</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/iOS-$BUILD" \
    -exportOptionsPlist "$OUT/ExportOptions-iOS.plist" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} -quiet

if [[ $DESTINATION == upload ]]; then
    echo "Uploaded build $BUILD. It shows in TestFlight once App Store Connect has processed it."
else
    echo "Exported to $OUT/iOS-$BUILD"
fi
