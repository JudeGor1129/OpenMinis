#!/bin/bash
# Source guards only; device execution and full Swift build remain required.
set -euo pipefail
cd "$(dirname "$0")/../.."
f=src/ios/Views/Rootfs/RootfsManagementView.swift
for id in python node git ssh network archive; do
    grep -Fq "id: \"$id\"" "$f"
done
grep -Fq 'MinisEnvironmentPresetsSection()' "$f"
grep -Fq 'MountedFoldersSettingsView()' "$f"
grep -Fq 'guard ISHKernel.shared.isBooted' "$f"
grep -Fq 'RootfsManager.shared.didResetWhileBooted' "$f"
grep -Fq 'timeout: 15' "$f"
grep -Fq 'DispatchQueue.global(qos: .utility)' "$f"
grep -Fq 'ISHTerminalView(showCloseButton: true, initCommand: terminalCommand)' "$f"
grep -Fq '未检测' "$f"
grep -Fq '未完整安装' "$f"
echo 'PASS: six environment presets, explicit install confirmation, bounded guest detection and mount entry.'
