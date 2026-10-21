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
# [T-ios15-exclusivity-abi] Ship a RELEASE build, not Debug.
#
# Seven session-open crashes so far. What finally resolved the confusion is that
# they never agreed on a call site:
#
#   15:04:13, 16:06:42  ViewGraph.sizeThatFits -> DynamicContainerInfo.updateItems
#   15:04:18, 16:06:47  preferredLayoutAttributesFitting -> AppLogger.info
#   16:48:32, 18:43:14  AIChatView.navTitleKey -> NavbarEvalStats.toolbarPass += 1
#
# but every single one stopped in the same callee:
#
#   swift_beginAccess -> swift::runtime::AccessSet::insert
#
# Different callers, one callee, faulting values that decode to ASCII text
# ("the cook") and to the double 0.5, one address inside the GPU carveout
# region. That is the exclusivity bookkeeping corrupting itself, not a violation
# (a real violation reports "Simultaneous accesses to ..." and never reaches
# SIGSEGV inside the tracker).
#
# This build was Debug, and -Onone is what makes it lethal: at -Onone the
# compiler emits a runtime access scope at essentially every property and
# global access, and those scopes are executed by the iOS 15.4.1 SYSTEM Swift
# runtime (/usr/lib/swift/libswiftCore.dylib) even though their access-record
# layout comes from the Xcode 26.3 / iOS 26.x SDK toolchain. Release does not
# have this shape: -O collapses almost all of those scopes, and the crash site
# itself is compiled out entirely.
#
# -enforce-exclusivity=unchecked stays as belt-and-braces and is injected
# through OTHER_SWIFT_FLAGS rather than the build setting, because this target
# sets `OTHER_SWIFT_FLAGS = ""` in every configuration (project.pbxproj:3664,
# :3718), which silently swallowed the setting-only attempt in build 85.
xcodebuild -project src/ios/Minis.xcodeproj \
  -scheme Minis \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios15/DerivedData \
  -resultBundlePath build/ios15/Minis.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  'OTHER_SWIFT_FLAGS=-enforce-exclusivity=unchecked $(inherited)' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MINIS_LEGACY_FILE_PROVIDER' \
  LIBRARY_SEARCH_PATHS='$(SRCROOT)/../../deps/libs' \
  build

# [T-ios15-release-verify] Assert the build is genuinely the shape that does not
# crash, instead of asserting something that was never true.
#
# An earlier draft of this block failed build 86 by demanding that
# _swift_beginAccess disappear from the binary. It never disappears: Swift routes
# global/static storage through swift_beginAccess in every configuration,
# including Release. That check could only ever fail, and the build log showed
# exactly that after "** BUILD SUCCEEDED **".
#
# The properties below are real and are what actually matter:
#   1. The product is the Release product (Debug would still be -Onone).
#   2. It is a single self-contained executable, not the Xcode 16+ debug-dylib
#      stub pair, so the code under test is the code that ships.
#   3. DEBUG-only code is compiled out — verified by the absence of the exact
#      symbol that was on top of the two most recent crash reports.
# Every failure mode is fatal: a missing nm, a wrong path, or empty output must
# never quietly rubber-stamp a broken build.
BIN=build/ios15/DerivedData/Build/Products/Release-iphoneos/Minis.app/Minis
[[ -f "$BIN" ]] || { echo "error: Release executable missing at $BIN" >&2; exit 1; }
[[ ! -e build/ios15/DerivedData/Build/Products/Release-iphoneos/Minis.app/Minis.debug.dylib ]] || {
  echo 'error: Release product unexpectedly contains a debug dylib' >&2; exit 1; }
command -v nm >/dev/null 2>&1 || { echo 'error: nm not available — cannot verify release shape' >&2; exit 1; }
NM_OUT=ci-logs/release-symbols.txt
if ! nm "$BIN" > "$NM_OUT" 2>ci-logs/release-nm.err; then
  echo 'error: nm failed on the Release executable — cannot verify release shape' >&2
  sed -n '1,5p' ci-logs/release-nm.err >&2
  exit 1
fi
if [[ ! -s "$NM_OUT" ]]; then
  echo 'error: nm produced no output — cannot verify release shape' >&2
  exit 1
fi
if grep -q 'NavbarEvalStats' "$NM_OUT"; then
  echo 'error: NavbarEvalStats is present — this is not a DEBUG-free build' >&2
  echo 'error: that DEBUG-only counter is where builds 84/85 crashed' >&2
  exit 1
fi
echo "ok: Release executable, $(wc -l < "$NM_OUT") symbols, DEBUG-only code absent"

