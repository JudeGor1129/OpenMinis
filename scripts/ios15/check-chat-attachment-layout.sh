#!/bin/bash
# Source guards, not Swift typechecking or a UIKit rendering test.
set -euo pipefail
cd "$(dirname "$0")/../.."
view=src/ios/Views/Chat/ChatInputBar.swift

require() {
    grep -Fq "$1" "$view" || { printf 'FAIL: missing %s\n' "$1"; exit 1; }
}

require 'private struct FlowLayout<Item: Identifiable, Content: View>: View'
require 'if #available(iOS 16.0, *)'
require 'NativeFlowLayout(hSpacing: hSpacing, vSpacing: vSpacing, alignment: alignment)'
require 'let tile = UserAttachmentTileMetrics.tile'
require 'max(1, Int((max(0, availableWidth) + hSpacing) / (tile + hSpacing)))'
require '(items.count + columns - 1) / columns'
require 'ForEach(Array(items.dropFirst(row * columns).prefix(columns)))'
require 'HStack(spacing: hSpacing)'
require 'alignment: alignment == .trailing ? .trailing : .leading)'
require 'Color.clear.preference(key: AttachmentFlowWidthKey.self,'
require 'value = nextValue()'
require 'static let tile: CGFloat = 64'
require 'static let gap: CGFloat = 6'
require 'FlowLayout(items: tiles, hSpacing: 8, vSpacing: 8)'
require 'case .loading:'
require 'VideoLoadingChip()'
require '.onDrop(of: [.text], delegate: AttachmentDropDelegate('
require 'onRemove(attachment)'
require 'openGallery(startingAt: meta)'
require 'AsyncCacheURLImageTile(cacheURL: attachment.cacheURL, tileSize: tileSize)'

[ "$(grep -Fc 'FlowLayout(items:' "$view")" -eq 3 ] || {
    echo 'FAIL: all three attachment entry points must pass items'; exit 1;
}
[ "$(grep -Fc 'FlowLayout(items: attachments, hSpacing: UserAttachmentTileMetrics.gap' "$view")" -eq 2 ] || {
    echo 'FAIL: both sent and queued attachments must use shared metrics'; exit 1;
}
if grep -Fq '        FlowLayout(hSpacing:' "$view"; then
    echo 'FAIL: obsolete FlowLayout call without items'; exit 1
fi

# Integer-point model of the fixed-tile packing contract. This checks expected
# edge cases, not execution of SwiftUI or the Swift implementation itself.
check_columns() {
    local width=$1 gap=$2 expected=$3 columns
    columns=$(((width + gap) / (64 + gap)))
    if [ "$columns" -lt 1 ]; then columns=1; fi
    [ "$columns" -eq "$expected" ] || {
        echo "FAIL: packing model width=$width gap=$gap columns=$columns expected=$expected"; exit 1;
    }
}
check_columns 0 6 1
check_columns 64 6 1
check_columns 133 6 1
check_columns 134 6 2
check_columns 203 6 2
check_columns 204 6 3
check_columns 320 6 4
check_columns 344 6 5
check_columns 135 8 1
check_columns 136 8 2
check_columns 352 8 5

# On a 320pt message area, five tiles are 4 + 1, NOT a five-row stack.
columns=4
count=5
rows=$(((count + columns - 1) / columns))
[ "$rows" -eq 2 ]
height=$((rows * 64 + (rows - 1) * 6))
[ "$height" -eq 134 ]
count=0
[ "$(((count + columns - 1) / columns))" -eq 0 ]
echo 'PASS: three attachment entry points, official metrics, wrapping and alignment source guards; packing model edge cases.'
echo 'NOTE: Swift compilation and iOS 15 rendering/drag/selection tests still required.'
