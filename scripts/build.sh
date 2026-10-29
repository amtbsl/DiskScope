#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/DiskScope.app/Contents/MacOS build/DiskScope.app/Contents/Resources build/bin
# Keep the executable's deployment target consistent with Info.plist.
arch_list=(${=DISKSCOPE_ARCHS:-$(uname -m)})
binaries=()
for build_arch in $arch_list; do
  [[ "$build_arch" == arm64 || "$build_arch" == x86_64 ]] || { print -u2 'Supported build architectures: arm64 x86_64'; exit 1; }
  xcrun swiftc -O -swift-version 5 -target "$build_arch-apple-macosx12.0" Sources/*.swift -o "build/bin/DiskScope-$build_arch" -framework AppKit -framework WebKit -framework IOKit -framework Carbon -framework Security
  binaries+=("build/bin/DiskScope-$build_arch")
done
if (( ${#binaries} > 1 )); then
  lipo -create $binaries -output build/DiskScope.app/Contents/MacOS/DiskScope
else
  cp "$binaries[1]" build/DiskScope.app/Contents/MacOS/DiskScope
fi
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
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHumanReadableCopyright</key><string>Independent local implementation</string>
</dict></plist>
PLIST
zsh scripts/make-icon.sh
codesign --force --deep --sign - build/DiskScope.app
printf 'Built: %s/build/DiskScope.app\n' "$PWD"
