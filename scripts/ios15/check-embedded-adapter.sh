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
SNAPSHOT=src/ios/Agent/Build/EmbeddedToolchainProjectSnapshot.swift
MATERIALIZER=src/ios/Agent/Build/EmbeddedToolchainProjectMaterializer.swift
REQUEST=src/ios/Agent/Build/EmbeddedToolchainRestrictedRequest.swift
RESTRICTED_EXECUTION=src/ios/Agent/Build/EmbeddedToolchainRestrictedExecution.swift
PUBLISHER=src/ios/Agent/Build/EmbeddedToolchainProjectPublisher.swift
PROVIDER=src/ios/Agent/Build/EmbeddedToolchainBuildProvider.swift
HARNESS=toolchain-build/scripts/test-embedded-adapter.swift
EXECUTION_HARNESS=toolchain-build/scripts/test-embedded-restricted-execution.swift
PUBLISHER_HARNESS=toolchain-build/scripts/test-embedded-project-publisher.swift
for file in "$ADAPTER" "$SNAPSHOT" "$MATERIALIZER" "$REQUEST" "$RESTRICTED_EXECUTION" "$PUBLISHER" "$PROVIDER" "$HARNESS" "$EXECUTION_HARNESS" "$PUBLISHER_HARNESS"; do
  [[ -s "$file" ]] || { echo "FAIL: missing or empty $file" >&2; exit 1; }
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
snapshot=Path('src/ios/Agent/Build/EmbeddedToolchainProjectSnapshot.swift').read_text()
materializer=Path('src/ios/Agent/Build/EmbeddedToolchainProjectMaterializer.swift').read_text()
request=Path('src/ios/Agent/Build/EmbeddedToolchainRestrictedRequest.swift').read_text()
restricted=Path('src/ios/Agent/Build/EmbeddedToolchainRestrictedExecution.swift').read_text()
publisher=Path('src/ios/Agent/Build/EmbeddedToolchainProjectPublisher.swift').read_text()
view=Path('src/ios/Views/Rootfs/EmbeddedProjectBuildView.swift').read_text()
settings=Path('src/ios/Views/Rootfs/RootfsBuildSettingsView.swift').read_text()
for token, body in [('static func loadProject(root: URL)', snapshot), ('openat(', snapshot), ('O_NOFOLLOW', snapshot),
                    ('static func plan(snapshot:', materializer), ('operations.append(.link', materializer),
                    ('struct EmbeddedToolchainRestrictedRequest', request), ('sourceFingerprints', request),
                    ('captureDylib: captureVerifiedDylib', restricted), ('verifiedArtifact:', restricted),
                    ('publishVerifiedDylib', publisher), ('renameat(', publisher),
                    ('EmbeddedProjectBuildView()', settings), ('loadProject(root: url)', view),
                    ('captureVerifiedDylib: true', view)]:
    require(token in body, 'deliverable project-build phase wiring missing: ' + token)
require('publishVerifiedDylib' not in provider and 'EmbeddedToolchainRestrictedExecutor' not in provider,
        'generic Provider must remain disconnected from verification executor and publication')
require('context.executor' not in provider and provider.count('.unavailable(await availability(for: context))') == 2,
        'generic build/test Provider must remain unavailable and shell-free')
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
require('EmbeddedAdapterArtifact.digest(data) == expectedHash' in adapter and
        'expectedHash: Self.libSystemSHA256' in adapter and 'expectedHash: Self.objcRuntimeSHA256' in adapter,
        'native libSystem SHA-256 comparison must remain enforced')
require('"1ab02266a39491a8bd5a91ba36d5c8c8c6ac6efb92099e1091a1fd2370fc53e3"' in adapter,
        'native libSystem content pin must not be replaced with a fake-fixture hash')
require('0x2c' in adapter and 'cryptid=0' in adapter and
        'command == 0x2c' in adapter and 'word(cursor + 16) == 0' in adapter and
        'word(cursor + 20) == 0' in adapter and '0x21]' not in adapter,
        'pinned iOS dylib must admit only bounded LC_ENCRYPTION_INFO_64 with cryptid=0')
