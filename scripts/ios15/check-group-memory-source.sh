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
# iOS 15 group UI is an in-place disclosure now: tapping 会话分组 or a group
# must never push a screen. Guard the disclosure wiring and the sheet-hosted
# management entry instead of the old NavigationLink.
grep -q 'DisclosuredGroupHeader(' src/ios/Views/LegacyContentView.swift
grep -q 'sheet(item: \$managingFolder' src/ios/Views/LegacyContentView.swift
grep -q 'LegacyGroupDetailView(folder: folder)' src/ios/Views/LegacyContentView.swift
grep -q 'guard isChatViewVisible' src/ios/Views/Chat/AIChatView.swift
printf 'PASS: group memory/soul, edit/revoke, legacy menu and share-visibility source wiring.\n'
printf 'NOTE: full Swift compilation and device share/scroll/isolation tests are still required.\n'

# Full scrollable history, bulk skills and scoped UI.
grep -Fq 'ForEach(vm.messages)' src/ios/Views/Chat/AIChatView.swift
grep -q 'lastSize != scroll.contentSize || lastBounds != scroll.bounds.size' src/ios/Views/Chat/AIChatView.swift
grep -q 'Button("全部开启")' "$skills"
grep -q 'Button("全部关闭")' "$skills"
grep -q 'MinisGroupMemorySettings(configuration:' "$skills"
grep -q 'groupMemoryEnabled = configuration?.memoryEnabled' "$vm"
[[ $(grep -c 'guard memoryEnabled && groupMemoryEnabled' "$memory") == 2 ]]
! grep -q '未读取到分享内容，请重新分享文件' src/ios/Views/LegacyContentView.swift
printf 'PASS: bounded transcript, bulk skill actions, scoped settings and duplicate-share guards.\n'

grep -q 'let includeMemoryTools = memoryEnabled && groupMemoryEnabled' src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift
[[ $(grep -c 'if memoryEnabled && groupMemoryEnabled' "$vm") == 3 ]]
printf 'PASS: group switch gates prompt status, both injection paths, registration and execution.\n'
