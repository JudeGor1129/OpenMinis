# tapi-shim

A minimal `tapi/` C++ API implemented on top of the LLVM `TextAPI` library that
the embedded toolchain already carries, so the pinned ld64 can be built with
`TAPI_SUPPORT` and read real `.tbd` stubs.

## Why it exists

`ld: dynamic executables or dylibs must link with libSystem.dylib` was reported
for every dynamic link on device (build187). The pinned ld64 reads `.tbd` stubs
only when built with `TAPI_SUPPORT`, and that code path talks to Apple's
libtapi. The shipped `libomld64.a` was built without it, so the SDK's
`libSystem.B.tbd` was invisible to the linker and nothing could satisfy the
mandatory libSystem dependency.

Two facts made a shim the smallest correct fix rather than a workaround:

* libtapi's `LinkerInterfaceFile` is itself a thin adapter over
  `llvm::MachO::InterfaceFile`, and the locked LLVM archive
  (`libomllvm-arm64.a`, `libomllvm-arm64e.a`) already exports
  `llvm::MachO::TextAPIReader` / `DylibReader`.
* ld64 uses a small, closed surface of that API: 25 members of
  `LinkerInterfaceFile`, plus `APIVersion`, `Version`, `ParsingFlags`,
  `PackedVersion32` and `Symbol`.

So this shim reimplements libtapi's adapter logic -- architecture selection,
`$ld$` directives, Objective-C symbol expansion, inlined documents -- on top of
`TextAPIReader`. ld64 is not modified, no second copy of LLVM is added, and no
prebuilt binary is fetched. A stub that silently accepts anything would be a
fake fix; this one is exercised against the real SDK stub by a test that fails
if `$ld$` handling or slice filtering regresses.

## What it does not do

* No `.tbd` writing and no `tapi` command line tool. ld64 only reads.
* The diagnostic reader of libtapi is not reimplemented; it has no bearing on
  linking.
* Symbol flags are masked to the three bits `tapi::SymbolFlags` defines, which
  is all ld64 inspects.

## Provenance

Derived from `tpoechtrager/apple-libtapi`'s `LinkerInterfaceFile.h/.cpp`,
`Defines.h`, `APIVersion.h`, `PackedVersion32.h`, `Symbol.h` and `Version.h`
(Apache-2.0 WITH LLVM-exception). Declarations are reproduced so ld64 compiles
unchanged; the implementation is rewritten against LLVM `TextAPI` and is
documented where it deliberately diverges.

## Tests

`run-tests.sh` builds `tests/test-linker-interface.cpp` on the host and runs it
against a real `libSystem.B.tbd`:

```sh
sh run-tests.sh --llvm-config /usr/lib/llvm19/bin/llvm-config \
    /opt/theos/sdks/iPhoneOS16.5.sdk/usr/lib/libSystem.B.tbd
```

(`sh run-tests.sh`, not `./run-tests.sh`: the execute bit does not survive this
workspace's file layer, and the script only needs a POSIX shell.)

It asserts the architecture-resolved install name and version, re-export and
inlined-document resolution, `$ld$hide$` behaviour at its own deployment target
versus a different one, arm64-vs-armv7 slice filtering, Objective-C symbol
expansion, and the error messages for a wrong architecture or a missing file.
The iOS configuration is checked separately by compiling the implementation for
`arm64-apple-ios` and `arm64e-apple-ios` against the locked Run7 headers.
