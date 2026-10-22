#!/bin/bash
# Source guards, not compilation or evidence that a runtime crash is fixed.
# Build70 restart guard: this file is intentionally under scripts/ios15 so
# changes to the active baseline reliably trigger the diagnostic workflow.
set -euo pipefail
cd "$(dirname "$0")/../.."
view=src/ios/Views/Chat/AIChatView.swift
row=$(sed -n '/^private struct MinisLegacyTranscriptRow:/,/^private struct MinisLegacyTranscriptBlock:/p' "$view")
require() {
    grep -Fq "$1" <<< "$row" || {
        printf 'FAIL: build70 message row missing %s\n' "$1"; exit 1;
    }
}
require 'Text(userDisplayText)'
require 'fontSettings.scaledMessage(16.5)'
require 'AssistantBlockView('
require '.environmentObject(vm)'
require 'ToolLiveSheet(toolBlocks: tools,'
require 'toolSnapshots: vm.toolSnapshots'
require '.textSelection(.enabled)'
require '.fixedSize(horizontal: false, vertical: true)'
require 'private var systemDivider: some View'
require 'message.role == .compactDivider || message.role == .systemInfo'
require '.opacity(message.isCompactedHistory ? 0.5 : 1)'
require '.padding(.horizontal, 14)'
require '.padding(.vertical, 10)'
require 'RoundedRectangle(cornerRadius: 18)'
require '.fill(message.isQueued ? Color.clear : ChatColors.userBubble)'
require 'StrokeStyle(lineWidth: 1.5, dash: [6, 4])'
require '.padding(.leading, message.role == .user ? 60 : 0)'
require 'range: start.upperBound..<text.endIndex'
require 'AssistantSoulName()'
require 'Image("AssistantAvatar")'
grep -Fq '.onReceive(vm.forceScrollToTop)' "$view"
grep -Fq 'vm.isNearBottom = follows' "$view"
grep -Fq 'ContextUsageHint.make(usage: $0, generation: -1)' "$view"
require 'UserAttachmentList(attachments: message.attachments)'
require 'QueuedAttachmentPreview(attachments: message.inputAttachments)'
require '.modifier(MinisOpenURLHandler())'
if grep -Eq '^[[:space:]]*\.contextMenu|Label\(message.role|\.padding\(message.role' <<< "$row"; then
    echo 'FAIL: recovery labels, doubled inset or SwiftUI context menu reintroduced'; exit 1
fi
# This is intentionally build70's iOS15 path, NOT the later collection renderer.
area=$(sed -n '/private var messagesArea:/,/private struct MinisLegacyTranscript:/p' "$view")
grep -Fq 'if #available(iOS 16.0, *)' <<< "$area"
grep -Fq 'MinisLegacyTranscript(' <<< "$area"
grep -Fq '@State private var visibleLimit = 12' "$view"
grep -Fq 'scroll.isTracking || scroll.isDragging || scroll.isDecelerating' "$view"
attachments=src/ios/Views/Chat/ChatInputBar.swift
grep -Fq 'private struct UserAttachmentTileLayout<Content: View>: View' "$attachments"
[ "$(grep -Fc '        UserAttachmentTileLayout(count: attachments.count) {' "$attachments")" -eq 2 ]
grep -Fq 'LazyVGrid(columns: Array(repeating: GridItem(.fixed(UserAttachmentTileMetrics.tile),' "$attachments"
require '!message.blocks.contains(where: { $0.kind == .text && !$0.content.isEmpty })'
echo 'PASS: build70 chat bubble metrics, assistant identity, system dividers, metadata range, attachment grid and legacy-renderer source guards.'
echo 'NOTE: Swift compilation, selection, long-text wrapping and session entry must still be tested on iOS15.'
