#!/usr/bin/env bash
#
# quick-build.sh — local convenience wrapper around build-ios-toolchain.sh.
# Run this on a macOS host to produce both arm64 and arm64e archives in one go.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -d work/llvm-project/.git ] || [ ! -d work/cctools-port/.git ]; then
  echo "==> fetching pinned sources (first run)"
  bash scripts/fetch-sources.sh
fi

ARCHS="${ARCHS:-arm64 arm64e}"
LLVM_MIN_IOS="${LLVM_MIN_IOS:-14.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "==> building iOS toolchain"
echo "    architectures: $ARCHS"
echo "    minimum iOS  : $LLVM_MIN_IOS"
echo "    parallel jobs: $JOBS"

ARCHS="$ARCHS" LLVM_MIN_IOS="$LLVM_MIN_IOS" JOBS="$JOBS" \
  bash scripts/build-ios-toolchain.sh

echo
echo "==> verifying artifacts"
bash verify-artifacts.sh build/ios
bash scripts/check-dev-headers.sh build/ios
bash scripts/check-enabled-bridge.sh build/ios

echo
echo "==> done. Artifacts:"
ls -lh build/ios/*.a build/ios/toolchain.json
echo
echo "Next: copy these to src/ios/Vendor/OMToolchain/ and follow toolchain-build/INTEGRATION.md"
