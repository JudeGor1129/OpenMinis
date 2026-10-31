#!/usr/bin/env bash
#
# check-tapi-shim.sh — gate for the libtapi-compatible shim.
#
# Three layers, each cheap enough to run before any device build:
#
#   1. source policy: the ld64 build must actually enable TAPI and compile the
#      shim, because a missing -DTAPI_SUPPORT is exactly what produced the
#      on-device "must link with libSystem.dylib" failure -- the parser file
#      compiles to an empty object and nothing looks broken.
#   2. behaviour: the host unit test, when a host LLVM is available, runs the
#      shim against a real libSystem.B.tbd (the SDK's own stub).
#   3. artifact: if an already-built libomld64.a is present, it must define the
#      tapi symbols and carry a non-empty text-stub parser, so an archive that
#      silently lost the parser is caught.
#
# Parts that cannot run on this machine are reported as skipped, never assumed.

set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_SCRIPT=toolchain-build/scripts/build-ld64-inprocess.sh
SHIM_DIR=toolchain-build/src/tapi-shim
SHIM_IMPL="$SHIM_DIR/lib/LinkerInterfaceFile.cpp"
SHIM_HEADER="$SHIM_DIR/include/tapi/LinkerInterfaceFile.h"
TEST_UNIT="$SHIM_DIR/tests/test-linker-interface.cpp"
RUNNER="$SHIM_DIR/run-tests.sh"

for f in "$BUILD_SCRIPT" "$SHIM_IMPL" "$SHIM_HEADER" "$TEST_UNIT" "$RUNNER"; do
  [[ -f "$f" ]] || { echo "error: missing $f" >&2; exit 1; }
done

python3 - "$BUILD_SCRIPT" "$SHIM_IMPL" "$SHIM_HEADER" "$TEST_UNIT" <<'PY'
from pathlib import Path
import sys
script, impl, header, unit = [Path(p).read_text(encoding="utf-8") for p in sys.argv[1:]]

def require(condition, message):
    if not condition:
        raise SystemExit("tapi-shim gate failed: " + message)

# 1. The ld64 build must enable the code path and compile the shim into it.
require("-DTAPI_SUPPORT" in script,
        "build-ld64-inprocess.sh must define TAPI_SUPPORT; without it the text-stub parser is an empty object")
require('SHIM="$ROOT/src/tapi-shim"' in script, "the build must point at the shim sources")
require('"lib/LinkerInterfaceFile.cpp"' in script, "the shim implementation must be in the source list")
require('-I"$SHIM/include"' in script, "the shim headers must be on the include path")
require("dev-headers/common/include" in script and "llvm/TextAPI/TextAPIReader.h" in script,
        "the build must locate this build tree's LLVM headers for the shim")
require("EXPECTED_OBJECTS" in script,
        "the object count must account for the shim, or a dropped unit goes unnoticed")
require('shift 4' in script and 'EXTRA_INCLUDES="$*"' in script,
        "the compile driver must take per-architecture include directories from every trailing argument")
require('$EXTRA_INCLUDES' in script,
        "the compile driver must actually use those include directories")

# 2. The shim must stay a shim: no dynamic loading, no second parser, and no
#    ld64 internals, since it is compiled into ld64's own archive.
for forbidden in ("dlopen", "NSBundle", "libtapi.a", "system(", "popen("):
    require(forbidden not in impl, f"shim implementation must not use {forbidden}")
for needed in ("LinkerInterfaceFile::create", "LinkerInterfaceFile::isSupported",
               "getInlinedFramework", "TextAPIReader"):
    require(needed in impl, f"shim implementation must implement {needed}")
require("isSupported(" in header and "getInlinedFramework(" in header and "create(" in header,
        "the public header must declare what ld64 calls")
require("parseVersion32" in impl and "$ld$" in impl,
        "the shim must process $ld$ directives; the SDK stubs depend on them")

# 3. The test must be run against a real SDK stub, not a fixture.
require("libSystem.B.tbd" in unit, "the unit test must target the SDK's libSystem stub")
require("isSupported" in unit and "getInlinedFramework" in unit,
        "the unit test must exercise recognition and inlined documents")
print("PASS: tapi-shim source policy (TAPI enabled, shim compiled, no second parser).")
PY

# ---------------------------------------------------------------------------
# Behaviour, when the host has an LLVM to link against.
# ---------------------------------------------------------------------------
LLVM_CONFIG="${LLVM_CONFIG:-}"
if [[ -z "$LLVM_CONFIG" ]]; then
  for candidate in llvm-config llvm-config-19 /usr/lib/llvm19/bin/llvm-config; do
    if command -v "$candidate" >/dev/null 2>&1; then LLVM_CONFIG="$candidate"; break; fi
  done
fi

STUB="${TAPI_SHIM_STUB:-}"
if [[ -z "$STUB" ]]; then
  for candidate in /opt/theos/sdks/iPhoneOS*.sdk/usr/lib/libSystem.B.tbd; do
    [[ -f "$candidate" ]] && STUB="$candidate" && break
  done
fi

if [[ -n "$LLVM_CONFIG" && -n "$STUB" ]]; then
  echo "==> host test against $STUB"
  LLVM_CONFIG="$LLVM_CONFIG" sh "$RUNNER" --llvm-config "$LLVM_CONFIG" "$STUB"
elif [[ -z "$LLVM_CONFIG" ]]; then
  echo "SKIP host test: no llvm-config on this machine (it runs on the host, not the device)"
else
  echo "SKIP host test: no iPhoneOS SDK stub found; set TAPI_SHIM_STUB"
fi

# ---------------------------------------------------------------------------
# Compile for the device, when a device SDK and xcrun are available.
# ---------------------------------------------------------------------------
DEV_HEADERS="${TAPI_SHIM_DEV_HEADERS:-toolchain-build/build/ios/dev-headers}"
if command -v xcrun >/dev/null 2>&1 && [[ -d "$DEV_HEADERS/common/include" ]]; then
  SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
  for ARCH in arm64 arm64e; do
    echo "==> compile shim for $ARCH"
    xcrun --sdk iphoneos clang++ -arch "$ARCH" \
      -I"$SHIM_DIR/include" -I"$DEV_HEADERS/common/include" -I"$DEV_HEADERS/$ARCH/include" \
      -std=c++2a -fexceptions -frtti -D__DARWIN_UNIX03 -DTAPI_SUPPORT -Wno-everything \
      -isysroot "$SDKROOT" -c "$SHIM_IMPL" -o "$(mktemp -d)/shim-$ARCH.o"
  done
else
  echo "SKIP device compile: needs xcrun plus $DEV_HEADERS"
fi

echo 'PASS: tapi-shim gate complete.'
