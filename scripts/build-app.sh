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
swift scripts/make-icon.swift "$PWD/dist/AppIcon.iconset"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
SIGN_IDENTITY="${DEVICE_STUDIO_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier com.jackzoppa.devicestudio "$APP"
else
    codesign --force --options runtime --timestamp --entitlements scripts/entitlements.plist --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
if [[ "$INSTALL_APP" == true ]]; then
    mkdir -p "$HOME/Applications"
    ditto "$APP" "$HOME/Applications/Device Studio.app"
    echo "Installed: $HOME/Applications/Device Studio.app"
else
    echo "Built: $APP"
fi
