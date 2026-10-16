#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

mkdir -p ci-logs build/ios15
[[ -f deps/ish/meson.build ]] || { echo 'error: missing pinned iSH sources' >&2; exit 1; }

if [[ ! -f src/ios/Configs/ProviderCustomization.xcconfig ]]; then
  cp src/ios/Configs/ProviderCustomization.xcconfig.example \
     src/ios/Configs/ProviderCustomization.xcconfig
fi

xcodebuild -version
xcrun --sdk iphoneos metal --version

# Preserve upstream dependency order: FFmpeg detects and links LAME.
bash deps/build_lame.sh
bash deps/build_ffmpeg.sh
bash deps/build_ish.sh
bash deps/prepare_alpine_rootfs.sh
IOS_DEPLOYMENT_TARGET=15.0 bash deps/build_rclone_ios.sh

# Diagnostic build only, not an IPA/release job. In this disposable CI checkout,
# lower existing 16.0 settings (project, app, Share and FileProvider) to 15.0.
# Keep Live Activity's 16.2 and test targets' 26.2 settings unchanged. A global
# command-line override would incorrectly lower the Live Activity extension.
PROJECT=src/ios/Minis.xcodeproj/project.pbxproj
cp "$PROJECT" ci-logs/project-before-ios15.pbxproj
sed -i '' 's/IPHONEOS_DEPLOYMENT_TARGET = 16\.0;/IPHONEOS_DEPLOYMENT_TARGET = 15.0;/g' "$PROJECT"
grep -n 'IPHONEOS_DEPLOYMENT_TARGET' "$PROJECT" | tee ci-logs/deployment-targets.txt
rm -rf build/ios15/Minis.xcresult
xcodebuild -project src/ios/Minis.xcodeproj \
  -scheme Minis \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios15/DerivedData \
  -resultBundlePath build/ios15/Minis.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MINIS_LEGACY_FILE_PROVIDER' \
  build
