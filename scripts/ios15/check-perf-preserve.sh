#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
require_swift=0
case "${1:-}" in '') ;; --require-swift) require_swift=1 ;; *) exit 2 ;; esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/minis-perf-contract.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys,subprocess
r=Path('src/ios');out=Path(sys.argv[1]);agent=(r/'Providers/AgentProvider.swift').read_text()
# Actual canonical definitions and content enum; no copy of tested algorithms.
a=agent.index('struct AgentToolDefinition {');b=agent.index('/// Native reasoning payload',a)
defs=agent[a:b]
stubs='''
struct AgentMessage { var dbMessageId: String?; var parts: [AgentContentPart] }
final class BPETokenizer {
 static let shared = BPETokenizer()
 func countImageTokens(_ data: Data) -> Int { fatalError("Image tokenizer not covered by this harness") }
}
struct BrowserResourceMonitor { static func currentAppCPUPercent() -> Double { 0 } }
struct AppLogger {
 init(category: String) {}
 private static let lock = NSLock()
 private static var output: [String] = []
 static var lines: [String] { lock.lock(); defer { lock.unlock() }; return output }
 static func reset() { lock.lock(); output=[]; lock.unlock() }
 func info(_ line: String) { Self.lock.lock(); Self.output.append(line); Self.lock.unlock() }
 func warning(_ line: String) { info(line) }
}
'''
(out/'Dependencies.swift').write_text('import Foundation\n'+defs+stubs)
vm=(r/'Agent/Chat/AIChatViewModel.swift').read_text();ct=(r/'Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text();ss=(r/'Agent/Chat/AIChatViewModel+SSEStream.swift').read_text()
mgr=(r/'Agent/BrowserUse/BrowserUseManager.swift').read_text();ui=(r/'Views/Chat/ToolLiveSheet.swift').read_text();pbx=(r/'Minis.xcodeproj/project.pbxproj').read_text()
assert 'var fixedContextCache = FixedContextTokenCache()' in vm
assert 'fixedContextCache.measure(systemPrompt: userSystemPrompt, tools: tools)' in vm
assert 'static let maxConcurrentTools = 10' in ct
assert 'let stallTimeoutSeconds: TimeInterval = 120' in ss
assert 'case "build_project", "run_tests", "analyze_build_log", "verify_artifact", "run_toolchain_fixtures"' in ct
assert 'Self.preflightValidateToolCall' in ct and 'REFUSED truncated write' in ct
assert mgr.count('webView.takeSnapshot(configuration: config)')==1
assert mgr.count('try await captureBrowserSnapshot(')==2
assert ui.count('manager.captureBrowserSnapshot()')==2 and 'manager.webView.takeSnapshot' not in ui
assert 'config.snapshotWidth = NSNumber(value: plan.snapshotWidth)' in mgr
assert 'fullPageMaxHeight: CGFloat = 32_768' in mgr
assert pbx.count('BrowserSnapshotPolicy.swift in Sources')==2
# Key contracts remain unchanged; existing Unicode/context test now recognises the
# exact run-local memo rather than requiring the old literal call site.
for name in ['ToolPairingInvariantTests.swift','ParallelToolResultImageOrderTests.swift','StreamDropNoFinishTests.swift','SwitchModelNextRequestTests.swift','ContextMeasureOutboundTests.swift']:
 assert (r/'MinisTests/Standalone'/name).is_file()
print('PASS: production source extraction, unchanged safety gates, four screenshot paths and App Sources wiring')
PY
if ! command -v swiftc >/dev/null 2>&1; then
 echo 'SKIP: actual Swift compilation/execution and benchmark unavailable locally'
 [[ "$require_swift" -eq 0 ]] || exit 1
 exit 0
fi
swiftc -swift-version 5 -O -parse-as-library "$TMP/Dependencies.swift" \
 src/ios/Agent/Chat/ContextPolicy.swift src/ios/Diagnostics/PerfProbe.swift \
 src/ios/Agent/BrowserUse/BrowserSnapshotPolicy.swift \
 scripts/ios15/tests/test-perf-preserve.swift -o "$TMP/contract"
"$TMP/contract"
for test in ContextMeasureOutboundTests ToolPairingInvariantTests ParallelToolResultImageOrderTests StreamDropNoFinishTests SwitchModelNextRequestTests; do
 swift "src/ios/MinisTests/Standalone/$test.swift"
done
