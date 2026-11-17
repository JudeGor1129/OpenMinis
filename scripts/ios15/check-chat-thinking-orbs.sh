#!/bin/sh
# Source gate for the Thinking Orbs status animation change.
#
# Two visible states moved to ThinkingOrbs: the session transcript's busy
# line and the model-status orb beside the navigation title. The orb renderer
# also gained a still-frame gate so a toolbar or list never runs a 60 Hz
# timeline in the background. These assertions pin the structure and the
# spacing contract that keeps the newest message near the composer.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ORB="$ROOT/src/ios/Shared/ThinkingOrb.swift"
VIEW="$ROOT/src/ios/Views/Chat/AIChatView.swift"
fail=0

check() {
    if grep -Fq "$2" "$1" 2>/dev/null; then
        printf 'PASS  %s\n' "$3"
    else
        printf 'FAIL  %s\n' "$3"
        fail=$((fail + 1))
    fi
}

forbid() {
    if grep -Fq "$2" "$1" 2>/dev/null; then
        printf 'FAIL  %s\n' "$3"
        fail=$((fail + 1))
    else
        printf 'PASS  %s\n' "$3"
    fi
}

# 1. Renderer lifecycle: no timeline while paused, inactive or disappeared.
check "$ORB" 'minimumInterval: 1.0 / 30.0' 'orb timeline capped at 30 fps'
check "$ORB" 'scenePhase == .active' 'orb runs only in an active scene'
check "$ORB" '@State private var isOnScreen = false' 'orb starts suspended'
check "$ORB" '.onDisappear { isOnScreen = false }' 'orb suspends after disappearing'
check "$ORB" 'if isRunning {' 'orb draws a still frame when not running'
check "$ORB" 'tint: Color? = nil' 'orb accepts an optional semantic tint'
check "$ORB" 'tintDepth' 'tinted ink keeps depth instead of a flat fill'

# 2. Navigation title: semantic status orb, driven by real turn state.
check "$VIEW" 'isPaused: !(vm.isProcessing || vm.isCompacting)' 'title orb animates only while a turn runs'
check "$VIEW" 'tint: isAuthed ? Color.green : Color.orange' 'title orb keeps the signed-in colour meaning'
check "$VIEW" 'vm.isCompacting ? .weaving : (vm.isProcessing ? .working : .breathing)' 'title orb design follows the phase'
check "$VIEW" 'isProcessing: vm.isProcessing,' 'title cache key carries turn start'
check "$VIEW" 'isCompacting: vm.isCompacting,' 'title cache key carries compaction'
forbid "$VIEW" '.fill(isAuthed ? Color.green : Color.orange)' 'plain status dot is gone'

# 3. Transcript busy line and waiting-for-model line share the same language.
check "$VIEW" 'ThinkingOrb(vm.isCompacting ? .weaving : .working,' 'busy line uses the orb'
check "$VIEW" 'ThinkingOrb(.working, size: .small, speed: 0.8)' 'waiting-for-model line uses the orb'
check "$VIEW" 'ThinkingOrb(.weaving, size: .small, diameter: 12, speed: 0.8)' 'compaction divider uses the weaving orb'
check "$VIEW" 'LoadingDotsView(dotSize: 8)' 'session entry keeps its loading card'

# 4. Latest-message spacing: one tail spacer, message gaps preserved.
check "$VIEW" 'LazyVStack(alignment: .leading, spacing: 0)' 'legacy stack owns spacing per row'
check "$VIEW" '.padding(.top, (message.id == vm.messages.last?.id' 'newest row drops the tail gap'
check "$VIEW" 'bottomInset: inputBarHeight + floatingBarHeight + 8' 'tail inset is composer plus 8pt'
forbid "$VIEW" 'bottomInset: inputBarHeight + floatingBarHeight + 32' 'old 32pt tail inset is gone'

# 5. ProgressView must not reappear in the two converted busy states.
busy=$(sed -n '/if vm.isProcessing || vm.isCompacting {/,/^                        }$/p' "$VIEW" | head -20)
if printf '%s' "$busy" | grep -Fq 'ProgressView()'; then
    printf 'FAIL  %s\n' 'transcript busy line has no ProgressView'
    fail=$((fail + 1))
else
    printf 'PASS  %s\n' 'transcript busy line has no ProgressView'
fi

if [ "$fail" -ne 0 ]; then
    printf '\n%d Thinking Orbs gate check(s) failed\n' "$fail"
    exit 1
fi
printf '\nThinking Orbs status animation gate passed\n'
