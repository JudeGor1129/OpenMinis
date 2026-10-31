#!/bin/sh
#
# run-tests.sh — build and run the tapi-shim host test against a real SDK stub.
#
# The shim only has to satisfy ld64, so the test that matters is the one that
# feeds it the actual libSystem.B.tbd from an iPhoneOS SDK rather than a
# hand-written fixture.
#
# POSIX sh on purpose: this runs from iSH, from macOS, and from the source
# gate, and the workspace file layer does not preserve an execute bit, so it is
# normally invoked as `sh run-tests.sh`.
#
# usage: run-tests.sh [--llvm-config PATH] [--cxx PATH] <libSystem.B.tbd>

set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
LLVM_CONFIG="${LLVM_CONFIG:-llvm-config}"
CXX="${CXX:-clang++}"

while [ $# -gt 0 ]; do
  case "$1" in
    --llvm-config) LLVM_CONFIG="$2"; shift 2 ;;
    --cxx) CXX="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) break ;;
  esac
done

if [ $# -ne 1 ]; then
  echo "usage: $0 [--llvm-config PATH] <libSystem.B.tbd>" >&2
  exit 2
fi
TBD="$1"
[ -f "$TBD" ] || { echo "error: no such stub: $TBD" >&2; exit 2; }

if ! command -v "$LLVM_CONFIG" >/dev/null 2>&1; then
  echo "error: $LLVM_CONFIG not found; pass --llvm-config or set LLVM_CONFIG" >&2
  exit 2
fi

INCLUDES="$("$LLVM_CONFIG" --includedir)"
LIBDIR="$("$LLVM_CONFIG" --libdir)"
VERSION="$("$LLVM_CONFIG" --version)"
MAJOR="${VERSION%%.*}"
BIN="$(mktemp -d)/tapi-shim-test"

"$CXX" -std=c++17 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
  -I "$INCLUDES" -I "$ROOT/include" \
  "$ROOT/tests/test-linker-interface.cpp" "$ROOT/lib/LinkerInterfaceFile.cpp" \
  -L "$LIBDIR" -lLLVM-"$MAJOR" -Wl,-rpath,"$LIBDIR" -o "$BIN"

echo "==> tapi-shim host test (LLVM $VERSION, stub $TBD)"
"$BIN" "$TBD"
