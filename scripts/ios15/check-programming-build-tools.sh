#!/usr/bin/env bash
# Source guard for the programming build loop. Full Xcode compilation still runs
# in app-diagnostics; this guard catches seam/wiring/truth-state regressions fast.
set -euo pipefail
cd "$(dirname "$0")/../.."

build=src/ios/Agent/Build
chat=src/ios/Agent/Chat/AIChatViewModel+BuildTools.swift
defs=src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift
dispatch=src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift
pbx=src/ios/Minis.xcodeproj/project.pbxproj
tests=src/ios/MinisTests/ProgrammingBuildToolsTests.swift

test -f "$tests" || { echo 'FAIL: programming build unit tests missing'; exit 1; }
grep -q 'testCommandRunnerUsesCapturedExitCodeNotSuccessText' "$tests" || { echo 'FAIL: exit-code truth test missing'; exit 1; }
grep -q 'testBuildRunMigrationIsIdempotent' "$tests" || { echo 'FAIL: migration idempotence test missing'; exit 1; }

for file in BuildModels.swift BuildProjectDetector.swift BuildProviders.swift BuildVerification.swift BuildRunStore.swift ProgrammingBuildTools.swift; do
  test -f "$build/$file" || { echo "FAIL: missing $build/$file"; exit 1; }
  test "$(grep -c "$file in Sources" "$pbx")" -eq 2 || { echo "FAIL: $file must have one PBXBuildFile and one Sources entry"; exit 1; }
done
test -f "$chat" || { echo "FAIL: missing build tool adapter"; exit 1; }
test "$(grep -c 'AIChatViewModel+BuildTools.swift in Sources' "$pbx")" -eq 2 || { echo 'FAIL: build tool adapter not in app Sources'; exit 1; }

for provider in LocalISHBuildProvider TheosBuildProvider RemoteGitHubActionsProvider MacSSHBuildProvider; do
  grep -q "struct $provider: BuildProvider" "$build/BuildProviders.swift" || { echo "FAIL: missing $provider"; exit 1; }
done
grep -q '^protocol BuildProvider' "$build/BuildProviders.swift" || { echo 'FAIL: BuildProvider seam missing'; exit 1; }
grep -q 'state: available ? .available : .unavailable' "$build/BuildProviders.swift" || { echo 'FAIL: providers do not expose structured availability'; exit 1; }

for tool in build_project run_tests analyze_build_log verify_artifact; do
  grep -q "name: \"$tool\"" "$chat" || { echo "FAIL: $tool definition missing"; exit 1; }
  grep -q "\"$tool\"" "$dispatch" || { echo "FAIL: $tool dispatch missing"; exit 1; }
done
grep -q 'programmingBuildToolDefinitions()' "$defs" || { echo 'FAIL: programming tools not registered'; exit 1; }

engine="$build/ProgrammingBuildTools.swift"
grep -q 'execution.exitCode == 0 ? .success : .failed' "$engine" || { echo 'FAIL: build success is not exit-code gated'; exit 1; }
grep -q 'execution.exitCode == 0 ? .passed : .failed' "$engine" || { echo 'FAIL: tests passed is not exit-code gated'; exit 1; }
grep -q 'artifacts.append(await ArtifactVerifier.verify' "$engine" || { echo 'FAIL: artifacts bypass verification'; exit 1; }
grep -q 'request.maxAttempts' "$engine" && grep -q '(1...5)' "$engine" || { echo 'FAIL: repair budget not capped at 3-5 rounds'; exit 1; }

store="$build/BuildRunStore.swift"
for column in project_id project_path git_commit configuration toolchain exit_code diagnostics_json artifact_path log_path created_at cache_fingerprint; do
  grep -q "$column" "$store" || { echo "FAIL: build_runs missing $column"; exit 1; }
done
grep -q 'CREATE TABLE IF NOT EXISTS build_runs' "$store" || { echo 'FAIL: idempotent build_runs migration missing'; exit 1; }
grep -q 'appendingPathComponent("MinisChat"' "$store" || { echo 'FAIL: build_runs must migrate in the existing ChatStore database'; exit 1; }
grep -q 'CREATE INDEX IF NOT EXISTS idx_build_runs_fingerprint' "$store" || { echo 'FAIL: cache fingerprint index missing'; exit 1; }

grep -q 'databaseId,number,status,conclusion,url' "$build/BuildProviders.swift" || { echo 'FAIL: GitHub run id/number/status metadata missing'; exit 1; }
grep -q 'run_logs_url' "$build/BuildProviders.swift" || { echo 'FAIL: GitHub run log metadata missing'; exit 1; }
grep -q '__MINIS_JOB__id=' "$build/BuildProviders.swift" || { echo 'FAIL: GitHub job metadata missing'; exit 1; }
grep -q 'archive_download_url' "$build/BuildProviders.swift" || { echo 'FAIL: GitHub artifact metadata link missing'; exit 1; }
grep -q 'MINIS_MAC_SSH_HOST' "$build/BuildProviders.swift" || { echo 'FAIL: macOS SSH configuration seam missing'; exit 1; }
if grep -REn '(GH_TOKEN|GITHUB_TOKEN|SSH_KEY)[[:space:]]*=' "$build" | grep -v 'test -n' | grep -v 'missingConfiguration' | grep -q .; then
  echo 'FAIL: credential-like value assignment in build implementation'; exit 1
fi

python3 - <<'PY'
from pathlib import Path
v=Path('src/ios/Agent/Build/BuildVerification.swift').read_text()
for needle in ['locationWithColumn', 'locationWithoutColumn', 'makeDiagnostic', 'sha256sum', 'ENTRY_COUNT', 'DEB control', 'ROOTLESS_VIOLATION', 'otool', 'codesign', 'ldid']:
    assert needle in v, f'FAIL: verification coverage missing {needle}'
m=Path('src/ios/Agent/Build/BuildModels.swift').read_text()
assert 'case available' in m and 'case unavailable' in m
assert 'case queued' in m and 'case notRun' in m
print('PASS: BuildProvider seam, high-level tools, exit-code truth gates, verification, cache persistence and remote metadata wiring.')
PY
