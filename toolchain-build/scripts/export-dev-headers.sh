#!/usr/bin/env bash
# Export headers from the same patched checkout and architecture builds as libs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-$ROOT/work}"
BUILD="${2:-$ROOT/build/ios}"
ARCHS="${3:-arm64 arm64e}"
SOURCE="$WORK/llvm-project"

[ -n "$ARCHS" ] || { echo "No architectures requested" >&2; exit 1; }
SEEN=" "
for ARCH in $ARCHS; do
  case "$ARCH" in arm64|arm64e) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
  case "$SEEN" in *" $ARCH "*) echo "Duplicate architecture: $ARCH" >&2; exit 1 ;; esac
  SEEN="$SEEN$ARCH "
  for HEADER in llvm/Config/llvm-config.h llvm/Config/config.h llvm/Config/abi-breaking.h llvm/IR/IntrinsicEnums.inc llvm/IR/IntrinsicImpl.inc; do
    [ -f "$WORK/build-ios-$ARCH/include/$HEADER" ] || { echo "Missing generated header: $ARCH/include/$HEADER" >&2; exit 1; }
  done
  for HEADER in clang/Basic/Version.inc clang/Config/config.h; do
    [ -f "$WORK/build-ios-$ARCH/tools/clang/include/$HEADER" ] || { echo "Missing generated header: $ARCH/tools/clang/include/$HEADER" >&2; exit 1; }
  done
done
for HEADER in llvm/include/llvm/ADT/ArrayRef.h clang/include/clang/Frontend/CompilerInstance.h; do
  [ -f "$SOURCE/$HEADER" ] || { echo "Missing source header: $HEADER" >&2; exit 1; }
done
for LICENSE in llvm/LICENSE.TXT clang/LICENSE.TXT; do
  [ -f "$SOURCE/$LICENSE" ] || { echo "Missing license: $LICENSE" >&2; exit 1; }
done

mkdir -p "$BUILD"

# The builtin resource headers include generated arm_neon/arm_sve/etc. files.
# They are emitted into lib/clang/<major>/include by Clang's resource-header
# target, not kept only in clang/lib/Headers. Export the generated directory
# from the first requested slice; both slices use the same pinned source.
RESOURCE_INCLUDE=""
for ARCH in $ARCHS; do
  candidate="$(find "$WORK/build-ios-$ARCH" -type f \
    -path '*/lib/clang/*/include/arm_neon.h' -print -quit 2>/dev/null | \
    sed 's#/arm_neon\.h$##')"
  [ -n "$candidate" ] || { echo "Missing generated Clang resource headers: $ARCH/lib/clang/*/include" >&2; exit 1; }
  for HEADER in arm_neon.h arm_fp16.h arm_sve.h arm_sme.h arm_bf16.h arm_mve.h arm_cde.h; do
    [ -f "$candidate/$HEADER" ] || { echo "Missing generated Clang resource header: $ARCH/$HEADER" >&2; exit 1; }
  done
  if [ -z "$RESOURCE_INCLUDE" ]; then RESOURCE_INCLUDE="$candidate"; fi
done
rm -rf "$BUILD/clang-resource"
mkdir -p "$BUILD/clang-resource/include"
# Start with the pinned source builtin headers, then overlay generated target
# headers so the runtime resource is complete rather than arm-only fragments.
cp -R "$SOURCE/clang/lib/Headers/." "$BUILD/clang-resource/include/"
cp -R "$RESOURCE_INCLUDE/." "$BUILD/clang-resource/include/"
echo "Exported Clang resource headers from $SOURCE/clang/lib/Headers + $RESOURCE_INCLUDE"

STAGE="$(mktemp -d "$BUILD/.dev-headers.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/common/include" "$STAGE/licenses"
cp -R "$SOURCE/llvm/include/." "$STAGE/common/include/"
cp -R "$SOURCE/clang/include/." "$STAGE/common/include/"
cp "$SOURCE/llvm/LICENSE.TXT" "$STAGE/licenses/LLVM-LICENSE.txt"
cp "$SOURCE/clang/LICENSE.TXT" "$STAGE/licenses/Clang-LICENSE.txt"
for ARCH in $ARCHS; do
  mkdir -p "$STAGE/$ARCH/include"
  cp -R "$WORK/build-ios-$ARCH/include/." "$STAGE/$ARCH/include/"
  cp -R "$WORK/build-ios-$ARCH/tools/clang/include/." "$STAGE/$ARCH/include/"
done
# Only the export destination is replaced, never the upstream source/build tree.
rm -rf "$BUILD/dev-headers"
mv "$STAGE" "$BUILD/dev-headers"
echo "Exported source + per-architecture generated headers: $BUILD/dev-headers"
echo "Include order: dev-headers/<arch>/include, then dev-headers/common/include"
