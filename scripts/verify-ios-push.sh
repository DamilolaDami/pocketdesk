#!/usr/bin/env bash
# Verify App Store/TestFlight push signing after export, without printing other entitlements.
set -euo pipefail
if [[ $# != 1 || ! -f $1 ]]; then
    echo "Usage: scripts/verify-ios-push.sh <exported.ipa>" >&2
    exit 1
fi
PUSH_CHECK=$(mktemp -d)
trap 'rm -rf "$PUSH_CHECK"' EXIT
unzip -q "$1" -d "$PUSH_CHECK"
PUSH_APPS=("$PUSH_CHECK"/Payload/*.app)
[[ ${#PUSH_APPS[@]} == 1 && -d ${PUSH_APPS[0]} ]] || { echo "Expected one app in IPA" >&2; exit 1; }
# macOS 26's abstract view reads DER entitlements too; forcing XML can miss DER-only signatures.
codesign -d --entitlements - "${PUSH_APPS[0]}" > "$PUSH_CHECK/entitlements.txt" 2>/dev/null
PUSH_ENV=$(awk '/\[Key\] aps-environment/{found=1;next} found && /\[String\]/{print $NF;exit}' "$PUSH_CHECK/entitlements.txt")
[[ $PUSH_ENV == production ]] || { echo "Expected aps-environment=production, got $PUSH_ENV" >&2; exit 1; }
echo "Exported app: aps-environment=production"
