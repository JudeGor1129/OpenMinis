#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compiler=${CC:-cc}
build=$(mktemp -d "${TMPDIR:-/tmp}/minis-root-command-tests.XXXXXX")
trap 'rm -rf "$build"' EXIT
"$compiler" -std=c11 -D_GNU_SOURCE -O2 -Wall -Wextra -Werror -pthread -I"$root/src/ios/Diagnostics" "$root/tools/privileged-helper/tests/RootCommandProcessTests.c" -o "$build/root-command-tests"
"$build/root-command-tests"
