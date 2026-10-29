"""Read plutil's JSON output; check the existing Minis main target wiring."""
import json
from pathlib import Path
import sys

project_json, repository = sys.argv[1:]
with open(project_json, encoding="utf-8") as file:
    objects = json.load(file)["objects"]
root = Path(repository)


def require(condition, message):
    if not condition:
        raise SystemExit("registration check failed: " + message)


targets = [value for value in objects.values()
           if value.get("isa") == "PBXNativeTarget" and value.get("name") == "Minis"]
require(len(targets) == 1, "expected exactly one Minis main target")
phases = [objects[key] for key in targets[0]["buildPhases"]]
source_files = []
resource_files = []
framework_files = []
for phase in phases:
    files = [objects[objects[key]["fileRef"]]
             for key in phase.get("files", []) if "fileRef" in objects[key]]
    kind = phase["isa"]
    if kind == "PBXSourcesBuildPhase":
        source_files += files
    elif kind == "PBXResourcesBuildPhase":
        resource_files += files
    elif kind == "PBXFrameworksBuildPhase":
        framework_files += files

require(sum(file.get("path") == "OMToolchain.mm" for file in source_files) == 1,
        "bridge implementation must occur once in main Sources")
require(not any(file.get("path") == "OMVerifyToolchain.mm" for file in source_files),
        "standalone LLVM validation harness must not enter production Sources")
resources = [file for file in resource_files if file.get("path") == "clang-resource"]
require(len(resources) == 1 and resources[0].get("lastKnownFileType") == "folder",
        "resource folder reference must preserve include/ layout")
require(not any("libomllvm" in file.get("path", "") or "libomld64" in file.get("path", "")
                for file in framework_files), "disabled stage must not link compiler archives")
for header in ("stddef.h", "stdarg.h", "stdint.h", "ptrauth.h", "arm_neon.h"):
    require((root / "src/ios/Vendor/OMToolchain/clang-resource/include" / header).is_file(),
            "builtin header missing: " + header)
bridging = (root / "src/ios/MinisApp-Bridging-Header.h").read_text(encoding="utf-8")
require('#import "Vendor/OMToolchain/OMToolchain.h"' in bridging,
        "main Swift bridging header import")
print("Minis disabled-bridge registration check passed.")
