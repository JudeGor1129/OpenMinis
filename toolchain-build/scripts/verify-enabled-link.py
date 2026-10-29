"""Read link-only probe headers; write a report, not a runtime success claim."""
import json
from pathlib import Path
import struct
import sys


def inspect(path, arch, expected_filetype):
    with path.open("rb") as file:
        data = file.read(32)
    if len(data) != 32:
        raise SystemExit("truncated Mach-O header: " + str(path))
    magic, cpu, subtype, filetype, _, _, _, _ = struct.unpack("<8I", data)
    expected_subtype = {"arm64": 0, "arm64e": 2}[arch]
    if (magic != 0xFEEDFACF or cpu != 0x0100000C or
            subtype & 0x00FFFFFF != expected_subtype or filetype != expected_filetype):
        raise SystemExit(f"wrong architecture/file type for {arch}: {path} "
                         f"magic={magic:#x} cpu={cpu:#x} subtype={subtype:#x} type={filetype}")
    return {"file": path.name, "architecture": arch,
            "cputype": f"0x{cpu:08x}", "cpusubtype": f"0x{subtype:08x}",
            "filetype": filetype}


def main(directory, manifest_path):
    directory = Path(directory)
    with Path(manifest_path).open(encoding="utf-8") as file:
        manifest = json.load(file)
    results = []
    for arch in ("arm64", "arm64e"):
        for name, filetype in ((f"bridge-{arch}.o", 1),
                               (f"enabled-link-{arch}", 2)):
            results.append(inspect(directory / name, arch, filetype))
    report = {
        "check": "enabled bridge compile and static link only",
        "llvm_commit": manifest["llvm_commit"],
        "compiler_library_minimum_ios": manifest["minimum_ios"],
        "probe_minimum_ios": "16.0",
        "results": results,
        "not_tested": ["execution of probes", "runCC1 source compilation",
                       "runLinker dylib generation", "PAC instructions or behavior",
                       "diagnostics and repeated jobs", "full Minis build",
                       "installation and iPhone runtime"],
    }
    with (directory / "enabled-link-report.json").open("w", encoding="utf-8") as file:
        json.dump(report, file, indent=2)
        file.write("\n")
    print("Enabled bridge objects and link-only executables match arm64 / arm64e.")
    print("This is not a runtime, PAC, installation or full Minis validation.")


if __name__ == "__main__":
    main(*sys.argv[1:])
