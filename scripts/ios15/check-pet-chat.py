#!/usr/bin/env python3
"""Source contracts for pet entry points; these are NOT UIKit runtime tests."""
from pathlib import Path
import subprocess,re
ROOT=Path(__file__).resolve().parents[2]
def src(name):return (ROOT/'src/ios'/name).read_text()
router=src('Shared/DeepLinkRouter.swift')
legacy=src('Views/LegacyContentView.swift')
modern=src('Views/ContentView.swift')
chat=src('Views/Chat/AIChatView.swift')
inline=src('Views/Chat/Voice/InlineVoiceInputView.swift')
voice=src('Views/Chat/Voice/VoiceInputPanel.swift')
checks=0
def check(ok,title):
    global checks
    assert ok,title
    checks+=1;print('PASS',title)
check('case "chat":' in router,'chat route is dispatched by the existing URL router')
check('named.count == 1' in router,'ambiguous folder names fail closed')
check('$0.folderId == folder.id && !$0.isChild' in router,'only group member root conversations selected')
check('PetChatNavigation.shared.route = .init(sessionId: target.id)' in router,'cold-launch route remains buffered')
check('guard resolutionID == requestID' in router,'late async resolutions cannot overwrite newer taps')
check('請' not in router and '请先在该分组中开始一个新会话' in router,'empty group has visible guidance')
start=legacy.index('Label("会话分组"')
check('.contextMenu' in legacy[start:start+480] and 'creatingGroup = true' in legacy[start:start+480], 'iOS15 home group row gains New Group menu')
check('LegacyGroupNameSheet(title: "新建分组"' in legacy,'iOS15 existing create sheet reused')
for name,text in [('legacy',legacy),('modern',modern)]:
    check('.onReceive(petNavigation.$route)' in text,f'{name} subscribes to buffered route')
    check('guard scenePhase == .active, let route = petNavigation.route' in text,f'{name} refuses background navigation')
check('guard petNavigationIdentity == identity' in legacy,'legacy interrupted navigation cannot replace a newer route')
check('Label("新建分组", systemImage: "folder.badge.plus")' in modern,'modern group context menu retained')
check('guard !cleanName.isEmpty, !duplicateName' in modern,'modern new-group sheet refuses empty/duplicate names')
check('voiceVM.handleMainButtonTap()' not in chat,'auto-start never invokes the delayed microphone toggle')
check('enablePetVoiceIfRequested()' in chat and '.onReceive(voiceLaunch.$pending)' in chat,'cold and same-visible-chat requests both handled')
check('launchSessionId: sessionId' in chat,'voice panel receives a session-scoped intent')
check('.task(id: (launchPanelVisible && petLaunchReady) ? voiceLaunch.generation : nil)' in inline,'recording task bound to visible panel and parent readiness')
check('petLaunchReady: isChatViewVisible && !hasOverlayPresented && scenePhase != .background' in chat,'recording does not arm under chat overlays or in background')
check(inline.index('viewModel.prepare()') < inline.index('await viewModel.startListeningForPetLaunch'),'panel prepared before explicit start')
check('voiceLaunch.consumeAutoStart(sessionId: launchSessionId)' in inline,'consume at recording entry, not before navigation')
check('voiceLaunch.isCurrent(request)' in inline,'stale recording intent checked after permissions')
method=voice.split('func startListeningForPetLaunch',1)[1].split('/// Stop capture',1)[0]
check('handleMainButtonTap' not in method and '!vad.isCapturing' in method,'explicit recording is idempotent, never toggle')
check('!Task.isCancelled' in method and 'UIApplication.shared.applicationState == .active' in method,'recording start refuses cancelled/background work')
check(method.count('guard allowed()')>=4,'all asynchronous permission returns revalidate visibility')
check('if willUseSystemASR' in method,'cloud ASR does not request unrelated Speech authorization')
check('Date().addingTimeInterval(60)' in router,'unused microphone intents expire')
info=src('Info.plist')
check('NSMicrophoneUsageDescription' in info and 'NSSpeechRecognitionUsageDescription' in info,'existing iOS privacy descriptions remain')
subprocess.run(['git','diff','--check'],cwd=ROOT,check=True)
check(subprocess.run(['git','merge-base','--is-ancestor','7c39a5fb05e6ff00051110ed54354577ecc402b0','HEAD'],cwd=ROOT).returncode==0,'branch descends from verified build329 commit')
protected=['src/ios/Shared/ThinkingOrb.swift','src/ios/Views/Chat/ChatInputBar.swift','tools/privileged-helper/MinisPrivilegedHelper.m','.github/workflows/ios15.yml']
check(not subprocess.check_output(['git','diff','7c39a5f','--']+protected,cwd=ROOT),'329 renderer, core composer, helper and CI unchanged')
# The new question sheet needs one source registration. Permit ONLY its four
# exact records; after removing them the entire project must equal build329.
projectPath='src/ios/Minis.xcodeproj/project.pbxproj'
project=(ROOT/projectPath).read_text()
records=[
 '\t\tE5UQ00001 /* UserQuestionPresenter.swift in Sources */ = {isa = PBXBuildFile; fileRef = E5UQ00002 /* UserQuestionPresenter.swift */; };\n',
 '\t\tE5UQ00002 /* UserQuestionPresenter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UserQuestionPresenter.swift; sourceTree = "<group>"; };\n',
 '\t\t\t\tE5UQ00002 /* UserQuestionPresenter.swift */,\n',
 '\t\t\t\tE5UQ00001 /* UserQuestionPresenter.swift in Sources */,\n']
check(all(project.count(record)==1 for record in records),'one exact source registration for user-question sheet')
for record in records: project=project.replace(record,'',1)
baseline=subprocess.check_output(['git','show','7c39a5f:'+projectPath],cwd=ROOT,text=True)
check(project==baseline,'all build329 project records unchanged outside four exact question-sheet additions')
print(f'{checks} source contracts passed; runtime and compilation require macOS/real iPhone.')
