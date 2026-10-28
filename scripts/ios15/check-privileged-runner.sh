#!/bin/sh
# Real unprivileged process tests. No Apple helper, shell fixture or Frida.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compiler=
for candidate in cc clang gcc; do
    if command -v "$candidate" >/dev/null 2>&1; then
        compiler=$candidate
        break
    fi
done
if [ -z "$compiler" ]; then
    echo 'FAIL: install cc, clang or gcc with POSIX/pthread development headers' >&2
    exit 1
fi
case $(uname -s) in
    Linux|Darwin) ;;
    *) echo 'FAIL: this check supports Linux and macOS only' >&2; exit 1 ;;
esac
build=$(mktemp -d "${TMPDIR:-/tmp}/minis-runner-tests.XXXXXX")
trap 'rm -rf "$build"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
src="$root/src/ios/Diagnostics"
tests="$root/tools/privileged-helper/tests"
echo "INFO compiler=$compiler platform=$(uname -s) arch=$(uname -m) C11 -O2 pthread"
"$compiler" -std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror \
    "$tests/Fixture.c" -o "$build/fixture"
"$compiler" -std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror -pthread \
    -I"$src" "$tests/RunnerTests.c" "$src/HelperProcessRunner.c" -o "$build/runner-tests"
"$build/runner-tests" "$build/fixture"
