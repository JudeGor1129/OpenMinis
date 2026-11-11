"""Verify the exported schema-2 development kit. Never executes the libraries."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import shutil
import subprocess


# Darwin's nm prepends '_' to Itanium C++ names. These must be definitions,
# not undefined references or arbitrary strings embedded in an old archive.
LLD_SYMBOLS = {
    "lldMachO": ("_ZN3lld5macho4linkE", "_ZN3lld5macho22createARM64eTargetInfoEv"),
    "lldCommon": ("_ZN3lld13getLLDVersionEv",),
}


def verify_lld_symbols(path, libraries=("lldMachO", "lldCommon")):
    if not shutil.which("xcrun"):
        fail("LLD defined-symbol verification requires Xcode xcrun; use --integrity-only for metadata checks (not kit acceptance)")
    result = subprocess.run(["xcrun", "nm", "-g", "-U", str(path)], capture_output=True, text=True)
    if result.returncode:
        fail("nm failed for " + str(path) + ": " + result.stderr)
    symbols = set()
    for line in result.stdout.splitlines():
        match = re.fullmatch(r"\s*[0-9a-fA-F]+\s+T\s+(\S+)\s*", line)
        if match:
            symbols.add(match[1].removeprefix("_"))
    for library in libraries:
        for prefix in LLD_SYMBOLS[library]:
            if not any(symbol.startswith(prefix) for symbol in symbols):
                fail(f"missing defined LLD symbol ({library}): {prefix} in {path}")


def fail(message):
    raise SystemExit(message)


def safe_file(root, relative):
    path = PurePosixPath(relative)
    if path.is_absolute() or ".." in path.parts or not path.parts or "\\" in relative:
        fail("unsafe manifest path: " + relative)
    result = root.joinpath(*path.parts)
    if result.is_symlink() or not result.is_file():
        fail("missing or symlinked file: " + str(result))
    if not result.resolve().is_relative_to(root.resolve()):
        fail("manifest path escapes root: " + relative)
    return result


def verify_file(path, record):
    expected = record.get("sha256", "")
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        fail("missing/invalid sha256: " + str(path))
    if type(record.get("bytes")) is not int or record["bytes"] != path.stat().st_size:
        fail("size mismatch: " + str(path))
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        fail("sha256 mismatch: " + str(path))


def verify_backend_metadata(manifest):
    if manifest.get("llvm_commit") != "40f30ea173b50c130c01d843b612f9563ca63930":
        fail("LLD kit requires the currently pinned LLVM commit")
    patches = manifest.get("llvm_patches", {})
    allowed = ({"llvm-arm64e-twork.diff"}, {"llvm-pr-188378.diff", "llvm-pr-188638.diff"})
    if set(patches) not in allowed:
        fail("LLD kit requires the pinned arm64e patch inventory")
    deps = Path(__file__).resolve().parents[1] / "deps"
    for name, digest in patches.items():
        if digest != hashlib.sha256((deps / "patches" / name).read_bytes()).hexdigest():
            fail("LLVM patch hash differs from pinned input: " + name)
    backends = manifest.get("linker_backends", {})
    lld = backends.get("lld_macho", {})
    expected_archives = {arch: f"libomllvm-{arch}.a" for arch in manifest["architectures"]}
    if (lld.get("version") != "24.0.0" or lld.get("llvm_commit") != manifest["llvm_commit"]
            or lld.get("tool_lld") != 4 or lld.get("api") != "lld::macho::link"
            or lld.get("component_libraries") != ["lldMachO", "lldCommon"]
            or lld.get("archive_by_architecture") != expected_archives
            or lld.get("arm64e") is not True):
        fail("missing/invalid LLD MachO capability: rebuild old kits; ld64 is not LLD")
    cctools = json.loads((deps / "cctools-source.json").read_text())["commit"]
    ld64 = backends.get("ld64", {})
    if ld64 != {"archive": "libomld64.a", "cctools_commit": cctools, "tapi_shim": True}:
        fail("missing/invalid pinned ld64/TAPI backend")


def main(directory, integrity_only=False):
    root = Path(directory).resolve()
    with (root / "toolchain.json").open(encoding="utf-8") as file:
        manifest = json.load(file)
    if manifest.get("schema") != 2:
        fail("schema 2 required: rebuild artifacts with development header export")
    if manifest.get("architectures") != ["arm64", "arm64e"]:
        fail("full kit requires architectures in order: arm64 arm64e")
    verify_backend_metadata(manifest)
    artifacts = manifest.get("artifacts", {})
    for arch in ("arm64", "arm64e"):
        name = f"libomllvm-{arch}.a"
        if name not in artifacts or artifacts[name].get("arch") != arch:
            fail("missing or mismatched archive record: " + name)
    for name in ("libomllvm-arm64.a", "libomllvm-arm64e.a", "libomld64.a"):
        if name not in artifacts:
            fail("missing archive record: " + name)
        verify_file(safe_file(root, name), artifacts[name])
    if manifest.get("clang_resource_dir") != "clang-resource":
        fail("invalid resource layout")
    headers = manifest.get("development_headers", {})
    expected_generated = {arch: f"dev-headers/{arch}/include" for arch in ("arm64", "arm64e")}
    if headers.get("common_include") != "dev-headers/common/include" or headers.get("generated_include") != expected_generated:
        fail("invalid development header layout")
    if headers.get("include_order") != ["generated_include[host_architecture]", "common_include"]:
        fail("generated headers must precede common source headers")
    required_trees = {"clang-resource", "dev-headers/common/include", "dev-headers/licenses", *expected_generated.values()}
    trees = manifest.get("header_trees", {})
    if set(trees) != required_trees:
        fail("header tree inventory missing or unexpected")
    for relative_root, records in sorted(trees.items()):
        base = root / relative_root
        if not records or not base.is_dir() or base.is_symlink():
            fail("empty/missing/symlinked header tree: " + relative_root)
        actual = set()
        for path in base.rglob("*"):
            if path.is_symlink():
                fail("symlink in header export: " + str(path))
            if path.is_file():
                actual.add(path.relative_to(base).as_posix())
        if actual != set(records):
            fail("header inventory differs from files: " + relative_root)
        for name, record in sorted(records.items()):
            verify_file(safe_file(base, name), record)
    for header in ("stddef.h", "stdarg.h", "stdint.h", "ptrauth.h", "arm_neon.h"):
        safe_file(root, "clang-resource/include/" + header)
    for header in ("llvm/ADT/ArrayRef.h", "clang/Frontend/CompilerInstance.h", "lld/Common/Driver.h", "lld/Common/Version.h", "lld/Common/ErrorHandler.h", "lld/Common/CommonLinkerContext.h"):
        safe_file(root, "dev-headers/common/include/" + header)
    common = root / "dev-headers/common/include"
    for arch in ("arm64", "arm64e"):
        generated = root / f"dev-headers/{arch}/include"
        for header in ("llvm/Config/config.h", "llvm/Config/llvm-config.h", "llvm/Config/abi-breaking.h", "llvm/IR/IntrinsicEnums.inc", "llvm/IR/IntrinsicImpl.inc", "clang/Basic/Version.inc", "clang/Config/config.h"):
            safe_file(generated, header)
        config = (generated / "llvm/Config/llvm-config.h").read_text()
        for part, expected in (("MAJOR", "24"), ("MINOR", "0"), ("PATCH", "0")):
            if not re.search(r"^#define LLVM_VERSION_" + part + r"\s+" + expected + r"\s*$", config, re.M):
                fail("generated LLVM version disagrees with LLD manifest: " + arch)
        # Include closure for the LLD public tree, including generated .inc
        # dependencies and LLVM includes, checked against both include roots.
        for base in (common, generated):
            for path in (base / "lld").rglob("*"):
                if not path.is_file():
                    continue
                for include in re.findall(r'^\s*#\s*include\s*[<"]((?:lld|llvm)/[^">]+)[">]', path.read_text(), re.M):
                    if not (generated / include).is_file() and not (common / include).is_file():
                        fail("missing LLD transitive include: " + include + " for " + arch)
    for license in ("LLVM-LICENSE.txt", "Clang-LICENSE.txt", "LLD-LICENSE.txt"):
        safe_file(root, "dev-headers/licenses/" + license)
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", manifest.get("minimum_ios", "")):
        fail("invalid minimum iOS")
    if integrity_only:
        print("Metadata/header/hash integrity only; LLD symbols and architecture NOT verified. Not kit acceptance.")
    else:
        for arch in ("arm64", "arm64e"):
            verify_lld_symbols(root / f"libomllvm-{arch}.a")
        print("Schema-2 LLD kit archive/header hashes + MachO/Common/arm64e defined symbols verified.")
    print("This does not establish ABI, PAC, signing or runtime compatibility.")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--integrity-only"):
        fail("usage: verify-toolchain-manifest.py KIT [--integrity-only]")
    main(sys.argv[1], integrity_only=len(sys.argv) == 3)
