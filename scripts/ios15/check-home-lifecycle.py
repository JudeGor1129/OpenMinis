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
entries = function(legacy,'private struct LegacySessionListEntry:')
snapshot = function(legacy,'private struct LegacySessionListSnapshot:')
member_rows = function(home,'ForEach(members) { entry in')
check('var id: String { session.id }' in entries and 'if let' not in member_rows
      and member_rows.count('LegacySessionRow(') == 1 and 'entry: entry' in member_rows,
      'grouped List has exactly one row per stable session ID')
check('selectionMode: .constant(false)' in member_rows and 'selectedSessions: .constant([])' in member_rows,
      'grouped row opens instead of selecting')
check('memberCount: sessionRows.grouped[folder.id]?.count ?? 0' in home,'collapsed group counts retained')
badge = legacy.split('private struct LegacySessionActivityBadge:', 1)[1].split('// A two-line list subtitle', 1)[0]
check('LegacySessionActivitySnapshot' not in home and 'showsActivity: true' in home,
      'home does not observe whole activity sets')
check(badge.count('.map { $0.contains(id) }') == 2 and badge.count('.removeDuplicates()') == 3,
      'activity publishes only changed status for the matching badge')
check('LegacySessionActivityBadge(sessionID: session.id' in legacy and 'if status != next { status = next }' in badge,
      'unrelated activity does not write row state')
check('let nextRows = LegacySessionListSnapshot(sessions: allSessions)' in home
      and 'if sessionRows != nextRows { sessionRows = nextRows }' in home,
      'unchanged session rows do not republish')
check('self.preview = legacySessionListPreview(session.lastMessage)' in entries
      and 'if let preview = entry.preview' in legacy,
      'bounded display preview is prepared before composing a row')
chat = (ROOT/'src/ios/Views/Chat/AIChatView.swift').read_text()
wrapper = function(chat,'private final class CachedViewModel:')
visibility = function(wrapper,'func setLegacyViewVisible(')
check('if #available(iOS 16.0, *) { return }' in visibility
      and 'if #available(iOS 16.0, *)' in function(wrapper,'init(sessionId:'),
      'visible-only forwarding is scoped to iOS 15')
check('guard cancellable == nil else { return }' in visibility
      and 'observeModel()' in visibility and 'objectWillChange.send()' in visibility
      and 'cancellable?.cancel()' in visibility and 'cancellable = nil' in visibility,
      'legacy chat cancels its root observer and republishes on re-entry')
