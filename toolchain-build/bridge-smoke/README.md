# Disabled bridge smoke app

This is not Minis and does not contain LLVM. It compiles/links the disabled (`OM_TOOLCHAIN_ENABLED=0`) Objective-C++ bridge and contains runtime assertions. A successful build is not evidence those assertions ran. Install/launch only when explicitly requested.

The local Twork source resolver did not resolve a `../../src/...` entry in `_FILES`, so this harness uses copies of the canonical bridge. Refresh the snapshot before every build:

```sh
cp src/ios/Vendor/OMToolchain/OMToolchain.h toolchain-build/bridge-smoke/
cp src/ios/Vendor/OMToolchain/OMToolchain.mm toolchain-build/bridge-smoke/
```

Canonical source: `src/ios/Vendor/OMToolchain/OMToolchain.{h,mm}`.

This harness does not validate SwiftUI, Swift bridging import, Minis dependencies, or real Clang/ld64 compilation. The full Minis target requires a separate Xcode build.

## Local verified result

Built successfully using Twork 0.3.57, iPhoneOS 15.6 SDK and an arm64/iOS 15.0 **test-harness** target. Both sources compiled and linked; `packages/OMBridgeSmoke.ipa` was packaged. No installation or runtime assertion execution occurred. The actual Minis Xcode target still requires iOS 16.0 and has not been built here.

At harness minimum iOS 16.0, both sources compiled but the local 15.6 SDK link failed on `objc_claimAutoreleasedReturnValue`. Setting `-fobjc-runtime=ios-15.0` alone did not fix it. Only the isolated harness minimum was aligned with the available SDK.

Canonical-source regression CI is in `../bridge-check/`; its macOS host execution and Swift import check are pending until CI runs.
