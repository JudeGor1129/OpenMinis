#!/usr/bin/env bash
# Compile the actual pure-memory snapshot materializer and its contracts.
set -euo pipefail
cd "$(dirname "$0")/../.."
SNAPSHOT=src/ios/Agent/Build/EmbeddedToolchainProjectSnapshot.swift
MATERIALIZER=src/ios/Agent/Build/EmbeddedToolchainProjectMaterializer.swift
HARNESS=toolchain-build/scripts/test-embedded-project-materializer.swift
for f in "$SNAPSHOT" "$MATERIALIZER" "$HARNESS"; do [[ -f "$f" ]] || { echo "FAIL: missing $f" >&2; exit 1; }; done
python3 - <<'PY'
from pathlib import Path
snapshot=Path('src/ios/Agent/Build/EmbeddedToolchainProjectSnapshot.swift').read_text()
materializer=Path('src/ios/Agent/Build/EmbeddedToolchainProjectMaterializer.swift').read_text()
harness=Path('toolchain-build/scripts/test-embedded-project-materializer.swift').read_text()
def need(ok,msg):
 if not ok: raise SystemExit('FAIL: materializer policy: '+msg)
need('static func plan(snapshot:' in materializer,'plan API missing')
need('var operations: [EmbeddedToolchainOperation]' in materializer and 'operations.append(.compile' in materializer and 'operations.append(.link' in materializer,'typed operation conversion missing')
need('Data(contentsOf:' not in materializer and 'Process(' not in materializer,'materializer must stay pure memory')
need('EmbeddedToolchainExecutionAdapter' not in materializer,'materializer must not execute adapter')
need('include order' in harness and 'project.dylib' in harness,'materializer contract coverage missing')
need('EmbeddedToolchainProjectMaterializer.plan' in harness,'actual materializer harness missing')
print('PASS: pure-memory materializer source policy and operation boundary present.')
PY
if ! command -v swiftc >/dev/null 2>&1; then
  echo 'SKIP: Swift materializer contracts (swiftc not found); policy is not behavior evidence.'
  exit 0
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/om-project-materializer.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
swiftc --version
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$SNAPSHOT" "$MATERIALIZER" "$HARNESS" -o "$TMP/materializer-contract"
"$TMP/materializer-contract"
echo 'PASS: actual Swift snapshot materializer contracts executed.'
