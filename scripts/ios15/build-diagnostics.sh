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
bash scripts/ios15/build-privileged-helper.sh
sh scripts/ios15/check-helper-response.sh

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

# Disposable CI checkout: use the exact verified Run7 arm64 kit. This links
# the bridge for App validation only; OM_TOOLCHAIN_VERIFIED remains absent.
TOOLCHAIN_ROOT=build/ios15/embedded-toolchain
[[ -f "$TOOLCHAIN_ROOT/libomllvm-arm64.a" && -f "$TOOLCHAIN_ROOT/libomld64.a" ]] || {
  echo 'error: verified embedded toolchain archives missing' >&2; exit 1;
}
rm -rf src/ios/Vendor/OMToolchain/clang-resource
cp -R "$TOOLCHAIN_ROOT/clang-resource" src/ios/Vendor/OMToolchain/clang-resource
sed -i '' '/"-lfakefs",/a\
                    "$(SRCROOT)/../../build/ios15/embedded-toolchain/libomllvm-arm64.a",\
                    "$(SRCROOT)/../../build/ios15/embedded-toolchain/libomld64.a",\
                    "-lz",\
' "$PROJECT"
sed -i '' '/OTHER_SWIFT_FLAGS = "";/a\
                    OTHER_CPLUSPLUSFLAGS = (\
                        "$(inherited)",\
                        "-DOM_TOOLCHAIN_ENABLED=1",\
                        "-fno-rtti",\
                        "-fexceptions",\
                        "-I$(SRCROOT)/../../build/ios15/embedded-toolchain/dev-headers/arm64/include",\
                        "-I$(SRCROOT)/../../build/ios15/embedded-toolchain/dev-headers/common/include",\
                    );\
' "$PROJECT"
printf '%s\n' 'OM_TOOLCHAIN_ENABLED=1; OM_TOOLCHAIN_VERIFIED intentionally unset; runtime provider remains unavailable.' | tee ci-logs/embedded-link-settings.txt
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
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MINIS_LEGACY_FILE_PROVIDER' \
  'LIBRARY_SEARCH_PATHS=$(SRCROOT)/../../deps/libs' \
  build

# A previous baseline reset accidentally restored Debug/-Onone packaging.
# Check the artifact shape so another reset cannot silently ship a debug stub.
APP=build/ios15/DerivedData/Build/Products/Release-iphoneos/Minis.app
[[ -f "$APP/Minis" ]] || { echo 'error: optimized Release executable missing' >&2; exit 1; }
[[ ! -e "$APP/Minis.debug.dylib" ]] || { echo 'error: unexpected debug dylib in Release app' >&2; exit 1; }
nm "$APP/Minis" > ci-logs/release-symbols.txt
[[ -s ci-logs/release-symbols.txt ]] || { echo 'error: cannot inspect Release symbols' >&2; exit 1; }
app_archs="$(xcrun lipo -archs "$APP/Minis")"
printf 'Minis executable architectures: %s\n' "$app_archs" | tee ci-logs/embedded-app-architecture.txt
[[ "$app_archs" == "arm64" ]] || {
  echo "error: enabled App must contain only arm64, got: $app_archs" >&2; exit 1;
}
grep -q 'om_ld64_main' ci-logs/release-symbols.txt || {
  echo 'error: linked App lacks the in-process ld64 entry point' >&2; exit 1;
}
grep -q 'LLVMInitializeAArch64Target' ci-logs/release-symbols.txt || {
  echo 'error: linked App lacks the LLVM AArch64 target initializer' >&2; exit 1;
}
python3 scripts/ios15/verify-bundled-clang-resource.py \
  "$TOOLCHAIN_ROOT/toolchain.json" "$APP/clang-resource" \
  | tee ci-logs/embedded-app-clang-resource.txt
if grep -q 'NavbarEvalStats' ci-logs/release-symbols.txt; then
  echo 'error: DEBUG-only chat profiling code survived Release compilation' >&2
  exit 1
fi
printf 'PASS: optimized arm64 Release App links locked LLVM/ld64; runtime verification remains disabled.\n'
