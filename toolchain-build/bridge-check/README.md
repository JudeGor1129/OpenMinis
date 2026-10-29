# Disabled toolchain regression checks

Run on a macOS host with Xcode installed:

```sh
bash toolchain-build/bridge-check/check-macos.sh
```

Or manually trigger `.github/workflows/ios-toolchain-bridge-check.yml`. Pull requests touching listed paths also run it.

The script uses the canonical bridge, not the smoke app's source snapshot. It checks:

- actual Minis main target source/resource registration and Swift bridging import;
- disabled return values, diagnostic slots, repeated calls and explicit path preservation;
- cc1 argument construction;
- synthetic thin Mach-O header parsing, including arm64e capability bits;
- host compilation/execution on macOS;
- arm64 iPhoneOS 16.0 object compilation with Xcode's SDK;
- Swift typechecking of `OMToolchain.capabilityStatus()` as `[String: String]`.

On a machine without Xcode it exits with status 2 instead of claiming success. Tests generate temporary files and remove them. Synthetic headers do not validate PAC code generation or signed executables.

It does not test enabled LLVM/ld64, the full SwiftUI settings view, the full Minis target, iOS runtime, IPA installation or compiling user projects. It does not lower Minis' iOS minimum or change its architecture. CI results are pending until the workflow actually runs.

## Local compile-only validation

Twork 0.3.57 successfully compiled and linked `DisabledBridgeTests.mm` and the copied `OMToolchain.mm` with `-Wall -Wextra -Werror`, arm64, iPhoneOS 15.6 SDK and an isolated test target minimum of iOS 15.0. This validates the test translation units, not the execution of assertions or Swift typechecking.

The Makefile uses `OMToolchain.h/mm` snapshots only for the on-device compile/link check. Refresh them from `src/ios/Vendor/OMToolchain` before rebuilding; CI uses canonical files directly. The generated `packages/OMBridgeCheckCompile.ipa` (`com.twork.ombridgecheckcompile`) is merely an output of the Theos application packager. Its entry point is console-style, not UIKit: **do not install or launch it as an iOS app**. Runtime tests execute only as the macOS console binary built by the script.

Local `bash -n` passed. Running `check-macos.sh` on this iOS host returned the intended exit 2 with a missing-Xcode message. macOS test execution, Python registration checking and Swift import typechecking remain unverified until CI runs. The LLVM build workflow now depends on this check job.
