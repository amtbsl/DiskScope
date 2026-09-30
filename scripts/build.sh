#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/DiskScope.app/Contents/MacOS build/DiskScope.app/Contents/Resources
# Keep the executable's deployment target consistent with Info.plist.
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" Sources/Core.swift Sources/Services.swift Sources/main.swift -o build/DiskScope.app/Contents/MacOS/DiskScope -framework AppKit -framework WebKit -framework IOKit
cp -R web build/DiskScope.app/Contents/Resources/
cp LICENSE build/DiskScope.app/Contents/Resources/LICENSE
cat > build/DiskScope.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DiskScope</string>
<key>CFBundleIdentifier</key><string>local.chichu.diskscope</string>
<key>CFBundleName</key><string>DiskScope</string>
<key>CFBundleDisplayName</key><string>DiskScope</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHumanReadableCopyright</key><string>Independent local implementation</string>
</dict></plist>
PLIST
zsh scripts/make-icon.sh
codesign --force --deep --sign - build/DiskScope.app
printf 'Built: %s/build/DiskScope.app\n' "$PWD"
