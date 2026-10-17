#!/bin/bash
# Compile the production precedence resolver; verify all 18 optional-input cases.
set -euo pipefail
cd "$(dirname "$0")/../.."
SWIFT="$(xcrun --find swift)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
sed -n '/^enum MinisSkillEnablement {/,/^\/\/ END Skill enablement precedence/p' \
  src/ios/Agent/Session/SkillStore.swift > "$OUT/main.swift"
cat >> "$OUT/main.swift" <<'SWIFT'
var cases = 0
let choices: [Bool?] = [nil, false, true]
for session in choices {
    for group in choices {
        for global in [false, true] {
            let expected: Bool
            if let session { expected = session }
            else if let group { expected = group }
            else { expected = global }
            precondition(MinisSkillEnablement.resolve(session: session, group: group, global: global) == expected)
            cases += 1
        }
    }
}
// Removing a session choice reveals the group, not the global default.
precondition(MinisSkillEnablement.resolve(session: nil, group: false, global: true) == false)
precondition(MinisSkillEnablement.resolve(session: true, group: false, global: false) == true)
print("PASS: \(cases) production skill precedence combinations + reset/explicit-choice cases")
SWIFT
"$SWIFT" "$OUT/main.swift"
# Wiring guards complement, but do not replace, the full app compilation.
grep -q 'await SkillStore.shared.refreshGroupDefaults(sessionId: sid)' src/ios/Agent/Chat/AIChatViewModel.swift
[[ "$(grep -c 'if let skillFragment = taskSkillFragment' src/ios/Agent/Chat/AIChatViewModel.swift)" == 2 ]]
grep -q 'func resetSessionOverrides(sessionId: String)' src/ios/Agent/Session/SkillStore.swift
grep -q 'skillConfigurationSource(skill.id, sessionId:' src/ios/Views/Chat/SessionSkillsView.swift
echo 'PASS: task snapshot, fallback, reset and UI source wiring guards'
