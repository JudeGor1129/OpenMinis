#!/usr/bin/env bash
#
# build-ld64-inprocess.sh — compile the adapted ld64 into build/ios/libomld64.a
#
# Pair with build-ld64-inprocess.py, which rewrites the CLI entry point into a
# reentrant one before compilation.
#
# ld64 is built from source rather than reused for the same reason as LLVM:
# Apple ships it as a command-line tool, and a CLI cannot be embedded.
#
# The source list below is transcribed from the port's own Makefile.am files
# rather than globbed. Globbing ld64/src picks up other/ObjectDump.cpp and
# other/unwinddump.cpp, which are *separate programs* that each define main();
# linking them in would collide with our own entry point. It also misses the C
# sources (debugline.c, libcodedirectory.c, and the 3rd/ helpers) that provide
# uuid, strlcpy, md5/sha1/sha256 and reallocf.
#
# Written for /bin/bash 3.2, which is what macOS still ships: no mapfile, no
# associative arrays, no `wait -n`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/work"
BUILD="$ROOT/build/ios"
CCTOOLS="$WORK/cctools-port"
SRCROOT="$CCTOOLS/cctools"
LDSRC="$SRCROOT/ld64/src"
OUT="$BUILD/libomld64.a"
OBJDIR="$WORK/obj-ld64"

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MIN_IOS="${LLVM_MIN_IOS:-14.0}"

mkdir -p "$BUILD" "$OBJDIR"

if [ ! -d "$LDSRC/ld" ]; then
  echo "missing ld64 sources at $LDSRC; run scripts/fetch-sources.sh first" >&2
  exit 1
fi

echo "==> applying in-process adaptations"
python3 "$ROOT/scripts/build-ld64-inprocess.py"

# ---------------------------------------------------------------------------
# Source list, from ld64's Makefile.am files.
# ---------------------------------------------------------------------------
SOURCES_C=(
  "ld/debugline.c"
  "ld/libcodedirectory.c"
  "3rd/helper.c"
  "3rd/qsort_r.c"
  "3rd/strlcat.c"
  "3rd/strlcpy.c"
  "3rd/eprintf.c"
  "3rd/md5.c"
  "3rd/sha1.c"
  "3rd/sha256.c"
  "3rd/mkpath_np.c"
  "3rd/reallocf.c"
)

SOURCES_CXX=(
  "ld/InputFiles.cpp"
  "ld/ld.cpp"
  "ld/Options.cpp"
  "ld/OutputFile.cpp"
  "ld/Resolver.cpp"
  "ld/Snapshot.cpp"
  "ld/SymbolTable.cpp"
  "ld/PlatformSupport.cpp"
  "ld/ResponseFiles.cpp"
  "ld/FatFile.cpp"
  "ld/Mangling.cpp"
  "ld/code-sign-blobs/blob.cpp"
  "ld/om_reset_hooks.cpp"
  "mach_o/Error.cpp"
  "mach_o/ExportsTrie.cpp"
  "ld/parsers/archive_file.cpp"
  "ld/parsers/lto_file.cpp"
  "ld/parsers/macho_dylib_file.cpp"
  "ld/parsers/macho_relocatable_file.cpp"
  "ld/parsers/opaque_section_file.cpp"
  "ld/parsers/textstub_dylib_file.cpp"
  "ld/parsers/generic_dylib_file.cpp"
  "ld/passes/branch_island.cpp"
  "ld/passes/branch_shim.cpp"
  "ld/passes/compact_unwind.cpp"
  "ld/passes/dtrace_dof.cpp"
  "ld/passes/dylibs.cpp"
  "ld/passes/got.cpp"
  "ld/passes/huge.cpp"
  "ld/passes/objc.cpp"
  "ld/passes/order.cpp"
  "ld/passes/tlvp.cpp"
  "ld/passes/stubs/stubs.cpp"
  "ld/passes/bitcode_bundle.cpp"
  "ld/passes/code_dedup.cpp"
  "ld/passes/thread_starts.cpp"
  "ld/passes/inits.cpp"
  "ld/passes/objc_constants.cpp"
  "ld/passes/objc_stubs.cpp"
)

# The libtapi-compatible shim. ld64 reads .tbd stubs only under TAPI_SUPPORT,
# and that code path calls Apple's libtapi; without it the SDK's libSystem --
# which is a stub -- is invisible to the linker, so every dynamic link failed
# on device with "must link with libSystem.dylib". The shim supplies that API
# on top of the LLVM TextAPI this app already links; see src/tapi-shim.
SHIM="$ROOT/src/tapi-shim"
SHIM_SOURCES=(
  "lib/LinkerInterfaceFile.cpp"
)
# The shim is the only translation unit here that needs LLVM headers, which
# export-dev-headers.sh has already written into the build tree: the common set
# plus per-architecture generated headers (llvm-config.h). ld64 itself does not
# need them, which is why they are not in INCLUDES below.
SHIM_INCLUDES_COMMON="$BUILD/dev-headers/common/include"
SHIM_INCLUDES_ARCH_DIR="$BUILD/dev-headers"

