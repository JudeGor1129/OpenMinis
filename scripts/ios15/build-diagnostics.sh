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
# [T-ios15-exclusivity-abi] Do NOT ship Swift runtime exclusivity checking.
#
# SWIFT_ENFORCE_EXCLUSIVE_ACCESS defaults to `full` for Debug and
# `compile-time` for Release, and this project never overrides it. Because the
# whole app is compiled Debug (the IPA is packaged from Debug-iphoneos), every
# `swift_beginAccess` carries a runtime check emitted by the Xcode 26.2 /
# iOS 26.2 SDK toolchain, which is then executed by the iOS 15.4.1 SYSTEM
# Swift runtime (/usr/lib/swift/libswiftCore.dylib — the app bundles none).
#
# That mismatch is fatal and explains all four session-open crashes
# (15:04:13, 15:04:18, 16:06:42, 16:06:47, 16:48:32): every report stops in
# swift_beginAccess -> swift::runtime::AccessSet::insert, reached from a
# completely different call site each time (preferredLayoutAttributesFitting,
# AppLogger.info, ViewGraph.sizeThatFits, NavbarEvalStats.toolbarPass). A
# genuine exclusivity VIOLATION prints "Simultaneous accesses to ..." through
# _swift_stdlib_reportFatalError; it does not SIGSEGV inside the tracker.
# Instead the faulting words decode to ASCII text ("the cook") and to the
# double 0.5 — the tracker's own container memory being scribbled over — and
# one report lands in the GPU carveout reserved region.
#
# compile-time keeps the optimisation-time guarantee (the compiler still
# diagnoses statically knowable conflicts) and only stops emitting the
# runtime instrumentation that the older system runtime cannot execute.
# Set on the command line so it applies to every target, including the
# extensions, without editing the project file.
xcodebuild -project src/ios/Minis.xcodeproj \
  -scheme Minis \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios15/DerivedData \
  -resultBundlePath build/ios15/Minis.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_ENFORCE_EXCLUSIVE_ACCESS=compile-time \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MINIS_LEGACY_FILE_PROVIDER' \
  LIBRARY_SEARCH_PATHS='$(SRCROOT)/../../deps/libs' \
  build
