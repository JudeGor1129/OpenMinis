#!/usr/bin/env bash
# Publication contracts use the adapter harness's inspected Mach-O fixture.
set -euo pipefail
cd "$(dirname "$0")/../.."
for f in src/ios/Agent/Build/EmbeddedToolchainProjectPublisher.swift toolchain-build/scripts/test-embedded-project-publisher.swift; do
  [[ -s "$f" ]] || { echo "FAIL: missing or empty $f" >&2; exit 1; }
done
python3 - <<'PY'
from pathlib import Path
s=Path('src/ios/Agent/Build/EmbeddedToolchainProjectPublisher.swift').read_text()
t=Path('toolchain-build/scripts/test-embedded-project-publisher.swift').read_text()
for needle in ('O_NOFOLLOW', 'openat(', 'renameat(', 'fsync(', 'commitIfNotCancelled', 'directorySynced'):
 assert needle in s, needle
assert 'MachOFixture.image' in t and 'build symlink' in t and 'cancel' in t
assert 'ProjectPublisherContracts.run()' in Path('toolchain-build/scripts/test-embedded-adapter.swift').read_text()
assert 'dlopen(' not in s and 'Process(' not in s
print('PASS: atomic publication/cancellation contracts bound to real Swift suite.')
PY
exec bash scripts/ios15/check-embedded-adapter.sh "$@"
