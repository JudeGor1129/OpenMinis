#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos swiftc -typecheck \
  -target arm64-apple-ios15.0 -sdk "$SDK" \
  -D MINIS_LEGACY_FILE_PROVIDER \
  src/ios/FileProvider/FileProviderExtension.swift \
  src/ios/FileProvider/FileProviderEnumerator.swift \
  src/ios/FileProvider/FileProviderItem.swift \
  src/ios/FileProvider/FPSyncTraceLog.swift \
  src/ios/Views/Settings/SharedFolderVisibility.swift
printf 'PASS: legacy FileProvider source type-checks for iOS 15. Runtime behavior is not verified.\n'
