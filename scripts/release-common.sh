# Shared by the release scripts: reads Config/Release.xcconfig and picks the build number.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Config/Release.xcconfig
if [[ ! -f $CONFIG ]]; then
    echo "Missing $CONFIG: copy Config/Release.example.xcconfig and fill it in." >&2
    exit 1
fi
setting() { sed -nE "s/^$1[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p" "$CONFIG" | tail -1; }
TEAM_ID=$(setting DEVELOPMENT_TEAM)
PREFIX=$(setting BUNDLE_ID_PREFIX)
NOTARY_PROFILE=$(setting NOTARY_PROFILE)
ASC_KEY_ID=$(setting ASC_KEY_ID)
ASC_ISSUER_ID=$(setting ASC_ISSUER_ID)
# Signing and uploading go through the API key when there is one, not an Xcode account.
AUTH=()
if [[ -n $ASC_KEY_ID && -n $ASC_ISSUER_ID ]]; then
    AUTH=(-authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
          -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
VERSION=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?/\1/p' project.yml | head -1)
# Every commit on main is a new build; TestFlight needs each upload to be higher.
BUILD=$(git rev-list --count HEAD)
OUT=.build/release
mkdir -p "$OUT"

echo "PocketDesk $VERSION ($BUILD) · team $TEAM_ID · $PREFIX"
xcodegen --quiet
