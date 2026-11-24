#!/bin/bash
# ============================================================================
# [T-ios-aojit] Assemble the AOJIT images into deps/libs/libish_aot.a
# ============================================================================
# An AOT image (aot_<name>.S, from deps/ish/tools/jit_aot/gen.py) is the ARM64
# JIT's translations of one guest module, recorded ahead of time. It carries a
# constructor that calls ish_aot_register(), so the app links the archive with
# -force_load. The images are too large for git (hundreds of MB of assembly):
# they live in deps/aot/ (gitignored) — see deps/aot/README.md.
#
# Each image must come from the same ish as libish (same "abi" in
# /proc/ish/jit) and match the guest file by build-id; a mismatch is not an
# error, the runtime just rejects or never hits that image.
#
# Usage: deps/build_aot.sh        (called by build_ish.sh)
#   PLATFORM=iphoneos (default)     -> deps/libs/libish_aot.a
#   PLATFORM=iphonesimulator        -> deps/libs/iphonesimulator/libish_aot.a
# The images are plain arm64 code, so the same .S files serve both; only the
# Mach-O platform (and so the SDK / min-version flag) differs. Each platform
# keeps its own object cache so neither one invalidates the other's.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOT_DIR="$SCRIPT_DIR/aot"
MIN_IOS="${IOS_DEPLOYMENT_TARGET:-15.0}"
# Normal/final builds fail closed on missing or mismatched recorded images.
# Explicit AOJIT_OFF=1 is a development-only build and must never be described
# as AOJIT-enabled/final. It writes a marked empty archive solely to validate
# the rest of the iOS integration; the locked-input verifier remains unchanged.
AOJIT_OFF="${AOJIT_OFF:-0}"
[[ "$AOJIT_OFF" == 0 || "$AOJIT_OFF" == 1 || "$AOJIT_OFF" == true || "$AOJIT_OFF" == false ]] || { echo 'AOJIT_OFF must be 0/1 or true/false' >&2; exit 1; }
if [[ "$AOJIT_OFF" == 1 || "$AOJIT_OFF" == true ]]; then
    echo 'WARNING: AOJIT_OFF development build — no AOJIT translations are included.' >&2
else
    python3 "$SCRIPT_DIR/aot/tools/verify_inputs.py" "$SCRIPT_DIR"
fi
AOT_BUILD_JOBS="${AOT_BUILD_JOBS:-1}"
[[ "$AOT_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid AOT_BUILD_JOBS' >&2; exit 1; }
PLATFORM="${PLATFORM:-iphoneos}"
case "$PLATFORM" in
    iphoneos)
        OBJ_DIR="$AOT_DIR/.build"
        OUT_DIR="$SCRIPT_DIR/libs"
        MIN_FLAG="-miphoneos-version-min=$MIN_IOS"
        ;;
    iphonesimulator)
        OBJ_DIR="$AOT_DIR/.build-iphonesimulator"
        OUT_DIR="$SCRIPT_DIR/libs/iphonesimulator"
        MIN_FLAG="-mios-simulator-version-min=$MIN_IOS"
        ;;
    *) echo "❌ unknown PLATFORM=$PLATFORM (iphoneos|iphonesimulator)" >&2; exit 1 ;;
esac
OUT="$OUT_DIR/libish_aot.a"
SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"

mkdir -p "$OBJ_DIR" "$OUT_DIR"
shopt -s nullglob
images=("$AOT_DIR"/aot_*.S)

objs=()
pids=()
for src in ${images[@]+"${images[@]}"}; do
    obj="$OBJ_DIR/$(basename "${src%.S}").o"
    objs+=("$obj")
    # Assembling the large images takes minutes: skip unchanged ones.
    if [ "$obj" -nt "$src" ]; then
        echo "⏭️  $(basename "$src") unchanged"
        continue
    fi
    echo "🔧 assembling $(basename "$src") ($(du -h "$src" | cut -f1)) for $PLATFORM"
    xcrun --sdk "$PLATFORM" clang -c -arch arm64 -isysroot "$SDK" \
        "$MIN_FLAG" -o "$obj.tmp" "$src" && mv "$obj.tmp" "$obj" &
    pids+=($!)
    if (( ${#pids[@]} >= AOT_BUILD_JOBS )); then
        for pid in "${pids[@]}"; do wait "$pid"; done
        pids=()
    fi
done
for pid in "${pids[@]+"${pids[@]}"}"; do wait "$pid"; done

if [ ${#objs[@]} -eq 0 ]; then
    if [[ "$AOJIT_OFF" != 1 && "$AOJIT_OFF" != true ]]; then
        echo 'ERROR: no verified AOJIT images, refusing empty archive' >&2
        exit 2
    fi
    echo 'void minis_aojit_off_development_marker(void) {}' | xcrun --sdk "$PLATFORM" clang -x c -c -arch arm64 \
        -isysroot "$SDK" "$MIN_FLAG" -o "$OBJ_DIR/aot_off_marker.o" -
    objs=("$OBJ_DIR/aot_off_marker.o")
fi

rm -f "$OUT"
xcrun libtool -static -o "$OUT" "${objs[@]}"
echo "✅ $OUT ($(du -h "$OUT" | cut -f1), ${#images[@]} image(s))"
