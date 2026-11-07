#!/bin/bash
# Type-check the ACTUAL guarded bridge before spending time on dependencies.
# This compiles only; no generated iOS code, Frida runtime, server or target is run.
set -euo pipefail
cd "$(dirname "$0")/../.."
command -v xcrun >/dev/null || { echo 'UNAVAILABLE: Xcode compiler not present'; exit 77; }
[[ -s deps/include/frida-core.h ]] || { echo 'FAIL: pinned Frida header required'; exit 1; }
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
source=src/ios/Diagnostics/FridaCoreBridge.m
flags=(-arch arm64 -isysroot "$sdk" -miphoneos-version-min=15.0
       -fobjc-arc -fblocks -fsyntax-only -Werror=implicit-function-declaration
       -Werror=incompatible-function-pointer-types -I src/ios/Diagnostics)
xcrun --sdk iphoneos clang "${flags[@]}" -I deps/include "$source"
echo 'PASS: production guarded Frida bridge type-checks against actual pinned header and iOS SDK.'
xcrun --sdk iphoneos clang "${flags[@]}" "$source"
echo 'PASS: headerless local-status fallback type-checks; no target code executed.'
