#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# Narrow source regression guard, NOT a Swift compiler or availability audit.
# Sync views are explicitly iOS 17-only, so their newer toolbar is intentional.
files=(
  src/ios/Views/Settings/BackupDestinationDetailView.swift
  src/ios/Views/Settings/BackupDestinationPicker.swift
  src/ios/Views/Settings/BackupRestoreView.swift
  src/ios/Views/Settings/BackupSettingsView.swift
  src/ios/Views/Settings/BackupHistoryDetailView.swift
  src/ios/Views/Settings/BackupSkippedFilesView.swift
  src/ios/Views/Settings/RcloneAddServerView.swift
  src/ios/Views/Settings/EnvironmentVariablesView.swift
  src/ios/Views/Settings/MountedFoldersSettingsView.swift
  src/ios/Views/Settings/MountDetailView.swift
  src/ios/Views/Settings/HelperSettingsView.swift
  src/ios/Views/Settings/SoulSettingsView.swift
  src/ios/Views/Settings/MemoryManagementView.swift
  src/ios/Views/Settings/LogManagementView.swift
  src/ios/Views/Providers/GroupSlotPicker.swift
  src/ios/Views/Providers/ModelGroupsView.swift
  src/ios/Views/Providers/UnifiedModelPicker.swift
  src/ios/Views/Providers/ModelQuickTestSheet.swift
  src/ios/Views/Providers/ProviderInstancesView.swift
  src/ios/Views/Providers/AddProviderView.swift
  src/ios/Views/Providers/KimiDeviceLoginSheet.swift
  src/ios/Views/Providers/CopilotDeviceLoginSheet.swift
  src/ios/Views/Providers/ProviderInstanceDetailView.swift
  src/ios/Views/Providers/ThinkingRuleEditorView.swift
  src/ios/Views/Providers/ShadowVoiceProviderDetailView.swift
  src/ios/Views/Providers/OnboardingModelSelectionView.swift
  src/ios/Views/Providers/ModelGroupDetailView.swift
  src/ios/Views/Providers/AgentLoopModelsView.swift
  src/ios/Views/Chat/UsageStatsView.swift
  src/ios/Views/Chat/SessionMemoryView.swift
  src/ios/Views/Chat/SessionSkillsView.swift
  src/ios/Views/Chat/ChatInputBar.swift
  src/ios/Views/Chat/WebPreviewSheet.swift
  src/ios/Views/Chat/AssistantBlockView.swift
)
pattern='^[[:space:]]*(NavigationStack|LabeledContent|ShareLink)[[:space:]]*[( {]|\.autocorrectionDisabled\(|\.topBar(Leading|Trailing)|\.presentationDetents\(|\.presentationDragIndicator\(|\.scrollDismissesKeyboard\(|\.scrollContentBackground\(|axis: \.vertical'
status=0
grep -nE "$pattern" "${files[@]}" || status=$?
case "$status" in
  0) printf 'FAIL: reviewed settings contain a direct newer-system call.\n' >&2; exit 1 ;;
  1) printf 'PASS: reviewed settings source regression guard.\n' ;;
  *) printf 'ERROR: source scan failed (grep %s).\n' "$status" >&2; exit "$status" ;;
esac
printf 'NOTE: does not validate compilation, alert text fields, or runtime behavior.\n'
