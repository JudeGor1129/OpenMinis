#!/bin/bash
# Source guards for the native Theos/SDK settings page.
#
# The page no longer probes or drives the iSH compiler stack (clang/ld64/ldid/
# make): native compilation happens in-process, so only the built-in compiler
# status plus SDK library management remain.
set -euo pipefail
cd "$(dirname "$0")/../.."
view=src/ios/Views/Rootfs/RootfsBuildSettingsView.swift
manager=src/ios/Views/Rootfs/IOSDKManagerView.swift
library=src/ios/Views/Rootfs/ToolchainSDKLibrary.swift
pbx=src/ios/Minis.xcodeproj/project.pbxproj

fail() { echo "FAIL: $1"; exit 1; }
for f in "$view" "$manager" "$library"; do
  [ -f "$f" ] || fail "missing $f"
done
have() { grep -q -- "$1" "$2" || fail "$2 is missing: $1"; }
absent() { if grep -q -- "$1" "$2"; then fail "$2 must not contain: $1"; fi; }

have 'struct RootfsBuildSettingsView: View' "$view"
have 'IOSDKManagerView()' "$view"
have 'ToolchainSDKLibrary' "$view"
have 'Theos 与 SDK' "$view"
# The iSH compiler stack must be gone from this page and its entry point.
absent 'ToolchainStatusView' "$view"
absent 'ISHTerminalView' "$view"
absent 'RootfsBuildSettingsViewModel' "$view"
absent 'IOSDKSelectionView' "$view"

have 'struct IOSDKManagerView: View' "$manager"
have 'fileImporter' "$manager"
have 'arrow.down.circle' "$manager"
have 'ToolchainSDKImportRow()' "$manager"

have 'class ToolchainSDKLibrary: ObservableObject' "$library"
have 'toolchain.selectedSDKVersion' "$library"
have 'BackupZipExtractor.extract' "$library"
have 'URLSession.shared.download' "$library"
have 'usr/lib/libSystem.B.tbd' "$library"
have 'materializePlaceholderSymlinks' "$library"
# The SDK library is pure file management: no shell, no process spawn.
if grep -qE 'Process\(|posix_spawn|system\(|executeCommandSync' "$library"; then
  fail "$library must not execute commands"
fi

have 'E5RF0001 /\* RootfsBuildSettingsView.swift in Sources \*/' "$pbx"
have 'E5SDK0001 /\* ToolchainSDKLibrary.swift in Sources \*/' "$pbx"
have 'E5SDK0011 /\* IOSDKManagerView.swift in Sources \*/' "$pbx"

have 'RootfsBuildSettingsView()' src/ios/Views/Rootfs/RootfsManagementView.swift
absent 'ToolchainStatusView' src/ios/Views/Rootfs/RootfsManagementView.swift

printf 'PASS: native Theos/SDK settings, ZIP import, download entry and SDK library are registered; iSH compiler UI is gone.\n'
