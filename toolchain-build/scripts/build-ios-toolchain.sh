#!/usr/bin/env bash
#
# build-ios-toolchain.sh — build clang/LLVM (arm64e; optionally arm64) and the
# in-process Mach-O linker as iOS static libraries, so they can be linked into
# the OpenMinis host process.
#
# Runs on a macOS host with Xcode. It cannot run on-device: producing LLVM needs
# CMake, Ninja, a full C++ compiler and an iOS SDK, none of which exist in the
# app sandbox. The app therefore cannot build its own compiler without one.
#
# Why a static library and not a dylib: iOS refuses to dlopen() a main
# executable, so a host app can only own a compiler by linking it in. That is
# exactly what Twork does, and why its compiler cannot be extracted or reused.
#
# ---------------------------------------------------------------------------
# CROSS-COMPILE NOTE (this is the step that makes or breaks the build)
#
# Clang's build generates .inc files by running llvm-tblgen and clang-tblgen.
# When CMAKE_OSX_SYSROOT is the iPhoneOS SDK, those two get built for iOS — and
# an iOS binary cannot execute on the build host, so the build dies partway
# through. The supported fix is to build tablegen natively first and hand the
# paths to the cross build via LLVM_TABLEGEN/CLANG_TABLEGEN.
# ---------------------------------------------------------------------------

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/work"
BUILD="$ROOT/build/ios"
DEPS="$ROOT/deps"

LLVM_COMMIT="${LLVM_COMMIT:-40f30ea173b50c130c01d843b612f9563ca63930}"
LLVM_MIN_IOS="${LLVM_MIN_IOS:-14.0}"
# arm64e is the target; add "arm64" to ARCHS for a universal library.
ARCHS="${ARCHS:-arm64e}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
# Local builds can use cores - 1; CI runners report few cores but throttle.
[ "$JOBS" -gt 4 ] && JOBS=$((JOBS - 1))

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"

echo "==> iPhoneOS SDK : $SDKROOT"
echo "==> LLVM         : $LLVM_COMMIT"
echo "==> architectures: $ARCHS"
echo "==> jobs         : $JOBS"
echo "==> skip ld64    : ${SKIP_LD64:-false}"

mkdir -p "$WORK" "$BUILD"

# ---------------------------------------------------------------------------
# 1. LLVM + clang sources, arm64e adaptation applied
# ---------------------------------------------------------------------------
if [ ! -d "$WORK/llvm-project/.git" ]; then
  echo "==> cloning llvm-project (blob-filtered)"
  git clone --filter=blob:none --no-checkout \
    https://github.com/llvm/llvm-project.git "$WORK/llvm-project"
fi

cd "$WORK/llvm-project"
echo "==> checking out $LLVM_COMMIT"
if ! git cat-file -e "$LLVM_COMMIT^{commit}" 2>/dev/null; then
  git fetch origin "$LLVM_COMMIT" 2>/dev/null || git fetch --all --tags
fi
git checkout --force "$LLVM_COMMIT"
git clean -fdx >/dev/null 2>&1 || true

apply_patch() {
  echo "==> applying $(basename "$1")"
  git apply --3way --whitespace=nowarn "$1"
}

# Prefer the consolidated Twork diff: it already folds PR 188378 and 188638
# together and carries the product's own adaptations. Fall back to the two
# upstream diffs against the same revision.
ARM64E_OK=0
if apply_patch "$DEPS/patches/llvm-arm64e-twork.diff" 2>&1; then
  ARM64E_OK=1
  echo "   consolidated arm64e diff applied"
else
  echo "   consolidated diff did not apply; reverting and using upstream PRs"
  git checkout --force "$LLVM_COMMIT"
  git clean -fdx >/dev/null 2>&1 || true
fi
if [ "$ARM64E_OK" -eq 0 ]; then
  apply_patch "$DEPS/patches/llvm-pr-188378.diff"
  apply_patch "$DEPS/patches/llvm-pr-188638.diff"
  echo "   upstream PR diffs applied"
fi

# ---------------------------------------------------------------------------
# 2. Assert the arm64e backend is really present
#
# A toolchain missing this file still builds and still "succeeds" — it just
# links arm64e as arm64 and silently drops to A-key signing. Failing here is far
# cheaper than discovering it from a broken device build.
# ---------------------------------------------------------------------------
echo "==> verifying arm64e support landed"
if grep -rq "isArm64e" clang/lib/CodeGen/CGCall.cpp; then
  echo "   clang CodeGen: arm64e branches present"
else
  echo "!! clang CodeGen has no arm64e handling — NonLazyBind patch missing" >&2
  exit 1
fi

# The lld backend is only needed if linking with lld; we link with ld64. Check it
# but do not fail, so an ld64-only toolchain can still be produced.
if [ -f lld/MachO/Arch/ARM64e.cpp ]; then
  echo "   lld MachO: ARM64e.cpp present"
else
  echo "   note: lld MachO ARM64e.cpp absent (fine for ld64-only linking)"
fi

# ---------------------------------------------------------------------------
# 3. Native tablegen (must exist before any cross build)
# ---------------------------------------------------------------------------
HOST_BUILD="$WORK/build-host"
HOST_TBLGEN="$HOST_BUILD/bin/llvm-tblgen"
HOST_CLANG_TBLGEN="$HOST_BUILD/bin/clang-tblgen"

