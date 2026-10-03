#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox -c release
mkdir -p build/VPNBar.app/Contents/MacOS build/VPNBar.app/Contents/Helpers build/VPNBar.app/Contents/Resources
cp .build/release/VPNBar build/VPNBar.app/Contents/MacOS/VPNBar
cp .build/release/VPNBarCLI build/VPNBar.app/Contents/Helpers/vpnbar
cp .build/release/VPNBarNetwork build/VPNBar.app/Contents/Helpers/VPNBarNetwork
cp .build/release/VPNBarShareAgent build/VPNBar.app/Contents/Helpers/VPNBarShareAgent
cp Resources/Info.plist build/VPNBar.app/Contents/Info.plist
cp -R Resources/Shortcuts build/VPNBar.app/Contents/Resources/
cp Resources/cloudflared-LICENSE.txt build/VPNBar.app/Contents/Resources/
if [[ -x Resources/bin/cloudflared ]]; then
    mkdir -p build/VPNBar.app/Contents/Resources/bin
    cp Resources/bin/cloudflared build/VPNBar.app/Contents/Resources/bin/
    codesign --force --sign - build/VPNBar.app/Contents/Resources/bin/cloudflared
fi
for helper in build/VPNBar.app/Contents/Helpers/*; do
    codesign --force --sign - "$helper"
done
codesign --force --sign - build/VPNBar.app
echo "App creata: $PWD/build/VPNBar.app"
