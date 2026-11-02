#!/usr/bin/env bash
# Independent contract gate: compile the ACTUAL adapter, not a behavioural copy.
# The stub only replaces OMToolchain/LLVM; this is not native runtime evidence.
set -euo pipefail
cd "$(dirname "$0")/../.."

require_swift=0
case "${1:-}" in
  '') ;;
  --require-swift) require_swift=1; shift ;;
  -h|--help) echo "usage: $0 [--require-swift]"; exit 0 ;;
  *) echo "FAIL: unknown argument: $1" >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || { echo 'FAIL: unexpected arguments' >&2; exit 2; }

ADAPTER=src/ios/Agent/Build/EmbeddedToolchainExecutionAdapter.swift
PROVIDER=src/ios/Agent/Build/EmbeddedToolchainBuildProvider.swift
HARNESS=toolchain-build/scripts/test-embedded-adapter.swift
for file in "$ADAPTER" "$PROVIDER" "$HARNESS"; do
  [[ -f "$file" ]] || { echo "FAIL: missing $file" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo 'FAIL: source policy requires python3' >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/om-embedded-adapter.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

python3 - "$ADAPTER" "$PROVIDER" "$HARNESS" "$TMP/Models.swift" <<'PY'
from pathlib import Path
import re, sys
adapter, provider, harness = [Path(p).read_text(encoding='utf-8') for p in sys.argv[1:4]]
def require(ok, message):
    if not ok:
        raise SystemExit('FAIL: embedded-adapter source policy: ' + message)

# Slice the real enums AND their validation helpers; do not reproduce models.
start = provider.index('enum EmbeddedToolchainLanguage:')
end = provider.index('@MainActor', start)
models = provider[start:end]
require('enum EmbeddedToolchainOperation:' in models, 'operation enum missing')
require('struct EmbeddedToolchainBuildProvider:' not in models, 'provider leaked into standalone compilation')
Path(sys.argv[4]).write_text('import Foundation\n\n' + models, encoding='utf-8')

# Generic shell-oriented provider stays unavailable. Separate reviewed UI
# wiring is a later gate, intentionally not a temporary source-policy needle.
provider_body = provider[end:]
require('state: .unavailable' in provider_body, 'generic provider availability must remain unavailable')
require(provider_body.count('.unavailable(await availability(for: context))') == 2,
        'generic build and test must remain unavailable')
require('context.executor' not in provider_body and '.execute(' not in provider_body,
        'generic provider must not execute an adapter or shell')
require('EmbeddedAdapterBridge' in adapter and 'EmbeddedAdapterCall' in adapter,
        'injectable bridge seam missing')
require(re.search(r'func\s+execute\s*\(\s*sources\s*:\s*\[String\s*:\s*String\]', adapter),
        'execute must accept the structured sources dictionary')
require('operations:' in adapter and 'cancellation:' in adapter, 'structured execution/cancellation API missing')
for pattern in (r'\bProcess\s*\(', r'\b(?:system|popen|posix_spawn|execve|dlopen)\s*\(',
                r'\b(?:ShellExecutor|ISHCommandExecutor)\b', r'context\.executor'):
    require(not re.search(pattern, adapter), 'adapter must not invoke a shell, subprocess or generated code: ' + pattern)
require(not re.search(r'func\s+execute\s*\([^)]*(?:argv|command|shell)\s*:', adapter),
        'raw argv/shell execution must not be a public adapter entry point')
require('class EmbeddedToolchainExecutionAdapter' not in harness and
        'actor EmbeddedToolchainExecutionAdapter' not in harness and
        'enum EmbeddedToolchainOperation:' not in harness,
        'harness must not contain a copy of the adapter or enum models')
require('@main' in harness and 'EmbeddedAdapterBridge' in harness,
        'a real executable Swift fake-bridge test is required')
# Never bypass the native pinned-content check just to make the fake work.
require('EmbeddedAdapterArtifact.digest(data) == Self.libSystemSHA256' in adapter,
        'native libSystem SHA-256 comparison must remain enforced')
require('"1ab02266a39491a8bd5a91ba36d5c8c8c6ac6efb92099e1091a1fd2370fc53e3"' in adapter,
        'native libSystem content pin must not be replaced with a fake-fixture hash')
require('O_NOFOLLOW' in adapter, 'native/generated input must reject symlinks')
header = Path('src/ios/Vendor/OMToolchain/OMToolchain.h').read_text(encoding='utf-8')
require('NS_SWIFT_NAME(runCC1(_:stdout:stderr:))' in header and
        'NS_SWIFT_NAME(runLinker(_:stdout:stderr:))' in header,
        'bridge needs explicit Swift names immune to Darwin stdio selector macros')
project = Path('src/ios/Minis.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
view = Path('src/ios/Views/Rootfs/EmbeddedAdapterDiagnosticsView.swift').read_text(encoding='utf-8')
settings = Path('src/ios/Views/Rootfs/RootfsBuildSettingsView.swift').read_text(encoding='utf-8')
workflow = Path('.github/workflows/ios15.yml').read_text(encoding='utf-8')
for filename in ('EmbeddedToolchainExecutionAdapter.swift', 'EmbeddedAdapterDiagnosticsView.swift'):
    require(project.count(filename + ' in Sources') == 2, filename + ' must be compiled by the main App')
require('EmbeddedAdapterDiagnosticsView()' in settings and 'EmbeddedToolchainExecutionAdapter.shared' in view,
        'fixed validation UI must use the lifetime shared adapter')
require('TextEditor' not in view and 'TextField' not in view, 'validation UI must not accept arbitrary source/argv')
require('onDisappear { token?.cancel() }' in view, 'leaving validation must request cancellation')
require(workflow.count('check-embedded-adapter.sh --require-swift') == 2,
        'both quick CI and full App build must require actual Swift contracts')
require('EmbeddedAdapterProcessState' in adapter and 'bridge is EmbeddedNativeAdapterBridge ? .native' in adapter,
        'native adapters must share all process-lifetime state')
print('PASS: source policy; real enum extraction; generic provider remains unavailable.')
print('PASS: validation-only UI wiring and process-lifetime native state are bound.')
PY

if ! command -v swiftc >/dev/null 2>&1; then
  echo 'SKIP: Swift fake-bridge execution (swiftc not found); source policy alone is NOT a behaviour test.'
  if [[ "$require_swift" -eq 1 ]]; then
    echo 'FAIL: --require-swift requires an actual swiftc compile and test run.' >&2
    exit 1
  fi
  exit 0
fi

swiftc --version
# Real Objective-C importer: fake Swift stubs cannot establish NSString** or
# NS_ENUM import contracts. Typecheck actual production code without LLVM link.
swiftc -swift-version 6 -strict-concurrency=complete -typecheck \
  -import-objc-header src/ios/Vendor/OMToolchain/OMToolchain.h \
  "$TMP/Models.swift" "$ADAPTER"
echo 'PASS: actual OMToolchain.h importer and adapter typecheck.'
# Strict Swift 6 checks apply to the harness and production adapter alike.
# No source rewriting, compiler-error suppression, App, SDK or LLVM linkage.
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$TMP/Models.swift" "$ADAPTER" "$HARNESS" -o "$TMP/embedded-adapter-contract"
"$TMP/embedded-adapter-contract"
echo 'PASS: actual Swift adapter compiled and fake-bridge contracts executed.'
echo 'NOTE: native SHA-256/evidence checks were not changed; real LLVM, signing, loading and device RSS remain separate gates.'