check('.onAppear {\n            cached.setLegacyViewVisible(true)' in chat
      and '.onDisappear {\n            cached.setLegacyViewVisible(false)' in chat,
      'legacy chat observation follows the destination lifecycle')
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
preview = function(legacy,'private func legacySessionListPreview(')
store = (ROOT/'src/ios/Agent/Chat/ChatStore.swift').read_text()
session = function(store,'struct ChatSession:')
edge_policy = function(chat,'private func legacyShouldFollowNewest(')
source = '\n'.join(('import Foundation', session, preview, entries, snapshot, edge_policy)) + \
    '\n' + r'''
func expect(_ ok: @autoclosure () -> Bool,_ label:String) {
 guard ok() else { fatalError(label) }; print("PASS Swift:",label)
}
private func runHomeLifecycleTests() {
expect(!legacyShouldFollowNewest(atNewest:true,atOldest:true,hasOlderPage:true,draggedTowardHistory:true), "first history pull on short page retains browse state")
expect(legacyShouldFollowNewest(atNewest:true,atOldest:true,hasOlderPage:true,draggedTowardHistory:false), "reverse or cancelled drag returns to newest")
expect(legacyShouldFollowNewest(atNewest:true,atOldest:true,hasOlderPage:false,draggedTowardHistory:true), "short conversation without older pages stays at newest")
expect(!legacyShouldFollowNewest(atNewest:false,atOldest:true,hasOlderPage:true,draggedTowardHistory:true), "ordinary oldest edge still reveals history")
expect(!legacyShouldFollowNewest(atNewest:false,atOldest:false,hasOlderPage:true,draggedTowardHistory:false), "mid-history remains in browse state")
func fixture(_ id: String, _ title: String, folder: String? = nil, parent: String? = nil) -> ChatSession {
 ChatSession(id:id, title:title, modelId:"model", createdAt:Date(timeIntervalSince1970:0),
             updatedAt:Date(timeIntervalSince1970:0), folderId:folder, parentSessionId:parent)
}
var sessions=(0..<400).map { fixture("s\($0)","title\($0)",folder:$0<300 ? "a":"b") }
sessions += [fixture("hidden","child",folder:"a",parent:"s0"),fixture("loose","ungrouped")]
let initial=LegacySessionListSnapshot(sessions:sessions)
let visibleCount=initial.grouped.values.reduce(initial.ungrouped.count) { $0 + $1.count }
expect(initial.grouped["a"]?.map { $0.id } == (0..<300).map { "s\($0)" },"400-session order and membership")
expect(initial.grouped["b"]?.count == 100 && visibleCount == 401,"child excluded; full group count retained")
expect(initial.ungrouped.map { $0.id } == ["loose"],"ungrouped data retained")
expect(initial == LegacySessionListSnapshot(sessions:sessions),"no-op refresh stays unchanged")
sessions[0].lastMessage="new preview"
expect(!initial.isEmpty && initial != LegacySessionListSnapshot(sessions:sessions),"preview change refreshes without timestamp change")
let oldIDs=initial.grouped["a"]?.map { $0.id }
sessions[0].title="renamed"
let renamed=LegacySessionListSnapshot(sessions:sessions)
expect(renamed.grouped["a"]?.map { $0.id } == oldIDs,"rename keeps stable identity and order")
expect(renamed.grouped["a"]?.first?.session.title == "renamed" && renamed.grouped["a"]?.first?.preview == "new preview","fresh data on same ID")
sessions[0].folderId="b"; sessions.removeAll { $0.id == "s1" }
let moved=LegacySessionListSnapshot(sessions:sessions)
expect(moved.grouped["a"]?.count == 298 && moved.grouped["b"]?.first?.id == "s0" && moved.grouped["b"]?.last?.id == "s399","move/delete preserve remaining order")
expect(moved.grouped["b"]?.filter { $0.id == "s0" }.count == 1 && moved.grouped["a"]?.contains { $0.id == "s1" } == false,"moved and deleted rows do not linger")
expect(legacySessionListPreview(nil) == nil && legacySessionListPreview("") == nil,"empty previews absent")
expect(legacySessionListPreview("short") == "short","short preview unchanged")
let large=String(repeating:"中文👩🏽‍💻",count:15000)
expect(legacySessionListPreview(large)?.count == 240,"long preview bounded")
expect(legacySessionListPreview(large) == String(large.prefix(240)),"Unicode graphemes preserved")
expect(large.count == 45000,"full message unchanged")
var longSession=fixture("long","long")
longSession.lastMessage=large
let indexedLong = LegacySessionListSnapshot(sessions:[longSession]).ungrouped.first
expect(indexedLong?.preview == String(large.prefix(240)) && indexedLong?.session.lastMessage == large,"entry caps display only")
expect(LegacySessionListSnapshot(sessions:[fixture("child","hidden",parent:"s0")]).isEmpty,"all-child snapshot is empty")
expect(LegacySessionListSnapshot().isEmpty,"empty refresh clears rows")
}
runHomeLifecycleTests()
'''
with tempfile.TemporaryDirectory(prefix='minis-home-test-') as tmp:
    path=Path(tmp); (path/'main.swift').write_text(source)
    subprocess.run([swift,'-O',str(path/'main.swift'),'-o',str(path/'test')],check=True,timeout=120)
    subprocess.run([str(path/'test')],check=True,timeout=30)
print('PASS: extracted Swift data tests. Device scrolling/watchdog recurrence still unverified.')
