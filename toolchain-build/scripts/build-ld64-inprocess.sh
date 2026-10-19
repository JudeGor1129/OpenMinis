#!/usr/bin/env bash
#
# build-ld64-inprocess.sh — compile the adapted ld64 into build/ios/libomld64.a
#
# Pair with build-ld64-inprocess.py, which rewrites the CLI `main` into a
# reentrant entry point before compilation.
#
# ld64 is compiled from source rather than reused for the same reason as LLVM:
# Apple ships it as a command-line tool, and the CLI cannot be embedded.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/work"
BUILD="$ROOT/build/ios"
CCTOOLS="$WORK/cctools-port"
OUT="$BUILD/libomld64.a"
OBJDIR="$WORK/obj-ld64"

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

mkdir -p "$BUILD" "$OBJDIR"

if [ ! -d "$CCTOOLS" ]; then
  echo "missing $CCTOOLS; run scripts/fetch-sources.sh first" >&2
  exit 1
fi

echo "==> applying in-process adaptations"
python3 "$ROOT/scripts/build-ld64-inprocess.py"

LDROOT="$CCTOOLS/cctools/ld64/src"
if [ ! -d "$LDROOT/ld" ]; then
  echo "missing ld64 src at $LDROOT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Compile each translation unit for arm64 and arm64e, then archive per slice.
# ---------------------------------------------------------------------------
mapfile -t SOURCES < <(find "$LDROOT" -name '*.cpp' | sort)
echo "==> ${#SOURCES[@]} ld64 translation units"

# -DHAVE_* are the portability knobs cctools-port expects on Darwin.
# ld64's own -Werror settings are relaxed because we are not the upstream CI.
COMMON_FLAGS=(
  -std=gnu++17
  -O2
  -fno-exceptions
  -fno-rtti
  -DHAVE_LIBDISPATCH=0
  -DHAVE_PTHREADS=0
  -D__STDC_LIMIT_MACROS
  -D__STDC_CONSTANT_MACROS
  -isysroot "$SDKROOT"
  -miphoneos-version-min=14.0
  -I"$CCTOOLS/cctools/include"
  -I"$CCTOOLS/cctools/ld64/src"
  -I"$LDROOT"
  -Wno-everything
)

SLICE_ARCHIVES=()
for ARCH in arm64 arm64e; do
  ARCHOBJ="$OBJDIR/$ARCH"
  mkdir -p "$ARCHOBJ"
  echo "==> compiling ld64 for $ARCH"
  PIDS=()
  FAILED=0
  for SRC in "${SOURCES[@]}"; do
    REL="$(echo "$SRC" | tr '/' '_')"
    OBJ="$ARCHOBJ/${REL}.o"
    (
      # -fno-exceptions conflicts with ld's throw sites; compile those with
      # exceptions enabled so the library can report failures without exiting.
      EXTRA=()
      if grep -q 'throw ' "$SRC" 2>/dev/null; then EXTRA+=(-fexceptions); fi
      xcrun --sdk iphoneos clang++ -arch "$ARCH" "${COMMON_FLAGS[@]}" "${EXTRA[@]}" \
        -c "$SRC" -o "$OBJ"
    ) &
    PIDS+=("$!")
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || FAILED=1; done
  done
  for pid in "${PIDS[@]}"; do wait "$pid" || FAILED=1; done
  if [ "$FAILED" -ne 0 ]; then
    echo "!! at least one ld64 translation unit failed to compile for $ARCH" >&2
    exit 1
  fi

  SLICE="$BUILD/libomld64-$ARCH.a"
  rm -f "$SLICE"
  find "$ARCHOBJ" -name '*.o' -print0 | xargs -0 xcrun libtool -static -o "$SLICE"
  SLICE_ARCHIVES+=("$SLICE")
  echo "   $SLICE"
done

echo "==> merging arch slices"
xcrun libtool -static -o "$OUT" "${SLICE_ARCHIVES[@]}"
echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1))"
