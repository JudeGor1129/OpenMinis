#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:-$ROOT/build/ios}"
VERIFY_FLAG="${2:-}"
case "$VERIFY_FLAG" in
  ""|--integrity-only|--require-lld) ;;
  *) echo "unsupported verification mode: $VERIFY_FLAG" >&2; exit 2 ;;
esac
fail=0
for file in libomllvm-arm64.a libomllvm-arm64e.a libomld64.a toolchain.json; do
  if [ ! -f "$DIR/$file" ]; then
    echo "missing: $DIR/$file" >&2
    fail=1
  fi
done
for directory in clang-resource/include dev-headers/common/include dev-headers/arm64/include dev-headers/arm64e/include dev-headers/licenses; do
  if [ ! -d "$DIR/$directory" ]; then
    echo "missing: $DIR/$directory" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1
command -v python3 >/dev/null 2>&1 || { echo "Python 3 required for manifest/hash verification" >&2; exit 2; }
# The Python gate checks declared capabilities, complete header hashes and
# defined MachO/Common/arm64e symbols when LLD is required. Calling without a
# flag verifies a legacy ld64-only kit but never claims LLD.
python3 "$ROOT/scripts/verify-toolchain-manifest.py" "$DIR" $VERIFY_FLAG
if command -v xcrun >/dev/null 2>&1; then
  xcrun lipo -info "$DIR/libomllvm-arm64.a"
  xcrun lipo "$DIR/libomllvm-arm64.a" -verify_arch arm64
  xcrun lipo -info "$DIR/libomllvm-arm64e.a"
  xcrun lipo "$DIR/libomllvm-arm64e.a" -verify_arch arm64e
  xcrun lipo -info "$DIR/libomld64.a"
  xcrun lipo "$DIR/libomld64.a" -verify_arch arm64 arm64e
else
  echo "Archive slice checks not run: Xcode xcrun is unavailable. Only manifest integrity checked."
fi
