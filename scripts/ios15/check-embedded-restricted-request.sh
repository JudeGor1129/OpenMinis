#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
require_swift=0
case "${1:-}" in
  "") ;;
  --require-swift) require_swift=1; shift ;;
  *) echo "FAIL: unknown argument: $1" >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || { echo "FAIL: unexpected arguments" >&2; exit 2; }
REQUEST=src/ios/Agent/Build/EmbeddedToolchainRestrictedRequest.swift
PROVIDER=src/ios/Agent/Build/EmbeddedToolchainBuildProvider.swift
SNAPSHOT=src/ios/Agent/Build/EmbeddedToolchainProjectSnapshot.swift
MATERIALIZER=src/ios/Agent/Build/EmbeddedToolchainProjectMaterializer.swift
HARNESS=toolchain-build/scripts/test-embedded-restricted-request.swift
for f in "$REQUEST" "$PROVIDER" "$SNAPSHOT" "$MATERIALIZER" "$HARNESS"; do [[ -f "$f" ]] || { echo "FAIL: missing $f" >&2; exit 1; }; done
TMP="$(mktemp -d "${TMPDIR:-/tmp}/om-restricted-request.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
python3 - "$PROVIDER" "$TMP/Models.swift" <<'PY'
from pathlib import Path
import sys
provider=Path(sys.argv[1]).read_text()
start=provider.index('enum EmbeddedToolchainLanguage:')
end=provider.index('@MainActor', start)
Path(sys.argv[2]).write_text('import Foundation\n\n'+provider[start:end])
request=Path('src/ios/Agent/Build/EmbeddedToolchainRestrictedRequest.swift').read_text()
materializer=Path('src/ios/Agent/Build/EmbeddedToolchainProjectMaterializer.swift').read_text()
harness=Path('toolchain-build/scripts/test-embedded-restricted-request.swift').read_text()
def need(ok,msg):
 if not ok: raise SystemExit('FAIL: restricted request policy: '+msg)
need('struct EmbeddedToolchainRestrictedRequest' in request,'request model missing')
need('snapshotFingerprint' in request and 'sourceFingerprints' in request,'snapshot/content binding missing')
need('EmbeddedToolchainExecutionAdapter' not in request,'request must not execute adapter')
need('context.executor' not in request and 'Process(' not in request,'request must not invoke shell')
need('EmbeddedToolchainRestrictedRequestBuilder.make' in harness,'request harness missing')
need('sourceFingerprintMismatch' in harness and 'missing link' in harness,'negative mutation coverage missing')
need('outputName' in materializer and 'operations.append(.link' in materializer,'materializer output operation binding missing')
print('PASS: pure-memory restricted request source policy and mutation boundaries present.')
PY
if ! command -v swiftc >/dev/null 2>&1; then
 echo 'SKIP: Swift restricted-request contracts (swiftc not found); policy is not behavior evidence.'
 [[ "$require_swift" -eq 0 ]] || { echo "FAIL: --require-swift requires actual Swift contracts" >&2; exit 1; }
 exit 0
fi
swiftc --version
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$TMP/Models.swift" "$SNAPSHOT" "$MATERIALIZER" "$REQUEST" "$HARNESS" -o "$TMP/restricted-request-contract"
"$TMP/restricted-request-contract"
echo 'PASS: actual Swift restricted-request contracts executed.'
