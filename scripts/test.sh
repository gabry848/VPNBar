#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
compiler="$(xcrun -f swiftc)"
plugin_dir="${compiler:h:h}/lib/swift/host/plugins/testing"
if [[ -d "$plugin_dir" ]]; then
    swift test --disable-sandbox -Xswiftc -plugin-path -Xswiftc "$plugin_dir"
else
    swift test --disable-sandbox
fi
