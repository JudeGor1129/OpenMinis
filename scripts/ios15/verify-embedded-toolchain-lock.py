#!/usr/bin/env python3
"""Verify the immutable Run7 artifact lock before and after extraction."""
import argparse, hashlib, json, re, stat, zipfile
from pathlib import Path, PurePosixPath

def fail(message):
    raise SystemExit("embedded toolchain verification failed: " + message)

def load_json(path):
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read JSON {path}: {error}")

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()

def require_sha(value, label):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        fail(f"invalid locked SHA-256 for {label}")

def safe_child(root, relative):
    pure = PurePosixPath(relative)
    if pure.is_absolute() or not pure.parts or ".." in pure.parts or "\\" in relative:
        fail(f"unsafe locked path: {relative}")
    child = root.joinpath(*pure.parts)
    if not child.is_file() or child.is_symlink():
        fail(f"missing or symlinked locked file: {relative}")
    if not child.resolve().is_relative_to(root.resolve()):
        fail(f"locked path escapes extraction root: {relative}")
    return child

def verify_lock_shape(lock):
    if lock.get("schema") != 1:
        fail("lock schema 1 required")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", lock.get("repository", "")):
        fail("invalid repository in lock")
    if type(lock.get("workflow_run_id")) is not int or type(lock.get("artifact", {}).get("id")) is not int:
        fail("workflow run and artifact IDs must be integers")
    if not re.fullmatch(r"[0-9a-f]{40}", lock.get("head_sha", "")):
        fail("invalid workflow head SHA")
    require_sha(lock.get("artifact", {}).get("archive_sha256"), "artifact archive")
    require_sha(lock.get("manifest", {}).get("sha256"), "toolchain.json")
    require_sha(lock.get("enabled_link_report", {}).get("sha256"), "enabled link report")

def verify_metadata(lock, path):
    metadata = load_json(path)
    artifact = lock["artifact"]
    workflow = metadata.get("workflow_run") or {}
    checks = (
        (metadata.get("id"), artifact["id"], "artifact ID"),
        (metadata.get("name"), artifact["name"], "artifact name"),
        (metadata.get("expires_at"), artifact["expires_at"], "artifact expiry"),
        (metadata.get("digest"), "sha256:" + artifact["archive_sha256"], "artifact digest"),
        (workflow.get("id"), lock["workflow_run_id"], "workflow run ID"),
        (workflow.get("head_sha"), lock["head_sha"], "workflow head SHA"),
    )
    for actual, expected, label in checks:
        if actual != expected:
            fail(f"GitHub {label} differs from lock: expected {expected}, got {actual}")
    if metadata.get("expired") is not False:
        fail("locked GitHub artifact is expired or has unknown expiry state")

def verify_archive(lock, archive):
    if not archive.is_file() or archive.is_symlink():
        fail(f"artifact archive is missing or symlinked: {archive}")
    expected = lock["artifact"]["archive_sha256"]
    actual = sha256(archive)
    if actual != expected:
        fail(f"artifact ZIP SHA-256 mismatch: expected {expected}, got {actual}")
    seen, total = set(), 0
    try:
        with zipfile.ZipFile(archive) as bundle:
            for item in bundle.infolist():
                name, pure = item.filename, PurePosixPath(item.filename)
                if pure.is_absolute() or not pure.parts or ".." in pure.parts or "\\" in name:
                    fail(f"unsafe artifact ZIP member: {name}")
                if name in seen:
                    fail(f"duplicate artifact ZIP member: {name}")
                seen.add(name); total += item.file_size
                if stat.S_ISLNK(item.external_attr >> 16):
                    fail(f"symlink in artifact ZIP: {name}")
                if item.flag_bits & 0x1:
                    fail(f"encrypted artifact ZIP member: {name}")
    except (OSError, zipfile.BadZipFile) as error:
        fail(f"invalid artifact ZIP: {error}")
    if total > 1_500_000_000:
        fail(f"artifact expands beyond safety limit: {total} bytes")
    required = {lock["manifest"]["path"], lock["enabled_link_report"]["path"],
                *lock["manifest"]["archives"].keys()}
    missing = sorted(required - seen)
    if missing:
        fail("artifact ZIP lacks locked members: " + ", ".join(missing))

def verify_extracted(lock, root):
    if not root.is_dir() or root.is_symlink():
        fail(f"invalid extraction root: {root}")
    ml = lock["manifest"]
    manifest_path = safe_child(root, ml["path"])
    if sha256(manifest_path) != ml["sha256"]:
        fail("toolchain.json does not match the locked Run7 manifest")
    manifest = load_json(manifest_path)
    for key in ("schema", "architectures", "llvm_commit", "minimum_ios"):
        if manifest.get(key) != ml.get(key):
            fail(f"toolchain.json field differs from lock: {key}")
    actual = manifest.get("artifacts", {})
    if set(actual) != set(ml["archives"]):
        fail("toolchain.json archive inventory differs from lock")
    for name, expected in ml["archives"].items():
        if actual.get(name) != expected:
            fail(f"toolchain.json archive record differs from lock: {name}")
        path = safe_child(root, name)
        if path.stat().st_size != expected["bytes"] or sha256(path) != expected["sha256"]:
            fail(f"archive differs from lock: {name}")
    rl = lock["enabled_link_report"]
    report_path = safe_child(root, rl["path"])
    if sha256(report_path) != rl["sha256"]:
        fail("enabled bridge report does not match the locked Run7 report")
    report = load_json(report_path)
    if report.get("check") != rl["check"] or report.get("llvm_commit") != ml["llvm_commit"]:
        fail("enabled bridge report identity differs from lock")
    if report.get("compiler_library_minimum_ios") != ml["minimum_ios"]:
        fail("enabled bridge report compiler minimum differs from manifest")
    if report.get("probe_minimum_ios") != rl["probe_minimum_ios"]:
        fail("enabled bridge report probe minimum differs from lock")
    results = report.get("results", [])
    if [item.get("architecture") for item in results] != rl["result_architectures"]:
        fail("enabled bridge report architecture sequence differs from lock")
    if [item.get("filetype") for item in results] != rl["result_filetypes"]:
        fail("enabled bridge report Mach-O file types differ from lock")
    if report.get("not_tested") != rl["not_tested"]:
        fail("enabled bridge report limitations differ from lock")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("lock", type=Path)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--root", type=Path)
    args = parser.parse_args()
    lock = load_json(args.lock)
    verify_lock_shape(lock)
    if args.metadata is not None:
        verify_metadata(lock, args.metadata)
    if args.archive is not None:
        verify_archive(lock, args.archive)
    if args.root is not None:
        if args.archive is None:
            fail("--root requires --archive")
        verify_extracted(lock, args.root)
    if args.metadata is None and args.archive is None:
        fail("at least one of --metadata or --archive is required")
    verified = []
    if args.metadata is not None:
        verified.append("GitHub metadata")
    if args.archive is not None:
        verified.append("ZIP")
    if args.root is not None:
        verified.extend(("manifest", "archives", "enabled-link report"))
    print("Locked Run7 " + ", ".join(verified) + " verified.")
    print("This is compile/link evidence only; runtime compiler verification remains absent.")

if __name__ == "__main__":
    main()
