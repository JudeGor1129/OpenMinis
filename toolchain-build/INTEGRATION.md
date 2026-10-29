# Toolchain integration status

## Verified state

The canonical `src/ios/Vendor/OMToolchain/OMToolchain.{h,mm}` bridge and `clang-resource` folder are registered in the Minis main target. The main Swift bridging header imports the declaration and `RootfsBuildSettingsView.swift` uses the capability dictionary. `OM_TOOLCHAIN_ENABLED` defaults to **0**: calls return `OMToolchainStatusUnavailable`; no LLVM/ld64 static archive is linked. This is NOT an enabled compiler.

The independent `toolchain-build/bridge-smoke` app compiled, linked and packaged successfully through Twork 0.3.57's InProcessClang backend:

- Architecture: arm64, cputype `0x0100000c`, cpusubtype `0x00000000`.
- Available SDK: iPhoneOS 15.6 (not a statement about running iOS).
- Harness minimum: iOS 15.0. Minis' Xcode minimum remains iOS 16.0.
- Output: `toolchain-build/bridge-smoke/packages/OMBridgeSmoke.ipa`.
- Bundle ID: `com.openminis.toolchainbridgesmoke`.
- No installation or launch occurred; runtime assertions did not run.

The harness initially failed because the local source resolver did not find the parent-directory `_FILES` entry. Canonical files were copied into the harness. Both sources then compiled at minimum iOS 16.0, but linking against the 15.6 SDK failed on `_objc_claimAutoreleasedReturnValue`. Explicit `-fobjc-runtime=ios-15.0` alone did not resolve it. Changing only the independent harness's minimum to 15.0 allowed linking. This does not validate a full Minis build or justify lowering Minis' minimum.

## Assets present vs missing

Present:

- Disabled-capability bridge, Xcode registration and settings display.
- Existing `libomllvm-arm64e.a` and ld64 archives, not linked to Minis.
- `clang-resource/include/` copied from the locally extracted Twork app; headers are preparation assets. Compatibility with the pinned LLVM archive is unverified.
- Toolchain source/build scripts and pinned patches.
- `.github/workflows/ios-toolchain.yml`: manual macOS LLVM/ld64 build.
- `.github/workflows/ios-toolchain-bridge-check.yml`: lightweight disabled-bridge checks; CI execution pending.

Required before enabling:

1. `libomllvm-arm64.a` matching the standard arm64 Minis process.
2. LLVM/Clang **development headers**, including generated build headers for the selected architecture. Builtin headers alone cannot compile the enabled bridge. The artifact workflow now has development-kit export and verification, but those steps have not yet run against a completed macOS LLVM build.
3. Builtin headers from the same LLVM revision, in `<resource-root>/include/`.
4. An iOS SDK usable by the native host. An SDK inside iSH's emulated filesystem is not automatically a native sysroot.
5. Architecture-matched library linking, C++ and other required support libraries, then enabled-bridge compilation against the pinned LLVM APIs.
6. BuildProvider integration and real compile/link/failure-recovery tests.

No arm64e-only Minis build or forced architecture fallback has been performed. The library's iOS 14.0 minimum does not lower the app's iOS 16.0 requirement. The existing arm64e archive is not a substitute for an arm64 archive.

## Regression checks

On a macOS host with Xcode:

```sh
bash toolchain-build/bridge-check/check-macos.sh
```

This checks actual Xcode registration, runs host disabled-bridge assertions, compiles the canonical bridge for arm64 iOS 16.0 and typechecks the Swift dictionary import. It does not test the complete SwiftUI view, full Minis dependencies, enabled LLVM, signing, installation or iPhone runtime. Lack of Xcode is an explicit failure, not a skipped pass.

The smoke harness uses source snapshots; refresh them before rebuilding:

```sh
cp src/ios/Vendor/OMToolchain/OMToolchain.h toolchain-build/bridge-smoke/
cp src/ios/Vendor/OMToolchain/OMToolchain.mm toolchain-build/bridge-smoke/
```

## Remaining sequence

1. Run the lightweight bridge CI and the full Minis Xcode build. They are not validated by the local smoke IPA.
2. Generate arm64 + arm64e libraries and matching development/generated headers on macOS using the updated export scripts:

   ```sh
   bash toolchain-build/quick-build.sh
   ```

3. Verify libraries and headers, replace preparation assets and integrate architecture-specific include/link settings. Keep compiler support disabled until a real enabled-bridge link succeeds.
4. Provide a native SDK, connect the provider, test a minimal source -> object -> dylib pipeline, diagnostics, repeated jobs and architecture validation.
5. Build the actual Minis IPA. Install/open only on explicit user request; compiling does not itself confer jailbreak privileges or tweak injection.

## Added regression infrastructure

The disabled-bridge CI job is also a prerequisite of the manual LLVM build workflow. `check-macos.sh` passes local shell syntax parsing and explicitly exits 2 on this host without Xcode. Its macOS assertion execution, Python project registration checker and Swift typechecker have not run here; they are pending real CI results.

The regression test translation units additionally compiled and linked locally with `-Wall -Wextra -Werror`, arm64, SDK 15.6 and an isolated iOS 15.0 test target. The produced `OMBridgeCheckCompile.ipa` is a packaging byproduct of a console-style entry point, not a UIKit app, and must not be installed/launched. No assertions executed. This does not change Minis' minimum iOS version or enable the compiler.

## Development-kit export added

The build now calls `scripts/export-dev-headers.sh` after cross builds. It exports patched public source headers into `dev-headers/common/include`, per-architecture generated headers into `dev-headers/{arm64,arm64e}/include`, and LLVM/Clang licenses. Generated include directories must precede common source headers; these are build-time inputs, not resources to bundle in Minis.

The manifest is now schema 2 with archive hashes and complete per-file hash/size inventories for builtin and development headers. `scripts/verify-toolchain-manifest.py` enforces the full kit layout and rejects legacy manifests, missing files, symlinks, mismatched inventories and hashes. When Xcode is available the wrapper checks required archive slices. `scripts/check-dev-headers.sh` compiles C++ include probes for both architectures; it does not validate enabled bridge APIs or static linking. CI uploads `dev-headers/` and runs the probe after verification; the local macOS convenience wrapper also invokes it.

Local validation performed: all five changed/new shell scripts passed `bash -n`; verification of existing vendor assets correctly failed on the missing arm64 LLVM archive and development-header directories; an unsupported export architecture was rejected; the header compile probe correctly exited 2 because Xcode is unavailable. The Python verifier, actual header export and arm64/arm64e probes have not run against real rebuilt artifacts. No compiler library was generated or linked, and no new Minis IPA was produced.

## Enabling policy

Do not add `OM_TOOLCHAIN_ENABLED=1` or `OM_TOOLCHAIN_VERIFIED=1` to the Minis Xcode target manually. Those macros may be supplied only by the release integration after the macOS workflow has produced both arm64 and arm64e libraries plus matching development headers, and `check-enabled-bridge.sh` has completed successfully for both architectures. The link-only probes are not runtime tests. Until that policy gate is satisfied, the production bridge must remain disabled and `EmbeddedToolchainBuildProvider` must remain unavailable.
