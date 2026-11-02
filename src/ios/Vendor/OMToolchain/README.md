# Embedded toolchain bridge

`OMToolchain.h` and `OMToolchain.mm` are the in-process Clang front end and re-entrant ld64 bridge.

The bridge is architecture-sensitive:

- an arm64 Minis process must link `libomllvm-arm64.a` and the arm64 ld64 objects;
- an arm64e Minis process must link `libomllvm-arm64e.a` and the arm64e ld64 objects;
- the process also needs the matching `clang-resource/` headers and an iOS SDK sysroot.

The bridge implementation and `clang-resource` folder are registered in the Minis main target. With `OM_TOOLCHAIN_ENABLED` undefined (default 0), the bridge builds without LLVM development headers or archives and returns `OMToolchainStatusUnavailable`; the settings page reports that status. The committed Xcode project does not link a compiler archive by default.

The iOS 15 full-build workflow verifies the immutable locked artifact (currently Run15), including the ZIP, schema-2 manifest, exported file hashes, Mach-O slices and enabled-link report, then links only `libomllvm-arm64.a` plus universal ld64 into an arm64 App. A passing fixed-fixture device report is checked against that lock before the disposable validation build defines `OM_TOOLCHAIN_VERIFIED=1`. The committed Xcode project remains unset, and `EmbeddedToolchainBuildProvider` remains unavailable until a constrained execution adapter is independently implemented and reviewed.

`OMToolchainDiagnostics` is a deliberately separate, user-triggered runtime evidence gate. It accepts only a bounded iteration count and uses fixed freestanding C/Objective-C fixtures; when an imported iPhoneOS SDK is present it also compiles a fixed Foundation Objective-C fixture to an object and inspects the Mach-O without linking, loading or executing it. That SDK compile supplies clang Driver-equivalent target macros, blocks/exceptions and ordered system/builtin include paths; a missing SDK is reported as a skipped Foundation check. The suite checks arm64 and arm64e object/dylib output, B-key PAC instructions, expected compiler/linker failures followed by recovery, repeated jobs and resident-memory samples. It removes temporary outputs and never changes `OM_TOOLCHAIN_VERIFIED` or Provider availability. Passing fixed fixtures is runtime evidence, not permission to execute arbitrary project builds through the provider.

**Device evidence (Run 199 / build 199, 2026-11-01):** the user supplied a three-round report with `passed=true`, all 3 repeated arm64 compile/link jobs successful, arm64 and arm64e baseline dylib links successful, expected compiler/linker failures followed by recovery, temporary outputs removed, and generated Mach-O execution disabled. Four ladder probes were negative by design (three omit the required libSystem input; the executable fixture lacks `_main`). Peak resident size was 552,222,720 bytes, with a 24,625,152-byte start-to-end increase. The report says `runtime_verification_gate=not_granted` and capability `verification=missing`; it predates the Foundation fixture.

**Device evidence (Run 201 / build 201, 2026-11-01):** the user supplied a three-round report with `passed=true` and `foundation_sdk_compilation=passed`. The Foundation Objective-C fixture produced a valid arm64 `MH_OBJECT` (3,104 bytes); arm64 and arm64e baseline dylib links passed; all three repeated arm64 compile/link rounds passed; both expected failure/recovery checks passed; temporary outputs were removed; generated Mach-O execution remained disabled. Four argument-ladder probes were negative by design. Resident size increased by 53,395,456 bytes (381,779,968 to 435,175,424), with a sampled peak of 435,224,576 bytes. The supplied report SHA-256 is `8d1c6ebf3a013a973d3e5e1f7dbf702d85a343c11cd7f2dba55af7747a52ecea`. At report time it still had `runtime_verification_gate=not_granted`, `verification=missing`, and `state=unavailable`; the subsequent validation-build macro is authorized only by the pinned evidence validator below. BuildProvider remains unavailable.
**Evidence-gated validation build:** `runtime-validation-evidence.json` is checked against the pinned Run15 artifact by `verify-embedded-toolchain-runtime-evidence.py` before the disposable full-App build. Only that validation build receives `OM_TOOLCHAIN_VERIFIED=1`; the committed Xcode project remains unset. `OMToolchainDiagnostics` reports `fixed_fixture_evidence_verified` when this bit is present, but still never executes generated code. The BuildProvider remains unavailable because no constrained, reviewed execution adapter exists.


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


### Validation-only adapter Mach-O inspection

The pinned iOS15 `ld64` emits `LC_ENCRYPTION_INFO_64` on an iOS dylib even
when it is not encrypted: its default `cryptid` is zero. The restricted adapter
therefore accepts only the bounded 64-bit load-command form (`cmdsize == 24`,
`cryptid == 0`, zero reserved pad, and a range wholly contained by `__TEXT`).
It rejects non-zero cryptid, malformed/duplicate commands and out-of-range
payloads, poisons the current adapter instance, removes the private run directory
and returns no artifact metadata. This is inspection of a zero-cryptid marker,
not support for encrypted outputs, and does not make the generic BuildProvider
available. The macOS contract gate also inspects a hash-pinned, real Clang/LLD
Mach-O byte fixture as parser regression coverage; LLD output is not represented
as evidence for the pinned native ld64 or an iOS device.
