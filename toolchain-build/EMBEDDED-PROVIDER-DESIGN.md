# EmbeddedToolchainBuildProvider safety design

Status: validation-only execution seam implemented. Generic `EmbeddedToolchainBuildProvider.build/test` remains unavailable; no user-project detector, external input or artifact publication is connected. The new adapter still requires Swift contracts, a full App build, review and its own device validation.

## Why the current fixed-fixture gate is insufficient

Run 203 proves a bounded, fixed C/Objective-C/Foundation fixture suite on the device:

- arm64 and arm64e CC1 object generation;
- arm64 and arm64e dylib generation with the real `libSystem.B.tbd`;
- Foundation SDK header compilation;
- expected failure and recovery;
- three repeated compile/link rounds;
- temporary-output cleanup and bounded resident-memory samples.

It does **not** prove that an arbitrary project command, Makefile, Xcode project,
Swift package, dependency graph, or user-supplied linker argument is safe to run
inside the app. The current provider therefore remains a read-only unavailable
provider even when `OM_TOOLCHAIN_VERIFIED=1` is present in the disposable
validation App.

## Proposed execution seam

Do not pass `BuildRequest.command` to the embedded provider. A shell command is
not an in-process toolchain API. Add a separate structured request, for example:

```swift
enum EmbeddedOperation: Sendable {
    case compile(source: String, language: EmbeddedLanguage, output: String)
    case link(objects: [String], output: String, installName: String)
}
```

The provider must reject a generic project request unless a trusted detector has
converted it into this operation list. The first supported project class should
be a bounded C/Objective-C fixture/project only; Swift, Xcode build graphs,
Makefiles, Theos, Cargo, Gradle, npm and arbitrary custom commands remain
unavailable and are routed to their existing providers.

## Required safety rules

1. **No shell or subprocesses.** The provider may call only the typed
   `OMToolchain.runCC1` and `OMToolchain.runLinker` bridge methods. It must never
   call `context.executor`, `system`, `popen`, `posix_spawn`, `dlopen`, or a
   standalone compiler/linker.
2. **Project-root confinement.** Canonicalize the project root and every source,
   header, object and output path. Reject symlinks, `..` escapes, absolute paths
   outside the root, and paths inside the app bundle or system directories.
3. **Allowlisted languages and flags.** Derive language from the file extension;
   do not accept raw `-cc1` or ld64 argv arrays. The adapter owns the target,
   minimum iOS, SDK, resource directory, `-fobjc-runtime`, ARC, PAC and linker
   flags. User input may select only approved source/output paths and an install
   name under a safe prefix.
4. **Input limits.** Bound source count, source bytes, include depth, object bytes,
   operation count and output size. Reject generated or recursive dependency
   graphs until a deterministic dependency scanner exists.
5. **Link policy.** Always add the verified SDK `libSystem.B.tbd`; require a dylib
   input for dylib output; reject unresolved symbols, `-undefined`, dynamic lookup,
   custom loaders, executable output without a verified `main`, and arbitrary
   load-command flags. Inspect Mach-O type, architecture and size before exposing
   an output.
6. **Atomic outputs.** Write only under a per-run temporary directory, inspect the
   result, then atomically move it into the caller-approved output path. On any
   diagnostic remove all temporary objects and outputs.
7. **Serialization and cancellation.** Keep the existing single linker/LLVM queue.
   Cancellation is checked between compile/link operations; an in-flight CC1/ld64
   call is not interrupted with signal handlers or `longjmp`. A cancelled run
   cleans its temporary directory and returns unavailable/cancelled, never a
   partial success.
8. **Failure poisoning.** Status 70/internal assertion, unexpected exception,
   malformed output or failed cleanup permanently poisons the provider instance
   until app restart. Do not reset and continue after skipped C++ destructors.
9. **Resource and memory limits.** Sample resident size before/after each
   operation, cap repeated links, and stop before a configured budget. Report the
   peak and delta in the structured build result.
