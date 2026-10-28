#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/ios15/verify-privileged-entitlements.py
helper=tools/privileged-helper/MinisPrivilegedHelper.m
bridge=src/ios/Diagnostics/PrivilegedHelperBridge.m
runner=src/ios/Diagnostics/HelperProcessRunner.c
swift=src/ios/Agent/Chat/AIChatViewModel+SystemFileTools.swift
settings=src/ios/Views/Settings/SystemAccessSettingsView.swift
tests=src/ios/MinisTests/SystemFileToolsTests.swift
project=src/ios/Minis.xcodeproj/project.pbxproj

for file in "$helper" "$bridge" "$runner" "$swift" "$settings" "$tests"; do test -s "$file" || { echo "FAIL missing $file"; exit 1; }; done
! grep -Eq 'system\(|/bin/(sh|bash)|execl|execv|popen|frida_' "$helper"
grep -q 'set_persona_uid_np' "$runner"
grep -q 'MINIS_HELPER_OUTPUT_LIMIT' "$runner"
grep -q 'waitpid' "$runner"
grep -q 'requestPath' "$runner"
grep -q 'NSFilePosixPermissions:@0700' "$bridge"
grep -q 'chmod(temp.fileSystemRepresentation, 0600)' "$bridge"
grep -q 'S_IXUSR' "$bridge"
! grep -q 'access(path.fileSystemRepresentation, X_OK)' "$bridge"
grep -q 'UIApplicationDidEnterBackgroundNotification' "$bridge"
grep -q 'OpenMinisCancelPrivilegedRequests' "$bridge"
for action in identity read write rollback; do grep -q "@\"$action\"" "$helper"; done
for denied in Keychains /private/var/db /private/preboot /System /dev /var/jb/basebin; do grep -q "$denied" "$helper"; done
grep -q '/var/jb/var/tmp' "$helper"
grep -q '/var/jb/usr/local' "$helper"
grep -q 'realpath_outside_tier' "$helper"
grep -q 'extension_denied' "$helper"
grep -q 'dylib replacement is not supported' "$helper"
grep -q 'expected_sha_race' "$helper"
grep -q 'fsync' "$helper"
grep -q 'rename(temp.fileSystemRepresentation' "$helper"
grep -q 'system-access.jsonl' "$helper"
grep -q 'SystemWriteConfirmer.shared.confirm' "$swift"
grep -q 'testDirectHostWritesCannotBypassSystemConfirmation' "$tests"
grep -q 'system_file_write' "$swift"
grep -q 'system_file_rollback' "$swift"
grep -q 'Direct host_write_\* calls never bypass confirmation' src/ios/Agent/Chat/AIChatViewModel+HostWriteTools.swift
for name in AIChatViewModel+SystemFileTools.swift SystemAccessSettingsView.swift HelperProcessRunner.c PrivilegedHelperBridge.m; do
  test "$(grep -Fc "/* $name in Sources */" "$project")" -eq 2 || { echo "FAIL target membership $name"; exit 1; }
done
sh scripts/ios15/check-privileged-runner.sh
bash -n scripts/ios15/package-trollstore.sh scripts/ios15/build-privileged-helper.sh scripts/ios15/build-diagnostics.sh
if command -v xcrun >/dev/null; then
  SDK=$(xcrun --sdk iphoneos --show-sdk-path)
  xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -std=c11 -fsyntax-only -Werror "$runner"
  xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -fobjc-arc -fblocks -fsyntax-only -Werror -I src/ios/Diagnostics "$bridge"
  xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -fobjc-arc -fblocks -fsyntax-only -Werror "$helper"
else
  echo 'NOTE: Apple SDK syntax and persona runtime checks run in macOS CI/device.'
fi
echo 'PASS: isolated root helper, path tiers, confirmation, atomic backup, audit and rollback wiring.'
