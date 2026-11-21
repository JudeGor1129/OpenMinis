#!/usr/bin/env python3
"""Source contracts + extracted Swift data tests, NOT UI/framerate tests."""
import argparse, shutil, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(); p.add_argument('--require-swift', action='store_true'); args = p.parse_args()
legacy = (ROOT/'src/ios/Views/LegacyContentView.swift').read_text()
app = (ROOT/'src/ios/MinisApp.swift').read_text()
bka = (ROOT/'src/ios/Agent/Background/BackgroundKeepAliveManager.swift').read_text()
def check(ok, label):
    assert ok, label
    print('PASS:', label, flush=True)
def function(text, signature):
    start=text.index(signature); opening=text.index('{',start); depth=0
    for i in range(opening,len(text)):
        if text[i]=='{': depth+=1
        elif text[i]=='}':
            depth-=1
            if depth==0: return text[start:i+1]
    raise AssertionError('Unterminated function: '+signature)
home=legacy.split('private struct LegacyContentView: View {',1)[1].split('\nprivate struct ',1)[0]
observer=app.split('.onChange(of: scenePhase) { newPhase in',1)[1].split('// MARK: - Lifecycle Logging',1)[0]
queued=observer.index('DispatchQueue.main.async {')
check(home.count('Label("新建分组", systemImage: "folder.badge.plus")')==1,'one home creation entry, in retained context menu')
check('.contextMenu' in home and 'creatingGroup = true' in home and '.sheet(isPresented: $creatingGroup' in home,'long-press creation and existing sheet retained')
check('所有会话都已归入分组；展开分组即可查看。' not in home,'redundant all-filed explanation removed')
check('ForEach(memberIDs, id: \\.self)' in home and 'ForEach(members(of:' not in home,'grouped List diffs stable session IDs')
check('if let session = groupedSessionsByID[sessionID]' in home,'row content resolves current lookup')
check('selectionMode: .constant(false)' in home and 'selectedSessions: .constant([])' in home,'grouped row opens instead of selecting')
check('memberCount: groupSessionIDs[folder.id]?.count ?? 0' in home,'collapsed group counts retained')
check('activity.$activeSessions\n            .removeDuplicates()' in legacy and 'concurrency.$suspendedSessions\n            .map { Set($0) }\n            .removeDuplicates()' in legacy,'unchanged activity sets deduplicated')
check('legacySessionListPreview(session.lastMessage)' in legacy,'bounded display preview wired')
for call in ('showPrivacyScreen = true','clearAllUnlocks()','noteAppBackgrounded()'):
    check(observer.index(call)<queued,'privacy precedes deferred maintenance: '+call)
check('handleScenePhaseChange(newPhase)' in observer[queued:],'maintenance queued outside observer')
check('guard scenePhase == phase else { return }' in app,'stale inactive/background callbacks are discarded')
check(app.count('guard scenePhase == .active else { return }')>=3,'foreground work revalidates after suspension')
active=bka.split('NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)',1)[1].split('.store(in: &cancellables)',1)[0]
check('DispatchQueue.main.async { [weak self] in' in active and 'UIApplication.shared.applicationState == .active' in active,'stale active notification cannot clean up new keep-alive')
check('[LifecycleTiming]' in app and 'elapsed >= 0.1' in app,'conditional slow lifecycle timing exists')
swift=shutil.which('swiftc')
if swift is None:
    print('UNAVAILABLE: Swift behavior tests; source checks are NOT runtime evidence.',flush=True)
    raise SystemExit(1 if args.require_swift else 0)
preview=function(legacy,'private func legacySessionListPreview(')
indexer=function(legacy,'private func reloadGroupMembers()').replace('private func','mutating func',1)
source='''import Foundation
struct ChatSession {
 let id:String
 var title:String
 var folderId:String?
 var isChild:Bool=false
}
struct IndexHarness {
 var sessions:[ChatSession]=[]
 var groupSessionIDs:[String:[String]]=[:]
 var groupedSessionsByID:[String:ChatSession]=[:]
'''+indexer+'\n}\n'+preview+'''
func expect(_ ok: @autoclosure () -> Bool,_ label:String) {
 guard ok() else { fatalError(label) }; print("PASS Swift:",label)
}
var h=IndexHarness()
h.sessions=(0..<400).map { ChatSession(id:"s\\($0)",title:"title\\($0)",folderId:$0<300 ? "a":"b") }
h.sessions += [ChatSession(id:"hidden",title:"child",folderId:"a",isChild:true),ChatSession(id:"loose",title:"ungrouped",folderId:nil)]
h.reloadGroupMembers()
expect(h.groupSessionIDs["a"] == (0..<300).map { "s\\($0)" },"400-session order and membership")
expect(h.groupSessionIDs["b"]?.count == 100,"second group count")
expect(h.groupedSessionsByID["hidden"] == nil,"child sessions excluded")
expect(h.groupedSessionsByID["loose"]?.title == "ungrouped","ungrouped data retained")
let oldIDs=h.groupSessionIDs["a"]
h.sessions[0].title="renamed"; h.reloadGroupMembers()
expect(h.groupSessionIDs["a"] == oldIDs && h.groupedSessionsByID["s0"]?.title == "renamed","same IDs expose refreshed data")
h.sessions[0].folderId="b"; h.sessions.removeAll { $0.id == "s1" }; h.reloadGroupMembers()
expect(h.groupSessionIDs["a"]?.count == 298 && h.groupSessionIDs["b"]?.first == "s300" && h.groupSessionIDs["b"]?.last == "s0","move/delete preserve remaining order")
expect(h.groupSessionIDs["b"]?.filter { $0 == "s0" }.count == 1 && h.groupedSessionsByID["s1"] == nil,"moved/deleted lookup is fresh")
expect(legacySessionListPreview(nil) == nil && legacySessionListPreview("") == nil,"empty previews absent")
expect(legacySessionListPreview("short") == "short","short preview unchanged")
let large=String(repeating:"中文👩🏽‍💻",count:15000)
expect(legacySessionListPreview(large)?.count == 240,"long preview bounded")
expect(legacySessionListPreview(large) == String(large.prefix(240)),"Unicode graphemes preserved")
expect(large.count == 45000,"full message unchanged")
h.sessions=[]; h.reloadGroupMembers()
expect(h.groupSessionIDs.isEmpty && h.groupedSessionsByID.isEmpty,"empty refresh clears caches")
'''
with tempfile.TemporaryDirectory(prefix='minis-home-test-') as tmp:
    path=Path(tmp); (path/'main.swift').write_text(source)
    subprocess.run([swift,'-O',str(path/'main.swift'),'-o',str(path/'test')],check=True,timeout=120)
    subprocess.run([str(path/'test')],check=True,timeout=30)
print('PASS: extracted Swift data tests. Device scrolling/watchdog recurrence still unverified.')
