#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${DEVICE_STUDIO_SIGN_IDENTITY:?Set your Developer ID Application signing identity.}"
: "${DEVICE_STUDIO_NOTARY_PROFILE:?Set the name of an existing notarytool keychain profile.}"
if [[ "$DEVICE_STUDIO_SIGN_IDENTITY" == "-" ]]; then
    echo "A public release needs a Developer ID Application identity, not ad-hoc signing." >&2
    exit 2
fi
./scripts/build-app.sh --universal
APP="$PWD/dist/Device Studio.app"
UPLOAD="$PWD/dist/DeviceStudio-notarization.zip"
RELEASE="$PWD/dist/DeviceStudio-macOS.zip"
ditto -c -k --keepParent "$APP" "$UPLOAD"
xcrun notarytool submit "$UPLOAD" --keychain-profile "$DEVICE_STUDIO_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
ditto -c -k --keepParent "$APP" "$RELEASE"
shasum -a 256 "$RELEASE" > "$RELEASE.sha256"
echo "Signed, notarized release: $RELEASE"
