# OpenMinis in-process iOS toolchain

This directory builds the embedded Clang/LLVM front end and re-entrant Mach-O linker used by the iOS host process.

## Build

Run on a macOS host with Xcode, CMake, Ninja and network access:

```sh
./toolchain-build/scripts/fetch-sources.sh
ARCHS="arm64 arm64e" LLVM_MIN_IOS="14.0" \
  ./toolchain-build/scripts/build-ios-toolchain.sh
./toolchain-build/verify-artifacts.sh toolchain-build/build/ios
```

The build must produce both `libomllvm-arm64.a` and `libomllvm-arm64e.a`. `libomld64.a` is the re-entrant linker archive. Clang resource headers are copied to `clang-resource/` beside the archives.

The iOS app must link the archive matching its own architecture. Do not link the existing arm64e-only LLVM archive into an arm64 target.

## Current vendored state

`src/ios/Vendor/OMToolchain` contains the bridge, local builtin header preparation assets and previously produced arm64e test archives. The bridge and resource folder are registered in the Minis main target, but compiler support defaults to disabled (`OM_TOOLCHAIN_ENABLED=0`). Static archives are not linked. Enabling the compiler still requires a matching arm64 LLVM archive, development/generated headers, verified builtin headers and SDK. No complete Minis Xcode build or runtime compilation has been verified.

## Reproducibility

LLVM and cctools-port revisions are pinned in `scripts/fetch-sources.sh`. The arm64e patches are kept under `toolchain-build/deps/patches/`. The generated `toolchain.json` records archive sizes and SHA-256 values.

## Schema-2 development kit

The macOS build now exports this layout beside the static libraries:

```text
clang-resource/include/            # builtin runtime headers
 dev-headers/
   common/include/llvm/             # patched public source headers
   common/include/clang/
   arm64/include/llvm/              # generated build headers
   arm64/include/clang/
   arm64e/include/llvm/
   arm64e/include/clang/
   licenses/
```

For the enabled bridge, add `dev-headers/<app-architecture>/include` **before** `dev-headers/common/include`. These are build-time inputs, not required App bundle resources. Runtime compilation additionally needs `clang-resource` and an iOS SDK. Do not mix generated headers from another architecture or LLVM build.

`export-dev-headers.sh` copies the source/generated header trees from the same patched checkout and completed cross builds. The schema-2 `toolchain.json` records per-file sizes and SHA-256 hashes for all exported headers and licenses, as well as archive hashes and revision. Legacy schema-1 packages must be rebuilt; they cannot silently pass as a complete kit.

`verify-artifacts.sh` checks required layout, complete file inventories and hashes, then uses Xcode lipo when available to check required architecture slices. `check-dev-headers.sh` compiles a C++ header probe for each architecture. Both the CI workflow and `quick-build.sh` invoke these checks. Header probe compilation is not an enabled-bridge link or PAC/runtime validation. This export pipeline has not yet run on a macOS builder in this task.

## Enabled-bridge compile/link gate

After verification and header probes, CI and `quick-build.sh` run:

```sh
bash toolchain-build/scripts/check-enabled-bridge.sh toolchain-build/build/ios
```

This compiles the canonical `OMToolchain.mm` with `OM_TOOLCHAIN_ENABLED=1` using architecture-specific generated headers, then statically links its real clang/LLVM and ld64 references into a separate iPhoneOS executable for each architecture. It uses the Xcode SDK and minimum iOS 16.0. Missing APIs or undefined symbols stop the build; no unresolved-symbol suppression, dead stripping, dynamic lookup or architecture fallback is used. The existing Minis target is not changed.

`verify-enabled-link.py` checks the thin Mach-O headers of both bridge objects and linked probes: cputype, cpusubtype with capability bits masked, and file type. A successful check writes `build/ios/enabled-link-check/enabled-link-report.json`. Compiler/Xcode versions and per-step logs accompany it. CI uploads those diagnostics even on failure and uploads the complete toolchain kit only if the gate passes.

The executables are **link-only probes, not Apps: do not run or install them**. The report does not establish PAC behavior, successful `runCC1` compilation, `runLinker` output, diagnostics/recovery, complete Minis linking or runtime safety. No enabled bridge link has yet run in this task because the local host lacks Xcode and the required arm64 development kit.


The production Minis target must not define `OM_TOOLCHAIN_ENABLED` or `OM_TOOLCHAIN_VERIFIED` yet. These definitions belong to a later release integration change and require the successful macOS artifact, development-header, enabled-bridge compile/link, and full Minis build gates. A successful link-only probe alone does not authorize runtime compiler execution.
