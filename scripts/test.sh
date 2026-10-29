#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
zsh scripts/build.sh
python3 tests/test_core.py
zsh tests/run_native_tests.sh
zsh tests/run_service_tests.sh
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx12.0" Sources/Updates.swift tests/test_desktop_services.swift -o build/desktop-services-test
build/desktop-services-test
node tests/test_treemap.js
node tests/test_ui_state.js
node --check web/app.js
node --check web/ui-state.js
node --check web/treemap.js
build/DiskScope.app/Contents/MacOS/DiskScope --self-test
build/DiskScope.app/Contents/MacOS/DiskScope --trash-test
