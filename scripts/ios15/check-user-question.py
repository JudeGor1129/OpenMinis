#!/usr/bin/env python3
"""Source contracts, actual Swift state tests and macOS UIKit iOS15 typecheck.
Not device, notification delivery, keyboard or rendering tests.
"""
import argparse,json,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--require-swift',action='store_true');args=p.parse_args()
ui=(ROOT/'src/ios/Views/Settings/UserQuestionPresenter.swift').read_text()
tools=(ROOT/'src/ios/Views/Settings/ToolsSettingsView.swift').read_text()
route=(ROOT/'src/ios/Agent/Intents/SendPromptIntent.swift').read_text()
caller=(ROOT/'src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift').read_text()
project=(ROOT/'src/ios/Minis.xcodeproj/project.pbxproj').read_text()
cat=json.loads((ROOT/'src/ios/Localizable.xcstrings').read_text())['strings']
def check(ok,label):
 assert ok,label
 print('PASS:',label,flush=True)
checks=[
 ('final class MinisUserQuestionPresenter' not in tools and ui.count('final class MinisUserQuestionPresenter:')==1,'old alert removed; one presenter'),
 ('await MinisUserQuestionPresenter.shared.ask(question, sessionId: sessionId)' in caller,'origin session passed; tool protocol retained'),
 ('guard pending == nil' in ui and 'Another user question is already open.' in ui,'single-question rejection'),
 (ui.index('await withCheckedContinuation')<ui.index('if pending === request { pending = nil }'),'lock held through dismissal'),
 ('deadline = now + 300' in ui and 'mach_continuous_time()' in ui and 'systemUptime' not in ui and 'guard !Task.isCancelled' in ui,'sleep-inclusive five minutes and task cancellation'),
 (all(x in ui for x in ['appLocked: lock.appIsLocked, privacy: lock.showPrivacyScreen','lock.isVisuallyLocked($0)','self.canInteract(request)','UIApplication.willResignActiveNotification']),'present/send obey app and session locks; snapshot concealment'),
 (all(x in ui for x in ['controller.setPrivacyHidden(true)','controller.isSuspendingForPrivacy = true','request.controller ?? MinisUserQuestionViewController','!isSuspendingForPrivacy &&']),'privacy pause preserves controller/draft; never treated as cancel'),
 ('sheet.detents = [.medium(), .large()]' in ui and 'isModalInPresentation = true' in ui,'iOS15 detents; explicit cancel'),
 (all(x in ui for x in ['questionLabel.text = question','questionLabel.numberOfLines = 0','questionLabel.textAlignment = .left']),'complete left-aligned question'),
 (all(x in ui for x in ['UITextView()','answerView.returnKeyType = .default','onAnswer?(answerView.text ?? "")']),'multiline and empty/verbatim answer'),
 (all(x in ui for x in ['view.keyboardLayoutGuide.topAnchor','formScroll.contentLayoutGuide','questionScroll.contentLayoutGuide']),'keyboard anchor and scrollable form/question'),
 ('heightAnchor.constraint(greaterThanOrEqualToConstant: 50)' in ui and 'widthAnchor.constraint(greaterThanOrEqualToConstant: 44)' in ui,'minimum action sizes'),
 ('adjustsFontForContentSizeCategory = true' in ui and '.resolvedColor(with: traitCollection)' in ui,'Dynamic Type and dynamic border'),
 (all(x not in ui for x in ['UIVisualEffectView','presentationDetents','.custom(']),'no persistent blur/iOS16 custom detents'),
 ('UIApplication.shared.applicationState == .background' in ui and 'BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled' in ui,'background-only with existing switch'),
 ('settings.authorizationStatus == .notDetermined' in ui and ui.count('UIApplication.shared.applicationState == .active')>=4,'foreground authorization only'),
 (all(x in ui for x in ['removePendingNotificationRequests','removeDeliveredNotifications','try await center.add(notice)','Task.isCancelled || self.pending !== request']),'cleanup handles asynchronous add race'),
 ('content.body = AppLocalized("A user interaction needs your reply. Tap to return to Minis.")' in ui and 'content.body = question' not in ui,'neutral lock-screen message'),
 ('content.badge' not in ui and 'setNotificationCategories' not in ui,'other badges/categories retained'),
 (all(x in route for x in ['handleNotificationTap(questionId)','completionHandler([])','completionHandler([.banner, .sound])']),'live tap and selective foreground suppression'),
 (project.count('UserQuestionPresenter.swift in Sources')==2 and project.count('/* UserQuestionPresenter.swift */')==3,'Xcode target/group registration')]
for ok,label in checks:check(ok,label)
for key in ['Your response','Send answer','Minis is waiting for your answer','A user interaction needs your reply. Tap to return to Minis.']:
 check(all(lang in cat[key]['localizations'] for lang in ['zh-Hans','zh-Hant']),'localized '+key)
policy='struct MinisUserQuestionState'+ui.split('\nstruct MinisUserQuestionState',1)[1].split('// MARK: - End user question data policy',1)[0]
swift=shutil.which('swiftc')
if not swift:
 print('UNAVAILABLE: swiftc; Swift tests and UIKit iOS15 typecheck NOT executed.')
 raise SystemExit(1 if args.require_swift else 0)
