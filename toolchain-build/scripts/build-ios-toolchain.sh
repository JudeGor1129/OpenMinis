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
# Keep the source checkout in one canonical directory. The build and resource
# collection below both read from this path.
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
  # Try a direct application first. A blob-filtered clone cannot serve the
  # preimages that --3way needs, so --3way only produces noise here; keep it as
  # the fallback for the case where the tree has already drifted.
  if git apply --whitespace=nowarn "$1" 2>/dev/null; then
    return 0
  fi
  echo "   direct apply failed; retrying with --3way"
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

# LLD is a required library backend from this same patched checkout, not a
# separately versioned binary. Never publish an ld64-only kit as LLD-capable.
if [ ! -f lld/MachO/Arch/ARM64e.cpp ] || ! grep -q 'Arch/ARM64e.cpp' lld/MachO/CMakeLists.txt; then
  echo "!! patched lld MachO arm64e backend missing" >&2
  exit 1
fi
echo "   lld MachO: patched ARM64e.cpp is a build input"

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
  '-DLLVM_ENABLE_PROJECTS=clang;lld'
  -DBUILD_SHARED_LIBS=OFF
  -DLLVM_BUILD_LLVM_DYLIB=OFF
  -DLLVM_LINK_LLVM_DYLIB=OFF
  -DLLD_BUILD_TOOLS=OFF
  -DLLD_INCLUDE_TESTS=OFF
  -DLLVM_TARGETS_TO_BUILD=AArch64
  -DLLVM_ENABLE_ASSERTIONS=OFF
  -DLLVM_ENABLE_PIC=ON
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_BUILD_TOOLS=OFF
  -DLLVM_BUILD_UTILS=OFF
  -DLLVM_ENABLE_ZSTD=OFF
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
  # Clang's own executables are gated by CLANG_BUILD_TOOLS, not
  # LLVM_BUILD_TOOLS, so leaving it default builds bin/clang-24 -- and linking
  # that executable is what failed: LLVM_ENABLE_ZSTD defaults ON, and no arm64e
  # slice of libzstd exists in the iPhoneOS SDK, so the link died at 96% on
  # undefined _ZSTD_* symbols. We link the libraries rather than run the CLI, so
  # neither the executable nor zstd is needed. clang's builtin headers come from
  # clang/lib/Headers, which is outside this switch.
  -DCLANG_BUILD_TOOLS=OFF
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
  echo "==> building clang+LLVM+LLD for $ARCH (long step)"
  cmake --build "$ARCH_BUILD" -j "$JOBS"
  # Explicit targets are essential: LLVM_BUILD_TOOLS=OFF must never let an
  # apparently successful build omit the libraries we promise in the kit.
  cmake --build "$ARCH_BUILD" -j "$JOBS" --target lldMachO lldCommon
  SLICE_DIRS+=("$ARCH_BUILD")
  df -h "$WORK" || true
done

# Clang's builtin headers are source resources, not embedded in the static
# archives. Copy the exact pinned source headers beside the archives so the
# in-process bridge can resolve -resource-dir without depending on Xcode's
# private installation layout at runtime.
RESOURCE_DIR="$BUILD/clang-resource"
rm -rf "$RESOURCE_DIR"
mkdir -p "$RESOURCE_DIR/include"
CLANG_HEADERS="$WORK/llvm-project/clang/lib/Headers"
if [ ! -d "$CLANG_HEADERS" ]; then
  echo "!! missing Clang builtin headers at $CLANG_HEADERS" >&2
  exit 1
fi
cp -R "$CLANG_HEADERS/." "$RESOURCE_DIR/include/"
echo "==> copied Clang builtin headers to $RESOURCE_DIR/include"

# Export public source headers plus every architecture's generated headers.
# Builtin headers above are runtime resources, not LLVM's development headers.
bash "$ROOT/scripts/export-dev-headers.sh" "$WORK" "$BUILD" "$ARCHS"

# ---------------------------------------------------------------------------
# 5. Linker (in-process ld64)
# ---------------------------------------------------------------------------
if [ "${SKIP_LD64:-false}" = "true" ]; then
  echo "==> SKIP_LD64=true: producing a front-end-only toolchain"
else
  # Invoked via bash explicitly: the file may have arrived without its
  # executable bit (the Contents API cannot carry a mode), and `bash script`
  # does not care.
  # ARCHS is exported so ld64 builds exactly the slices the workflow asked for
  # instead of its own hardcoded pair; the two must not drift apart.
  ARCHS="$ARCHS" bash "$ROOT/scripts/build-ld64-inprocess.sh"
fi

# ---------------------------------------------------------------------------
# 6. Aggregate component archives, one library per architecture
#
# Within a single architecture the component archives have distinct member
# names, so libtool can merge them directly. Across architectures we keep
# separate outputs; a fat archive of two same-cputype slices is ambiguous and
# more trouble than it is worth for a library linked into one app.
# ---------------------------------------------------------------------------
LLVM_COMMIT="$LLVM_COMMIT" LLVM_MIN_IOS="$LLVM_MIN_IOS" ARM64E_OK="$ARM64E_OK" SKIP_LD64="${SKIP_LD64:-false}" \
python3 - "$BUILD" "$ARCHS" "$WORK" <<'PY'
import hashlib, json, os, re, runpy, subprocess, sys
from pathlib import Path

