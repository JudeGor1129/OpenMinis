#!/usr/bin/env python3
"""Verify the copied Clang resource tree against schema-2 toolchain.json."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys


def fail(message):
    raise SystemExit("bundled Clang resource verification failed: " + message)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            value.update(chunk)
    return value.hexdigest()


if len(sys.argv) != 3:
    fail("usage: verify-bundled-clang-resource.py TOOLCHAIN_JSON RESOURCE_DIR")
manifest_path = Path(sys.argv[1])
resource_root = Path(sys.argv[2])
if not manifest_path.is_file() or manifest_path.is_symlink():
    fail("missing or symlinked toolchain manifest")
if not resource_root.is_dir() or resource_root.is_symlink():
    fail("missing or symlinked bundled resource directory")
with manifest_path.open(encoding="utf-8") as handle:
    manifest = json.load(handle)
if manifest.get("schema") != 2 or manifest.get("clang_resource_dir") != "clang-resource":
    fail("schema-2 Clang resource manifest required")
records = manifest.get("header_trees", {}).get("clang-resource")
if not isinstance(records, dict) or not records:
    fail("manifest has no Clang resource inventory")
actual = set()
for path in resource_root.rglob("*"):
    if path.is_symlink():
        fail("symlink in bundled resource tree: " + str(path))
    if path.is_file():
        actual.add(path.relative_to(resource_root).as_posix())
if actual != set(records):
    missing = sorted(set(records) - actual)
    extra = sorted(actual - set(records))
    fail(f"inventory differs (missing={missing[:5]}, extra={extra[:5]})")
for relative, record in sorted(records.items()):
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts or "\\" in relative:
        fail("unsafe manifest resource path: " + relative)
    path = resource_root.joinpath(*pure.parts)
    if type(record.get("bytes")) is not int or path.stat().st_size != record["bytes"]:
        fail("size differs: " + relative)
    if digest(path) != record.get("sha256"):
        fail("SHA-256 differs: " + relative)
print(f"Verified {len(records)} locked Clang resource files in {resource_root}.")
