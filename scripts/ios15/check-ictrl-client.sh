#!/bin/sh
# [T-ictrl-envelope-v1] Source gate for the restored iCTRL client.
#
# The tool is an in-app client for the rootless daemon: encrypted envelope
# only, no shell, no downloads. These assertions keep that shape from drifting
# back into "run an external CLI" the way the removed integration worked.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLIENT="$ROOT/src/ios/Agent/Chat/ICTRLClient.swift"
fail=0

check() {
    if grep -q "$2" "$1" 2>/dev/null; then
        printf 'PASS  %s\n' "$3"
    else
        printf 'FAIL  %s\n' "$3"
        fail=$((fail + 1))
    fi
}

forbid() {
    if grep -q "$2" "$1" 2>/dev/null; then
        printf 'FAIL  %s\n' "$3"
        fail=$((fail + 1))
    else
        printf 'PASS  %s\n' "$3"
    fi
}

# 1. Envelope construction matches the daemon's v1 labels.
check "$CLIENT" 'ictrl-pair' 'pair label ictrl-pair present'
check "$CLIENT" 'ictrl-wrap' 'token wrap label present'
check "$CLIENT" 'ictrl-v1|enc-req' 'request encryption label present'
check "$CLIENT" 'ictrl-v1|enc-resp' 'response encryption label present'
check "$CLIENT" 'resp' 'response MAC label present'
check "$CLIENT" 'sharedSecretFromKeyAgreement' 'X25519 agreement via CryptoKit'
check "$CLIENT" 'HMAC<SHA256>' 'HMAC-SHA256 key schedule'

# 2. Pairing must verify the token binding before storing anything.
check "$CLIENT" 'tokenBindingMismatch' 'token fingerprint mismatch is fatal'
check "$CLIENT" 'completeFileProtectionUntilFirstUserAuthentication' 'session file is protected'
check "$CLIENT" 'posixPermissions: 0o600' 'session file is 0600'

# 3. Host policy: loopback or RFC1918, explicit port.
check "$CLIENT" 'only loopback or a private IPv4 address is accepted' 'host policy rejects public hosts'
check "$CLIENT" '127.0.0.1:8200' 'default endpoint is loopback'

# 4. Response authentication uses a constant-time compare.
check "$CLIENT" 'constantTimeEquals' 'constant-time tag compare'

# 5. No local execution, no downloads.
forbid "$CLIENT" 'Process(' 'no Process execution'
forbid "$CLIENT" 'NSTask' 'no NSTask'
forbid "$CLIENT" 'popen' 'no popen'
forbid "$CLIENT" 'executeCommand' 'no shell bridge'
forbid "$CLIENT" 'URLSession.shared.download' 'no client download'

# 6. Tool surface: definition, gate, dispatcher, display, settings, skill.
DEFS="$ROOT/src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift"
check "$DEFS" 'name: "ictrl_call"' 'tool definition present'
check "$DEFS" 'AgentToolSwitch.ictrl.isEnabled' 'definition is gated by the switch'

CT="$ROOT/src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift"
check "$CT" 'case "ictrl_call"' 'dispatcher handles ictrl_call'
check "$CT" 'ICTRLClient.call' 'dispatcher uses the in-app client'
check "$CT" 'ICTRLClient.pair' 'dispatcher can pair'

SSE="$ROOT/src/ios/Agent/Chat/AIChatViewModel+SSEStream.swift"
count=$(grep -c 'ictrl_call' "$SSE" 2>/dev/null || true)
if [ "${count:-0}" -ge 5 ]; then
    printf 'PASS  SSE stream shows iCTRL in %s places\n' "$count"
else
    printf 'FAIL  SSE stream has only %s iCTRL branch(es)\n' "${count:-0}"
    fail=$((fail + 1))
fi

SETTINGS="$ROOT/src/ios/Views/Settings/ToolsSettingsView.swift"
check "$SETTINGS" 'case ictrl = "agent.tools.ictrl.enabled"' 'switch case registered'
check "$SETTINGS" 'case "ictrl_call": return .ictrl' 'switch governs ictrl_call'
check "$SETTINGS" 'toolRow("iCTRL 手机控制"' 'settings row present'
check "$SETTINGS" 'case .ictrl: return false' 'switch defaults to off'

SKILL="$ROOT/src/ios/Shared/BundledSkillCatalog.swift"
check "$SKILL" 'static let ictrlVersion' 'bundled skill has a version'
check "$SKILL" 'ictrl-phone-control' 'bundled skill id restored'
check "$ROOT/src/ios/Agent/Session/SkillStore.swift" 'BundledSkillCatalog.ictrlContent' 'SkillStore installs the bundled skill'

PBX="$ROOT/src/ios/Minis.xcodeproj/project.pbxproj"
check "$PBX" 'ICTRLClient.swift in Sources' 'project compiles ICTRLClient.swift'
check "$PBX" 'BundledSkillCatalog.swift in Sources' 'project compiles BundledSkillCatalog.swift'

if [ "$fail" -ne 0 ]; then
    printf '\n%d iCTRL gate check(s) failed\n' "$fail"
    exit 1
fi
printf '\niCTRL client gate passed\n'
