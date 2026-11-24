#!/usr/bin/env python3
"""Check user_ask source contracts, run production Swift state tests and type-check the iOS 15 presenter/delegate."""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / 'src/ios'


def check(ok, label):
    if not ok:
        raise SystemExit('FAIL: ' + label)
    print('PASS: ' + label, flush=True)


def phase(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-swift', action='store_true')
    args = parser.parse_args()
    core = IOS / 'Agent/Chat/UserAskCore.swift'
    settings = IOS / 'Agent/Chat/UserAskSettings.swift'
    presenter = IOS / 'Views/Settings/UserQuestionPresenter.swift'
    ui = presenter.read_text()
    vm = (IOS / 'Agent/Chat/AIChatViewModel+UserAsk.swift').read_text()
    center = (IOS / 'Agent/Chat/UserAskCenter.swift').read_text()
    route = (IOS / 'Agent/Intents/SendPromptIntent.swift').read_text()
    pipe = (IOS / 'Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text()
    card = (IOS / 'Views/Chat/AssistantBlockView.swift').read_text()
    project = (IOS / 'Minis.xcodeproj/project.pbxproj').read_text()

    check('case "user_ask":' in pipe and 'await executeUserAsk(' in pipe and
          '"questions": AgentToolParam(type: .array' in vm and
          'sessionId: sessionId, toolCallId: toolUseId' in vm and
          'await UserAskCenter.shared.wait(requestId:' in vm, 'structured tool and originating session')
    check('withTaskCancellationHandler' in center and 'reason: .stopped' in center and
          'reason: .supersededByUserMessage' in vm, 'stop and new message resolve waiting tools')
    lock = phase(ui, 'private func canInteract', 'private func host')
    check(all(x in lock for x in ('applicationState == .active', '!lock.appIsLocked',
          '!lock.showPrivacyScreen', '!lock.isVisuallyLocked(ask.sessionId)',
          'ask.state == .pending', '!ask.isExpired(at: Date())')), 'app/session lock, foreground and expiry gates')
    for method, next_method in (('perform', 'present'), ('present', 'suspendForPrivacy')):
        check('canInteract(ask)' in phase(ui, 'private func '+method+'(', 'private func '+next_method+'('), method+' checks the live ask gate')
    check(all(x in ui for x in ('UIApplication.willResignActiveNotification', 'setPrivacyHidden(true)',
          'sheet.isSuspendingForPrivacy = true', 'isSuspendingForPrivacy != true')),
          'privacy cover and suspension are not cancellation')
    check('UserAskCenter.shared.' not in phase(card, 'private func userAskCard', 'private var textBlockView'),
          'inline card cannot bypass the answer gate')
    check(all(x in ui for x in ('sheet.detents = [.medium(), .large()]', 'isModalInPresentation = true',
          'questionLabel.numberOfLines = 0', 'questionLabel.textAlignment = .left', 'UITextView()',
          'view.keyboardLayoutGuide.topAnchor', 'formScroll.contentLayoutGuide',
          'adjustsFontForContentSizeCategory = true', '.resolvedColor(with: traitCollection)')),
          'iOS 15 sheet, multiline layout, keyboard and dynamic appearance')
    notice = phase(center, 'private func postNotification', 'static func notificationBody')
    check(all(x in notice for x in ('A user interaction needs your reply. Tap to return to Minis.',
          'applicationState == .background', 'BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled',
          'notificationInFlight.insert', 'try await center.add(request)',
          'removePendingNotificationRequests', 'removeDeliveredNotifications')) and
          not any(x in notice for x in ('content.categoryIdentifier', 'content.badge', 'ask.sessionTitle', 'ask.questions')),
          'neutral reminder, settings gate, deduplication and late delivery cleanup')
    reply = phase(route, 'if let questionId = userInfo', '        if let sessionId = userInfo')
    check(reply.index('guard response.actionIdentifier == UNNotificationDefaultActionIdentifier') <
          reply.index('handleNotificationTap(questionId)') and
          all(x not in center+reply for x in ('handleNotificationResponse', 'UNTextInputNotificationResponse')) and
          all(x in route for x in ('completionHandler([])', 'completionHandler([.banner, .sound])')),
          'tap-only routing and selective foreground suppression')
    check('settings.authorizationStatus == .notDetermined' in ui and
          'guard permissionTask == nil, UIApplication.shared.applicationState == .active' in ui,
          'notification permission requested only from active app')
    for file in (core.name, settings.name, presenter.name, 'UserAskSettingsView.swift'):
        check(project.count(file+' in Sources') == 2, file+' in application target')
    strings = json.loads((IOS / 'Localizable.xcstrings').read_text())['strings']
    for key in ('Your response', 'Send answer', 'Minis is waiting for your answer',
                'A user interaction needs your reply. Tap to return to Minis.'):
        check({'zh-Hans', 'zh-Hant'} <= strings[key].get('localizations', {}).keys(), 'localized '+key)

    swift = shutil.which('swiftc')
    if not swift:
        print('UNAVAILABLE: swiftc; Swift tests and UIKit iOS 15 type-check not executed.')
        return int(args.require_swift)
    with tempfile.TemporaryDirectory(prefix='minis-user-ask-') as temp:
        t = Path(temp)
        tests = IOS / 'MinisTests/Standalone/UserAsk115Cases.swift'
        (t / 'main.swift').write_text(tests.read_text())
        subprocess.run([swift, str(core), str(settings), str(t/'main.swift'), '-o', str(t/'test')], check=True, timeout=120)
        subprocess.run([str(t/'test')], check=True, timeout=30)
        xcrun = shutil.which('xcrun')
        if not xcrun:
            print('UNAVAILABLE: xcrun; UIKit iOS 15 type-check not executed.')
            return int(args.require_swift)
        support = '''import UIKit
import Combine
import UserNotifications
func AppLocalized(_ key: String.LocalizationValue) -> String { "" }
@MainActor final class SessionLockStore: ObservableObject {
 static let shared = SessionLockStore()
 @Published var appIsLocked = false
 @Published var showPrivacyScreen = false
 func isVisuallyLocked(_ id: String) -> Bool { false }
}
@MainActor final class BackgroundKeepAliveManager {
 static let shared = BackgroundKeepAliveManager()
 var backgroundNotificationsEnabled = true
}
@MainActor final class UserAskCenter: ObservableObject {
 static let shared = UserAskCenter()
 @Published var asks: [String: PendingAsk] = [:]
 func updateAnswer(requestId: String, index: Int, _ answer: UserAskAnswer) {}
 func submitQuestion(requestId: String, index: Int) {}
 func confirm(requestId: String, index: Int, choice: UserAskConfirmChoice, note: String?) {}
 func goTo(requestId: String, index: Int) {}
 func dismiss(requestId: String, reason: UserAskDismissReason) {}
}
extension Notification.Name {
 static let openSessionFromIntent = Notification.Name("openSessionFromIntent")
 static let openHelperSheet = Notification.Name("openHelperSheet")
}
'''
        delegate = '@MainActor\nfinal class NotificationNavigationStore'
        (t/'Support.swift').write_text(support + delegate + route.split(delegate, 1)[1])
        sdk = subprocess.check_output([xcrun, '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        subprocess.run([xcrun, '--sdk', 'iphoneos', 'swiftc', '-typecheck', '-target', 'arm64-apple-ios15.0',
                        '-sdk', sdk, str(core), str(settings), str(presenter), str(t/'Support.swift')], check=True, timeout=120)
        print('PASS: production UIKit presenter/delegate type-check for iOS 15, with app seams stubbed.')
    print('NOTE: notification delivery, keyboard, accessibility and rendering are not device-tested.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
