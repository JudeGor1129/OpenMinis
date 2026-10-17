#!/bin/bash
# Wiring guards only; full CI compilation and on-device checks remain required.
set -euo pipefail
cd "$(dirname "$0")/../.."
bridge=src/ios/Diagnostics/FridaCoreBridge.m
view=src/ios/Views/Chat/AIChatView.swift
persist=src/ios/Agent/Chat/AIChatViewModel+Persistence.swift
grep -q 'OpenMinisFridaProcessesAsync' src/ios/Diagnostics/FridaCoreBridge.h
grep -q 'frida_device_enumerate_processes_sync' "$bridge"
grep -q 'dispatch_async(OpenMinisFridaQueue()' "$bridge"
grep -q 'g_object_unref(processes)' "$bridge"
grep -q 'name: "frida_processes"' src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift
grep -q 'case "frida_status", "frida_processes":' src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift
grep -q 'case "frida_status", "frida_processes": return .frida' src/ios/Views/Settings/ToolsSettingsView.swift
! grep -Eq 'frida_(device_attach|session_create_script|device_spawn)' "$bridge"
grep -q 'VStack(alignment: message.role == .user ? .trailing : .leading' "$view"
grep -q 'multilineTextAlignment(isUser ? .trailing : .leading)' "$view"
grep -q 'onChange(of: geometry.size.height)' "$view"
grep -q 'if rawIndex.isMultiple(of: 20) { await Task.yield() }' "$persist"
grep -q 'let isLast = aIdx == lastAssistantIndex' "$persist"
printf 'PASS: Frida read-only tool wiring, transcript alignment and cooperative history reconstruction.\n'
printf 'NOTE: not proof of Swift/ObjC compilation, device process visibility or scroll performance.\n'
