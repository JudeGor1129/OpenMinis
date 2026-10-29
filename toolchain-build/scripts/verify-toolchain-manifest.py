"""Verify the exported schema-2 development kit. Never executes the libraries."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys


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


def main(directory):
    root = Path(directory).resolve()
    with (root / "toolchain.json").open(encoding="utf-8") as file:
        manifest = json.load(file)
    if manifest.get("schema") != 2:
        fail("schema 2 required: rebuild artifacts with development header export")
    if manifest.get("architectures") != ["arm64", "arm64e"]:
        fail("full kit requires architectures in order: arm64 arm64e")
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
    for header in ("llvm/ADT/ArrayRef.h", "clang/Frontend/CompilerInstance.h"):
        safe_file(root, "dev-headers/common/include/" + header)
    for arch in ("arm64", "arm64e"):
        for header in ("llvm/Config/config.h", "llvm/Config/llvm-config.h", "llvm/Config/abi-breaking.h", "llvm/IR/IntrinsicEnums.inc", "llvm/IR/IntrinsicImpl.inc", "clang/Basic/Version.inc", "clang/Config/config.h"):
            safe_file(root, f"dev-headers/{arch}/include/{header}")
    for license in ("LLVM-LICENSE.txt", "Clang-LICENSE.txt"):
        safe_file(root, "dev-headers/licenses/" + license)
    if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("llvm_commit", "")):
        fail("invalid pinned LLVM commit")
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", manifest.get("minimum_ios", "")):
        fail("invalid minimum iOS")
    print("Schema-2 toolchain archives + all exported header hashes verified.")
    print("Hash/layout validation does not establish ABI, PAC, signing or runtime compatibility.")


if __name__ == "__main__":
    main(sys.argv[1])
