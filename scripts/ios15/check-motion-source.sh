#!/bin/bash
# Regression guards only: CI compilation and on-device UX checks required.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
from pathlib import Path
root = Path('src/ios')
chat = (root / 'Views/Chat/AIChatView.swift').read_text()
model = (root / 'Agent/Chat/AIChatViewModel.swift').read_text()
load = (root / 'Agent/Chat/AIChatViewModel+Persistence.swift').read_text()
modern = (root / 'Agent/MessageList/CollectionViewMessageListV3.swift').read_text()
helper = (root / 'Views/Chat/HelperSheet.swift').read_text()
motion = (root / 'Shared/MinisNavigationContainer.swift').read_text()
bka = (root / 'Agent/Background/BackgroundKeepAliveManager.swift').read_text()
audio = (root / 'Providers/Voice/AudioSessionCoordinator.swift').read_text()
def require(ok, message):
    if not ok: raise SystemExit('FAIL: ' + message)
legacy = chat.split('struct MinisLegacyTranscript:', 1)[1].split('private struct MinisLegacyTranscriptRow:', 1)[0]
container = legacy.split('private struct MinisLegacyToolDetailTarget:', 1)[0]
probe = legacy.split('private struct MinisLegacyScrollFollow:', 1)[1]
row = chat.split('private struct MinisLegacyTranscriptRow:', 1)[1]
require('ForEach(vm.messages.reversed())' in container and '.rotationEffect(.degrees(180))' in container,
        'latest messages must be laid out at native offset zero')
require('Timer(' not in legacy and 'setContentOffset(' not in legacy and 'scrollTo(' not in probe,
        'legacy viewport must never chase lazy numeric offsets or content growth')
# Installing the search callback on appear is not a scroll command. The
# callback runs when search navigates to a match (initial result or next/prev).
import re
search_callback = re.compile(
    r'^                    chatSearch\?\.onNavigate = \{ hit in\n'
    r'(?P<body>.*?)^                    \}\n', re.MULTILINE | re.DOTALL
)
callbacks = list(search_callback.finditer(container))
require(len(callbacks) == 1 and
        re.findall(r'proxy\.scrollTo\([^\n]*', callbacks[0]['body']) ==
        ['proxy.scrollTo(hit.key.messageId, anchor: .center)'],
        'search may only scroll to its selected result')
without_search_callback = search_callback.sub('', container, count=1)
# The remaining commands must each live in the named user jump handler.
for event, command in [
    ('.onReceive(vm.forceScrollToBottom)', 'proxy.scrollTo(bottomAnchor, anchor: .top)'),
    ('.onReceive(vm.forceScrollToTop)', 'proxy.scrollTo(first, anchor: .bottom)'),
]:
    require(event in without_search_callback, 'missing user jump handler: ' + event)
    handler = without_search_callback.split(event, 1)[1].split('\n                }', 1)[0]
    require(re.findall(r'proxy\.scrollTo\([^\n]*', handler.replace(' }', '')) == [command],
            'only the expected scroll command is allowed in ' + event)
require(without_search_callback.count('scrollTo(') == 2,
        'entry and history replacement must not issue automatic scroll commands')
for event in ['.onAppear {', '.onChange(of: vm.latestSessionAnchorRequest) {']:
    body = without_search_callback.split(event, 1)[1].split('\n                }', 1)[0]
    require('scrollTo(' not in body, 'session restoration must not scroll')
require('scroll.isTracking || scroll.isDragging || scroll.isDecelerating' in probe,
        'native gestures and momentum take priority')
require('scrollView?.panGestureRecognizer.removeTarget' in probe and 'observe(\\.contentOffset' not in probe,
        'scroll follow must avoid per-frame contentOffset observation')
require('MinisInvertedContextMenuBridge' in chat and 'UIContextMenuInteraction' in chat,
        'iOS15 inverted messages must use detached UIKit context menu')
require('interactionEndCheck?.cancel()' in probe and 'if userInteractionActive { checkInteractionEnd() }' in probe,
        'native momentum end must be detected without an idle timer')
require('.sheet(item: $toolDetail)' in container and '.sheet(' not in row,
        'task windows must be owned by a stable transcript, never recycled rows')
require('tools.append(selected)' in row and 'detailBlock: detailBlock' in row,
        'task selection must keep the tapped block in a nonempty snapshot')
require('if #available(iOS 16.0, *)' in helper and
        'MinisLegacyTranscript(vm: vm, bottomInset: 16, readOnly: true)' in helper,
        'child transcripts must use the same iOS15 read-only renderer')
require('@Published private(set) var latestSessionAnchorRequest' in model and
        'vm.$latestSessionAnchorRequest' in modern and 'vm.requestLatestSessionAnchor()' in chat,
        'cached session intent must survive renderer binding timing')
require('!vm.isLoadingSession || vm.isShowingHistoryPreview' in modern and
        load.index('isShowingHistoryPreview = !preview.isEmpty') < load.index('messages = preview'),
        'tail preview must publish before the full-history reconstruction completes')
require('lastSessionAnchorRequest = vm?.latestSessionAnchorRequest' in modern and
        '!cv.isTracking, !cv.isDragging, !cv.isDecelerating' in modern,
        'dragging must discard stale restoration requests')
require('UIAccessibility.isReduceMotionEnabled' in motion and 'dampingFraction: 0.86' in motion,
        'shared motion must support Reduce Motion and use the unified spring')
build = Path('scripts/ios15/build-diagnostics.sh').read_text()
package = Path('scripts/ios15/package-trollstore.sh').read_text()
require('-configuration Release' in build and 'SWIFT_OPTIMIZATION_LEVEL=-O' in build,
        'test IPA must use optimized Release compilation')
require('Release-iphoneos/Minis.app' in package and 'Debug-iphoneos' not in package,
        'package must consume the optimized app')
require('hasRunningBackgroundSupport' in bka and 'backgroundAudioStatus' in bka,
        'background UI and task expiry must use actual running legs')
require('beginWhenReady(.backgroundKeepAlive)' in bka and
        'silentAudioRetry' in bka and 'startSilentAudioEngine' in bka,
        'silent audio must wait for activation and retry bounded failures')
require('completion: @escaping @MainActor @Sendable' in audio,
        'audio session readiness must be delivered asynchronously')
print('PASS: zero-travel session entry, native gestures, stable task sheets, child renderer, optimized IPA and actual background keep-alive state.')
PY
