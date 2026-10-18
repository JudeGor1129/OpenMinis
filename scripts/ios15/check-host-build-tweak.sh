#!/bin/bash
# Guard for the on-device Theos build tool [T-host-build-tweak].
#
# This one is unusual: its central claim is about SIGNING, not just code.
# A build tool that cannot exec a foreign binary is worthless, and the
# entitlement that makes exec possible is easy to drop silently.
set -uo pipefail
cd "$(dirname "$0")/../.."

impl=src/ios/Agent/Chat/AIChatViewModel+HostBuildTools.swift
defs=src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift
disp=src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift
ents=src/ios/Minis.entitlements
pbx=src/ios/Minis.xcodeproj/project.pbxproj
fail=0

echo "== tool registration =="
grep -q 'name: "host_build_tweak"' "$defs" || { echo "FAIL: definition missing"; fail=1; }
grep -q 'case "host_build_tweak"' "$disp" || { echo "FAIL: dispatch missing"; fail=1; }
grep -q 'func executeHostBuildTweak' "$impl" || { echo "FAIL: implementation missing"; fail=1; }
echo "  host_build_tweak defined, dispatched and implemented"

echo "== entitlements grant process execution outside the sandbox =="
# Without these two, posix_spawn of /var/jb/usr/bin/clang is denied and the
# tool silently degrades to "launch failed". Twork carries exactly these.
grep -q '<key>platform-application</key>' "$ents" \
  || { echo "FAIL: platform-application missing from Minis.entitlements"; fail=1; }
grep -q '<key>com.apple.private.security.no-sandbox</key>' "$ents" \
  || { echo "FAIL: no-sandbox missing from Minis.entitlements"; fail=1; }
echo "  platform-application + no-sandbox declared"

echo "== entitlements stay small and reviewed =="
# A wildcard claim would be worse than the two specific ones: it hides which
# privileges are actually required.
if grep -q 'get-task-allow' "$ents"; then
    echo "FAIL: get-task-allow is a debug entitlement; do not ship it"; fail=1
fi
echo "  no debug entitlements (get-task-allow absent)"

echo "== packaging keeps the entitlements when signing =="
grep -q -- '--entitlements src/ios/Minis.entitlements' scripts/ios15/package-trollstore.sh \
  || { echo "FAIL: package-trollstore.sh no longer signs the app with Minis.entitlements"; fail=1; }
if grep -q 'No extra platform, unsandboxed' scripts/ios15/package-trollstore.sh; then
    echo "FAIL: INSTALL-NOTES still claims no unsandboxed entitlements were added"; fail=1
fi
echo "  app bundle signed with the updated entitlements file"

echo "== the toolchain is discovered, never assumed =="
grep -q 'makefiles/common.mk' "$impl" \
  || { echo "FAIL: Theos detection must require makefiles/common.mk, not mere existence"; fail=1; }
grep -q '/var/jb/usr/bin/clang' "$impl" || { echo "FAIL: clang paths not probed"; fail=1; }
grep -q 'iPhoneOS' "$impl" || { echo "FAIL: SDK detection missing"; fail=1; }
echo "  Theos validated by common.mk; clang and SDK probed by path"

echo "== absence of a toolchain is reported, not disguised =="
grep -q 'Procursus' "$impl" || { echo "FAIL: must name the package source to install"; fail=1; }
grep -q 'llvm-16' "$impl" || { echo "FAIL: must name installable packages"; fail=1; }
grep -q 'ld64' "$impl" || { echo "FAIL: must name the linker package"; fail=1; }
echo "  missing-toolchain path names Sileo/Procursus packages"

echo "== project is validated before building =="
grep -q 'hostValidateTheosProject' "$impl" || { echo "FAIL: no project validation"; fail=1; }
grep -q 'missing control' "$impl" || { echo "FAIL: control file not checked"; fail=1; }
echo "  Makefile + control + a source file are required"

echo "== pipes are drained concurrently (no 64 KB deadlock) =="
# Reading a pipe only after waitUntilExit() deadlocks once the child fills the
# buffer. A compiler does this immediately, so the readers must run on queues.
grep -q 'readToEnd' "$impl" || { echo "FAIL: output is not drained via readToEnd"; fail=1; }
if grep -q 'waitUntilExit()' "$impl" && ! grep -q 'fileHandleForReading.readToEnd' "$impl"; then
    echo "FAIL: waitUntilExit without concurrent pipe readers can deadlock"; fail=1
fi
grep -q 'DispatchQueue.global' "$impl" || { echo "FAIL: no background drain queues"; fail=1; }
echo "  stdout/stderr drained on background queues"

echo "== a hung build cannot hang the agent =="
grep -q 'timedOut' "$impl" || { echo "FAIL: no timeout tracking"; fail=1; }
grep -q 'SIGKILL' "$impl" || { echo "FAIL: runaway build is never force-killed"; fail=1; }
echo "  timeout enforced; terminate then SIGKILL"

echo "== success requires an artifact, not just exit 0 =="
# "make exited 0" is not evidence that a .deb exists.
grep -q 'artifacts.isEmpty' "$impl" || { echo "FAIL: success is not tied to an artifact"; fail=1; }
grep -q 'packages' "$impl" || { echo "FAIL: packages/ directory not inspected"; fail=1; }
echo "  success == exit 0 AND a .deb/.ipa exists"

echo "== stderr is reported verbatim =="
grep -q 'stderr' "$impl" || { echo "FAIL: stderr not captured"; fail=1; }
grep -q 'hostTail' "$impl" || { echo "FAIL: output not tailed/bounded"; fail=1; }
echo "  compiler errors surfaced, output bounded"

echo "== Xcode registration =="
n=$(grep -c 'HostBuildTools' "$pbx")
[[ "$n" == "4" ]] || { echo "FAIL: expected 4 pbxproj references, found $n"; fail=1; }
echo "  build file, file reference and Sources membership present"

if [[ "$fail" == "0" ]]; then
  echo "PASS: host_build_tweak drives the on-device Theos toolchain."
  echo "NOTE: not proof of compilation. The entitlement only takes effect when the"
  echo "      IPA is installed via TrollStore; a normally-signed build will refuse."
else
  echo "FAILURES above must be fixed."
  exit 1
fi
