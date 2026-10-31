#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

PROJECT=src/ios/Minis.xcodeproj/project.pbxproj
DIAGNOSTICS=src/ios/Vendor/OMToolchain/OMToolchainDiagnostics.m
HEADER=src/ios/Vendor/OMToolchain/OMToolchainDiagnostics.h
BRIDGE=src/ios/MinisApp-Bridging-Header.h
PROVIDER=src/ios/Agent/Build/EmbeddedToolchainBuildProvider.swift
VIEW=src/ios/Views/Rootfs/RootfsBuildSettingsView.swift

for file in "$DIAGNOSTICS" "$HEADER" "$BRIDGE" "$PROVIDER" "$VIEW"; do
  [[ -f "$file" ]] || { echo "error: missing runtime diagnostic source: $file" >&2; exit 1; }
done
plutil -lint "$PROJECT"

python3 - "$PROJECT" "$DIAGNOSTICS" "$HEADER" "$BRIDGE" "$PROVIDER" "$VIEW" <<'PY'
from pathlib import Path
import sys
project, impl, header, bridge, provider, view = [Path(p).read_text(encoding="utf-8") for p in sys.argv[1:]]

def require(condition, message):
    if not condition:
        raise SystemExit("runtime diagnostic source gate failed: " + message)

require(project.count("D0A173000000000000000003") == 2,
        "diagnostic build-file ID must be defined once and listed once in the main target")
require(project.count("D0A173000000000000000014") == 3,
        "diagnostic implementation reference must connect build file, file reference and group")
require(project.count("D0A173000000000000000013") == 2,
        "diagnostic header reference must appear in the file table and group")
require('OMToolchainDiagnostics.h"' in bridge, "diagnostic header missing from Swift bridge")
require("runSuiteWithIterations:(NSUInteger)iterations" in header,
        "public surface must accept only a bounded iteration count")
require("MIN(iterations, (NSUInteger)3)" in impl, "diagnostic iteration count must be capped at three")
require("output_execution_attempted\": @NO" in impl, "report must state generated output is never executed")
require("runtime_verification_gate\": @\"not_granted\"" in impl,
        "diagnostic report must not claim the runtime gate")
for forbidden in ("dlopen(", "NSBundle bundleWithPath", "system(", "popen(", "posix_spawn("):
    require(forbidden not in impl, "diagnostic implementation must not execute code or spawn processes: " + forbidden)
require("-fptrauth-returns" in impl and "b_key_return_signing" in impl,
        "arm64e diagnostics must inspect deterministic B-key return signing")
require("expected_clang_failure" in impl and "clang_recovery_after_failure" in impl,
        "clang diagnostic and recovery checks are required")
require("expected_linker_failure" in impl and "linker_recovery_after_failure" in impl,
        "linker diagnostic and recovery checks are required")
require("compile_arm64_objective_c" in impl, "freestanding Objective-C fixture is required")
require("Task.detached" in view and "最多重复 3 轮" in view,
        "UI must run off-main and disclose the bounded repetition")
require(provider.count(".unavailable(await availability(for: context))") == 2,
        "BuildProvider build/test must remain unavailable")
require("state: .unavailable" in provider, "BuildProvider availability must remain unavailable")
print("PASS: fixed-fixture runtime diagnostic source policy and Provider lock verified.")
PY

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -isysroot "$SDK" \
  -fobjc-arc -Wall -Wextra -Werror \
  -I src/ios/Vendor/OMToolchain -fsyntax-only "$DIAGNOSTICS"

echo 'PASS: runtime diagnostics compile with the selected iPhoneOS SDK.'
echo 'NOTE: no LLVM/ld64 entry point was executed by this source gate.'
