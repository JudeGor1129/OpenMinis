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
  for HEADER in llvm/Config/llvm-config.h llvm/Config/config.h llvm/Config/abi-breaking.h llvm/IR/Intrinsics.inc; do
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
