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
# FIVE session-open crashes (15:04:13, 15:04:18, 16:06:42, 16:06:47, 16:48:32,
# 18:43:14) all stop in the SAME pair of symbols despite completely different
# call sites each time:
#
#   swift_beginAccess -> swift::runtime::AccessSet::insert
#
#   preferredLayoutAttributesFitting / AppLogger.info / ViewGraph.sizeThatFits
#   / NavbarEvalStats.toolbarPass -- five different callers, one callee.
#
# A real exclusivity VIOLATION prints "Simultaneous accesses to ..." via
# _swift_stdlib_reportFatalError. These reports never do: they SIGSEGV inside
# the tracker bookkeeping itself, with faulting words that decode to ASCII text
# ("the cook"), to the double 0.5, and one address inside the GPU carveout
# reserved region. That is memory corruption in the access-record container.
#
# Mechanism: SWIFT_ENFORCE_EXCLUSIVE_ACCESS defaults to `full` for Debug, so
# every exclusivity scope emits swift_beginAccess/swift_endAccess, which execute
# inside the iOS 15.4.1 SYSTEM runtime (/usr/lib/swift/libswiftCore.dylib -- the
# app bundles no libswiftCompatibility* back-deployment shim) while the checking
# code was emitted by the Xcode 26.2 / iOS 26.2 SDK toolchain.
#
# IMPORTANT: setting SWIFT_ENFORCE_EXCLUSIVE_ACCESS=compile-time alone does NOT
# work here. This target sets `OTHER_SWIFT_FLAGS = ""` explicitly in every
# configuration (project.pbxproj), which drops the build-setting-derived flag
# before it reaches swiftc -- verified: build 85 still imported
# _swift_beginAccess and crashed with a byte-identical stack. So the flag is
# injected directly through OTHER_SWIFT_FLAGS, and OTHER_LDFLAGS for the
# extension targets too, via a command-line override whose value starts with a
# space so it appends instead of replacing the (empty) project value.
#
# `unchecked` is chosen over `compile-time`: both stop the runtime
# instrumentation, but `unchecked` also tolerates the pre-existing static
# conflicts this large codebase may contain, and it is what a shipping Release
# build effectively behaves like for these accesses.
xcodebuild -project src/ios/Minis.xcodeproj \
  -scheme Minis \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios15/DerivedData \
  -resultBundlePath build/ios15/Minis.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  'OTHER_SWIFT_FLAGS=-enforce-exclusivity=unchecked $(inherited)' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MINIS_LEGACY_FILE_PROVIDER' \
  LIBRARY_SEARCH_PATHS='$(SRCROOT)/../../deps/libs' \
  build

# [T-ios15-exclusivity-verify] Build-time proof that the flag reached swiftc.
# A settings-only fix already shipped once and silently did nothing, so the
# build now fails loudly instead of producing another IPA that crashes.
#
# NOTE: this must never "pass" because the check itself failed. A missing `nm`,
# a wrong path, or empty output all have to be hard errors — an absent `nm`
# returns 0 matches and would silently rubber-stamp a broken build.
APP_BIN=build/ios15/DerivedData/Build/Products/Debug-iphoneos/Minis.app/Minis.debug.dylib
[[ -f "$APP_BIN" ]] || { echo 'error: built Minis.debug.dylib missing' >&2; exit 1; }
command -v nm >/dev/null 2>&1 || { echo 'error: nm not available — cannot verify exclusivity flag' >&2; exit 1; }
NM_OUT=ci-logs/exclusivity-undefined-symbols.txt
if ! nm -u "$APP_BIN" > "$NM_OUT" 2>ci-logs/exclusivity-nm.err; then
  echo 'error: nm failed on Minis.debug.dylib — cannot verify exclusivity flag' >&2
  sed -n '1,5p' ci-logs/exclusivity-nm.err >&2
  exit 1
fi
if [[ ! -s "$NM_OUT" ]]; then
  echo 'error: nm produced no output — cannot verify exclusivity flag' >&2
  exit 1
fi
if grep -q 'swift_beginAccess' "$NM_OUT"; then
  echo 'error: _swift_beginAccess still imported — exclusivity instrumentation was NOT disabled' >&2
  echo 'error: iOS 15.4.1 crashes in AccessSet::insert because of it; refusing to ship' >&2
  grep -o 'swift_beginAccess' "$NM_OUT" | wc -l >&2 || true
  exit 1
fi
echo "ok: no swift_beginAccess import in $(wc -l < "$NM_OUT") undefined symbols — runtime exclusivity checking is disabled"

