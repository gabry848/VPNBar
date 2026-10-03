#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version=2026.9.3
architecture="$(uname -m)"
case "$architecture" in
    arm64) asset=cloudflared-darwin-arm64.tgz; digest=587c2cfb1c230fe36c7fa7727da78be459dae028cabe8c001291999350f07095 ;;
    x86_64) asset=cloudflared-darwin-amd64.tgz; digest=d1155d0837487f261183b15c1eab6c4ebcad9dc49b94675f1524c3564cea3977 ;;
    *) print -u2 "Architettura non supportata"; exit 1 ;;
esac
mkdir -p .build/downloads Resources/bin
archive=".build/downloads/$asset"
curl --fail --location --proto '=https' --tlsv1.2 "https://github.com/cloudflare/cloudflared/releases/download/$version/$asset" -o "$archive"
print "$digest  $archive" | shasum -a 256 -c -
tar -xzf "$archive" -C Resources/bin cloudflared
chmod 755 Resources/bin/cloudflared
Resources/bin/cloudflared --version
