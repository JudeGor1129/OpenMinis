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

# TrollStore test IPA, built with Release optimizations. In this disposable CI checkout,
# lower existing 16.0 settings (project, app, Share and FileProvider) to 15.0.
# Keep Live Activity's 16.2 and test targets' 26.2 settings unchanged. A global
# command-line override would incorrectly lower the Live Activity extension.
PROJECT=src/ios/Minis.xcodeproj/project.pbxproj
cp "$PROJECT" ci-logs/project-before-ios15.pbxproj
sed -i '' 's/IPHONEOS_DEPLOYMENT_TARGET = 16\.0;/IPHONEOS_DEPLOYMENT_TARGET = 15.0;/g' "$PROJECT"
grep -n 'IPHONEOS_DEPLOYMENT_TARGET' "$PROJECT" | tee ci-logs/deployment-targets.txt
# Add Frida only to the app's existing iSH linker lists, not every extension.
# Global OTHER_LDFLAGS overrides would also link iSH/Frida into share/widget targets.
[[ -f deps/include/frida-core.h && -f deps/libs/libfrida-core.a ]] || {
  echo 'error: verified Frida SDK missing' >&2; exit 1;
}
sed -i '' '/"-lfakefs",/a\
                    "-lfrida-core",\
                    "-lbsm",\
                    "-ldl",\
                    "-lm",\
                    "-lresolv",\
                    "-lpthread",\
                    "-framework",\
                    "Security",\
                    "-framework",\
                    "CoreFoundation",\
                    "-framework",\
                    "Foundation",\
' "$PROJECT"
plutil -lint "$PROJECT"
rm -rf build/ios15/Minis.xcresult
xcodebuild -project src/ios/Minis.xcodeproj \
  -scheme Minis \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios15/DerivedData \
  -resultBundlePath build/ios15/Minis.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  ENABLE_TESTABILITY=NO \
  ENABLE_DEBUG_DYLIB=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MINIS_LEGACY_FILE_PROVIDER' \
  LIBRARY_SEARCH_PATHS='$(SRCROOT)/../../deps/libs' \
  build

# A previous baseline reset accidentally restored Debug/-Onone packaging.
# Check the artifact shape so another reset cannot silently ship a debug stub.
APP=build/ios15/DerivedData/Build/Products/Release-iphoneos/Minis.app
[[ -f "$APP/Minis" ]] || { echo 'error: optimized Release executable missing' >&2; exit 1; }
[[ ! -e "$APP/Minis.debug.dylib" ]] || { echo 'error: unexpected debug dylib in Release app' >&2; exit 1; }
nm "$APP/Minis" > ci-logs/release-symbols.txt
[[ -s ci-logs/release-symbols.txt ]] || { echo 'error: cannot inspect Release symbols' >&2; exit 1; }
if grep -q 'NavbarEvalStats' ci-logs/release-symbols.txt; then
  echo 'error: DEBUG-only chat profiling code survived Release compilation' >&2
  exit 1
fi
printf 'PASS: optimized Release executable, no debug dylib or DEBUG-only chat profiler.\n'
