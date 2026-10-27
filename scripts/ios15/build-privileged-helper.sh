#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=build/ios15/privileged-helper
DEVKIT=build/frida-probe/devkit
mkdir -p "$OUT" ci-logs
[[ -s "$DEVKIT/frida-core.h" && -s "$DEVKIT/libfrida-core.a" ]] || {
  echo 'error: verified Frida 17.9.10 devkit missing' >&2; exit 1;
}
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
  -miphoneos-version-min=15.0 -fobjc-arc -fblocks -O2 \
  -I"$DEVKIT" tools/privileged-helper/MinisPrivilegedHelper.m \
  "$DEVKIT/libfrida-core.a" -o "$OUT/minis-privileged-helper" \
  -lbsm -ldl -lm -lresolv -lpthread \
  -framework Foundation -framework Security -framework CoreFoundation \
  -Wl,-fatal_warnings
file "$OUT/minis-privileged-helper"
xcrun vtool -show-build "$OUT/minis-privileged-helper"
# Never execute this target on the CI host or the user's device automatically.
echo 'PASS: isolated socket-only helper linked for iOS 15; root and protocol runtime not tested.'
