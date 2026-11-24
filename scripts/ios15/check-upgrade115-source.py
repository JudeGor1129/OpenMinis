#!/usr/bin/env python3
import json,subprocess
from pathlib import Path
R=Path(__file__).resolve().parents[2]; B=Path('/var/minis/workspace/10-minis/pet-voice-334')
def ok(v,m):
 if not v: raise SystemExit('FAIL: '+m)
 print('PASS:',m)
ok(not subprocess.check_output(['git','status','--porcelain'],cwd=B,text=True),'original build349 clean')
ok(subprocess.check_output(['git','rev-parse','HEAD'],cwd=B,text=True).strip()=='b5c205a930cf496d9eb6bab03761b8e3c052f232','original build349 unchanged')
v=(R/'src/ios/Providers/Voice/VoiceOutputPlayer.swift').read_text();a=(R/'src/ios/MinisApp.swift').read_text();ok(not any(x in v+a for x in ['PetSpeech','startPetSpeechBridge','minispet.speech','MinisPetSpeech']),'desktop pet bridge removed');ok(all(x in v for x in ['func enqueue(','func enqueueSegmented(','func stopAll()']),'chat voice queue retained')
vm=(R/'src/ios/Agent/Chat/AIChatViewModel+UserAsk.swift').read_text();core=(R/'src/ios/Agent/Chat/UserAskCore.swift').read_text();c=(R/'src/ios/Agent/Chat/UserAskCenter.swift').read_text();s=(R/'src/ios/Views/Settings/UserQuestionPresenter.swift').read_text()
ok('static let name = "user_ask"' in vm and '"questions"' in vm and 'options' in vm and 'confirm' in vm,'user_ask protocol')
ok('class MinisUserAskSheetPresenter' in s and all(x in s for x in ['medium()','large()','UITextView']),'A sheet iOS15/multiline')
intent=(R/'src/ios/Agent/Intents/SendPromptIntent.swift').read_text()
route=intent.split('if let questionId = userInfo["userAskRequestId"] as? String {',1)[1].split('completionHandler()\n            return',1)[0]
notice=c.split('private func postNotification',1)[1].split('static func notificationBody',1)[0]
interaction=s.split('private func canInteract',1)[1].split('private func host()',1)[0]
ok('guard response.actionIdentifier == UNNotificationDefaultActionIdentifier' in route and 'handleNotificationTap(questionId)' in route and 'handleNotificationResponse' not in c+route,'notification cannot submit answers')
ok('A user interaction needs your reply' in notice and not any(x in notice for x in ['content.categoryIdentifier','ask.sessionTitle','ask.questions','UNTextInputNotificationAction']),'privacy neutral reminder')
ok(all(x in interaction for x in ['applicationState == .active','!lock.appIsLocked','!lock.showPrivacyScreen','!lock.isVisuallyLocked(ask.sessionId)']) and 'canInteract(ask) else { return }' in s.split('private func perform(',1)[1],'answer submission checks app and session locks')
ok('answerMessageId' in core and 'toolResultMatches' in c and 'markDeferredConsumed(requestId)' in c,'durable answer outbox')
chat=(R/'src/ios/Views/Chat/AIChatView.swift').read_text();e=(R/'src/ios/Views/Chat/ChatExportRenderer.swift').read_text();q=(R/'src/ios/Providers/Quota/QuotaStore.swift').read_text();p=(R/'src/ios/Views/Providers/UnifiedModelPicker.swift').read_text();ok('ChatSearchControls' in chat and 'ChatShareSelectionView' in chat and 'PDFDocument' in e,'search/share integration');ok('class QuotaStore' in q and 'ModelQuotaHintView' in p,'quota integration')
ish=(R/'deps/build_ish.sh').read_text();aot=(R/'deps/build_aot.sh').read_text();lock=json.loads((R/'deps/aot/images.lock.json').read_text());ok('0fd17a135e78b7a0cf08a4f5831217bbb76ed22f' in ish and 'git rev-parse HEAD' in ish,'iSH pin gate');ok('verify_inputs.py' in aot and 'no verified AOJIT images' in aot and len(lock['images'])==25 and lock['inputs_available'] is False,'AOJIT strict missing-input gate')
pbx=(R/'src/ios/Minis.xcodeproj/project.pbxproj').read_text()
for n in ['UserAskCenter.swift','UserAskCore.swift','AIChatViewModel+UserAsk.swift','QuotaStore.swift','ChatSearchController.swift','ChatShareSelectionView.swift','AOJITShellStats.swift']:ok(n+' in Sources' in pbx,n+' PBX source registration')
print('NOTE: no swiftc/xcodebuild/full app or device validation')