10. **Artifact verification.** Use the existing artifact verifier after the final
    output. A non-zero tool status, failed structural check or missing cleanup
    must never become `BuildState.success`.

## Availability and release policy

`OM_TOOLCHAIN_VERIFIED=1` means only that the pinned archives, enabled bridge and
reviewed fixed-runtime evidence passed for the validation build. It does not by
itself make the generic BuildProvider executable. Provider availability should
remain `.unavailable` with `in-process BuildProvider execution adapter` in
`missingConfiguration` until the typed operation seam above exists.

The adapter implementation must add:

- fake-bridge unit tests for argument construction, path confinement, cancellation
  and poisoning;
- an integration fixture covering compile -> link -> inspect -> cleanup;
- negative tests for shell strings, symlinks, escaped paths, unsupported language,
  missing libSystem input, unresolved symbols and output-type mismatch;
- a device run proving one successful request, one expected failure/recovery and
  cancellation without an app crash;
- a release gate proving BuildProvider still cannot execute arbitrary project
  commands.

## Implemented first phase (validation only)

`EmbeddedToolchainExecutionAdapter.execute(sources:operations:cancellation:)`
accepts immutable in-memory text and typed operations, not a caller filesystem
root. Inputs and outputs use fresh flat allowlisted names in a private 0700
per-request directory. Link inputs must have been compiled and hashed earlier
in that same request. No external `.o`, user path or generic command is accepted.

- At most 4 ASCII sources of 128 KiB each, 6 operations, one link per request.
- C and Objective-C front ends only, target arm64/iOS15, freestanding C11; no
  project/SDK headers. Preprocessing spellings, backslash continuations,
  trigraphs/digraphs, inline assembly, pragmas and module imports are rejected.
  This deliberately restrictive subset is **not a sandbox for arbitrary C**.
- Library input is a bounded snapshot of SDK16.5 `libSystem.B.tbd`, checked
  against SHA-256 `1ab02266a39491a8bd5a91ba36d5c8c8c6ac6efb92099e1091a1fd2370fc53e3`.
- Production uses one lifetime singleton. At most 3 adapter link attempts;
  admissions stop at sampled RSS >=384 MiB or cumulative growth >=64 MiB.
  Sampling cannot interrupt or enforce an in-flight LLVM/ld64 allocation limit.
- Cancellation is cooperative between operations (including Swift Task
  cancellation); no signals, longjmp or skipped destructors.
- Internal/unknown bridge status, unsafe/missing/malformed output, unexpected
  I/O and failed cleanup poison the adapter. Ordinary diagnostics can recover.
- Outputs undergo thin-arm64 Mach-O type/range/dependency checks and SHA-256.
  Only inspection metadata is returned: all run files are removed, no output
  is published, loaded, executed, signed or installed. Failures/cancellation
  discard even intermediate artifact metadata.

The separate settings entry `运行受限适配器验证` runs a successful two-source
compile/link, expected compiler and unresolved-symbol linker failures, recovery,
and pre-cancellation. It consumes the three-link process budget; restart the App
and run once, without running the old fixture suite first. Its JSON is new
adapter evidence, not an authorization to open generic project builds.

`check-embedded-adapter.sh --require-swift` compiles the actual Swift adapter and
model with a fake bridge and runs behavioural contracts before costly App
dependencies. A machine without `swiftc` may run source policy, but reports the
behavioural tests as SKIP; CI treats missing Swift as failure. The stub cannot
prove real Objective-C importer wiring or native LLVM operation: a full App
build and the new device report remain necessary.

Next phases still need a reviewed project/dependency detector, safe immutable
header snapshots/virtual filesystem, guarded atomic publication into approved
project outputs, and existing build history/artifact-verifier integration.
Generic Provider availability, build and test remain unavailable throughout
this phase. Existing Run203 fixed-runtime evidence and the pinned Run15 kit are
not reclassified as adapter evidence.
