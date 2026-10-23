#!/bin/bash
# Regression guards only: CI Swift compilation and on-device UX checks required.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
from pathlib import Path
root = Path('src/ios')
chat = (root / 'Views/Chat/AIChatView.swift').read_text()
model = (root / 'Agent/Chat/AIChatViewModel.swift').read_text()
load = (root / 'Agent/Chat/AIChatViewModel+Persistence.swift').read_text()
modern = (root / 'Agent/MessageList/CollectionViewMessageListV3.swift').read_text()
motion = (root / 'Shared/MinisNavigationContainer.swift').read_text()
def require(ok, message):
    if not ok: raise SystemExit('FAIL: ' + message)
legacy = chat.split('private struct MinisLegacyTranscript:', 1)[1].split('private struct MinisLegacyTranscriptRow:', 1)[0]
require('Timer(' not in legacy and 'setContentOffset(' not in legacy,
        'legacy restoration must not chase lazy numeric content offsets')
require('proxy.scrollTo(bottomAnchor, anchor: .bottom)' in legacy,
        'restore through the real tail anchor')
require('transaction.disablesAnimations = true' in legacy,
        'session restoration must not animate through history')
require('scroll.isTracking || scroll.isDragging || scroll.isDecelerating' in legacy,
        'native gestures and momentum take priority')
require('scrollView?.panGestureRecognizer.removeTarget' in legacy and 'observations.removeAll()' in legacy,
        'scroll observations must be dismantled')
require('@Published private(set) var latestSessionAnchorRequest' in model,
        'session restore intent must survive renderer subscription timing')
require('vm.$latestSessionAnchorRequest' in modern and 'vm.requestLatestSessionAnchor()' in chat,
        'cached-session entry must use a replayable restoration request')
require('!vm.isLoadingSession || vm.isShowingHistoryPreview' in modern,
        'tail preview must be displayable during full reconstruction')
require(load.index('isShowingHistoryPreview = !preview.isEmpty') < load.index('messages = preview'),
        'publish preview permission before messages')
require('UIAccessibility.isReduceMotionEnabled' in motion and 'dampingFraction: 1' in motion,
        'shared motion must support Reduce Motion and avoid layout bounce')
require('.animation(MinisMotion.feedback, value: forcePullToast)' in chat,
        'chat feedback must use the local short motion token')
build = Path('scripts/ios15/build-diagnostics.sh').read_text()
package = Path('scripts/ios15/package-trollstore.sh').read_text()
require('-configuration Release' in build and 'SWIFT_OPTIMIZATION_LEVEL=-O' in build,
        'test IPA must use optimized Release compilation')
require('Release-iphoneos/Minis.app' in package and 'Debug-iphoneos' not in package,
        'package must consume the optimized app, not a Debug product')
print('PASS: motion tokens, replayable entry, visible tail preview, native gesture priority, teardown and optimized IPA.')
PY
