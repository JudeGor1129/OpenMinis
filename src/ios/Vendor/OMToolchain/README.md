# Embedded toolchain bridge

`OMToolchain.h` and `OMToolchain.mm` are the in-process Clang front end and re-entrant ld64 bridge.

The bridge is architecture-sensitive:

- an arm64 Minis process must link `libomllvm-arm64.a` and the arm64 ld64 objects;
- an arm64e Minis process must link `libomllvm-arm64e.a` and the arm64e ld64 objects;
- the process also needs the matching `clang-resource/` headers and an iOS SDK sysroot.

The bridge implementation and `clang-resource` folder are registered in the Minis main target. With `OM_TOOLCHAIN_ENABLED` undefined (default 0), the bridge builds without LLVM development headers or archives and returns `OMToolchainStatusUnavailable`; the settings page reports that status. The committed Xcode project does not link a compiler archive by default.

The iOS 15 full-build workflow has a narrower integration gate: it downloads the immutable Run7 artifact, rechecks the ZIP, schema-2 manifest, every exported file hash, Mach-O slices and enabled-link report, then links only `libomllvm-arm64.a` plus universal ld64 into an arm64 App validation build. That build defines `OM_TOOLCHAIN_ENABLED=1` but intentionally leaves `OM_TOOLCHAIN_VERIFIED` unset, so `EmbeddedToolchainBuildProvider` remains unavailable. A successful App link is not runtime compiler verification.

The builtin headers copied from the local extracted Twork app are preparation assets, not a verified match for the pinned LLVM revision. Replace them with headers from the same successful LLVM build before enabling compilation. The resource root must contain `include/`.

Enabling `OM_TOOLCHAIN_ENABLED=1` additionally requires matching LLVM/Clang static archives, LLVM/Clang development headers (including generated headers), ld64, C++ link flags and an iOS SDK. It is not enough to supply builtin headers. Keep Minis' deployment target at 16.0; the compiler library's 14.0 minimum does not lower the app's requirements.

Do not add `OMVerifyToolchain.mm` to the production target; it is a standalone validation harness.

`EmbeddedToolchainBuildProvider` is registered as a read-only readiness provider. It always reports unavailable until both `OM_TOOLCHAIN_ENABLED=1` and `OM_TOOLCHAIN_VERIFIED=1` are supplied by a build that has passed the enabled compile/link gate. It does not spawn a command, execute the standalone harness, or fall back to iSH. The verification macro is intentionally separate from the compiler macro so a linked-but-unverified archive cannot be selected accidentally.
