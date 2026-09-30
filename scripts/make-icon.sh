#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
xcrun swiftc scripts/Icon.swift -o build/make-icon -framework AppKit
build/make-icon build/icon-png
mkdir -p build/DiskScope.iconset
for n in 16 32 128 256 512; do
  cp "build/icon-png/size${n}.png" "build/DiskScope.iconset/icon_${n}x${n}.png"
  double=$((n*2))
  cp "build/icon-png/size${double}.png" "build/DiskScope.iconset/icon_${n}x${n}@2x.png"
done
iconutil -c icns build/DiskScope.iconset -o build/DiskScope.app/Contents/Resources/AppIcon.icns
