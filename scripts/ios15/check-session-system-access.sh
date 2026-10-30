#!/usr/bin/env bash
# Execute pure ownership/policy tests and typecheck real permission/UI sources.
# This never executes a persona helper or modifies a system file.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if [ "$(uname -s)" != Darwin ] || ! command -v xcrun >/dev/null 2>&1; then
  echo 'UNAVAILABLE: real Foundation execution and SwiftUI typecheck require macOS/Xcode.' >&2
  exit 2
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/om-session-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MACSDK="$(xcrun --sdk macosx --show-sdk-path)"
B=src/ios/Diagnostics
xcrun --sdk macosx clang -isysroot "$MACSDK" -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror \
  -I "$B" tools/privileged-helper/tests/SessionPolicyTests.m -framework Foundation -o "$WORK/policy-tests"
"$WORK/policy-tests"
for SOURCE in "$B/PrivilegedHelperBridge.m" tools/privileged-helper/MinisPrivilegedHelper.m; do
  xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -isysroot "$SDK" \
    -fobjc-arc -fblocks -Wall -Wextra -Werror -fsyntax-only "$SOURCE"
done

# Extract the real menu structs; verify the REAL call-site argument list and
# typecheck its matching initializer without unrelated chat-renderer code.
python3 - "$WORK/menus.swift" <<'PY'
from pathlib import Path
import re, sys
s=Path('src/ios/Views/Chat/AIChatView.swift').read_text()
a=s.index('private struct ChatTrailingMenu:')
z=s.index('// MARK: - Move To Session Sheet',a)
menus=s[a:z]
k=s.index('private struct ChatToolbarKey:')
ke=s.index('/// [T-ios-navbar-toolbar-host] Zero-footprint host',k)
key=s[k:ke]
def contract(type_name, decl, call, end_marker):
    fields=re.findall(r'^    let (\w+): (.+)$',decl,re.M)
    start=s.index(call)
    call_body=s[start:s.index(end_marker,start)]
    labels=re.findall(r'^            (\w+):',call_body,re.M)
    # Include the first parameter if the call and label share the same line.
    same_line=re.match(r'[^\n]*\([ \t]*(\w+):',call_body)
    if same_line: labels.insert(0,same_line.group(1))
    assert labels==[n for n,t in fields], (type_name,labels,fields)
    def value(t):
        return {'Bool':'false','SessionSystemAccessMode':'.disabled','String?':'nil',
                '() -> Void':'{}','(Bool) -> Void':'{ _ in }','NavTitleKey':'NavTitleKey()'}[t.strip()]
    return '@MainActor\nprivate func '+type_name+'InitializerContract() {\n _ = '+type_name+'(\n'+',\n'.join(n+': '+value(t) for n,t in fields)+'\n)\n}\n'
u=menus[menus.index('private struct ChatTrailingMenuButton:'):]
u=u[:u.index('    /// The displayed-state snapshot')]
ctor=contract('ChatTrailingMenuButton',u,'ChatTrailingMenuButton(','    // MARK: - New Chat (menu entry)')
ctor+=contract('ChatToolbarKey',key,'ChatToolbarKey(','    /// [T-codex-fast-mode] True when the session')
Path(sys.argv[1]).write_text('import SwiftUI\nimport UIKit\nprivate struct NavTitleKey: Equatable {}\n'+key+menus+ctor)
print('PASS: actual UIKit menu and toolbar call sites match all stored initializer fields')
PY
xcrun --sdk iphoneos swiftc -typecheck -swift-version 5 -target arm64-apple-ios15.0 \
  -sdk "$SDK" -module-cache-path "$WORK/modules" -import-objc-header "$B/PrivilegedHelperBridge.h" \
  scripts/ios15/session-system-access-typecheck.swift \
  src/ios/Shared/MinisNavigationContainer.swift \
  src/ios/Agent/Chat/AIChatViewModel+SystemFileTools.swift \
  src/ios/Views/Settings/SystemAccessSettingsView.swift "$WORK/menus.swift"
echo 'PASS: actual session policy execution, iOS15 bridge/helper syntax, permission/client/panel/settings/menu Swift typecheck.'
echo 'Not tested: full Minis App, installation, device writes, PAC or appearance/gesture runtime.'
