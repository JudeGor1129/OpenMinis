#!/usr/bin/env bash
# Actual entry/parser/error contracts. Registry/SQLite are spies: no native LLVM.
set -euo pipefail
cd "$(dirname "$0")/../.."
require_swift=0
case "${1:-}" in
  '') ;;
  --require-swift) require_swift=1; shift ;;
  *) echo 'FAIL: unsupported argument' >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || exit 2
TMP="$(mktemp -d "${TMPDIR:-/tmp}/om-native-entry.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
root=Path('src/ios/Agent/Build'); out=Path(sys.argv[1])
def between(file,start,end):
 text=(root/file).read_text(); return text[text.index(start):text.index(end)]
models=(root/'BuildModels.swift').read_text()
tools=(root/'ProgrammingBuildTools.swift').read_text()
assert 'var isNativeEmbedded: Bool' in models
assert tools.count('request.provider?.isNativeEmbedded == true')==2
assert tools.count('Self.nativeInspection(request: request, provider: providerID)')==2
assert '$0.id == request.provider' in tools
assert 'installName == rootlessInstallName' in models
for token in ['testNativeWorkspaceRouting', 'testTargetAndParser', 'testLocalizedErrors']:
 assert token in Path('toolchain-build/scripts/test-native-build-entry.swift').read_text()
parts=[between('EmbeddedToolchainBuildProvider.swift','enum EmbeddedToolchainArchitecture:','enum EmbeddedToolchainLanguage:'),
       between('EmbeddedToolchainExecutionAdapter.swift','enum EmbeddedAdapterError:','struct EmbeddedAdapterArtifact:'),
       between('EmbeddedToolchainDebPackage.swift','struct EmbeddedDebMetadata:','/// Fixed-name project manifest'),
       between('BuildRunStore.swift','struct PersistedBuildRun:','actor BuildRunStore'),
       between('BuildProviders.swift','@MainActor\nprotocol BuildProvider','@MainActor\nenum BuildProviderRegistry'),
       between('BuildProjectDetector.swift','enum BuildToolError:','private extension String')]
(out/'Dependencies.swift').write_text('import Foundation\n\n'+'\n'.join(parts))
print('PASS: native-entry boundaries and actual source extraction verified.')
PY
if ! command -v swiftc >/dev/null 2>&1; then
  echo 'SKIP: native-entry Swift behavior (swiftc unavailable); source checks are not behavior evidence.'
  [[ "$require_swift" -eq 0 ]] || { echo 'FAIL: --require-swift requires actual compilation and execution' >&2; exit 1; }
  exit 0
fi
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$TMP/Dependencies.swift" src/ios/Agent/Build/BuildModels.swift \
  src/ios/Agent/Build/ProgrammingBuildTools.swift \
  toolchain-build/scripts/test-native-build-entry.swift -o "$TMP/native-entry-contract"
"$TMP/native-entry-contract"
echo 'PASS: actual build/runTests, Theos parser and error contracts executed (spies; no LLVM/output execution).'