# Fail loudly on a missing file instead of silently producing a partial archive.
MISSING=0
for REL in "${SOURCES_C[@]}" "${SOURCES_CXX[@]}"; do
  if [ ! -f "$LDSRC/$REL" ]; then
    echo "!! missing source: $REL" >&2
    MISSING=1
  fi
done
for REL in "${SHIM_SOURCES[@]}"; do
  if [ ! -f "$SHIM/$REL" ]; then
    echo "!! missing source: $SHIM/$REL" >&2
    MISSING=1
  fi
done
if [ ! -f "$SHIM_INCLUDES_COMMON/llvm/TextAPI/TextAPIReader.h" ]; then
  echo "!! missing LLVM TextAPI headers under $SHIM_INCLUDES_COMMON" >&2
  echo "   the shim links against llvm::MachO::TextAPIReader; run export-dev-headers.sh first" >&2
  MISSING=1
fi
if [ "$MISSING" -ne 0 ]; then
  exit 1
fi

EXPECTED_OBJECTS=$(( ${#SOURCES_C[@]} + ${#SOURCES_CXX[@]} + ${#SHIM_SOURCES[@]} ))
echo "==> ${#SOURCES_CXX[@]} C++ and ${#SOURCES_C[@]} C translation units, plus ${#SHIM_SOURCES[@]} tapi-shim unit"

# ---------------------------------------------------------------------------
# Flags
#
# Exceptions and RTTI are both ON. ld64 reports every failure by throwing
# strings, and the parsers and OutputFile.cpp use dynamic_cast; the Makefile's
# own build has both enabled. Disabling either does not make the library more
# embeddable -- it just fails to compile.
#
# -std=c++2a, not c++17: this port uses std::span and string_view::starts_with
# /ends_with, which are C++20. The port's own configure.ac sets exactly this.
#
# The HAVE_* defines stand in for autoconf. cctools/include/foreign/strings.h
# defines its own static inline bcmp/bzero/bcopy/index/rindex unless the
# corresponding HAVE_ macro is set, and each of those collides with the real
# declaration the iPhoneOS SDK already provides
# ("static declaration of 'rindex' follows non-static declaration").
# The port's configure probes for exactly these five symbols, so declaring them
# present is the faithful translation of a successful configure.
# ---------------------------------------------------------------------------
INCLUDES=(
  -I"$SRCROOT/include"
  -I"$SRCROOT/include/foreign"
  -I"$LDSRC"
  -I"$LDSRC/abstraction"
  -I"$LDSRC/3rd"
  -I"$LDSRC/3rd/include"
  -I"$LDSRC/ld"
  -I"$LDSRC/ld/parsers"
  -I"$LDSRC/ld/passes"
  -I"$LDSRC/mach_o"
  -I"$SHIM/include"
)

COMMON=(
  -O2
  -fexceptions
  -frtti
  -D__DARWIN_UNIX03
  -DHAVE_LIBDISPATCH=0
  -DHAVE_PTHREADS=0
  -DHAVE_BCMP=1
  -DHAVE_BZERO=1
  -DHAVE_BCOPY=1
  -DHAVE_INDEX=1
  -DHAVE_RINDEX=1
  -D__STDC_LIMIT_MACROS
  -D__STDC_CONSTANT_MACROS
  # The port's configure enables TAPI when tapi/tapi.h links, and the shim
  # provides it. Without the define textstub_dylib_file.cpp compiles to an
  # empty object and no .tbd can ever be read -- which is exactly how the SDK's
  # stub-based libSystem became invisible on device.
  -DTAPI_SUPPORT
  -DPROGRAM_PREFIX='""'
  -isysroot "$SDKROOT"
  -miphoneos-version-min="$MIN_IOS"
  -Wno-everything
)

CXX_STD="-std=c++2a"

# ---------------------------------------------------------------------------
# Per-file compile driver.
#
# Kept in a file and driven by xargs so job control works on bash 3.2, and so
# xargs can report a non-zero status if any unit fails.
# ---------------------------------------------------------------------------
DRIVER="$WORK/compile-ld64-one.sh"
cat > "$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env bash
# args: lang arch src dst
set -euo pipefail
LANG_KIND="$1"; ARCH="$2"; SRC="$3"; OBJ="$4"
# Optional per-translation-unit include directories. The tapi-shim needs the
# LLVM headers generated for THIS architecture, which the shared COMMON_INCLUDES
# cannot express. Empty for every ld64 source.
EXTRA_INCLUDES="${5:-}"
: "${COMMON_INCLUDES:?}"
: "${COMMON_FLAGS:?}"
: "${CXX_STD:?}"
if [ "$LANG_KIND" = "c" ]; then
  # shellcheck disable=SC2086
  xcrun --sdk iphoneos clang -arch "$ARCH" $COMMON_INCLUDES $EXTRA_INCLUDES $COMMON_FLAGS \
    -c "$SRC" -o "$OBJ"
else
  # shellcheck disable=SC2086
  xcrun --sdk iphoneos clang++ -arch "$ARCH" $COMMON_INCLUDES $EXTRA_INCLUDES $COMMON_FLAGS \
    "$CXX_STD" -c "$SRC" -o "$OBJ"
fi
DRIVER_EOF
chmod +x "$DRIVER"

export COMMON_INCLUDES="${INCLUDES[*]}"
export COMMON_FLAGS="${COMMON[*]}"
export CXX_STD

SLICE_ARCHIVES=()
# Follow ARCHS when the caller set it (build-ios-toolchain.sh passes the
# workflow's arch list down), otherwise keep the historical both-arch default
# so this script stays runnable on its own.
LD64_ARCHS="${ARCHS:-arm64 arm64e}"
for ARCH in $LD64_ARCHS; do
  ARCHOBJ="$OBJDIR/$ARCH"
  rm -rf "$ARCHOBJ"
  mkdir -p "$ARCHOBJ"
  echo "==> compiling ld64 for $ARCH (-j$JOBS)"

  PLAN="$WORK/plan-ld64-$ARCH.txt"
  : > "$PLAN"
  for REL in "${SOURCES_C[@]}"; do
    OBJ="$ARCHOBJ/$(echo "$REL" | tr '/' '_').o"
    printf 'c %s %s %s\n' "$ARCH" "$LDSRC/$REL" "$OBJ" >> "$PLAN"
  done
  for REL in "${SOURCES_CXX[@]}"; do
    OBJ="$ARCHOBJ/$(echo "$REL" | tr '/' '_').o"
    printf 'cpp %s %s %s\n' "$ARCH" "$LDSRC/$REL" "$OBJ" >> "$PLAN"
  done
  # The shim is also C++, but it is the one unit that needs this architecture's
  # generated LLVM headers, passed as the driver's optional fifth argument.
  for REL in "${SHIM_SOURCES[@]}"; do
    OBJ="$ARCHOBJ/tapi_shim_$(basename "$REL").o"
    printf 'cpp %s %s %s %s\n' "$ARCH" "$SHIM/$REL" "$OBJ" \
      "-I$SHIM_INCLUDES_COMMON -I$SHIM_INCLUDES_ARCH_DIR/$ARCH/include" >> "$PLAN"
  done

  if ! xargs -P "$JOBS" -L1 bash "$DRIVER" < "$PLAN"; then
    echo "!! at least one ld64 translation unit failed to compile for $ARCH" >&2
    exit 1
  fi

  COUNT="$(find "$ARCHOBJ" -name '*.o' | wc -l | tr -d ' ')"
  echo "    $COUNT objects"
  if [ "$COUNT" -ne "$EXPECTED_OBJECTS" ]; then
    echo "!! expected $EXPECTED_OBJECTS objects, got $COUNT" >&2
    exit 1
  fi

  # A build without TAPI_SUPPORT still succeeds: textstub_dylib_file.cpp
  # compiles to a few hundred bytes of nothing, .tbd parsing disappears, and the
  # failure only shows up on device as "must link with libSystem.dylib". The
  # real parser is tens of kilobytes, so this floor catches that regression at
  # the build that caused it.
  STUB_OBJ="$ARCHOBJ/ld_parsers_textstub_dylib_file.cpp.o"
  STUB_BYTES="$(wc -c < "$STUB_OBJ" | tr -d ' ')"
  if [ "$STUB_BYTES" -lt 8192 ]; then
    echo "!! text-stub parser object is only $STUB_BYTES bytes for $ARCH;" >&2
    echo "   TAPI_SUPPORT is not taking effect, so no .tbd can be read" >&2
    exit 1
  fi
  echo "    text-stub parser: $STUB_BYTES bytes"

  SLICE="$BUILD/libomld64-$ARCH.a"
  rm -f "$SLICE"
  find "$ARCHOBJ" -name '*.o' -print0 | xargs -0 xcrun libtool -static -o "$SLICE"
  SLICE_ARCHIVES+=("$SLICE")
  echo "    $SLICE"
done

echo "==> merging arch slices"
xcrun libtool -static -o "$OUT" "${SLICE_ARCHIVES[@]}"
echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1))"

# The linker resolves .tbd stubs through these symbols; if they are missing
# from the archive every dynamic link on device fails on the forced libSystem
# dependency, which is a long way from here to debug.
TAPI_SYMBOLS="$(xcrun nm "$OUT" 2>/dev/null | grep -c 'tapi' || true)"
if [ "${TAPI_SYMBOLS:-0}" -lt 4 ]; then
  echo "!! the tapi-shim symbols are missing from $OUT (found ${TAPI_SYMBOLS:-0})" >&2
  exit 1
fi
echo "==> tapi-shim symbols in archive: $TAPI_SYMBOLS"
