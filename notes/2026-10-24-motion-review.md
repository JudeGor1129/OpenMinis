# Minis interaction and motion review

Target: SwiftUI/UIKit, iOS 15.4.1 first, preserving the iOS 16+ renderer. Minis is a conversation-and-tools app: useful content should be visible immediately and controls must not delay reading or typing.

## Changes implemented

- Shared motion vocabulary: control feedback 0.14s ease-out; local transitions 0.22s ease-in-out; layout 0.28s critically damped spring. These are implementation choices, not timing values prescribed by Apple.
- Home/group/search, settings, providers/model groups, MCP, skills, file browser, browser full-screen and chat/tool/voice controls use the shared motion policy. System navigation and sheets retain their native transitions and cancellation. Existing crash-prevention navigation transactions are preserved.
- Passive progress changes and repeatedly streamed transcription/thinking text do not queue animations. Copy/save/sync HUD animation stays within the feedback layer instead of animating the entire screen.
- Loading dots, browser pulses, shimmer and typing decorations respect Reduce Motion. Visible labels/status remain available when motion is disabled.
- iOS 15 session entry resolves the actual ScrollViewReader tail anchor instead of incrementally chasing LazyVStack's estimated numeric content offset every 100ms. Current messages remain lazy and all history stays available.
- Session initial positioning has no travel animation; explicit jump actions use the local transition. The message viewport reveals after the initial positioning request. Loading remains visible during this layout step.
- Scroll following uses coalesced native contentSize/bounds/inset observations. User drag/deceleration take precedence and observation/gesture targets are detached on teardown. Native interactive keyboard dismissal is enabled.
- Cached session restoration uses a replayable request counter, avoiding a lost event when the renderer binds after parent onAppear. On modern systems, tail preview is permitted while the full history rebuild continues; preview permission is set before messages publish.

## HIG references read

- `motion.md › Providing feedback`: “Aim for brevity and precision in feedback animations”; “Let people cancel motion”; avoid unnecessary motion for frequent interactions.
- `scroll-views.md › Best practices`: support default scrolling gestures; automatic scrolling only as much as needed to retain context.
- `loading.md › Best practices`: “Show something as soon as possible.”
- `gestures.md › Best practices`: “Handle gestures as responsively as possible.”
- `feedback.md › Best practices`: status feedback near the item it describes; accessible feedback.
- Also read accessibility, layout, typography, color, designing-for-ios and progress-indicators pages. No palette or typography redesign is included in this motion change.

## Validation and limits

Source regression scripts cover real tail anchoring, no timer/numeric offset chase, native gesture priority, observation teardown, replayable entry intent, preview publication ordering and Reduce Motion policy. These checks are not frame-rate measurements.

CI must compile with the iOS 15 deployment target and package a TrollStore IPA. Real-device acceptance: open long sessions cold/warm, verify latest reply is visible without traversal; scroll up during streaming and stay there; jump back down; open/close keyboard, rotate, expand tool panel; switch sessions rapidly; repeat with Reduce Motion enabled. Database reconstruction still retains all agent history. No claim of measured FPS or complete runtime coverage is made before those checks.

## Build-mode correction

After the motion patch passed a full build (#115, commit 152d8be), inspection of the current scripts found the earlier build70 baseline reset had restored `-configuration Debug` and `Debug-iphoneos` packaging. Follow-up fa54126 changes the final IPA to Release with explicit Swift `-O`, testability disabled and debug-dylib disabled. Packaging checks the Release app; CI verifies the absence of the debug stub and the DEBUG-only NavbarEvalStats profiler. This removes debug overhead but is not a measured guarantee of a particular frame rate. Final optimized build: #116, https://github.com/JudeGor1129/OpenMinis/actions/runs/39982224497 .

## Follow-up to build115 device feedback

User reports entry still visibly scrolls, plus tapping a sub-agent task window crashes. The new implementation in 7dd76af removes restoration-by-scroll entirely on iOS15: reversed rows and an inverted native viewport put the newest edge at native offset zero. Cold load, preview/full-history replacement, keyboard/floating-bar changes have no programmatic scrolling. Only explicit user jump buttons call scrollTo.

Agent task sheet ownership moved from recycled lazy rows to the stable transcript. Selection keeps a nonempty snapshot including the tapped block. Child transcript uses the same iOS15 renderer; notifications are scoped to the visible session and delivered on main. Detail thumbnail work rejects overlap and stale/cancelled returns. The app's readable crash records did not contain a matching build115 tap crash; the system CrashReporter directory is unreadable. These are confirmed code-path/lifecycle fixes, not a claim of reproduced and symbolicated crash resolution. Acceptance still requires tapping running/finished agent tasks and the nested conversation page on iOS15.
