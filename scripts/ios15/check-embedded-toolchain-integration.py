#!/usr/bin/env python3
"""Source-policy gate for the linked-but-runtime-disabled toolchain build."""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def text(relative):
    return (ROOT / relative).read_text(encoding="utf-8")

def require(condition, message):
    if not condition:
        raise SystemExit("embedded toolchain integration check failed: " + message)

build = text("scripts/ios15/build-diagnostics.sh")
package = text("scripts/ios15/package-trollstore.sh")
prepare = text("scripts/ios15/prepare-embedded-toolchain.sh")
provider = text("src/ios/Agent/Build/EmbeddedToolchainBuildProvider.swift")
theos_executor = text("src/ios/Agent/Build/EmbeddedTheosExecutor.swift")
adapter = text("src/ios/Agent/Build/EmbeddedToolchainExecutionAdapter.swift")
theos_plan = text("src/ios/Agent/Build/EmbeddedTheosCompilePlan.swift")
theos_snapshot = text("src/ios/Agent/Build/EmbeddedToolchainProjectSnapshot.swift")
ld64_adapter = text("toolchain-build/scripts/build-ld64-inprocess.py")
project = text("src/ios/Minis.xcodeproj/project.pbxproj")
lock_path = ROOT / "toolchain-build/verified-toolchain-lock.json"
evidence_path = ROOT / "toolchain-build/runtime-validation-evidence.json"
lock = json.loads(lock_path.read_text(encoding="utf-8"))
require(evidence_path.is_file(), "reviewed fixed-runtime evidence record is missing")
verification = subprocess.run(
    [sys.executable, str(ROOT / "scripts/ios15/verify-embedded-toolchain-runtime-evidence.py"),
     str(evidence_path), str(lock_path)],
    capture_output=True, text=True, check=False)
require(verification.returncode == 0,
        "fixed-runtime evidence does not match the pinned toolchain: " +
        (verification.stderr or verification.stdout).strip())
require(project.count('LIBRARY_SEARCH_PATHS = "$(SRCROOT)/../../deps/libs";') == 2,
        "expected exactly two main-App library search path anchors")
require(project.count('"-lfakefs",') == 2,
        "expected exactly two main-App linker-list anchors")
require(project.count('OTHER_SWIFT_FLAGS = "";') == 2,
        "expected exactly two main-App C++ flag anchors")
for value in ('embedded-toolchain/libomllvm-arm64.a', 'embedded-toolchain/libomld64.a',
              '"-lz"', '"-DOM_TOOLCHAIN_ENABLED=1"',
              "dev-headers/arm64/include", "ARCHS=arm64"):
    require(value in build, f"missing App build setting: {value}")
require("libomllvm-arm64e.a" not in build, "arm64 App must not link the arm64e LLVM archive")
require("OM_TOOLCHAIN_VERIFIED=1" in build, "evidence-validated App must expose the runtime-verification bit")
require("verify-embedded-toolchain-runtime-evidence.py" in build and
        "runtime-validation-evidence.json" in build,
        "verification bit must be bound to the reviewed runtime evidence record")
require("OM_TOOLCHAIN_VERIFIED" not in project,
        "committed Xcode project must not globally enable runtime verification")
require("mapfile" not in prepare, "prepare script must remain compatible with macOS Bash 3.2")
require("--metadata" in prepare, "GitHub artifact metadata must be checked before download")
require("verify-bundled-clang-resource.py" in build,
        "built App must verify the full locked Clang resource inventory")
require("verify-bundled-clang-resource.py" in package,
        "TrollStore staging must reverify the full Clang resource inventory")
require("actions/artifacts/$ARTIFACT_ID/zip" in prepare, "prepare script must download the locked artifact ID")
require("verify-artifacts.sh" in prepare, "prepare script must rerun manifest and slice checks")
require("-verify_arch arm64 arm64e" in prepare, "universal ld64 slices must be rechecked")
require("OM_TOOLCHAIN_VERIFIED remains intentionally unset" in prepare,
        "prepare script must state that runtime verification is absent")
require("EmbeddedToolchainTweakManifest" in provider and
        "completedWithArtifacts" in provider and
        "publishRootlessDeb" in provider,
        "embedded provider must be manifest-gated and return verified DEB evidence")
require("state: .unavailable" in provider, "unready native capability must remain unavailable")
require("enum EmbeddedToolchainOperation" in provider and
        "func validationError(root: URL) -> String?" in provider,
        "structured embedded operations must have a path/argument validation seam")
require("isArm64Object(at:" in provider and "containsSymlinkComponent" in provider and
        "maxObjectCount" in provider and "maxTotalObjectBytes" in provider and
        "typeRegular" in provider and "@rpath/" in provider,
        "structured adapter policy must check Mach-O, symlinks, bounds and install names")
require("EmbeddedTheosMaterializedHeader" in theos_plan and
        "let entitlements: Data?" in theos_plan,
        "Theos compile plans must bind headers and canonical entitlements")
require("loadDeclaredTheosFiles" in theos_snapshot and
        "O_NOFOLLOW" in theos_snapshot,
        "Theos inputs must be read through bounded nofollow snapshot APIs")
require("snapshot hash mismatch" in theos_executor and
        "projectRoot.path" not in theos_executor,
        "Theos executor must compile only verified private snapshots")
require("context.executor" not in provider,
        "embedded provider must not invoke the shell executor")
require('"-adhoc_codesign"' in theos_executor and
        '"-adhoc_codesign_entitlements"' in theos_executor and
        "EmbeddedCodeSignature.verify" in theos_executor,
        "embedded Theos executor must request and independently verify ad-hoc signatures")
require("expectedEntitlements" in adapter and "entitlements special-slot hash mismatch" in adapter and
        "codeSlotMismatch" in adapter,
        "ad-hoc verification must cover code pages and entitlement special slots")
require("adapt_options_h" in ld64_adapter and "adapt_linkedit_h" in ld64_adapter and
        "CSSLOT_ENTITLEMENTS" in ld64_adapter and "O_NOFOLLOW" in ld64_adapter,
        "ld64 adaptation must embed bounded, nofollow entitlement blobs")
require("i + 1 >= argc" in ld64_adapter,
        "entitlements linker option must reject a missing path before argv increment")
require(lock.get("schema") == 1, "lock schema must be 1")
# The lock must describe exactly one artifact, and that artifact's name must
# identify the commit it was built from. Binding it this way catches a pin that
# points at the wrong run without hardcoding an id that every intentional
# re-pin would have to edit.
require(type(lock.get("artifact", {}).get("id")) is int and lock["artifact"]["id"] > 0,
        "lock must pin one concrete artifact id")
require(lock["artifact"].get("name") == "OpenMinis-iOS-toolchain-" + lock.get("head_sha", ""),
        "locked artifact name must identify the locked commit")
require(lock.get("manifest", {}).get("architectures") == ["arm64", "arm64e"],
        "lock must preserve both verified architectures")
require(set(lock.get("manifest", {}).get("archives", {})) == {
    "libomllvm-arm64.a", "libomllvm-arm64e.a", "libomld64.a"
}, "lock archive inventory differs from the locked toolchain")
require(lock.get("enabled_link_report", {}).get("result_architectures") ==
        ["arm64", "arm64", "arm64e", "arm64e"],
        "locked enabled-link report must cover both object and executable architectures")
print("PASS: policy binds the disposable arm64 validation App to the locked kit and fixed-runtime evidence.")
print("PASS: OM_TOOLCHAIN_VERIFIED is validation-only; committed Xcode target and BuildProvider remain locked.")
