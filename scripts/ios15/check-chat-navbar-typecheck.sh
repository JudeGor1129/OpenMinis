#!/bin/bash
# Typecheck the ACTUAL navigation Adapter, not a hand-written API imitation.
# Run on macOS with Xcode: bash scripts/ios15/check-chat-navbar-typecheck.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
if ! command -v xcrun >/dev/null 2>&1; then
    echo 'UNAVAILABLE: Xcode xcrun is required for iOS 15 Swift typechecking.' >&2
    exit 2
fi
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
swiftc=$(xcrun --find swiftc)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/openminis-chat-navbar.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
source=src/ios/Views/Chat/AIChatView.swift
fixture="$tmp/ChatNavigationBackground.swift"
{
    printf 'import SwiftUI\nimport UIKit\n\n'
    sed -n '/^private struct LegacyChatNavigationBarBackground:/,/^\/\/ MARK: - Chat Trailing/p' "$source"
} > "$fixture"
grep -q '^private struct LegacyChatNavigationBarBackground:' "$fixture" || {
    echo 'FAIL: actual navigation Adapter could not be extracted' >&2; exit 1;
}
"$swiftc" -typecheck -sdk "$sdk" -target arm64-apple-ios15.0 \
    -module-cache-path "$tmp/ModuleCache" "$fixture"
echo 'PASS: actual chat navigation Adapter typechecked against iPhoneOS SDK at minimum iOS 15.0.'
echo 'NOTE: full app compilation and device navigation/rendering tests are still required.'
