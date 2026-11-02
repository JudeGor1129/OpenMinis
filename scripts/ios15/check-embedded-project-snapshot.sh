#!/usr/bin/env bash
# Source policy and macOS Swift contracts for the immutable project snapshot gate.
set -euo pipefail
cd "$(dirname "$0")/../.."
SNAPSHOT=src/ios/Agent/Build/EmbeddedToolchainProjectSnapshot.swift
HARNESS=toolchain-build/scripts/test-embedded-project-snapshot.swift
PROJECT=src/ios/Minis.xcodeproj/project.pbxproj
TESTS=src/ios/MinisTests/ProgrammingBuildToolsTests.swift
for f in "$SNAPSHOT" "$HARNESS" "$TESTS" "$PROJECT"; do [[ -f "$f" ]] || { echo "FAIL: missing $f" >&2; exit 1; }; done
python3 - <<'PY'
from pathlib import Path
import re
snapshot=Path('src/ios/Agent/Build/EmbeddedToolchainProjectSnapshot.swift').read_text()
harness=Path('toolchain-build/scripts/test-embedded-project-snapshot.swift').read_text()
pbx=Path('src/ios/Minis.xcodeproj/project.pbxproj').read_text()
tests=Path('src/ios/MinisTests/ProgrammingBuildToolsTests.swift').read_text()
def need(x,msg):
 if not x: raise SystemExit('FAIL: snapshot policy: '+msg)
need('struct EmbeddedToolchainProjectSnapshot' in snapshot,'snapshot model missing')
need('static func build(files:' in snapshot,'builder missing')
need('SHA256' in snapshot and 'fingerprint' in snapshot,'content fingerprint missing')
need('maxDependencyDepth' in snapshot and 'dependencyCycle' in snapshot,'dependency bounds missing')
need('Input/' not in snapshot and 'FileHandle' not in snapshot and 'Process(' not in snapshot,'snapshot must not read filesystem or spawn process')
need('EmbeddedToolchainProjectSnapshot.swift' in pbx,'snapshot file not in project')
need('B1000000000000000000000B' in pbx and 'B2000000000000000000000B' in pbx,'snapshot PBX objects missing')
need('testEmbeddedProjectSnapshotBuildsDeterministicallyAndScansLocalHeaders' in tests,'XCTest snapshot coverage missing')
need('@main' in harness and 'EmbeddedToolchainProjectSnapshotBuilder.build' in harness,'real snapshot Swift harness missing')
for token in ('#include <stdio.h>','dependency depth','cycle','fingerprint','__asm__'):
 need(token in harness,'snapshot negative coverage missing '+token)
print('PASS: immutable project snapshot source policy, PBX wiring and test coverage are present.')
PY
if ! command -v swiftc >/dev/null 2>&1; then
 echo 'SKIP: Swift project-snapshot contracts (swiftc not found); policy is not a behavior test.'
 exit 0
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/om-project-snapshot.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
swiftc --version
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$SNAPSHOT" "$HARNESS" -o "$TMP/project-snapshot-contract"
"$TMP/project-snapshot-contract"
echo 'PASS: actual Swift project-snapshot contracts executed.'
