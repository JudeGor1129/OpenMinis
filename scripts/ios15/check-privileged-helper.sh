#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/ios15/verify-privileged-entitlements.py
bridge=src/ios/Diagnostics/FridaCoreBridge.m
helper=tools/privileged-helper/MinisPrivilegedHelper.m
runner=src/ios/Diagnostics/HelperProcessRunner.c
locator=src/ios/Shared/ContainerLocator.swift
grep -q 'MCMMetadataIdentifier' "$locator"
grep -q 'Library/MinisChat/minis.db' "$locator"
grep -q 'ContainerLocator.libraryDirectory' src/ios/Agent/Chat/ChatStore.swift
grep -q 'ContainerLocator.documentsDirectory' src/ios/iSH/RootfsManager.swift
grep -q 'ContainerLocator.libraryDirectory' src/ios/Agent/Session/SkillStore.swift
grep -q 'ContainerLocator.libraryDirectory' src/ios/Shared/EnvVarStore.swift
if grep -Eq 'com.apple.private.security.no-sandbox' src/ios/Minis.entitlements; then
  echo 'FAIL: common app entitlements must not disable sandbox'; exit 1
fi
if grep -Eq 'frida_init\(|frida_device_manager_new\(' "$bridge"; then
  echo 'FAIL: Frida Core entered GUI process'; exit 1
fi
if grep -Eq 'frida_device_manager_new\(|frida_device_manager_enumerate_devices' "$helper"; then
  echo 'FAIL: automatic local backend is forbidden'; exit 1
fi
if grep -Eq 'frida_(device_attach|device_spawn|session_create_script)' "$helper"; then
  echo 'FAIL: unreviewed attach/spawn/script entry point'; exit 1
fi
grep -q 'frida_device_manager_new_with_socket_backend_only' "$helper"
grep -q '127.0.0.1:27042' "$helper"
grep -q 'ParentLease' "$helper"
grep -q 'AwaitLaunchPermit' "$helper"
grep -q 'alarm(12)' "$helper"
grep -q 'root_verified' "$helper"
grep -q 'getuid() == 0 && geteuid() == 0 && getgid() == 0 && getegid() == 0' "$helper"
grep -q 'gid.*egid' "$helper"
grep -q 'json\[@"gid"\].*intValue] == 0' src/ios/Diagnostics/PrivilegedHelperBridge.m
grep -q 'json\[@"egid"\].*intValue] == 0' src/ios/Diagnostics/PrivilegedHelperBridge.m
grep -q 'set_persona_uid_np' "$runner"
grep -q 'MINIS_HELPER_OUTPUT_LIMIT' "$runner"
grep -q 'waitpid' "$runner"
grep -q 'POSIX_SPAWN_CLOEXEC_DEFAULT' "$runner"
sh scripts/ios15/check-privileged-runner.sh
bash -n scripts/ios15/package-trollstore.sh scripts/ios15/build-privileged-helper.sh scripts/ios15/build-diagnostics.sh
if ! command -v xcrun >/dev/null; then
  echo 'NOTE: Apple SDK checks will run in macOS CI; on-device root/Frida not tested.'
  exit 0
fi
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
  -std=c11 -fsyntax-only -Werror "$runner"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
  -fobjc-arc -fblocks -fsyntax-only -Werror \
  src/ios/Diagnostics/PrivilegedHelperBridge.m "$bridge"
xcrun --sdk iphoneos swiftc -typecheck -swift-version 6 \
  -target arm64-apple-ios15.0 -sdk "$SDK" \
  -import-objc-header src/ios/Diagnostics/PrivilegedHelperBridge.h \
  scripts/ios15/PrivilegedToolsTypecheckSupport.swift \
  src/ios/Views/Settings/PrivilegedToolsSection.swift
echo 'PASS: real native bridge and isolated settings type-check for iOS15; no privileged operation executed.'
