#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRIDGE="$ROOT/src/ios/Vendor/OMToolchain"
TESTS="$ROOT/toolchain-build/bridge-check"

# Fail explicitly on iOS/Linux: these checks require the actual Xcode SDKs and
# macOS execution. Never call a shell parse or a missing-tool skip a test pass.
if [ "$(uname -s)" != Darwin ] || ! command -v xcrun >/dev/null 2>&1; then
  echo "This check requires macOS with Xcode (xcrun, clang, swiftc and iPhoneOS SDK)." >&2
  exit 2
fi
xcrun --find clang++ >/dev/null
xcrun --find swiftc >/dev/null
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/openminis-bridge-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Validate the real pbxproj, not a snapshot of the registration.
plutil -lint "$ROOT/src/ios/Minis.xcodeproj/project.pbxproj"
plutil -convert json -o "$WORK/project.json" "$ROOT/src/ios/Minis.xcodeproj/project.pbxproj"
python3 "$TESTS/verify-registration.py" "$WORK/project.json" "$ROOT"

# Run actual host assertions against canonical source, without LLVM headers/libs.
xcrun --sdk macosx clang++ -isysroot "$MAC_SDK" -std=c++17 -fobjc-arc \
  -DOM_TOOLCHAIN_ENABLED=0 -Wall -Wextra -Werror -I "$BRIDGE" \
  "$BRIDGE/OMToolchain.mm" "$TESTS/DisabledBridgeTests.mm" \
  -framework Foundation -o "$WORK/disabled-bridge-tests"
"$WORK/disabled-bridge-tests"

# Separately compile iPhoneOS code and typecheck its Swift import. The host test
# above does NOT establish iPhoneOS runtime behavior or the whole Minis build.
xcrun --sdk iphoneos clang++ -target arm64-apple-ios16.0 \
  -isysroot "$IOS_SDK" -std=c++17 -fobjc-arc -DOM_TOOLCHAIN_ENABLED=0 \
  -Wall -Wextra -Werror -c "$BRIDGE/OMToolchain.mm" -o "$WORK/bridge-ios.o"
xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios16.0 \
  -sdk "$IOS_SDK" -module-cache-path "$WORK/swift-module-cache" \
  -import-objc-header "$BRIDGE/OMToolchain.h" "$TESTS/SwiftImportCheck.swift"
echo "Bridge checks passed: host assertions, iOS object compile, Swift import and project registration."
echo "Not tested: enabled LLVM/ld64, full Minis Xcode build, device runtime or installation."
