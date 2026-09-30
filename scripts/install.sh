#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
zsh scripts/build.sh
if [[ -e /Applications/DiskScope.app ]]; then
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/DiskScope.app/Contents/Info.plist)" != 'local.chichu.diskscope' ]]; then
    print -u2 'Refusing to replace an unrelated application named DiskScope.'
    exit 1
  fi
  if pgrep -f '^/Applications/DiskScope.app/Contents/MacOS/DiskScope$' >/dev/null; then
    print -u2 'Quit DiskScope before installing the new build.'
    exit 1
  fi
  mv /Applications/DiskScope.app "build/DiskScope-backup-$(date +%Y%m%d-%H%M%S).app"
fi
ditto build/DiskScope.app /Applications/DiskScope.app
codesign --verify --deep --strict /Applications/DiskScope.app
print 'Installed: /Applications/DiskScope.app'
