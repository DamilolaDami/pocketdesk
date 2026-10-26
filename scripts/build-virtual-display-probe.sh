#!/bin/bash
# Local developer artifact, never a PocketDesk app release. Identity/profile stay outside Git.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/virtual-display-proof/package"
SCRATCH="${PD_PROBE_SCRATCH_PATH:-$ROOT/.build/relay-tests}"
APP="$OUT/PocketDeskDisplayProbe.app"
: "${PD_PROBE_SIGN_IDENTITY:?Set PD_PROBE_SIGN_IDENTITY to your Developer ID Application identity}"

swift build --package-path "$ROOT/Packages/PocketDeskKit" --scratch-path "$SCRATCH" --product PDVirtualDisplayProbe
mkdir -p "$APP/Contents/MacOS"
cp "$SCRATCH/debug/PDVirtualDisplayProbe" "$APP/Contents/MacOS/PDVirtualDisplayProbe"
cp "$ROOT/Config/VirtualDisplayProbe-Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign "$PD_PROBE_SIGN_IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict "$APP"

if [[ "${1:-}" == "--notarize" ]]; then
    : "${PD_PROBE_NOTARY_PROFILE:?Set PD_PROBE_NOTARY_PROFILE to an existing notarytool Keychain profile}"
    ditto -c -k --keepParent "$APP" "$OUT/PocketDeskDisplayProbe.zip"
    xcrun notarytool submit "$OUT/PocketDeskDisplayProbe.zip" --keychain-profile "$PD_PROBE_NOTARY_PROFILE" \
        --wait --output-format json > "$OUT/notarization.json"
    # notarytool may exit zero after a rejected submission; require the actual status.
    /usr/bin/plutil -extract status raw "$OUT/notarization.json" | /usr/bin/grep -qx Accepted
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose "$APP"
fi
printf '%s\n' "$APP"
