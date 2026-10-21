#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

bash scripts/ios15/check-build70-chat-style.sh

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

# Compilation only: verify the shared compatibility Module and representative
# callers for an iOS 15 deployment target. No native dependencies or signing.
xcrun --sdk iphoneos swiftc -typecheck \
  -target arm64-apple-ios15.0 \
  -sdk "$SDK" \
  src/ios/Shared/MinisNavigationContainer.swift \
  scripts/ios15/CompatibilityCallers.swift

printf 'PASS: shared compatibility implementation and sample callers type-check for arm64 iOS 15.0.\n'
printf 'NOTE: full app callers, presentation semantics, and runtime behavior are not validated here.\n'