for rule in ('encrypted_output_cryptid_nonzero', 'encryption_reserved_padding_nonzero',
             'encryption_range_outside_payload', 'encryption_range_outside_text_segment',
             'encryption_command_size_or_duplicate'):
    require(rule in adapter, 'unsafe LC_ENCRYPTION_INFO_64 rejection missing: ' + rule)
require('MachOFixture.image(filetype: 6' in harness and 'try await encryptionPolicy()' in harness,
        'zero-cryptid positive and unsafe encryption metadata mutation tests are required')
require('f7858c08290826dd443b3981e85bb7d908a2318f53a9c61530de12b9fbc33d4a' in harness,
        'actual-linker parser fixture hash binding is missing')
require('O_NOFOLLOW' in adapter, 'native/generated input must reject symlinks')
header = Path('src/ios/Vendor/OMToolchain/OMToolchain.h').read_text(encoding='utf-8')
require('swift_name("runCC1(_:stdout:stderr:)")' in header and
        'swift_name("runLinker(_:stdout:stderr:)")' in header,
        'bridge needs literal Swift names immune to nested Darwin stdio macro expansion')
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

# A real Clang/LLD-linked Mach-O exercises load commands absent from early
# synthetic fakes. It is bytes for inspection only, never executed or loaded.
python3 - "$TMP/real-linker.dylib" <<'PY'
from pathlib import Path
import base64, hashlib, json, sys, zlib
fixture = json.loads(Path('toolchain-build/fixtures/adapter-ios15-lld-dylib.json').read_text())
assert fixture['bytes'] == 49336 and fixture['sha256'] == 'f7858c08290826dd443b3981e85bb7d908a2318f53a9c61530de12b9fbc33d4a'
compressed = base64.b64decode(fixture['data'], validate=True)
assert len(compressed) <= 4096
inflater = zlib.decompressobj()
data = inflater.decompress(compressed, fixture['bytes'] + 1)
assert inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail
assert len(data) == fixture['bytes'] and hashlib.sha256(data).hexdigest() == fixture['sha256']
Path(sys.argv[1]).write_bytes(data)
print('PASS: nonexecuted real Clang/LLD fixture hash and decompression (not pinned native ld64 evidence).')
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
  "$TMP/Models.swift" "$SNAPSHOT" "$MATERIALIZER" "$ADAPTER" "$REQUEST" "$RESTRICTED_EXECUTION" "$PUBLISHER"
echo 'PASS: actual OMToolchain.h importer and project integration sources typecheck.'
# The product screen must also typecheck against the real iOS 15 SwiftUI/UIKit
# SDK before a costly full App build. No view stubs or source rewriting.
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
swiftc -swift-version 6 -strict-concurrency=complete -typecheck \
  -sdk "$IOS_SDK" -target arm64-apple-ios15.0 \
  -import-objc-header src/ios/Vendor/OMToolchain/OMToolchain.h \
  "$TMP/Models.swift" "$SNAPSHOT" "$MATERIALIZER" "$ADAPTER" "$REQUEST" "$RESTRICTED_EXECUTION" "$PUBLISHER" \
  src/ios/Views/Rootfs/EmbeddedProjectBuildView.swift
echo 'PASS: actual restricted project screen typechecked with iOS 15 SwiftUI/UIKit SDK.'
# Strict Swift 6 checks compile the actual snapshot/materializer/request,
# executor, publisher, adapter and fake-bridge integration contracts.
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$TMP/Models.swift" "$SNAPSHOT" "$MATERIALIZER" "$ADAPTER" "$REQUEST" "$RESTRICTED_EXECUTION" "$PUBLISHER" "$HARNESS" "$EXECUTION_HARNESS" "$PUBLISHER_HARNESS" -o "$TMP/embedded-adapter-contract"
"$TMP/embedded-adapter-contract" "$TMP/real-linker.dylib"
echo 'PASS: actual Swift adapter compiled and fake-bridge contracts executed.'
echo 'NOTE: native SHA-256/evidence checks were not changed; real LLVM, signing, loading and device RSS remain separate gates.'
