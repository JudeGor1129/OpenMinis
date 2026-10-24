#!/bin/bash
# Source guards for RootFS toolchain/SDK selection and explicit build flow.
set -euo pipefail
cd "$(dirname "$0")/../.."
view=src/ios/Views/Rootfs/RootfsBuildSettingsView.swift
pbx=src/ios/Minis.xcodeproj/project.pbxproj
[ -f "$view" ] || { echo 'FAIL: missing RootfsBuildSettingsView.swift'; exit 1; }
grep -q 'struct RootfsBuildSettingsView: View' "$view"
grep -q 'struct IOSDKSelectionView: View' "$view"
grep -q 'class RootfsBuildSettingsViewModel: ObservableObject' "$view"
grep -q 'rootfs.selectedIPhoneOSSDK' "$view"
grep -q 'iPhoneOS\*.sdk' "$view"
grep -q 'SDKROOT=' "$view"
grep -q 'SDKVERSION=' "$view"
grep -q 'THEOS_PLATFORM_SDK=' "$view"
grep -q "make package FINALPACKAGE=1 ARCHS='arm64 arm64e'" "$view"
grep -q 'ISHTerminalView(showCloseButton: true, initCommand: model.buildCommand)' "$view"
# Build must be an explicit terminal action, not a hidden shell execution.
! grep -q 'executeCommandSync' "$view"
grep -q 'E5RF0001 /\* RootfsBuildSettingsView.swift in Sources \*/' "$pbx"
grep -q 'E5RF0002 /\* RootfsBuildSettingsView.swift \*/' "$pbx"
grep -q 'RootfsBuildSettingsView()' src/ios/Views/Rootfs/RootfsManagementView.swift
status=src/ios/Views/Rootfs/ToolchainStatusView.swift
grep -q 'frame(width: 148' "$status"
grep -q 'truncationMode(.middle)' "$status"
grep -q 'minimumScaleFactor(0.75)' "$status"
printf 'PASS: RootFS toolchain summary, SDK picker, persistence and explicit Release build flow are registered.\n'
