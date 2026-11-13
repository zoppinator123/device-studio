#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/device-studio-checks.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc Sources/ControlCenter/Models.swift Sources/ControlCenter/SetupModels.swift Sources/ControlCenter/GranolaKeyEvent.swift Tests/ControlCenterTests.swift -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"
clang -Wall -Wextra -I Sources/CDeviceSupport/include Tests/HIDButtonTests.c -framework IOKit -framework CoreFoundation -o "$CHECK_DIR/hid-checks"
"$CHECK_DIR/hid-checks"
for f in ChromeExtension/*.js; do node --check "$f"; done
node Tests/MeetExtensionTests.js
python3 -c 'import json; json.load(open("ChromeExtension/manifest.json"))'
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
if [[ "${1:-}" == "--hardware" ]]; then
    clang -Wall -Wextra -I Sources/CDeviceSupport/include Tests/HIDHardwareTests.c -framework IOKit -framework CoreFoundation -o "$CHECK_DIR/hardware-checks"
    "$CHECK_DIR/hardware-checks"
fi
