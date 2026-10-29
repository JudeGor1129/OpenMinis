#!/bin/sh
# Compile and run only the production JSON/identity validator. This program has
# no persona calls, no helper spawn, and no privileged filesystem access.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
if [ "$(uname -s)" != Darwin ]; then
  echo 'UNAVAILABLE: Foundation response fixture execution requires macOS; iOS cross syntax check is separate.'
  exit 0
fi
build=$(mktemp -d "${TMPDIR:-/tmp}/minis-response-tests.XXXXXX")
trap 'rm -rf "$build"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -I"$root/src/ios/Diagnostics" \
  "$root/tools/privileged-helper/tests/ResponseTests.m" \
  -framework Foundation -framework CoreFoundation -o "$build/response-tests"
"$build/response-tests"
