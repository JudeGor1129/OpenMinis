#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=build/ios15/privileged-helper
mkdir -p "$OUT" ci-logs
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
  -miphoneos-version-min=15.0 -fobjc-arc -fblocks -O2 \
  tools/privileged-helper/MinisPrivilegedHelper.m \
  -o "$OUT/minis-privileged-helper" \
  -framework Foundation -framework Security \
  -Wl,-fatal_warnings
file "$OUT/minis-privileged-helper"
xcrun vtool -show-build "$OUT/minis-privileged-helper"
# Build only. Never execute a persona/root helper on CI.
echo 'PASS: allowlisted system-file helper built for iOS 15; root runtime requires explicit device verification.'
