#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos swiftc -typecheck \
  -target arm64-apple-ios15.0 -sdk "$SDK" \
  src/ios/Shared/AppLocalization.swift \
  scripts/ios15/LocalizationCallers.swift
printf 'PASS: localization literals, interpolation and guarded resources type-check for iOS 15. Runtime language switching not verified.\n'
