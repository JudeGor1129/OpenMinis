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
locator=src/ios/Shared/ContainerLocator.swift

for file in "$helper" "$bridge" "$runner" "$swift" "$settings" "$tests" "$locator"; do test -s "$file" || { echo "FAIL missing $file"; exit 1; }; done
grep -q 'MCMMetadataIdentifier' "$locator"
grep -q 'Library/MinisChat/minis.db' "$locator"
grep -q 'ContainerLocator.libraryDirectory' src/ios/Agent/Chat/ChatStore.swift
grep -q 'ContainerLocator.documentsDirectory' src/ios/iSH/RootfsManager.swift
grep -q 'ContainerLocator.libraryDirectory' src/ios/Agent/Build/BuildRunStore.swift
# Root persona cannot open app-container files on Xina; helper state is the
# fixed rootless temp directory, which the helper canonicalizes itself.
grep -q 'URL(fileURLWithPath: "/var/jb/var/tmp/MinisSystemAccess", isDirectory: true)' "$swift"
! grep -q 'AppLogger' "$locator"
grep -q 'static var applicationSupportDirectory' "$locator"
grep -q 'static var cachesDirectory' "$locator"
if find src/ios -name '*.swift' ! -name 'ContainerLocator.swift' -exec grep -HE 'FileManager\.default\.urls\(for: \.(documentDirectory|libraryDirectory|applicationSupportDirectory|cachesDirectory)' {} + | grep -q .; then
  echo 'FAIL: implicit app-container path remains under no-sandbox'; exit 1
fi
if grep -q 'com.apple.private.security.no-sandbox' src/ios/Minis.entitlements; then
  echo 'FAIL: common app entitlement set must stay sandboxed'; exit 1
fi
! grep -Eq 'system\(|/bin/(sh|bash)|execl|execv|popen|frida_' "$helper"
grep -q 'set_persona_uid_np' "$runner"
grep -q 'MINIS_HELPER_OUTPUT_LIMIT' "$runner"
grep -q 'waitpid' "$runner"
# Request bodies travel on a dedicated FD 3 frame channel, never on disk/argv.
grep -q 'posix_spawn_file_actions_adddup2(&actions, request\[0\], 3)' "$runner"
grep -q 'pump_request' "$runner"
grep -q 'SO_NOSIGPIPE' "$runner"
grep -q 'MinisHelperReadRequestFrame(MINIS_HELPER_REQUEST_FD' "$helper"
grep -q 'MINIS_HELPER_REQUEST_LIMIT (3u \* 1024u \* 1024u)' tools/privileged-helper/HelperLease.h
grep -q 'argc != 2' "$helper"
! grep -q 'requestPath' "$runner" "$helper" "$bridge"
! grep -q 'WriteRequestFile' "$bridge"
! grep -q 'requestDirectoryURL' "$swift" "$bridge" src/ios/Diagnostics/PrivilegedHelperBridge.h
! grep -q 'MinisSystemAccess/Requests' "$swift" "$helper"
grep -q 'requestBody.bytes, requestBody.length' "$bridge"
grep -q 'withTaskCancellationHandler' "$swift"
grep -q 'request.cancel()' "$swift"
# The helper resolves its own backup/audit root under the active bootstrap.
grep -q 'static NSString \*StateBase(' "$helper"
grep -q 'var/tmp/MinisSystemAccess' "$helper"
! grep -q 'URLsForDirectory:NSLibraryDirectory' "$bridge"
grep -q 'MinisValidateHelperResponse' "$bridge"
grep -q 'MinisHelperHasZeroID' src/ios/Diagnostics/HelperResponseValidation.h
# ValidateTarget returns response paths beyond its stack frame. Keep them
# ARC-owned; unsafe_unretained caused a device SIGSEGV while building JSON.
grep -q '@interface SafePath : NSObject' "$helper"
grep -Fq '@property(nonatomic, copy) NSString *literal;' "$helper"
! grep -Fq '__unsafe_unretained NSString *literal' "$helper"
python3 - <<'PY'
from pathlib import Path
source = Path('tools/privileged-helper/MinisPrivilegedHelper.m').read_text()
main = source[source.index('int main('):]
assert main.index('DoIdentity(action)') < main.index('ConsumeFramedRequest('), 'identity must not depend on request validation'
assert main.index('ConsumeFramedRequest(') < main.index('root_validation'), 'request must be framed before root checks'
assert 'IdentityFields()' in source[source.index('static void Fail('):source.index('static NSString *StateBase(')]
print('PASS: early helper errors preserve stage and actual IDs; identity is independent of request validation.')
PY
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
sh scripts/ios15/check-helper-response.sh
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
