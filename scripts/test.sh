#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
zsh scripts/build.sh
python3 tests/test_core.py
node tests/test_treemap.js
node --check web/app.js
node --check web/treemap.js
build/DiskScope.app/Contents/MacOS/DiskScope --self-test
build/DiskScope.app/Contents/MacOS/DiskScope --trash-test