if [ ! -x "$HOST_TBLGEN" ] || [ ! -x "$HOST_CLANG_TBLGEN" ]; then
  echo "==> building native llvm-tblgen/clang-tblgen for the build host"
  cmake -S llvm -B "$HOST_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS=clang \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_FORMAT=OFF
  cmake --build "$HOST_BUILD" -j "$JOBS" --target llvm-tblgen clang-tblgen
fi

if [ ! -x "$HOST_TBLGEN" ] || [ ! -x "$HOST_CLANG_TBLGEN" ]; then
  echo "!! native tablegen did not build; cannot cross-compile LLVM" >&2
  exit 1
fi
echo "==> native tablegen ready"
"$HOST_TBLGEN" --version | head -2 || true

# ---------------------------------------------------------------------------
# 4. Cross build, one slice per architecture
# ---------------------------------------------------------------------------
CROSS_CMAKE=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_SYSROOT="$SDKROOT"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$LLVM_MIN_IOS"
  -DLLVM_TABLEGEN="$HOST_TBLGEN"
  -DCLANG_TABLEGEN="$HOST_CLANG_TBLGEN"
  -DLLVM_ENABLE_PROJECTS=clang
  -DLLVM_TARGETS_TO_BUILD=AArch64
  -DLLVM_ENABLE_ASSERTIONS=OFF
  -DLLVM_ENABLE_PIC=ON
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_BUILD_TOOLS=OFF
  -DLLVM_BUILD_UTILS=OFF
  -DLLVM_ENABLE_TERMINFO=OFF
  -DLLVM_ENABLE_ZLIB=OFF
  -DLLVM_ENABLE_LIBXML2=OFF
  -DLLVM_ENABLE_BINDINGS=OFF
  -DLLVM_ENABLE_OCAMLDOC=OFF
  -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_FFI=OFF
  -DLLVM_ENABLE_THREADS=ON
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  -DCLANG_ENABLE_ARCMT=OFF
  -DCLANG_ENABLE_FORMAT=OFF
  -DCLANG_ENABLE_BOOTSTRAP=OFF
  -DCLANG_INCLUDE_TESTS=OFF
)

# Free space before the heavy step on constrained CI runners.
echo "==> disk before cross build"
df -h "$WORK" || true

SLICE_DIRS=()
for ARCH in $ARCHS; do
  ARCH_BUILD="$WORK/build-ios-$ARCH"
  echo "==> configuring LLVM for $ARCH -> $ARCH_BUILD"
  cmake -S llvm -B "$ARCH_BUILD" "${CROSS_CMAKE[@]}" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
  echo "==> building clang+LLVM for $ARCH (long step)"
  cmake --build "$ARCH_BUILD" -j "$JOBS"
  SLICE_DIRS+=("$ARCH_BUILD")
  df -h "$WORK" || true
done

# ---------------------------------------------------------------------------
# 5. Linker (in-process ld64)
# ---------------------------------------------------------------------------
if [ "${SKIP_LD64:-false}" = "true" ]; then
  echo "==> SKIP_LD64=true: producing a front-end-only toolchain"
else
  "$ROOT/scripts/build-ld64-inprocess.sh"
fi

# ---------------------------------------------------------------------------
# 6. Aggregate component archives, one library per architecture
#
# Within a single architecture the component archives have distinct member
# names, so libtool can merge them directly. Across architectures we keep
# separate outputs; a fat archive of two same-cputype slices is ambiguous and
# more trouble than it is worth for a library linked into one app.
# ---------------------------------------------------------------------------
python3 - "$BUILD" "$ARCHS" "$WORK" <<'PY'
import hashlib, json, os, subprocess, sys

build, archs, work = sys.argv[1], sys.argv[2].split(), sys.argv[3]

def component_libs(slice_dir):
    """LLVM/clang archives, keyed by basename, in a stable link order."""
    found = {}
    for root, _dirs, files in os.walk(slice_dir):
        for f in files:
            if f.endswith(".a") and (f.startswith("libclang") or f.startswith("libLLVM")):
                found[f] = os.path.join(root, f)
    # libclang* before libLLVM*; within each, alphabetical. Static link order
    # matters, and this keeps it deterministic between runs.
    return [found[k] for k in sorted(found, key=lambda n: (not n.startswith("libclang"), n))]

manifest = {"schema": 1, "architectures": archs, "artifacts": {}}

for arch in archs:
    libs = component_libs(os.path.join(work, f"build-ios-{arch}"))
    if not libs:
        raise SystemExit(f"no component archives found for {arch}")

    out = os.path.join(build, f"libomllvm-{arch}.a")
    print(f"[{arch}] merging {len(libs)} archives -> {out}")
    subprocess.run(["xcrun", "libtool", "-static", "-o", out, *libs], check=True)

    h = hashlib.sha256()
    with open(out, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    manifest["artifacts"][os.path.basename(out)] = {
        "arch": arch,
        "bytes": os.path.getsize(out),
        "sha256": h.hexdigest(),
    }

ld64 = os.path.join(build, "libomld64.a")
if os.path.isfile(ld64):
    h = hashlib.sha256()
    with open(ld64, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    manifest["artifacts"]["libomld64.a"] = {
        "bytes": os.path.getsize(ld64),
        "sha256": h.hexdigest(),
    }

with open(os.path.join(build, "toolchain.json"), "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
print(json.dumps(manifest, indent=2))
PY

echo "==> done. Artifacts in $BUILD"
ls -la "$BUILD"
