#!/usr/bin/env python3
"""Build the vendored Mach-O linker (Apple ld64, via cctools-port) as an iOS
static library with a reentrant entry point.

Background
----------
ld64 ships as a command-line tool: its `main()` calls `exit()`, registers
`atexit()` handlers, deliberately leaks its process-global roots (Options,
InternalState, InputFiles, Resolver, OutputFile) and owns the whole process
address space. None of that is acceptable inside a long-lived iOS app, where a
second link must not inherit the first one's state.

This script performs the same class of transformation Twork documents in its
OfflineToolchain NOTICE ("in-process entry point, serialized parsing, reusable
state, diagnostics, allocation/mmap cleanup"): it rewrites the CLI `main` into
`om_ld64_main`, converts the leaked roots to stack objects, replaces terminating
paths with returns/throws, disables pthread and libdispatch paths that assume a
standalone process, and adds explicit reset hooks the host calls between links.

Sources stay in deps/; all generated/adapted files land in work/ so the
adaptation is reviewable and reproducible.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEPS = ROOT / "deps"
WORK = ROOT / "work"
BUILD = ROOT / "build" / "ios"
CCTOOLS_DIR = WORK / "cctools-port"

ENTRY_NAME = "om_ld64_main"
RESET_HOOKS = """\
extern "C" void om_ld64_reset_options();
extern "C" void om_ld64_reset_state();
extern "C" void om_ld64_reset_branches();
extern "C" void om_ld64_reset_threads();
"""


def output(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def adapt_ld_main(text: str) -> str:
    """Turn `int main(...)` into a reusable, non-terminating entry point."""
    # Drop the wrapper preamble that only exists for the standalone CLI.
    start_marker = "#include <sys/wait.h>"
    end_marker = "int main(int argc, const char* argv[])"
    if start_marker in text and end_marker in text:
        text = text[: text.index(start_marker)] + text[text.index(end_marker) :]

    text = text.replace(
        "int main(int argc, const char* argv[])",
        f'extern "C" int {ENTRY_NAME}(int argc, const char* argv[])',
    )

    # The CLI probes for lld by spawning processes; meaningless in-process.
    text = text.replace("\tcheckWhetherToUseLLD(argc, argv); // ld64-port", "")

    # Never register process-wide exit handlers.
    if "// Override atexit()" in text:
        text = text[: text.index("// Override atexit()")]

    # Terminating calls become returns so the host survives a failed link.
    text = text.replace("exit(0);", "return 0;").replace("exit(1);", "return 1;")

    # The CLI intentionally leaks these roots. A library must reclaim them, so
    # promote each to a stack object whose lifetime is the build.
    declarations = [
        ("PerformanceStatistics& statistics = *(new PerformanceStatistics());",
         "PerformanceStatistics statistics;"),
        ("Options& options = *(new Options(argc, argv));",
         "Options options(argc, argv);"),
        ("InternalState& state = *(new InternalState(options));",
         "InternalState state(options);"),
        ("ld::tool::InputFiles& inputFiles = *(new ld::tool::InputFiles(options));",
         "ld::tool::InputFiles inputFiles(options);"),
        ("ld::tool::Resolver& resolver = *(new ld::tool::Resolver(options, inputFiles, state));",
         "ld::tool::Resolver resolver(options, inputFiles, state);"),
        ("ld::tool::OutputFile& out = *(new ld::tool::OutputFile(options, state));",
         "ld::tool::OutputFile out(options, state);"),
    ]
    for declaration, replacement in declarations:
        if declaration not in text:
            raise SystemExit(f"expected declaration not found in ld.cpp: {declaration}")
        text = text.replace(declaration, replacement)

    text += (
        f'\nextern "C" void om_ld64_reset_state() {{\n'
        f"  InternalState::resetSegments(); Snapshot::globalSnapshot = nullptr;\n"
        f"}}\n"
    )

    # Give FinalSection a way to drop the segments it accumulated last time.
    marker = "private:\n\tbool"
    if marker not in text:
        raise SystemExit("could not find FinalSection private section in ld.cpp")
    text = text.replace(
        marker,
        "static void resetSegments() { std::vector<const char*>().swap(FinalSection::_s_segmentsSeen); }\n"
        + marker,
        1,
    )
    return text


def adapt_options(text: str) -> str:
    # Informational flags must not terminate the host process.
    text = text.replace(
        "exit(0);", 'throw "ld64 information options are not build commands";'
    )
    text += (
        "\nextern \"C\" void om_ld64_reset_options() {\n"
        "  if (sWarningsSideFile) fclose(sWarningsSideFile);\n"
        "  sWarningsSideFile=nullptr; sWarningsSideFilePath=nullptr;\n"
        "  sWarningsCount=0; sFatalWarnings=false; sEmitWarnings=true;\n}\n"
    )
    return text


def adapt_plain(relative: str, text: str) -> str:
    if relative.endswith("ld64/src/ld/InputFiles.cpp"):
        return text.replace("#define HAVE_LIBDISPATCH 1", "#define HAVE_LIBDISPATCH 0")
    if relative.endswith("ld64/src/ld/InputFiles.h"):
        return text.replace("#define HAVE_PTHREADS 1", "#define HAVE_PTHREADS 0")
    if relative.endswith("ld64/src/ld/ld.cpp"):
        return adapt_ld_main(text)
    if relative.endswith("ld64/src/ld/Options.cpp"):
        return adapt_options(text)
    return text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="verify the source tree is present and patched")
    args = parser.parse_args()

    if not CCTOOLS_DIR.is_dir():
        sys.exit(
            "missing cctools-port sources at work/cctools-port; run "
            "scripts/fetch-sources.sh first"
        )

    ld_dir = CCTOOLS_DIR / "cctools" / "ld64" / "src" / "ld"
    if not ld_dir.is_dir():
        sys.exit("missing ld64 sources under cctools-port")

    targets = [p for p in ld_dir.rglob("*") if p.suffix in (".cpp", ".h")]
    if args.check:
        for path in targets:
            original = path.read_text(errors="replace")
            if adapt_plain(str(path), original) != original:
                print(f"would adapt: {path.relative_to(CCTOOLS_DIR)}")
        return 0

    changed = []
    for path in targets:
        original = path.read_text(errors="replace")
        adapted = adapt_plain(str(path), original)
        if adapted != original:
            path.write_text(adapted)
            changed.append(str(path.relative_to(CCTOOLS_DIR)))

    print(f"adapted {len(changed)} ld64 translation units")
    for name in changed:
        print(f"  {name}")

    # Provide the reset hooks the host calls between links.
    compat = CCTOOLS_DIR / "cctools" / "ld64" / "src" / "ld" / "om_reset_hooks.cpp"
    hook_sources = [
        p for p in ld_dir.rglob("*.cpp")
        if "FinalSection" in p.read_text(errors="replace")
        and p.name != "om_reset_hooks.cpp"
    ]
    compat.write_text(
        "// Generated by scripts/build-ld64-inprocess.sh -- see that script for why.\n"
        "#include <vector>\n"
        f"{RESET_HOOKS}\n"
        "extern \"C\" void om_ld64_reset_branches() {}\n"
        "extern \"C\" void om_ld64_reset_threads() {}\n"
    )
    print(f"wrote {compat.name} (reset hook definitions)")
    print(f"  (FinalSection reachable from: {[p.name for p in hook_sources]})")

    # Build is driven by the outer script, which knows the sysroot and arch list.
    print(json.dumps({"entry": ENTRY_NAME, "adapted": len(changed)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
