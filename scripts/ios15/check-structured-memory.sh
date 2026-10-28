#!/bin/bash
set -euo pipefail

root=src/ios/Agent/Chat
model=$root/StructuredMemory.swift
store=$root/ChatStore+StructuredMemory.swift
bridge=$root/AIChatViewModel+StructuredMemory.swift
project=src/ios/Minis.xcodeproj/project.pbxproj
tests=src/ios/MinisTests/StructuredMemoryTests.swift
ui=src/ios/Views/Settings/MemoryManagementView.swift

for f in "$model" "$store" "$bridge" "$tests"; do
  [[ -s "$f" ]] || { echo "FAIL: missing structured-memory file $f"; exit 1; }
done
for table in projects memories task_checkpoints token_budget_samples token_budget_calibrations; do
  grep -q "CREATE TABLE IF NOT EXISTS $table" "$store" || { echo "FAIL: missing table $table"; exit 1; }
done
grep -q 'CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5' "$store"
grep -q 'memories_fts MATCH' "$store"
grep -q 'LIKE ?' "$store"
grep -q 'TextSegmenter.shared.segmentForSearch' "$store"
grep -q 'supersedes_id' "$store"
grep -q 'MemoryCredentialGuard.admits' "$store"
grep -q 'structuredMemoryPromptFragment' src/ios/Agent/Chat/AIChatViewModel.swift
grep -q 'recordTokenBudgetSample' src/ios/Agent/Chat/AIChatViewModel.swift
grep -q 'captureProjectContext' src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift
for tool in memory_manage create_checkpoint; do
  grep -q "name: \"$tool\"" src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift
  grep -q "case \"$tool\"" src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift
done
for heading in 'Goal' 'Acceptance Criteria' 'Facts & Constraints' 'Completed Steps' 'Changed Files' 'Commands Run' 'Test Results' 'Failures & Blockers' 'Next Action'; do
  grep -q "## $heading" src/ios/Agent/Chat/AIChatViewModel+Compaction.swift || { echo "FAIL: checkpoint heading missing: $heading"; exit 1; }
done
grep -q 'linkTaskCheckpoint' src/ios/Agent/Chat/AIChatViewModel+Compaction.swift
grep -q 'StructuredMemoryCenterView' "$ui"
grep -q 'memory.structured.auto.enabled' "$ui"
for file in StructuredMemory.swift ChatStore+StructuredMemory.swift AIChatViewModel+StructuredMemory.swift; do
  [[ "$(grep -Fc "/* $file in Sources */" "$project")" -eq 2 ]] || { echo "FAIL: $file is not in Minis Sources"; exit 1; }
done
grep -q 'testFTSChineseSearchAndSupersession' "$tests"
grep -q 'testCredentialAdmissionRejectsSecrets' "$tests"
grep -q 'testCheckpointCodecPreservesRecoveryFields' "$tests"

echo 'PASS: scoped structured memory, FTS5/CJK fallback, checkpoints, token calibration, tools, UI and tests are wired.'
