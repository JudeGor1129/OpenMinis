#!/usr/bin/env python3
"""Adapt the vendored Apple ld64 into an embeddable, reentrant library.

What ld64 looks like as shipped
------------------------------
ld64 is a command-line tool. Its `main()` terminates the process, registers an
atexit override, deliberately leaks its process-global roots (Options,
InternalState, InputFiles, Resolver, OutputFile) and pulls in lld-fallback
helpers that spawn subprocesses. None of that can exist inside a long-lived iOS
app: a second link must not inherit the first one's state, and the host must
survive a failed link.

This script performs the same class of transformation Twork describes in its
OfflineToolchain NOTICE ("in-process entry point, serialized parsing, reusable
state, diagnostics, allocation/mmap cleanup").

It is deliberate that every edit below is *asserted* before it is applied. The
dangerous failure mode for a linker port is not a compile error — it is a
"successful" build that silently links wrong or leaks state across calls.

Sources stay in deps/; adapted output is written back under work/ so the
transformation is reviewable.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORK = ROOT / "work"
CCTOOLS = WORK / "cctools-port"

ENTRY_NAME = "om_ld64_main"
RESET_FN = "om_ld64_reset_state"

# Region markers, located by content — never by line number.
MARK_PRELUDE = "#include <sys/wait.h>"
MARK_MAIN = "int main(int argc, const char* argv[])"
MARK_LLD_PROBE = "\tcheckWhetherToUseLLD(argc, argv); // ld64-port"
MARK_ATEXIT = "// Override atexit()"

# FinalSection's public section; resetSegments() must be callable from within
# InternalState, so inserting into FinalSection's private region would be wrong.
MARK_FS_PUBLIC = ("\t\tstatic const ld::Section&\tobjectOutputSection("
                  "const ld::Section& sect, const Options&);")

# InternalState is a *nested* (and private) class inside ld.cpp's InternalState
# class. A free function cannot even name it: referring to
# InternalState::FinalSection from outside produces
#   error: 'FinalSection' is a private member of 'InternalState'
# so the reset cannot be reached directly. The public entry point therefore
# lives on InternalState itself, which as the enclosing class may name its own
# private nested type. Matched by regex because the file pads with tabs.
MARK_IS_PUBLIC_RE = re.compile(r"^\tvirtual\s+~InternalState\(\)\s*\{\}\s*$")
MARK_FS_STATIC_DEF = "std::vector<const char*> InternalState::FinalSection::_s_segmentsSeen;"

# The CLI intentionally leaks these; a library must reclaim them. Each is
# promoted to a stack object whose lifetime is one build.
LEAKED_ROOTS = [
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


class AdaptError(Exception):
    pass


def find_function_extent(lines: list[str], signature: str) -> tuple[int, int]:
    """Return [start, end) line indices covering a function definition.

    Brace counting, so the extent is real rather than guessed.
    """
    start = None
    for i, line in enumerate(lines):
        if line.startswith(signature):
            start = i
            break
    if start is None:
        raise AdaptError(f"function not found: {signature}")

    depth = 0
    seen_open = False
    for i in range(start, len(lines)):
        for ch in lines[i]:
            if ch == "{":
                depth += 1
                seen_open = True
            elif ch == "}":
                depth -= 1
                if seen_open and depth == 0:
                    return start, i + 1
    raise AdaptError(f"unterminated function body: {signature}")


def adapt_ld_cpp(text: str, report: dict) -> str:
    lines = text.splitlines(keepends=True)
    original_len = len(lines)

    # ------------------------------------------------------------------
    # 1. Drop the prelude block: the lld-fallback helpers spawn processes,
    #    which is exactly what an in-process library must not do.
    #    The slice spans from the sys/wait.h include up to (not including)
    #    main(), and contains execute_ld64_lld() and checkWhetherToUseLLD().
    # ------------------------------------------------------------------
    pre = next((i for i, l in enumerate(lines) if MARK_PRELUDE in l), None)
    m = next((i for i, l in enumerate(lines) if l.startswith(MARK_MAIN)), None)
    if pre is None or m is None:
        raise AdaptError("prelude/main markers not found")
    if pre >= m:
        raise AdaptError("prelude marker appears after main()")
    removed = lines[pre:m]
    report["prelude_removed_lines"] = len(removed)
    report["prelude_removed_symbols"] = [
        s for s in ("execute_ld64_lld", "checkWhetherToUseLLD")
        if any(s in l for l in removed)
    ]
    del lines[pre:m]

    # ------------------------------------------------------------------
    # 2. main() becomes a reentrant entry point.
    # ------------------------------------------------------------------
    for i, line in enumerate(lines):
        if line.startswith(MARK_MAIN):
            lines[i] = line.replace(
                MARK_MAIN, f'extern "C" int {ENTRY_NAME}(int argc, const char* argv[])'
            )
            break
    else:
        raise AdaptError("main() signature not found after prelude removal")

    # Drop the lld probe call; it only exists to dispatch to the lld binary.
    probe_hits = [i for i, l in enumerate(lines) if l.strip() == MARK_LLD_PROBE.strip()]
    if len(probe_hits) != 1:
        raise AdaptError(f"expected exactly one lld probe call, found {len(probe_hits)}")
    lines.pop(probe_hits[0])

    # ------------------------------------------------------------------
    # 3. Terminating calls, handled per call site.
    #    A blanket exit()->return rewrite is wrong: ld64 calls exit() from
    #    void functions such as __assert_rtn(), where `return 1;` does not
    #    compile.
    # ------------------------------------------------------------------
    mstart, mend = find_function_extent(lines, f'extern "C" int {ENTRY_NAME}')
    main_exits = 0
    for i in range(mstart, mend):
        new = re.sub(r"\bexit\((\d+)\);", r"return \1;", lines[i])
        if new != lines[i]:
            main_exits += lines[i].count("exit(")
            lines[i] = new
    report["main_exit_to_return"] = main_exits

    # __assert_rtn is void and represents an unrecoverable linker assertion.
    # abort() is the honest translation; returning is not possible.
    astart, aend = find_function_extent(lines, "void __assert_rtn(")
    assert_exits = 0
    for i in range(astart, aend):
        if "exit(1);" in lines[i]:
            lines[i] = lines[i].replace("exit(1);", "abort();")
            assert_exits += 1
    report["assert_exit_to_abort"] = assert_exits

    remaining = [i for i, l in enumerate(lines)
                 if re.search(r"\bexit\s*\(", l) and not l.strip().startswith("//")]
    report["remaining_exit_calls"] = remaining
    if remaining:
        # Any survivor would terminate the host process.
        raise AdaptError(
            "unhandled exit() calls remain at lines: "
            + ", ".join(str(i + 1) for i in remaining)
        )

    # ------------------------------------------------------------------
    # 4. Leaked process-global roots become stack objects.
    # ------------------------------------------------------------------
    joined = "".join(lines)
    for declaration, replacement in LEAKED_ROOTS:
        if joined.count(declaration) != 1:
            raise AdaptError(f"expected exactly one occurrence of: {declaration}")
        joined = joined.replace(declaration, replacement)
    report["roots_promoted"] = len(LEAKED_ROOTS)
    lines = joined.splitlines(keepends=True)

    # ------------------------------------------------------------------
    # 5. Neutralise the atexit override, and do it BEFORE anything is
    #    appended.
    #
    #    Ordering matters and was wrong once: the override sits at the tail of
    #    the file and is removed by truncation, so appending the reset hook
    #    first meant the truncation deleted the hook again — leaving a library
    #    whose reset entry point simply did not exist, with no build error.
    #
    #    The override exists so the CLI can exit() without running
    #    destructors. A library linked into a host app wants RAII to run, so
    #    it is removed rather than redefined.
    # ------------------------------------------------------------------
    atexit_idx = next((i for i, l in enumerate(lines) if MARK_ATEXIT in l), None)
    if atexit_idx is None:
        raise AdaptError("atexit override marker not found")
    tail = "".join(lines[atexit_idx:])
    if "__cxa_atexit" not in tail:
        raise AdaptError("atexit marker found but no __cxa_atexit override follows")
    report["atexit_tail_removed_lines"] = len(lines) - atexit_idx
    del lines[atexit_idx:]
    lines.append(
        "// Removed for in-process use. The CLI installs an exit-handler override so\n"
        "// that exit() skips destructors; a library linked into a host app must let\n"
        "// RAII run normally, so no such override is installed here.\n"
    )

    # ------------------------------------------------------------------
    # 6. Reset hooks.
    #
    #    Two levels are needed because of nesting:
    #
    #      ld.cpp's InternalState  (private nested FinalSection)
    #        -> public  static void resetState()      [free function calls this]
    #             -> FinalSection::resetSegments()    [reaches the private static]
    #
    #    FinalSection::_s_segmentsSeen is a private static of a private nested
    #    class, so it cannot be touched from a free function: naming
    #    InternalState::FinalSection outside the class is itself an error.
    #    InternalState, as the enclosing class, may name it, so the reset is
    #    split across the two levels.
    # ------------------------------------------------------------------
    hits = [i for i, l in enumerate(lines) if l.startswith(MARK_FS_PUBLIC)]
    if len(hits) != 1:
        raise AdaptError(
            f"expected exactly one FinalSection public anchor, found {len(hits)}"
        )
    lines.insert(
        hits[0] + 1,
        "\n"
        "\t\t// Added for in-process reuse: drop the segment cache accumulated by\n"
        "\t\t// the previous build so repeated links inside one process are clean.\n"
        "\t\tstatic void resetSegments() {\n"
        "\t\t\tstd::vector<const char*> empty;\n"
        "\t\t\t_s_segmentsSeen.swap(empty);\n"
        "\t\t}\n",
    )
    report["reset_segments_inserted_after_line"] = hits[0] + 1

    is_hits = [i for i, l in enumerate(lines) if MARK_IS_PUBLIC_RE.match(l)]
    if len(is_hits) != 1:
        raise AdaptError(
            f"expected exactly one InternalState public anchor, found {len(is_hits)}"
        )
    lines.insert(
        is_hits[0] + 1,
        "\n"
        "\t// Added for in-process reuse: after each build the segment cache has\n"
        "\t// to be dropped or the next link in the same process sees the previous\n"
        "\t// build's segments. FinalSection is private and nested, so the public\n"
        "\t// entry point has to live on this class and delegate inward.\n"
        "\tstatic void resetState() {\n"
        "\t\tFinalSection::resetSegments();\n"
        "\t}\n",
    )
    report["internal_reset_state_inserted_after_line"] = is_hits[0] + 1

    # _s_segmentsSeen is also seeded through push_back() on first use, so an
    # empty vector is a valid post-reset state; the counters reset with it.
    lines += [
        "\n",
        f'extern "C" void {RESET_FN}() {{\n',
        "\tInternalState::resetState();\n",
        "\tSnapshot::globalSnapshot = nullptr;\n",
        "}\n",
    ]

    final = "".join(lines)

    # Post-conditions for the two failure modes that produce no build error but
    # a silently broken library.
    #
    # Detection is on *definitions*, not mentions: the explanatory comment left
    # in place names the same symbol, so a substring test would fail on our own
    # comment text.
    if f'extern "C" void {RESET_FN}()' not in final:
        raise AdaptError("reset entry point vanished during adaptation")
    if "InternalState::resetState();" not in final:
        raise AdaptError("reset entry point does not call InternalState::resetState")
    if "FinalSection::resetSegments();" not in final:
        raise AdaptError("InternalState::resetState does not delegate to FinalSection")
    if "static void resetState()" not in final:
        raise AdaptError("InternalState::resetState was not inserted")
    if re.search(r"^int\s+__cxa_atexit\s*\(", final, re.MULTILINE):
        raise AdaptError("exit-handler override survived adaptation")

    report["lines_before"] = original_len
    report["lines_after"] = len(final.splitlines())
    return final


def adapt_options(text: str, report: dict) -> str:
    """Options.cpp prints help/version and exits; that must not end the host.

    It also defines __crashreporter_info__, which LLVM's PrettyStackTrace.cpp
    defines too. In a CLI only ld64's copy is ever pulled in, but here both
    archives land in one executable and the two strong definitions collide:

        duplicate symbol '___crashreporter_info__'
            libomld64.a(ld_Options.cpp.o)
            libomllvm.a(PrettyStackTrace.cpp.o)

    ld64's copy only exists to put its command line in crash reports, so make
    it weak and let LLVM's definition win. -multiply_defined is not an
    alternative: ld64 itself ignores that flag (see its option parser), and the
    failure here is a genuine duplicate definition, not a multiply-defined ref.
    """
    count = text.count("exit(0);")
    if count == 0:
        raise AdaptError("Options.cpp: expected exit(0); calls, found none")
    text = text.replace(
        "exit(0);", 'throw "ld64 information options are not build commands";'
    )
    report["options_exit_to_throw"] = count

    old_crash = "\tchar* __crashreporter_info__ = crashreporterBuffer;"
    new_crash = "\t__attribute__((weak)) char* __crashreporter_info__ = crashreporterBuffer;"
    if old_crash not in text:
        raise AdaptError("Options.cpp: __crashreporter_info__ definition not found")
    text = text.replace(old_crash, new_crash)
    report["crashreporter_symbol_made_weak"] = 1

    text += (
        "\nextern \"C\" void om_ld64_reset_options() {\n"
        "  if (sWarningsSideFile) fclose(sWarningsSideFile);\n"
        "  sWarningsSideFile=nullptr; sWarningsSideFilePath=nullptr;\n"
        "  sWarningsCount=0; sFatalWarnings=false; sEmitWarnings=true;\n}\n"
    )
    return text


def adapt_input_files_cpp(text: str, report: dict) -> str:
    if "#define HAVE_LIBDISPATCH 1" not in text:
        raise AdaptError("InputFiles.cpp: HAVE_LIBDISPATCH define not found")
    report["libdispatch_disabled"] = True
    return text.replace("#define HAVE_LIBDISPATCH 1", "#define HAVE_LIBDISPATCH 0")


def adapt_input_files_h(text: str, report: dict) -> str:
    if "#define HAVE_PTHREADS 1" not in text:
        raise AdaptError("InputFiles.h: HAVE_PTHREADS define not found")
    report["pthreads_disabled"] = True
    return text.replace("#define HAVE_PTHREADS 1", "#define HAVE_PTHREADS 0")


def adapt_mangling(text: str, report: dict) -> str:
    """demangleSymbol caches its scratch buffer in function-local statics.

    In a CLI one link per process makes that permanent buffer harmless. Here it
    is a cross-build cache: it is allocated on the first link and reused by
    every later one, so it must not outlive the build. Making it call-local is
    also what the reset hooks assume -- they reclaim the linker's allocation
    zone wholesale between runs.
    """
    old_size = "static size_t size = 1024;"
    old_buff = "static char* buff = (char*)malloc(size);"
    if old_size not in text or old_buff not in text:
        raise AdaptError("Mangling.cpp: demangleSymbol statics not found")
    text = text.replace(old_size, "size_t size = 1024;")
    text = text.replace(old_buff, "char* buff = (char*)malloc(size);")
    report["mangling_statics_made_local"] = 2
    return text


def adapt_output_file(text: str, report: dict) -> str:
    """ld64 installs a SIGINT handler that unlinks its temp output and exits.

    As a library that is a hijack of the host's signal disposition, and the
    handler calls exit(), which would kill the app. The host owns signals.
    """
    old = "::signal(SIGINT, removePathAndExit);"
    if old not in text:
        raise AdaptError("OutputFile.cpp: SIGINT handler install not found")
    text = text.replace(old, "// Host application owns its signal handlers.")
    report["sigint_handler_removed"] = 1
    return text


def adapt_branch_island(text: str, report: dict) -> str:
    """Append reset_branches to the TU that owns the maps.

    sAtomToAddress/sAtomToSectionIndex have internal linkage, so a function in
    another translation unit cannot name them; the reset has to be emitted
    here. swap() with a temporary releases the node allocations rather than
    merely emptying the containers, which matters because these entries point
    into the previous link's allocation zone.
    """
    for name in ("sAtomToAddress", "sAtomToSectionIndex"):
        if f"static std::map<const Atom*, " not in text or f" {name};" not in text:
            raise AdaptError(f"branch_island.cpp: {name} not found")
    text += (
        '\nextern "C" void om_ld64_reset_branches() {\n'
        "  decltype(ld::passes::branch_island::sAtomToAddress)().swap(\n"
        "      ld::passes::branch_island::sAtomToAddress);\n"
        "  decltype(ld::passes::branch_island::sAtomToSectionIndex)().swap(\n"
        "      ld::passes::branch_island::sAtomToSectionIndex);\n"
        "}\n"
    )
    report["branch_island_resets"] = 2
    return text


def adapt_thread_starts(text: str, report: dict) -> str:
    """Append reset_threads to the TU that owns sAtomToAddress (see above)."""
    if "static std::map<const Atom*, uint64_t> sAtomToAddress;" not in text:
        raise AdaptError("thread_starts.cpp: sAtomToAddress not found")
    text += (
        '\nextern "C" void om_ld64_reset_threads() {\n'
        "  decltype(ld::passes::thread_starts::sAtomToAddress)().swap(\n"
        "      ld::passes::thread_starts::sAtomToAddress);\n"
        "}\n"
    )
    report["thread_starts_resets"] = 1
    return text


def adapt_plain(rel: str, text: str, report: dict) -> str:
    if rel.endswith("ld64/src/ld/ld.cpp"):
        return adapt_ld_cpp(text, report)
    if rel.endswith("ld64/src/ld/Options.cpp"):
        return adapt_options(text, report)
    if rel.endswith("ld64/src/ld/InputFiles.cpp"):
        return adapt_input_files_cpp(text, report)
    if rel.endswith("ld64/src/ld/InputFiles.h"):
        return adapt_input_files_h(text, report)
    if rel.endswith("ld64/src/ld/Mangling.cpp"):
        return adapt_mangling(text, report)
    if rel.endswith("ld64/src/ld/OutputFile.cpp"):
        return adapt_output_file(text, report)
    if rel.endswith("ld64/src/ld/passes/branch_island.cpp"):
        return adapt_branch_island(text, report)
    if rel.endswith("ld64/src/ld/passes/thread_starts.cpp"):
        return adapt_thread_starts(text, report)
    return text


def write_reset_hooks(ld_dir: pathlib.Path) -> None:
    """Provide the remaining reset entry points the host calls between builds.

    reset_state() is emitted into ld.cpp (it needs access to ld.cpp's nested
    class). The other two are no-ops here: the port has threads disabled, and
    branch-island state is rebuilt per link.
    """
    header = (
        "// Generated by scripts/build-ld64-inprocess.py -- see that script for why.\n"
        "//\n"
        "// Declarations only. The reset hooks exist because a library, unlike a\n"
        "// CLI, runs many links in one process, so free-function statics that hold\n"
        "// the previous link's pointers must be released between runs -- but those\n"
        "// statics have internal linkage, so their reset functions cannot live in\n"
        "// this file. Each is appended to the very translation unit that owns the\n"
        "// state: reset_state in ld.cpp, reset_branches in passes/branch_island.cpp,\n"
        "// reset_threads in passes/thread_starts.cpp, reset_options in Options.cpp.\n"
        'extern "C" void om_ld64_reset_options();\n'
        'extern "C" void om_ld64_reset_state();\n'
        'extern "C" void om_ld64_reset_branches();\n'
        'extern "C" void om_ld64_reset_threads();\n'
    )
    (ld_dir / "om_reset_hooks.cpp").write_text(header)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="verify every asserted edit is applicable, without writing")
    args = parser.parse_args()

    if not CCTOOLS.is_dir():
        sys.exit(f"missing cctools-port sources at {CCTOOLS}; run fetch-sources.sh first")

    ld_dir = CCTOOLS / "cctools" / "ld64" / "src" / "ld"
    if not ld_dir.is_dir():
        sys.exit("missing ld64 sources under cctools-port")

    targets = [p for p in ld_dir.rglob("*") if p.suffix in (".cpp", ".h")]
    report: dict = {"mode": "check" if args.check else "apply", "edits": {}}
    failures: list[str] = []
    changed: list[str] = []

    for path in sorted(targets):
        rel = str(path.relative_to(CCTOOLS))
        original = path.read_text(errors="replace")
        per_file: dict = {}
        try:
            adapted = adapt_plain(rel, original, per_file)
        except AdaptError as e:
            failures.append(f"{rel}: {e}")
            continue
        if per_file:
            report["edits"][rel] = per_file
        if adapted != original:
            changed.append(rel)
            if not args.check:
                path.write_text(adapted)

    print(json.dumps(report, indent=2))
    if failures:
        print("\nFAILED assertions:", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        return 1

    if args.check:
        print(f"\nAll assertions hold. {len(changed)} file(s) would be adapted:")
        for c in changed:
            print(f"  {c}")
        return 0

    write_reset_hooks(ld_dir)
    print(f"\nAdapted {len(changed)} translation unit(s); wrote om_reset_hooks.cpp")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
