#!/usr/bin/env python3
"""Source-policy gate for the linked-but-runtime-disabled toolchain build."""
import json
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
project = text("src/ios/Minis.xcodeproj/project.pbxproj")
lock = json.loads(text("toolchain-build/verified-toolchain-lock.json"))
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
require("-DOM_TOOLCHAIN_VERIFIED" not in build, "runtime verification macro must remain unset")
require("OM_TOOLCHAIN_VERIFIED" not in project, "committed Xcode settings must not define runtime verification")
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
require(provider.count(".unavailable(await availability(for: context))") == 2,
        "build and test must both remain unavailable")
require("state: .unavailable" in provider, "availability must remain unavailable")
require(lock.get("schema") == 1, "lock schema must be 1")
require(lock.get("artifact", {}).get("id") == 12965155835, "unexpected Run7 artifact ID")
require(lock.get("manifest", {}).get("architectures") == ["arm64", "arm64e"],
        "lock must preserve both verified architectures")
require(set(lock.get("manifest", {}).get("archives", {})) == {
    "libomllvm-arm64.a", "libomllvm-arm64e.a", "libomld64.a"
}, "lock archive inventory differs from Run7")
require(lock.get("enabled_link_report", {}).get("result_architectures") ==
        ["arm64", "arm64", "arm64e", "arm64e"],
        "locked enabled-link report must cover both object and executable architectures")
print("PASS: source policy binds the future arm64 App validation build to exact Run7 archive paths.")
print("PASS: no link ran here; OM_TOOLCHAIN_VERIFIED is unset and the Provider remains unavailable.")
