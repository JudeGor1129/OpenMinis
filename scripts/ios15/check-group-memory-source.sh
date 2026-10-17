#!/bin/bash
# Source wiring guards only; not a Swift compiler or runtime test.
set -euo pipefail
cd "$(dirname "$0")/../.."
vm=src/ios/Agent/Chat/AIChatViewModel.swift
memory=src/ios/Agent/Chat/AIChatViewModel+MemoryTools.swift
files=src/ios/Agent/Chat/AIChatViewModel+FileTools.swift
view=src/ios/Views/Chat/SessionMemoryView.swift
skills=src/ios/Views/Chat/SessionSkillsView.swift
router=src/ios/Agent/ISH/MinisFsRouter.swift
# Both initial prompt and provider fallback must retain the same memory scope.
[[ $(grep -c 'loadGlobalMemoryFragment(directory: sessionMemoryDirectory)' "$vm") == 2 ]]
[[ $(grep -c 'loadRecentDailyMemoryFragment(directory: sessionMemoryDirectory)' "$vm") == 2 ]]
grep -q 'await refreshGroupContext()' "$vm"
grep -q 'identitySection(personalityOverride: taskGroupSoul)' "$vm"
grep -q 'let persistDir = sessionMemoryDirectory' "$memory"
grep -q 'let memDir = sessionMemoryDirectory' "$memory"
grep -q 'if taskGroupID == nil' "$memory"
grep -q 'case "memory": base = sessionMemoryDirectory' "$files"
grep -q 'return tail.isEmpty ? sessionMemoryDirectory' "$files"
grep -q 'func setMemoryDirectory' "$router"
grep -q 'func memoryDirectory(for sid:' "$router"
grep -q 'MemoryWriteDetailView(item: item, memoryDirectory: vm.sessionMemoryDirectory)' "$view"
grep -q 'directory: memoryDirectory)' "$view"
grep -q 'directory: vm.sessionMemoryDirectory)' src/ios/Views/Chat/AssistantBlockView.swift
grep -q 'try MinisGroupConfigurationStore.save' "$skills"
! grep -q 'let memDir = AIChatViewModel.minisMemoryPersistentDir' "$view"
! grep -q 'let memDir = AIChatViewModel.minisMemoryPersistentDir' src/ios/Views/Chat/MemoryWriteRevoker.swift
grep -q 'LegacyGroupManagerView()' src/ios/Views/LegacyContentView.swift
grep -q 'guard isChatViewVisible' src/ios/Views/Chat/AIChatView.swift
printf 'PASS: group memory/soul, edit/revoke, legacy menu and share-visibility source wiring.\n'
printf 'NOTE: full Swift compilation and device share/scroll/isolation tests are still required.\n'
