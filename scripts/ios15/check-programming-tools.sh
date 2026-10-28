#!/bin/bash
set -euo pipefail

impl=src/ios/Agent/Chat/AIChatViewModel+ProgrammingTools.swift
defs=src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift
dispatch=src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift
stream=src/ios/Agent/Chat/AIChatViewModel+SSEStream.swift
project=src/ios/Minis.xcodeproj/project.pbxproj
tests=src/ios/MinisTests/ProgrammingToolsTests.swift

for f in "$impl" "$defs" "$dispatch" "$stream" "$tests"; do
  [[ -s "$f" ]] || { echo "FAIL: missing programming-tools file: $f"; exit 1; }
done
for tool in inspect_project search_code project_read_file apply_patch git_status git_diff run_lint run_tests; do
  grep -Rq "name: \"$tool\"" src/ios/Agent/Chat/AIChatViewModel+*.swift || { echo "FAIL: missing tool definition $tool"; exit 1; }
  grep -q "\"$tool\"" "$dispatch" || { echo "FAIL: missing tool dispatch $tool"; exit 1; }
done
[[ "$(grep -c 'name: "file_read"' "$defs")" -eq 1 ]] || { echo 'FAIL: canonical file_read must be registered exactly once'; exit 1; }
[[ "$(grep -Rh 'name: "run_tests"' src/ios/Agent/Chat/AIChatViewModel+*.swift | wc -l | tr -d ' ')" -eq 1 ]] || { echo 'FAIL: run_tests must have one canonical definition'; exit 1; }
grep -q 'caseInsensitiveCompare(expectedHash)' "$impl"
grep -q 'status --porcelain=v1' "$impl"
grep -q 'replaceItemAt' "$impl"
grep -q 'ProjectWriteLockRegistry.shared.withLock' "$impl"
grep -q 'ProgrammingPathPolicy.projectRelativePath' "$impl"
grep -q 'EnvVarRedactor.redactIfEnabled' "$impl"
[[ "$(grep -c 'AIChatViewModel+ProgrammingTools.swift in Sources' "$project")" -ge 2 ]] || { echo 'FAIL: ProgrammingTools not added to Minis Sources phase'; exit 1; }
grep -q 'testRelativePathRejectsProjectEscape' "$tests"

echo 'PASS: structured project index, safe patching, Git/lint/test tools, stream UI, Xcode wiring and safety tests.'
