#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
store=src/ios/Shared/GroupWorkspaceStore.swift
chat=src/ios/Agent/Chat/ChatStore.swift
router=src/ios/Agent/ISH/MinisFsRouter.swift
view=src/ios/Views/ContentView.swift
pbx=src/ios/Minis.xcodeproj/project.pbxproj
tests=src/ios/MinisTests/GroupWorkspaceStoreTests.swift
for f in "$store" "$tests"; do test -s "$f" || { echo "FAIL missing $f"; exit 1; }; done
test "$(grep -Fc '/* GroupWorkspaceStore.swift in Sources */' "$pbx")" -eq 2
grep -q 'GroupWorkspaceStore.ensure(folderID: folder.id, name: folder.name)' "$chat"
grep -q 'GroupWorkspaceStore.adoptSessionWorkspace' "$chat"
grep -q 'setWorkspaceDirectory' "$router"
grep -q 'workspaceDirectory(for sid:' "$router"
grep -q 'sessionWorkspaceDirectory' src/ios/Agent/Chat/AIChatViewModel.swift
grep -q '(sessionWorkspaceDirectory, Self.minisWorkspaceLinuxDir)' src/ios/Agent/Chat/AIChatViewModel+Offloading.swift
grep -q 'rootPath: vm.sessionWorkspaceDirectory' src/ios/Views/Chat/AIChatView.swift
grep -q '删除分组时如何处理工作区' "$view"
grep -q '保留工作区' "$view"
grep -q '删除工作区' "$view"
grep -q 'GroupWorkspaceStore.remove' "$view"
grep -q 'GroupWorkspaceStore.merge' "$view"
grep -q '解散并保留工作区' src/ios/Views/LegacyContentView.swift
grep -q '解散并删除工作区' src/ios/Views/LegacyContentView.swift
grep -q 'preserve: true' "$chat"
grep -q 'testDirectoryNameUsesGroupNameAndStableIdentity' "$tests"
echo 'PASS: named group workspace creation, routing, migration, merge and delete/preserve prompts are wired.'
