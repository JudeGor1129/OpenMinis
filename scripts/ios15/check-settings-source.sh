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
  src/ios/Views/Rootfs/RootfsManagementView.swift
  src/ios/Views/Rootfs/ISHTerminalView.swift
  src/ios/Agent/BrowserUse/BrowserManagementView.swift
  src/ios/Views/MCP/MCPFormSheet.swift
  src/ios/Views/MCP/MCPIntegrationsView.swift
  src/ios/Views/MCP/SessionMCPsView.swift
  src/ios/Views/MCP/MCPJSONImportSheet.swift
  src/ios/Views/Skills/SkillsManagementView.swift
  src/ios/Views/Sync/CloudSyncSettingsV2View.swift
  src/ios/Views/Sync/SyncMigrationDetailView.swift
  src/ios/Agent/Background/BackgroundKeepAliveManager.swift
  src/ios/Agent/BrowserUse/BrowserSheetView.swift
  src/ios/Views/Chat/ChatTurnScreenshot.swift
  src/ios/Views/Chat/ToolLiveSheet.swift
  src/ios/Views/Chat/OffloadPermissionDialog.swift
  src/ios/Views/Chat/Media/AudioPlayback.swift
  src/ios/Views/Chat/MinisMediaViews.swift
  src/ios/Views/Chat/Voice/InlineVoiceInputView.swift
  src/ios/Views/Rootfs/RootfsResetButton.swift
  src/ios/WebApp/WebAppAddToHomeSheet.swift
  src/ios/Debug/MessageListTestView.swift
  src/ios/Debug/BrowserBenchTestView.swift
  src/ios/Views/Chat/ChatTurnScreenshot.swift
  src/ios/Views/Chat/WebPreviewSheet.swift
)
pattern='^[[:space:]]*(NavigationStack|LabeledContent|ShareLink)[[:space:]]*[( {]|\.autocorrectionDisabled\(|\.topBar(Leading|Trailing)|\.presentationDetents\(|\.presentationDragIndicator\(|\.scrollDismissesKeyboard\(|\.scrollContentBackground\(|\.toolbarBackground\(|axis: \.vertical'
status=0
# Comment lines cannot call a newer-system API, and several reviewed views
# document the exact API they replaced, so drop them before judging the scan.
matches=$(grep -nE "$pattern" "${files[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//') || status=$?
case "$status" in
  0) printf 'FAIL: reviewed settings contain a direct newer-system call.\n%s\n' "$matches" >&2; exit 1 ;;
  1) printf 'PASS: reviewed settings source regression guard.\n' ;;
  *) printf 'ERROR: source scan failed (grep %s).\n' "$status" >&2; exit "$status" ;;
esac
printf 'NOTE: does not validate compilation, alert text fields, or runtime behavior.\n'
