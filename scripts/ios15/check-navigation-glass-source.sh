#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
nav=src/ios/Shared/MinisNavigationContainer.swift
chat=src/ios/Views/Chat/AIChatView.swift
modern=src/ios/Views/ContentView.swift
legacy=src/ios/Views/LegacyContentView.swift
share=src/ios/Views/Chat/ChatShareSelectionView.swift
media=src/ios/Views/Chat/MinisMediaViews.swift
message=src/ios/Views/Chat/ChatMessageViews.swift
orb=src/ios/Shared/ThinkingOrb.swift
req(){ grep -Fq "$2" "$1" || { printf 'FAIL: %s\n' "$3"; exit 1; }; }
req "$nav" 'struct MinisNavigationChromeScope: ViewModifier' 'shared navigation style'
req "$nav" 'AnyShapeStyle(Material.ultraThin)' 'iOS16-25 navigation material'
req "$nav" 'reduceTransparency || colorSchemeContrast == .increased' 'opaque accessibility fallback'
# Guard the actual iOS 15 surfaces, not just the presence of page annotations.
req "$nav" 'MinisLegacyBarBackdrop(solid: reduceTransparency' 'iOS15 installs a page-scoped backdrop'
req "$nav" 'target[keyPath: slot] = style' 'navigation item receives the appearance'
req "$legacy" '.modifier(MinisLegacyControlSurface(shape: Capsule()))' 'legacy home toolbar capsule'
req "$legacy" '.background(Circle().fill(Color(UIColor.systemBlue)))' 'legacy new conversation button'
req "$legacy" '.labelStyle(LegacySettingsLabelStyle(' 'legacy settings rows'
req "$chat" '.modifier(MinisLegacyControlSurface(shape: shape))' 'legacy composer surface'
req "$nav" 'func minisNavigationChrome(' 'navigation style entry point'
req "$modern" '.minisNavigationChrome()' 'modern navigation roots'
req "$legacy" '.minisNavigationChrome()' 'legacy navigation roots'
req "$chat" 'MinisToolbarMenu.present(from: button, items: parent.menuItems())' 'session menu uses persistent UIKit button'
req "$chat" 'attributes: sessionAccessAvailable ? [] : [.disabled], action: onSessionAccess' 'session permission menu action respects availability'
req "$chat" 'onClearChat: { showClearChatConfirm = true }' 'Clear Chat retains confirmation'
req "$chat" 'if #available(iOS 17.0, *), iCloudSyncEnabled {' 'sync menu stays gated by OS and preference'
req "$chat" 'checked: screenAwake, action: onToggleSessionAwake' 'Keep Screen Awake state is shown'
req "$nav" 'controller.modalPresentationStyle = .popover' 'menu stays anchored to the toolbar'
req "$nav" 'popover.sourceView = source' 'popover is anchored to the presenting button'
req "$nav" 'controller.dismiss(animated: true) { [weak source] in' 'menu closes before executing the action'
req "$chat" 'SiriFlowBorder(' 'colored composer border'
req "$chat" 'AngularGradient(' 'colored border gradient'
req "$chat" 'TimelineView(.periodic(from: .now, by: 1.0 / 30.0))' 'composer animation'
req "$orb" 'public struct ThinkingOrb: View' 'ThinkingOrb resource'
req "$orb" 'TimelineView(.animation(minimumInterval: 1.0 / 30.0))' 'ThinkingOrb timeline'
req "$share" '.minisNavigationChrome()' 'session share submenu'
req "$media" '.minisNavigationChrome()' 'file preview submenus'
if grep -Fq 'glassEffect(' "$message"; then echo 'FAIL: message content glass'; exit 1; fi
folder=$(sed -n '/private struct FolderSurface:/,/private struct FolderCardBackground:/p' "$modern")
printf '%s' "$folder" | grep -Fq 'content.background(shape.fill(MinisHomeGroupInk.modern))'
if printf '%s' "$folder" | grep -Eq 'glassEffect\(|\.stroke\('; then echo 'FAIL: conversation group decoration'; exit 1; fi
panel=$(sed -n '/private struct MinisToolbarMenuPanel:/,/struct MinisToolbarMenuTrigger:/p' "$nav")
if printf '%s' "$panel" | grep -Eq '(Divider|List|Form)\s*[(\{]'; then echo 'FAIL: toolbar menu row separators'; exit 1; fi
menu=$(sed -n '/private func menuItems()/,/return items/p' "$chat")
for action in 'Share Conversation' 'Search in Conversation' 'Keep Screen Awake' 'New Chat' 'Compact Messages' 'Clear Chat' 'Force iCloud Sync' 'Force Pull Messages' 'Open Terminal' '编译器' 'Open Browser' 'Browse Chat Files' 'Skills in Session' 'MCPs in Session' 'Memories in Session' 'Speak Responses' '本会话权限' 'Enhanced Cache' 'Enable Fast Mode' 'Token Usage' 'Copy Requests' 'Copy Session Data'; do
    printf '%s' "$menu" | grep -Fq "$action" || { printf 'FAIL: session menu action missing: %s\n' "$action"; exit 1; }
done
for view in "$legacy" "$modern"; do
    menu=$(sed -n '/MinisToolbarMenuTrigger(/,/Keep Screen Awake/p' "$view")
    for action in 'Shell Terminal' 'Rootfs Management' 'Open Browser' 'Browser Settings' 'Keep Screen Awake'; do
        printf '%s' "$menu" | grep -Fq "$action" || { printf 'FAIL: home menu action missing: %s\n' "$action"; exit 1; }
    done
done
for page in ProviderInstancesView ModelGroupsView; do
    if grep -Fq 'MinisPageIntro(' "src/ios/Views/Providers/$page.swift"; then echo "FAIL: $page still has its summary card"; exit 1; fi
done
req "$modern" 'navigationDestination(for: SettingsDestination.self)' 'settings push destinations remain registered'
req "$modern" 'SettingsDestination.providerDetail' 'settings deep-link destinations remain available'
req "$chat" 'static let userBubbleBackground = MinisPageInk.sentMessage' 'solid sent message fill'
req "$message" 'shape.fill(ChatColors.userBubbleBackground)' 'sent bubble uses solid fill'
req "$chat" '.fill(message.isQueued ? Color.clear : ChatColors.userBubbleBackground)' 'legacy bubble uses solid fill'
# Check attachment within each hosted page's modifier chain (not once per file).
python3 - <<'CHECK_PAGES'
from pathlib import Path
import re

root = Path("src/ios")
checked = 0
missing = []
for path in sorted(root.rglob("*.swift")):
    parts = path.relative_to(root).parts
    if parts[0] not in {"Views", "Agent", "Shared", "WebApp"} or "Debug" in parts:
        continue
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        title = re.match(r"^([ \t]*)\.navigation(?:Bar)?Title\(", line)
        if not title:
            continue
        indent = title.group(1)
        # Allow a local mount either adjacent to the title or immediately
        # after title display mode / a one-line toolbar declaration.
        neighbors = lines[max(0, i - 1):i] + lines[i + 1:i + 4]
        if not any(s.startswith(indent + ".minisNavigationChrome(") for s in neighbors):
            missing.append(f"{path}:{i + 1}: {line.strip()}")
        checked += 1
if missing:
    raise SystemExit("FAIL: page-local navigation chrome missing:\n" + "\n".join(missing))
print(f"PASS: {checked} production title chains have a page-local navigation preference.")
CHECK_PAGES
printf 'PASS: navigation-only material, opaque messages, anchored menus, SiriFlowBorder and ThinkingOrb.\n'
printf 'NOTE: source contract is not a Swift build or device test.\n'
