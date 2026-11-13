#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
INSTALL_APP=false
ARCH_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_APP=true ;;
        --universal) ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
        *) echo "Usage: $0 [--install] [--universal]" >&2; exit 2 ;;
    esac
done
swift build -c release "${ARCH_ARGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)"
APP="$PWD/dist/Device Studio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DeviceStudio" "$APP/Contents/MacOS/DeviceStudio"
cp scripts/Info.plist "$APP/Contents/Info.plist"
# The Google Meet extension, copied out to Application Support by the app for Chrome's "Load unpacked".
rm -rf "$APP/Contents/Resources/ChromeExtension"
cp -R ChromeExtension "$APP/Contents/Resources/ChromeExtension"
swift scripts/make-icon.swift "$PWD/dist/AppIcon.iconset"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Signing, in order of preference:
#  1. DEVICE_STUDIO_SIGN_IDENTITY (a Developer ID for releases; see DISTRIBUTING.md).
#  2. An "Apple Development" identity in the keychain (a free Personal Team works). macOS keys permission
#     grants (microphone, system audio, Accessibility) to the signature, so a stable identity keeps them
#     across rebuilds; an ad-hoc signature loses them every time.
#  3. Ad-hoc, if neither exists.
SIGN_IDENTITY="${DEVICE_STUDIO_SIGN_IDENTITY:-}"
if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --entitlements scripts/entitlements.plist --sign "$SIGN_IDENTITY" "$APP"
elif DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ {print $2; exit}') && [[ -n "$DEV_IDENTITY" ]]; then
    codesign --force --options runtime --timestamp=none --entitlements scripts/entitlements.plist --sign "$DEV_IDENTITY" "$APP"
    echo "Signed with Apple Development identity $DEV_IDENTITY"
else
    codesign --force --sign - --identifier com.jackzoppa.devicestudio "$APP"
    echo "Signed ad-hoc: macOS permissions will need to be granted again after each rebuild"
fi
codesign --verify --deep --strict "$APP"
if [[ "$INSTALL_APP" == true ]]; then
    mkdir -p "$HOME/Applications"
    ditto "$APP" "$HOME/Applications/Device Studio.app"
    echo "Installed: $HOME/Applications/Device Studio.app"
else
    echo "Built: $APP"
fi
