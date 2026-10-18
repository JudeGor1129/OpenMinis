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
# Legacy transcript must render markdown through SelectableMarkdownView, not
# Text(verbatim:), which showed raw ** / ` / - and blocked text selection.
! grep -q 'Text(verbatim: message.content)' "$view"
! grep -q 'Text(verbatim: block.content)' "$view"
grep -q 'cachedContent: block.cachedMarkdown' "$view"
grep -q 'scroll.isTracking || scroll.isDragging || scroll.isDecelerating' "$view"
grep -q '.frame(width: max(0, viewport.size.width - 36)' "$view"
! grep -q 'else if followingBottom && !nearBottom' "$view"
grep -q 'precacheTail = 0' "$persist"
grep -q 'LegacySessionDestination(sessionID: session.id)' src/ios/Views/LegacyContentView.swift
grep -q 'if rawIndex.isMultiple(of: 20) { await Task.yield() }' "$persist"
grep -q 'let isLast = aIdx == lastAssistantIndex' "$persist"
printf 'PASS: Frida read-only tool wiring, transcript alignment and cooperative history reconstruction.\n'
printf 'NOTE: not proof of Swift/ObjC compilation, device process visibility or scroll performance.\n'

# Diagnose backend visibility without attributing every empty list to sandboxing.
grep -q 'g_strcmp0(deviceID, "local")' "$bridge"
grep -q 'g_strcmp0(deviceID, "socket")' "$bridge"
grep -q 'g_cancellable_cancel(cancel)' "$bridge"
grep -q 'Empty result from this backend; cause undetermined' "$bridge"
grep -q 'No built-in backend completed process enumeration' "$bridge"
! grep -q 'frida_device_manager_get_device_by_type_sync' "$bridge"
printf 'PASS: built-in backend allowlist, cooperative cancellation and empty-result diagnostics.\n'

# Re-entry should not rebuild full history; streaming tracks content size, not offset.
! grep -q 'if cached.isNew || (vm.messages.isEmpty' "$view"
! grep -q 'await vm.reloadMessagesFromDB(reason: "AIChatView.onAppear-reuse")' "$view"
grep -q '.background(MinisLegacyScrollFollow(' "$view"
# The floating tool preview must be reserved in the legacy transcript's bottom
# inset, otherwise the "Minis 电脑" panel covers the newest message on iOS 15.
grep -q 'bottomInset: inputBarHeight + floatingBarHeight' "$view"
! grep -q 'MinisLegacyTranscript(vm: vm, bottomInset: inputBarHeight + 24)' "$view"
grep -q 'scroll.setContentOffset(CGPoint' "$view"
grep -q 'lastSize != scroll.contentSize' "$view"
printf 'PASS: cached re-entry and native scroll follow wiring.\n'

# Native mount overlay must not be recopied per session VM.
grep -q 'guard !defaultOverlayApplied else { return }' src/ios/iSH/RootfsManager.swift
grep -q 'defaultOverlayApplied = !overlayFailed' src/ios/iSH/RootfsManager.swift
grep -q 'visibleLimit = 12' "$view"
printf 'PASS: process-local mount overlay guard and smaller initial layout batch.\n'
