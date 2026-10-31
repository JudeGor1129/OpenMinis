# Embedded toolchain bridge

`OMToolchain.h` and `OMToolchain.mm` are the in-process Clang front end and re-entrant ld64 bridge.

The bridge is architecture-sensitive:

- an arm64 Minis process must link `libomllvm-arm64.a` and the arm64 ld64 objects;
- an arm64e Minis process must link `libomllvm-arm64e.a` and the arm64e ld64 objects;
- the process also needs the matching `clang-resource/` headers and an iOS SDK sysroot.

The bridge implementation and `clang-resource` folder are registered in the Minis main target. With `OM_TOOLCHAIN_ENABLED` undefined (default 0), the bridge builds without LLVM development headers or archives and returns `OMToolchainStatusUnavailable`; the settings page reports that status. The committed Xcode project does not link a compiler archive by default.

The iOS 15 full-build workflow has a narrower integration gate: it downloads the immutable Run7 artifact, rechecks the ZIP, schema-2 manifest, every exported file hash, Mach-O slices and enabled-link report, then links only `libomllvm-arm64.a` plus universal ld64 into an arm64 App validation build. That build defines `OM_TOOLCHAIN_ENABLED=1` but intentionally leaves `OM_TOOLCHAIN_VERIFIED` unset, so `EmbeddedToolchainBuildProvider` remains unavailable. A successful App link is not runtime compiler verification.

`OMToolchainDiagnostics` is the next, deliberately separate gate. It accepts only a bounded iteration count and uses fixed freestanding C/Objective-C fixtures. On explicit user action it checks arm64 and arm64e object/dylib output, B-key PAC instructions, expected compiler/linker failures followed by recovery, repeated jobs and resident-memory samples. It never loads or executes generated code, removes temporary outputs and never changes `OM_TOOLCHAIN_VERIFIED` or Provider availability. A missing bundled SDK limits this suite to freestanding fixtures; Foundation/SDK compilation remains a later gate.

`OMStdioCapture.h` exists because the first device run of that suite proved the suite could not explain its own failures. Every link step reported

```
OMToolchain: ld64 exited with status 1
```

and nothing else: the vendored ld64 reports failures the way a CLI does -- `fprintf(stderr, ...)` then a non-zero return -- and fd 2 inside the app is not something the host can read back. The header moves fd 1/2 onto temporary files around one call, reads them back, and always restores them, including on the `@try`/`@catch` path. Without it a failing link is indistinguishable from a `library not found`, a rejected argument or a bad output path.

With the reason visible, the open question became *which* argument ld64 rejects. The suite therefore also runs a small argument ladder over the object it just compiled -- minimal `-dylib`, `-dylib` plus `-platform_version`, `-dylib` plus `-install_name`, the exact production argv, and one executable link -- so a single device report localises the failing argument instead of one build cycle per guess. The probes are diagnostics only: they do not feed the suite's overall pass, which stays the real `link_<arch>_dylib` step. Each link step now also reports the argv it ran.

The capture is exercised on the host by `toolchain-build/scripts/test-stdio-capture.c`, compiled and run by the runtime-diagnostic source gate. It covers the round trip, bounded reads, the abandon form, refused nesting, the guard being released, and that no temporary file survives -- a descriptor left behind would follow the app around for the rest of its life, which is far cheaper to find on a host than on a device.

The same gate compiles `toolchain-build/scripts/probe-linker-block-capture.mm`. `runLinker` builds its argv in one block and calls the linker entry point from a nested one, and a captured C++ object is const inside the capturing block: reaching `argv.data()` off the captured copy produced a `const char *const *` that the entry point cannot take, and that mistake cost a full build cycle because no machine without the LLVM archives can compile `runLinker` itself. The probe reproduces the shape with stand-ins that need no LLVM.

The builtin headers copied from the local extracted Twork app are preparation assets, not a verified match for the pinned LLVM revision. Replace them with headers from the same successful LLVM build before enabling compilation. The resource root must contain `include/`.

Enabling `OM_TOOLCHAIN_ENABLED=1` additionally requires matching LLVM/Clang static archives, LLVM/Clang development headers (including generated headers), ld64, C++ link flags and an iOS SDK. It is not enough to supply builtin headers. Keep Minis' deployment target at 16.0; the compiler library's 14.0 minimum does not lower the app's requirements.

Do not add `OMVerifyToolchain.mm` to the production target; it is a standalone validation harness.

`EmbeddedToolchainBuildProvider` is registered as a read-only readiness provider. It always reports unavailable until both `OM_TOOLCHAIN_ENABLED=1` and `OM_TOOLCHAIN_VERIFIED=1` are supplied by a build that has passed the enabled compile/link gate. It does not spawn a command, execute the standalone harness, or fall back to iSH. The verification macro is intentionally separate from the compiler macro so a linked-but-unverified archive cannot be selected accidentally.
