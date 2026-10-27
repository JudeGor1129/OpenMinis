#!/bin/bash
# Wiring guards only; full CI compilation and on-device checks remain required.
set -euo pipefail
cd "$(dirname "$0")/../.."
bridge=src/ios/Diagnostics/FridaCoreBridge.m
view=src/ios/Views/Chat/AIChatView.swift
persist=src/ios/Agent/Chat/AIChatViewModel+Persistence.swift
grep -q 'OpenMinisFridaProcessesAsync' src/ios/Diagnostics/FridaCoreBridge.h
grep -q 'OpenMinisFridaDiagnosticsAvailable' src/ios/Diagnostics/FridaCoreBridge.h
grep -q 'frida_device_enumerate_processes_sync' "$bridge"
grep -q 'dispatch_async(OpenMinisFridaQueue()' "$bridge"
grep -q 'g_object_unref(processes)' "$bridge"
grep -q 'name: "frida_status"' src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift
! grep -q 'name: "frida_processes"' src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift
grep -q 'case "frida_status", "frida_processes":' src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift
grep -q 'case "frida_status", "frida_processes": return .frida' src/ios/Views/Settings/ToolsSettingsView.swift
! grep -Eq 'frida_(device_attach|session_create_script|device_spawn)' "$bridge"
grep -q 'Frida Core probing remains disabled' "$bridge"
grep -q 'OpenMinisFridaServerDiagnostics' "$bridge"
grep -q 'VStack(alignment: message.role == .user ? .trailing : .leading' "$view"
# Legacy transcript must render markdown through SelectableMarkdownView, not
# Text(verbatim:), which showed raw ** / ` / - and blocked text selection.
! grep -q 'Text(verbatim: message.content)' "$view"
! grep -q 'Text(verbatim: block.content)' "$view"
# The legacy row now delegates typed blocks to the build70 official renderer.
grep -q 'AssistantBlockView(' "$view"
grep -q 'cachedContent: block.cachedMarkdown' src/ios/Views/Chat/AssistantBlockView.swift
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

# [T-ios15-openurl-bridge] Every SelectableMarkdownView that renders MESSAGE
# content must sit behind MinisOpenURLHandler. The view is a UIViewRepresentable
# hosting a UITextView; the coordinator copies `@Environment(\.openURL)`, which
# without the modifier is the SYSTEM action. `minis://workspace/file` has no
# registered system handler, so tapping a file link in a reply did nothing —
# iOS 15 only, because the modern transcript gets the bridge from
# AssistantBlockView while the legacy one had no wrapper.
for f in src/ios/Views/Chat/AIChatView.swift \
         src/ios/Views/Chat/HelperBlockView.swift \
         src/ios/Views/Chat/PaginatedMarkdownView.swift; do
    total=$(grep -c 'SelectableMarkdownView(' "$f")
    bridged=$(grep -c 'modifier(MinisOpenURLHandler())' "$f")
    [ "$bridged" -ge "$total" ] || {
        echo "FAIL: $f has $total SelectableMarkdownView call(s) but only $bridged MinisOpenURLHandler bridge(s)"
        exit 1
    }
done
echo "  every message-content markdown view bridges openURL to the app handler"

# [T-ios15-longpress-blank-menu] The legacy transcript must NOT wrap the
# markdown view in a SwiftUI .contextMenu: on iOS 15 it swallowed the long
# press and presented an empty menu, so replies could not be selected or
# copied. Guard the regression rather than relying on the comment.
# NOTE: the iOS15 user-bubble menu is a UIKit UIContextMenuInteraction bridge;
# only iOS16+ uses SwiftUI .contextMenu. The assistant markdown view still must
# retain the native UITextView edit menu, so no SwiftUI contextMenu is allowed
# inside the legacy transcript container itself.
transcript=$(awk '/^struct MinisLegacyTranscript:/{found=1; next} found && /^private struct [A-Z]/{exit} found' "$view")
if printf '%s\n' "$transcript" | grep -qE '^[[:space:]]*\.contextMenu'; then
    echo "FAIL: AIChatView.swift reintroduced a SwiftUI .contextMenu inside MinisLegacyTranscript — this suppresses the native edit menu on iOS 15"
    exit 1
fi
grep -Fq 'UIContextMenuInteraction' "$view"
echo "  legacy transcript keeps assistant edit menu native and user menu detached"
# Latest messages occupy native offset zero; only explicit jumps can scroll.
grep -Fq 'proxy.scrollTo(bottomAnchor, anchor: .top)' "$view"
! grep -Fq 'scroll.observe(\.contentOffset' "$view"
! grep -Fq 'Timer(timeInterval: 0.1' "$view"
grep -Fq 'scrollView?.panGestureRecognizer.removeTarget' "$view"
bash scripts/ios15/check-motion-source.sh
printf 'PASS: cached re-entry and event-driven native scroll follow wiring.\n'

# Native mount overlay must not be recopied per session VM.
grep -q 'guard !defaultOverlayApplied else { return }' src/ios/iSH/RootfsManager.swift
grep -q 'defaultOverlayApplied = !overlayFailed' src/ios/iSH/RootfsManager.swift
grep -Fq 'ForEach(vm.messages.reversed())' "$view"
printf 'PASS: process-local mount overlay guard and smaller initial layout batch.\n'