source='import Foundation\n'+policy+'''
func expect(_ ok: @autoclosure () -> Bool,_ label:String) {
 guard ok() else { fatalError(label) };print("PASS Swift:",label)
}
for active in [false,true] {for appLocked in [false,true] {for privacy in [false,true] {for sessionLocked in [false,true] {
 expect(MinisUserQuestionState.allowsInteraction(active:active,appLocked:appLocked,privacy:privacy,sessionLocked:sessionLocked)==(active && !appLocked && !privacy && !sessionLocked),"all lock/privacy/foreground gate combinations")
}}}}
var s=MinisUserQuestionState(id:"q1",now:20)
expect(s.isWaiting && s.deadline==320,"waiting and five-minute deadline")
s.finish("");expect(s.answer=="" && !s.isWaiting,"empty reply finishes")
s.finish("late");expect(s.answer=="","duplicate finish ignored")
var w=MinisUserQuestionState(id:"q2",now:0)
w.finish("  \\n中文👩🏽‍💻 ");expect(w.answer=="  \\n中文👩🏽‍💻 ","verbatim Unicode whitespace")
var e=MinisUserQuestionState(id:"q3",now:10)
e.expire(now:309.999);expect(e.isWaiting,"no early expiry")
e.expire(now:310);expect(e.answer=="User question timed out after five minutes.","exact expiry")
e.finish("late");expect(e.answer=="User question timed out after five minutes.","no late reply")
for reason in ["User cancelled the question.","Question cancelled because the task stopped."] {
 var x=MinisUserQuestionState(id:reason,now:0);x.finish(reason);x.expire(now:999)
 expect(x.answer==reason,"cancel/stop retained")
 expect(!x.reserveNotification(isBackground:true,enabled:true),"ended cannot notify")
}
for bg in [false,true] {for enabled in [false,true] {
 var x=MinisUserQuestionState(id:"gate",now:0)
 expect(x.reserveNotification(isBackground:bg,enabled:enabled)==(bg && enabled),"foreground/setting gate")
}}
var n=MinisUserQuestionState(id:"notice",now:0)
expect(n.reserveNotification(isBackground:true,enabled:true),"reserve in background")
expect(!n.reserveNotification(isBackground:true,enabled:true),"inflight duplicate blocked")
n.completeNotification(success:false)
expect(n.reserveNotification(isBackground:true,enabled:true),"failure allows later retry")
n.completeNotification(success:true)
expect(!n.reserveNotification(isBackground:true,enabled:true) && n.didNotify,"successful notice once across foreground/background")
var r=MinisUserQuestionState(id:"race",now:0)
_=r.reserveNotification(isBackground:true,enabled:true);r.finish("done");r.completeNotification(success:true)
expect(!r.isWaiting && r.answer=="done" && !r.notificationInFlight,"late add cannot reopen")
expect(!r.reserveNotification(isBackground:true,enabled:true),"late add cannot notify again")
var next=MinisUserQuestionState(id:"next",now:400)
expect(next.id != r.id && next.deadline==700 && !next.didNotify && next.isWaiting,"independent next question")
'''
with tempfile.TemporaryDirectory(prefix='minis-question-test-') as tmp:
 t=Path(tmp);(t/'main.swift').write_text(source)
 subprocess.run([swift,str(t/'main.swift'),'-o',str(t/'test')],check=True,timeout=120)
 subprocess.run([str(t/'test')],check=True,timeout=30)
 xcrun=shutil.which('xcrun')
 if not xcrun:
  print('UNAVAILABLE: xcrun; UIKit iOS15 typecheck NOT executed.')
  if args.require_swift:raise SystemExit(1)
 else:
  sdk=subprocess.check_output([xcrun,'--sdk','iphoneos','--show-sdk-path'],text=True).strip()
  support='''import UIKit
import UserNotifications
func AppLocalized(_ key: String.LocalizationValue) -> String { "" }
struct AppLogger { init(category:String) {} ; func info(_ message:String) {} }
@MainActor final class BackgroundKeepAliveManager {
 static let shared=BackgroundKeepAliveManager();var backgroundNotificationsEnabled=true
}
@MainActor final class SessionLockStore {
 static let shared=SessionLockStore();var appIsLocked=false;var showPrivacyScreen=false
 func isVisuallyLocked(_ sessionId:String)->Bool { false }
}
extension Notification.Name {
 static let openSessionFromIntent=Notification.Name("openSessionFromIntent")
 static let openHelperSheet=Notification.Name("openHelperSheet")
}
'''
  delegate=route[route.index('@MainActor\nfinal class NotificationNavigationStore'):]
  (t/'Support.swift').write_text(support+'\n'+delegate)
  subprocess.run([xcrun,'--sdk','iphoneos','swiftc','-typecheck','-target','arm64-apple-ios15.0','-sdk',sdk,str(ROOT/'src/ios/Views/Settings/UserQuestionPresenter.swift'),str(t/'Support.swift')],check=True,timeout=120)
  print('PASS: production UIKit presenter/delegate typecheck iOS15; app seams stubbed.')
print('NOTE: notification delivery, permissions, keyboard, VoiceOver, rotation and rendering NOT device-verified.')
