#!/bin/bash
# Type-check the ACTUAL guarded bridge AND the audited root helper before the
# long dependency build. Compiles only; never runs Frida, the helper, a target,
# a server or generated iOS code.
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v xcrun >/dev/null || { echo 'UNAVAILABLE: Xcode compiler not present'; exit 77; }
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
bridge=src/ios/Diagnostics/FridaCoreBridge.m
helper=tools/privileged-helper/MinisPrivilegedHelper.m

# The helper now shares the strict argv policy and the session allowlist.
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=15.0 \
  -fobjc-arc -fblocks -fsyntax-only -Werror=implicit-function-declaration \
  -Werror=incompatible-function-pointer-types "$helper" \
  -framework Foundation -framework Security
echo 'PASS: audited root helper type-checks with the frida_verdict action (never executed here).'

[[ -s deps/include/frida-core.h ]] || { echo 'FAIL: pinned Frida header required'; exit 1; }
flags=(-arch arm64 -isysroot "$sdk" -miphoneos-version-min=15.0
       -fobjc-arc -fblocks -fsyntax-only -Werror=implicit-function-declaration
       -Werror=incompatible-function-pointer-types -I src/ios/Diagnostics)
xcrun --sdk iphoneos clang "${flags[@]}" -I deps/include "$bridge"
echo 'PASS: production guarded Frida bridge type-checks against actual pinned header and iOS SDK.'
xcrun --sdk iphoneos clang "${flags[@]}" "$bridge"
echo 'PASS: headerless local-status fallback type-checks; no target code executed.'
