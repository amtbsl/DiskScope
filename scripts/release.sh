#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
zsh scripts/build.sh
app="$PWD/build/DiskScope.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
arch=$(uname -m)
name="DiskScope-${version}-macos-${arch}"
out="$PWD/build/releases/$name"
mkdir -p "$out"
stage=$(mktemp -d "$PWD/build/release-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/DiskScope.app"
ln -s /Applications "$stage/Applications"
cp LICENSE "$stage/LICENSE"
cat > "$stage/README.txt" <<'README'
DiskScope — macOS

中文：将 DiskScope.app 拖入 Applications。此版本使用临时签名，未经过 Apple 公证。
首次打开如被 macOS 阻止，请检查来源后，在“系统设置 → 隐私与安全性”中手动确认打开。
受保护目录的扫描可能需要为 DiskScope 授予“完全磁盘访问权限”。

English: Drag DiskScope.app into Applications. This build is ad hoc signed and
not Apple-notarized. If macOS blocks the first launch, review the download source
and approve opening in System Settings → Privacy & Security.
Scanning protected folders may require Full Disk Access for DiskScope.

Source / 源码: https://github.com/amtbsl/DiskScope
License / 协议: MIT
README
codesign --verify --deep --strict "$stage/DiskScope.app"
ditto -c -k --sequesterRsrc --keepParent "$stage/DiskScope.app" "$out/$name.zip"
hdiutil create -volname "DiskScope $version" -srcfolder "$stage" -format UDZO -ov "$out/$name.dmg"
(cd "$out" && shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS.txt)
printf 'Release assets: %s\n' "$out"
