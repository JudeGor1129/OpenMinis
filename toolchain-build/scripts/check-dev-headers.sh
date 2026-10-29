#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${1:-$ROOT/build/ios}"
if ! command -v xcrun >/dev/null 2>&1; then
  echo "Development header compile probes require macOS/Xcode; no compile test ran." >&2
  exit 2
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/om-dev-header-probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
for ARCH in arm64 arm64e; do
  [ -d "$DIR/dev-headers/$ARCH/include" ] || { echo "Missing generated headers: $ARCH" >&2; exit 1; }
  xcrun --sdk iphoneos clang++ -target "$ARCH-apple-ios14.0" \
    -isysroot "$SDK" -std=c++17 -fno-rtti \
    -I "$DIR/dev-headers/$ARCH/include" \
    -I "$DIR/dev-headers/common/include" \
    -c "$ROOT/scripts/DevHeaderProbe.cpp" -o "$WORK/probe-$ARCH.o"
  xcrun lipo -info "$WORK/probe-$ARCH.o"
  xcrun lipo -verify_arch "$ARCH" "$WORK/probe-$ARCH.o"
done
echo "Development header probes compiled for arm64 and arm64e."
echo "Not tested: enabled bridge APIs, static library link, PAC behavior or runtime."
