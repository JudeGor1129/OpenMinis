#!/usr/bin/env bash
# These contracts share the adapter's valid Mach-O fixture and fake bridge.
set -euo pipefail
cd "$(dirname "$0")/../.."
for f in src/ios/Agent/Build/EmbeddedToolchainRestrictedExecution.swift toolchain-build/scripts/test-embedded-restricted-execution.swift; do
  [[ -s "$f" ]] || { echo "FAIL: missing or empty $f" >&2; exit 1; }
done
python3 - <<'PY'
from pathlib import Path
s=Path('src/ios/Agent/Build/EmbeddedToolchainRestrictedExecution.swift').read_text()
t=Path('toolchain-build/scripts/test-embedded-restricted-execution.swift').read_text()
assert 'captureDylib: captureVerifiedDylib' in s and 'verifiedArtifact:' in s
assert 'RestrictedExecutionContracts.run()' in Path('toolchain-build/scripts/test-embedded-adapter.swift').read_text()
assert 'cancelled' in t and 'FakeBridge' in t
assert 'publishVerifiedDylib' not in s and 'context.executor' not in s
print('PASS: restricted execution contracts are bound to the real adapter suite.')
PY
exec bash scripts/ios15/check-embedded-adapter.sh "$@"