build, archs, work = sys.argv[1], sys.argv[2].split(), sys.argv[3]
verifier = runpy.run_path(str(Path(work).parent / "scripts/verify-toolchain-manifest.py"))

def component_libs(slice_dir):
    """Real built LLD/clang/LLVM archives; never synthesize a component name."""
    found = {}
    for root, _dirs, files in os.walk(slice_dir):
        for f in files:
            if f.endswith(".a") and (f.startswith("libclang") or f.startswith("libLLVM") or f in ("liblldMachO.a", "liblldCommon.a")):
                if f in found:
                    raise SystemExit(f"ambiguous component archive: {f} in {slice_dir}")
                found[f] = os.path.join(root, f)
    for library in ("lldMachO", "lldCommon"):
        name = f"lib{library}.a"
        if name not in found or os.path.getsize(found[name]) == 0:
            raise SystemExit(f"missing/empty required LLD component: {name} in {slice_dir}")
        verifier["verify_lld_symbols"](found[name], (library,))
    # LLD before clang before LLVM; only the two required LLD libraries.
    return [found[k] for k in sorted(found, key=lambda n: (0 if n == "liblldMachO.a" else 1 if n == "liblldCommon.a" else 2 if n.startswith("libclang") else 3, n))]

manifest = {"schema": 2, "architectures": archs, "artifacts": {}, "linker_backends": {}}
# Read the version from every completed cross build, not a hardcoded claim.
versions = set()
for arch in archs:
    config = (Path(work) / f"build-ios-{arch}/include/llvm/Config/llvm-config.h").read_text()
    parts = [re.search(r"^#define LLVM_VERSION_" + part + r"\s+(\d+)\s*$", config, re.M) for part in ("MAJOR", "MINOR", "PATCH")]
    if not all(parts):
        raise SystemExit(f"missing generated LLVM version: {arch}")
    versions.add(".".join(part[1] for part in parts))
if len(versions) != 1:
    raise SystemExit("LLVM versions differ between architecture builds")
manifest["linker_backends"]["lld_macho"] = {
    "version": versions.pop(), "tool_lld": 4, "api": "lld::macho::link", "arm64e": True,
    "llvm_commit": os.environ["LLVM_COMMIT"],
    "component_libraries": ["lldMachO", "lldCommon"],
    "archive_by_architecture": {arch: f"libomllvm-{arch}.a" for arch in archs},
}
patch_names = ["llvm-arm64e-twork.diff"] if os.environ["ARM64E_OK"] == "1" else ["llvm-pr-188378.diff", "llvm-pr-188638.diff"]
manifest["llvm_patches"] = {name: hashlib.sha256((Path(work).parent / "deps/patches" / name).read_bytes()).hexdigest() for name in patch_names}

def header_inventory(relative_root):
    base = os.path.join(build, relative_root)
    records = {}
    for directory, dirs, files in os.walk(base):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(directory, name)
            if os.path.islink(path):
                raise SystemExit(f"symlink not allowed in exported headers: {path}")
            digest = hashlib.sha256()
            with open(path, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    digest.update(chunk)
            relative = os.path.relpath(path, base).replace(os.sep, "/")
            records[relative] = {"bytes": os.path.getsize(path), "sha256": digest.hexdigest()}
    if not records:
        raise SystemExit(f"empty header export: {relative_root}")
    return records

roots = ["clang-resource", "dev-headers/common/include", "dev-headers/licenses"]
roots += [f"dev-headers/{arch}/include" for arch in archs]
manifest["header_trees"] = {root: header_inventory(root) for root in roots}
manifest["development_headers"] = {
    "common_include": "dev-headers/common/include",
    "generated_include": {arch: f"dev-headers/{arch}/include" for arch in archs},
    "include_order": ["generated_include[host_architecture]", "common_include"],
}

for arch in archs:
    libs = component_libs(os.path.join(work, f"build-ios-{arch}"))
    if not libs:
        raise SystemExit(f"no component archives found for {arch}")

    out = os.path.join(build, f"libomllvm-{arch}.a")
    print(f"[{arch}] merging {len(libs)} archives -> {out}")
    subprocess.run(["xcrun", "libtool", "-static", "-o", out, *libs], check=True)
    verifier["verify_lld_symbols"](out)

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
if os.environ["SKIP_LD64"] != "true":
    if not os.path.isfile(ld64) or os.path.getsize(ld64) == 0:
        raise SystemExit("missing/empty freshly built ld64 archive")
    cctools_commit = subprocess.check_output(["git", "-C", str(Path(work) / "cctools-port"), "rev-parse", "HEAD"], text=True).strip()
    manifest["linker_backends"]["ld64"] = {
        "archive": "libomld64.a", "cctools_commit": cctools_commit, "tapi_shim": True,
    }
    h = hashlib.sha256()
    with open(ld64, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    manifest["artifacts"]["libomld64.a"] = {
        "bytes": os.path.getsize(ld64),
        "sha256": h.hexdigest(),
    }

manifest["clang_resource_dir"] = "clang-resource"
manifest["llvm_commit"] = os.environ.get("LLVM_COMMIT", "40f30ea173b50c130c01d843b612f9563ca63930")
manifest["minimum_ios"] = os.environ.get("LLVM_MIN_IOS", "14.0")
with open(os.path.join(build, "toolchain.json"), "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
print(json.dumps(manifest, indent=2))
PY

echo "==> done. Artifacts in $BUILD"
ls -la "$BUILD"
