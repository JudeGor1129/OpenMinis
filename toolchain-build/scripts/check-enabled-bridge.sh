#!/usr/bin/env bash
# Compile/link canonical OMToolchain with real archives, never execute probes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${1:-$ROOT/build/ios}"
BRIDGE="$ROOT/../src/ios/Vendor/OMToolchain"
if ! command -v xcrun >/dev/null 2>&1; then
  echo "Enabled bridge check requires macOS/Xcode; no compile/link test ran." >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "Python 3 required for architecture report" >&2; exit 2; }
for FILE in libomllvm-arm64.a libomllvm-arm64e.a libomld64.a toolchain.json; do
  [ -f "$DIR/$FILE" ] || { echo "Missing enabled-bridge input: $DIR/$FILE" >&2; exit 1; }
done
# Caller must run verify-artifacts.sh first. Link failure is not an excuse to
# use dynamic_lookup, ignore unresolved symbols, or fall back to arm64.
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$DIR/enabled-link-check"
OUT="$(cd "$DIR/enabled-link-check" && pwd)"
# Remove stale success metadata before attempting any compilation.
rm -f "$OUT/enabled-link-report.json"
xcrun --sdk iphoneos clang++ --version > "$OUT/compiler-version.txt"
xcodebuild -version > "$OUT/xcode-version.txt"
for ARCH in arm64 arm64e; do
  GENERATED="$DIR/dev-headers/$ARCH/include"
  COMMON="$DIR/dev-headers/common/include"
  [ -d "$GENERATED" ] && [ -d "$COMMON" ] || { echo "Missing development headers for $ARCH" >&2; exit 1; }
  echo "==> compiling enabled OMToolchain bridge ($ARCH, minimum iOS 16.0)"
  # LLVM's build uses RTTI disabled; the bridge does not need RTTI. Keep C++
  # exceptions enabled, since the linker reports errors via exceptions.
  xcrun --sdk iphoneos clang++ -target "$ARCH-apple-ios16.0" \
    -isysroot "$SDK" -std=c++17 -fno-rtti -fexceptions -fobjc-arc \
    -DOM_TOOLCHAIN_ENABLED=1 -Wall -Wextra \
    -I "$GENERATED" -I "$COMMON" -I "$BRIDGE" \
    -c "$BRIDGE/OMToolchain.mm" -o "$OUT/bridge-$ARCH.o" \
    > "$OUT/compile-$ARCH.log" 2>&1 || { cat "$OUT/compile-$ARCH.log" >&2; exit 1; }
  xcrun --sdk iphoneos clang -target "$ARCH-apple-ios16.0" \
    -isysroot "$SDK" -fobjc-arc -I "$BRIDGE" \
    -c "$ROOT/scripts/EnabledBridgeLinkProbe.m" -o "$OUT/probe-$ARCH.o" \
    > "$OUT/probe-$ARCH.log" 2>&1 || { cat "$OUT/probe-$ARCH.log" >&2; exit 1; }
  echo "==> linking enabled bridge ($ARCH, no execution)"
  xcrun --sdk iphoneos clang++ -target "$ARCH-apple-ios16.0" \
    -isysroot "$SDK" "$OUT/probe-$ARCH.o" "$OUT/bridge-$ARCH.o" \
    "$DIR/libomllvm-$ARCH.a" "$DIR/libomld64.a" \
    -framework Foundation -lc++ -lz \
    -o "$OUT/enabled-link-$ARCH" \
    > "$OUT/link-$ARCH.log" 2>&1 || { cat "$OUT/link-$ARCH.log" >&2; exit 1; }
done
python3 "$ROOT/scripts/verify-enabled-link.py" "$OUT" "$DIR/toolchain.json"
echo "Enabled bridge compile/link gate completed; probes were NOT executed."
