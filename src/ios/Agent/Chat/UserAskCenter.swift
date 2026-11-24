//
//  UserAskCenter.swift
//  Minis
//
//  [T-user-ask] Runtime of the user_ask tool: live asks, the wait the agent
//  loop blocks on, the wall-clock timeout, the card's actions, background
//  notifications (with answer actions), and recovery after the app was killed.
//
//  Order of effects for a new ask (§12.3): record persisted → card shown →
//  notification posted. A crash between them never leaves a notification
//  pointing at a request that does not exist.
//

import Foundation
import Combine
import UIKit
import UserNotifications

@MainActor
final class UserAskCenter: ObservableObject {
    static let shared = UserAskCenter()

    /// Live asks by requestId (pending and recently resolved, for the card).
    @Published private(set) var asks: [String: PendingAsk] = [:]
    private var requestIdByToolUse: [String: String] = [:]
    private var records: [String: UserAskRecord] = [:]
    private var waiters: [String: CheckedContinuation<String, Never>] = [:]
    /// Asks whose tool call is running in this process. The agent loop owns
    /// their delivery (the batch persists the result); recovery must never
    /// deliver them too, even in the gap between resolution and that persist.
    private var inProcess: Set<String> = []
    private var tickTask: Task<Void, Never>?
    private let store = UserAskRecordStore()
    private let logger = AppLogger(category: "UserAsk")
    private var observers: [NSObjectProtocol] = []
    private var notificationInFlight: Set<String> = []
    private var deliveryInFlight: Set<String> = []

    private init() {
        // [T-user-ask-no-policy] Drop the stored "Always allow" rules and the
        // removed auto-default mode once, so neither can take effect again.
        let purged = UserAskSettings.purgeLegacyKeys()
        if !purged.isEmpty { logger.info("[UserAsk] removed legacy settings \(purged)") }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in UserAskCenter.shared.appDidEnterBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in UserAskCenter.shared.appDidBecomeActive() }
        })
    }

    // MARK: - Lookup

    func ask(forToolUseId id: String?) -> PendingAsk? {
        guard let id, let rid = requestIdByToolUse[id] else { return nil }
        return asks[rid]
    }

    func pendingAsks(inSession sessionId: String) -> [PendingAsk] {
        asks.values.filter { $0.sessionId == sessionId && $0.state == .pending }
    }

    func hasPendingAsk(inSession sessionId: String?) -> Bool {
        guard let sessionId else { return false }
        return asks.values.contains { $0.sessionId == sessionId && $0.state == .pending }
            || store.all().values.contains { $0.ask.sessionId == sessionId && $0.ask.state == .pending && !$0.ask.consumed }
    }

    // MARK: - Start and wait

    /// Register a new ask. Persists first; the card appears as soon as
    /// `asks` publishes; a notification follows if the app is not active.
    /// [T-user-ask-no-policy] Nothing is settled up front - every question,
    /// confirm included, waits for the user.
    func begin(_ record: UserAskRecord) {
        var r = record
        if let first = (0..<r.ask.questions.count).first(where: { !r.ask.submitted.contains($0) }) {
            r.ask.currentIndex = first
            Self.preselectRecommended(&r.ask, at: first)
        }
        persist(r)
        // [T-user-ask-deferred] A deferred ask has no tool call waiting on it:
        // its answer is handed on by deliverDeferred, not by the agent loop.
        if !r.ask.isDeferred { inProcess.insert(r.ask.requestId) }
        asks[r.ask.requestId] = r.ask
        requestIdByToolUse[r.ask.toolCallId] = r.ask.requestId
        logger.info("[UserAsk] BEGIN req=\(r.ask.requestId.prefix(8)) tool=\(r.ask.toolCallId.prefix(16)) sid=\(r.ask.sessionId.prefix(8)) questions=\(r.ask.questions.count) types=\(r.ask.questions.map(\.type.rawValue)) timeout=\(r.ask.timeoutMinutes)m state=\(r.ask.state.rawValue)")
        guard r.ask.state == .pending else { return }
        startTicking()
        // [T-mac-dock-badge] userIsAway: on a Mac UIKit stays .active while another app is in front.
        if UIApplication.shared.applicationState == .background { postNotification(for: r.ask) }
    }

    /// [T-user-ask-deferred] Start a deferred ask: only one stays open per
    /// conversation, so an older open deferred card is closed as replaced.
    func beginDeferred(_ record: UserAskRecord) {
        let older = asks.values.filter {
            $0.sessionId == record.ask.sessionId && $0.isDeferred && $0.state == .pending
        }
        for ask in older { dismiss(requestId: ask.requestId, reason: .replacedByNewAsk) }
        begin(record)
    }

    /// Suspend until the ask resolves; returns the tool_result JSON. Stop
    /// (task cancellation) resolves it as cancelled.
    func wait(requestId: String) async -> String {
        if let ask = asks[requestId], ask.state.isTerminal, let json = ask.resultJSON { return json }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                if let ask = asks[requestId], ask.state.isTerminal, let json = ask.resultJSON {
                    c.resume(returning: json)
                } else {
                    waiters[requestId] = c
                }
            }
        } onCancel: {
            Task { @MainActor in UserAskCenter.shared.dismiss(requestId: requestId, reason: .stopped) }
        }
    }

    // MARK: - Card actions

    /// `userAction: false` for the card's own preselection of the
    /// recommended option — that must not restart the wall-clock countdown.
    func updateAnswer(requestId: String, index: Int, _ answer: UserAskAnswer, userAction: Bool = true) {
        mutate(requestId) { ask in
            ask.setAnswer(answer, at: index)
            if userAction { ask.noteInteraction(at: Date()) }
        }
    }

    func noteInteraction(requestId: String) {
        mutate(requestId) { $0.noteInteraction(at: Date()) }
    }

    func goTo(requestId: String, index: Int) {
        mutate(requestId) { ask in ask.goTo(index, now: Date()) }
    }

    /// "Next" / "Submit" on one question. When every question is settled
    /// the ask resolves; otherwise the wizard moves to the next unsettled one.
    func submitQuestion(requestId: String, index: Int) {
        var resolveNow = false
        mutate(requestId) { ask in
            switch ask.submit(index, now: Date()) {
            case .rejected: break
            case .advanced(let next): Self.preselectRecommended(&ask, at: next)
            case .complete: resolveNow = true
            }
        }
        if resolveNow { resolveAnswered(requestId: requestId, source: .app) }
    }

    /// A confirm button: records the choice and submits that question.
    func confirm(requestId: String, index: Int, choice: UserAskConfirmChoice, note: String? = nil) {
        guard var a = asks[requestId]?.answers[safe: index] else { return }
        a.confirmChoice = choice
        if choice == .deny, let note { a.note = note }
        updateAnswer(requestId: requestId, index: index, a)
        submitQuestion(requestId: requestId, index: index)
    }

    /// §9.5: the recommended (first) option starts selected so one tap on
    /// Next accepts it — only on an untouched single-choice question, and
    /// not as an interaction (the countdown keeps running). Done here rather
    /// than in the card: a view's onChange can run with the previous
    /// question's values, which left question 2 of a wizard unselected.
    static func preselectRecommended(_ ask: inout PendingAsk, at index: Int) {
        guard ask.questions.indices.contains(index) else { return }
        let q = ask.questions[index]
        guard q.type == .options, !q.multiSelect, let options = q.options, !options.isEmpty else { return }
        let a = ask.answers[index]
        guard a.selected.isEmpty, !a.delegated, (a.otherText ?? "").isEmpty else { return }
        ask.answers[index].selected = [0]
    }

    // MARK: - Dismissal

    /// Stop, a new user message in the same session, or an explicit close.
    func dismiss(requestId: String, reason: UserAskDismissReason) {
        var changed = false
        mutate(requestId) { changed = $0.resolveDismissed(reason) }
        if changed {
            logger.info("[UserAsk] DISMISSED req=\(requestId.prefix(8)) reason=\(reason.rawValue)")
            finish(requestId)
        }
    }

    func dismissPending(inSession sessionId: String, reason: UserAskDismissReason) {
        for ask in pendingAsks(inSession: sessionId) {
            // [T-user-ask-deferred] Stop ends the running wait; a deferred card
            // belongs to no running call and stays open. A new user message
            // still replaces it (the user answered in their own words).
            if reason == .stopped, ask.isDeferred { continue }
            dismiss(requestId: ask.requestId, reason: reason)
        }
    }

    // MARK: - Resolution

    private func resolveAnswered(requestId: String, source: UserAskAnswerSource) {
        var changed = false
        mutate(requestId) { changed = $0.resolveAnswered(source: source) }
        if changed {
            logger.info("[UserAsk] ANSWERED req=\(requestId.prefix(8)) source=\(source.rawValue) statuses=\(self.asks[requestId]?.resultStatuses.map(\.rawValue) ?? [])")
            finish(requestId)
        }
    }

    private func resolveTimedOut(requestId: String) {
        var changed = false
        mutate(requestId) { changed = $0.resolveTimedOut() }
        if changed {
            let statuses = asks[requestId]?.resultStatuses.map(\.rawValue) ?? []
            logger.info("[UserAsk] TIMED OUT req=\(requestId.prefix(8)) statuses=\(statuses) - nothing applied")
            finish(requestId)
        }
    }

    /// Every resolution ends here: persist, clear the notification and its
    /// category, hand the result to a waiting tool call — or, if none is
    /// waiting (the app was killed meanwhile), deliver it to the session.
    private func finish(_ requestId: String) {
        removeNotification(requestId: requestId)
        guard let ask = asks[requestId], let json = ask.resultJSON else { return }
        if let c = waiters.removeValue(forKey: requestId) {
            c.resume(returning: json)
        } else if ask.isDeferred {
            Task { @MainActor in await self.deliverDeferred(requestId: requestId) }
        } else if !inProcess.contains(requestId), records[requestId] != nil {
            Task { @MainActor in await self.deliverRecovered(requestId: requestId) }
        }
        if !asks.values.contains(where: { $0.state == .pending || ($0.isDeferred && $0.state.isTerminal && !$0.consumed) }) {
            tickTask?.cancel(); tickTask = nil
        }
    }

    /// The agent loop persisted the tool_result for these tool calls: drop
    /// their records (idempotency is keyed by toolCallId from here on).
    func markDelivered(toolUseIds: [String]) {
        for id in toolUseIds {
            guard let rid = requestIdByToolUse[id] else { continue }
            // [T-user-ask-deferred] The loop stored the `deferred` result; the
            // record stays until the ANSWER is handed on (deliverDeferred).
            if asks[rid]?.isDeferred == true, asks[rid]?.consumed == false { continue }
            mutate(rid) { $0.consumed = true }
            store.remove(rid)
            records.removeValue(forKey: rid)
            inProcess.remove(rid)
            logger.info("[UserAsk] DELIVERED req=\(rid.prefix(8)) tool=\(id.prefix(16))")
        }
    }

    // MARK: - Timeout

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
        }
    }

    /// Wall clock: an ask that expired while the process was suspended
    /// resolves on the first tick after it wakes.
    private func tick() {
        let now = Date()
        for ask in asks.values where ask.isExpired(at: now) { resolveTimedOut(requestId: ask.requestId) }
        for ask in asks.values where ask.isDeferred && ask.state.isTerminal && !ask.consumed {
            Task { @MainActor in await self.deliverDeferred(requestId: ask.requestId) }
        }
    }

    // MARK: - State plumbing

    private func mutate(_ requestId: String, _ body: (inout PendingAsk) -> Void) {
        guard var ask = asks[requestId] ?? records[requestId]?.ask ?? store.record(requestId)?.ask else { return }
        body(&ask)
        asks[requestId] = ask
        requestIdByToolUse[ask.toolCallId] = requestId
        var r = records[requestId] ?? store.record(requestId) ?? UserAskRecord(ask: ask)
        r.ask = ask
        persist(r)
    }

    private func persist(_ r: UserAskRecord) {
        records[r.ask.requestId] = r
        store.save(r)
    }

    // MARK: - Notifications (§10)

    private var settings: UserAskSettings { UserAskSettings.load() }

    /// Shows the question the ask is on (the first not yet answered), under
    /// that question's own identifier [T-user-ask-notif-next-id], and clears
    /// any other question of the same request still in Notification Center,
    /// so one notification per ask is on screen. `sound: false` keeps the
    /// move to the next question quiet.
    private func postNotification(for ask: PendingAsk, sound: Bool = true) {
        guard ask.state == .pending, !ask.isExpired(at: Date()),
              UIApplication.shared.applicationState == .background,
              settings.notifyInBackground,
              BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled,
              let index = UserAskNotificationPlan.notifiedIndex(ask),
              ask.notifiedIndex != index else { return }
        let identifier = UserAskNotificationPlan.notificationId(requestId: ask.requestId, index: index)
        guard notificationInFlight.insert(identifier).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.notificationInFlight.remove(identifier) }
            let center = UNUserNotificationCenter.current()
            let permission = await center.notificationSettings()
            let authorized = [.authorized, .provisional, .ephemeral].contains(permission.authorizationStatus)
            guard authorized, let live = self.asks[ask.requestId], live.state == .pending,
                  !live.isExpired(at: Date()),
                  UIApplication.shared.applicationState == .background,
                  self.settings.notifyInBackground,
                  BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled else { return }
            let content = UNMutableNotificationContent()
            content.title = AppLocalized("Minis is waiting for your answer")
            content.body = AppLocalized("A user interaction needs your reply. Tap to return to Minis.")
            content.sound = sound ? .default : nil
            content.userInfo = ["sessionId": ask.sessionId, "userAskRequestId": ask.requestId,
                                "userAskQuestionIndex": index]
            // A neutral tap-to-open notice never carries the question/title,
            // nor an approval action that can bypass the Minis application lock.
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
                if let latest = self.asks[ask.requestId], latest.state == .pending,
                   !latest.isExpired(at: Date()), latest.currentIndex == index,
                   UIApplication.shared.applicationState == .background,
                   self.settings.notifyInBackground,
                   BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled {
                    self.mutate(ask.requestId) { $0.notifiedIndex = index }
                } else {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                }
            } catch { self.logger.warning("[UserAsk] neutral reminder could not be scheduled") }
        }
    }

    static func notificationBody(_ ask: PendingAsk) -> String { UserAskNotificationPlan.body(ask) }

    private func removeNotification(requestId: String) {
        let center = UNUserNotificationCenter.current()
        let count = asks[requestId]?.questions.count ?? UserAskParser.maxQuestions
        let ids = UserAskNotificationPlan.allNotificationIds(requestId: requestId, questionCount: count)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        NotificationCategoryCenter.shared.remove(identifiers:
            UserAskNotificationPlan.dynamicCategoryIds(requestId: requestId, questionCount: count))
    }

    private func appDidEnterBackground() {
        for ask in asks.values where ask.state == .pending { postNotification(for: ask) }
    }

    private func appDidBecomeActive() {
        // The card is on screen again; the notification would only go stale.
        for ask in asks.values where ask.state == .pending {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:
                UserAskNotificationPlan.allNotificationIds(requestId: ask.requestId, questionCount: ask.questions.count))
        }
        tick()
        Task { @MainActor in await self.recoverAll() }
    }

    // MARK: - Recovery after the process was killed (§12.4)

    private var recovering = false

    /// Scan persisted asks nobody is waiting on. Delivered → drop; resolved
    /// or expired → deliver the result and continue the run; still in time →
    /// show the card again (the run continues once it is answered).
    func recoverAll() async {
        guard !recovering else { return }
        recovering = true
        defer { recovering = false }
        let now = Date()
        store.purge(now: now)
        for (rid, r) in store.all() where waiters[rid] == nil && !inProcess.contains(rid) {
            guard await ChatStore.shared.getSession(r.ask.sessionId) != nil else {
                store.remove(rid); records.removeValue(forKey: rid); asks.removeValue(forKey: rid)
                removeNotification(requestId: rid)
                continue
            }
            let inStore = await Self.toolResultExists(sessionId: r.ask.sessionId, toolUseId: r.ask.toolCallId)
            switch UserAskRecovery.action(for: r, now: now, toolResultInStore: inStore) {
            case .alreadyDelivered:
                store.remove(rid)
                records.removeValue(forKey: rid)
            case .deliver:
                records[rid] = r
                asks[rid] = r.ask
                requestIdByToolUse[r.ask.toolCallId] = rid
                await deliverRecovered(requestId: rid)
            case .timeOutThenDeliver:
                records[rid] = r
                asks[rid] = r.ask
                requestIdByToolUse[r.ask.toolCallId] = rid
                resolveTimedOut(requestId: rid)  // → finish → deliverRecovered
            case .deliverDeferred:
                records[rid] = r
                asks[rid] = r.ask
                requestIdByToolUse[r.ask.toolCallId] = rid
                await deliverDeferred(requestId: rid)
            case .awaitUser:
                guard asks[rid] == nil || asks[rid]?.state == .pending else { continue }
                records[rid] = r
                asks[rid] = r.ask
                requestIdByToolUse[r.ask.toolCallId] = rid
                if !r.assistantPersisted { await persistRecoveredAssistant(rid) }
                startTicking()
                logger.info("[UserAsk] RECOVER awaiting req=\(rid.prefix(8)) — card restored, run continues on answer")
            }
        }
    }

    static func toolResultExists(sessionId: String, toolUseId: String) async -> Bool {
        await ChatStore.shared.loadMessages(sessionId: sessionId).contains { m in
            m.parts.contains { if case .toolResult(let tr) = $0 { return tr.toolUseId == toolUseId }; return false }
        }
    }

    private static func toolUseExists(sessionId: String, toolUseId: String) async -> Bool {
        await ChatStore.shared.loadMessages(sessionId: sessionId).contains { m in
            m.parts.contains { if case .toolUse(let tu) = $0 { return tu.toolUseId == toolUseId }; return false }
        }
    }

    /// Write the saved assistant row (with the user_ask tool_use) so a
    /// reopened session shows the card while it still waits.
    private func persistRecoveredAssistant(_ rid: String) async {
        guard var r = records[rid], let data = r.assistantRawJSON,
              let raw = try? JSONDecoder().decode(RawMessage.self, from: data) else { return }
        if await !Self.toolUseExists(sessionId: raw.sessionId, toolUseId: r.ask.toolCallId) {
            await ChatStore.shared.appendMessages([raw])
        }
        r.assistantPersisted = true
        persist(r)
        ViewModelCache.shared.markStale(sessionId: r.ask.sessionId)
        let (vm, _) = ViewModelCache.shared.getOrCreate(for: r.ask.sessionId)
        if !vm.isProcessing { await vm.loadSession() }
    }

    /// Append the result (and the saved assistant row if needed) to the
    /// transcript, then resume the run. Exactly once per toolCallId.
    private func deliverRecovered(requestId: String) async {
        guard let r = records[requestId] ?? store.record(requestId),
              let ask = asks[requestId] ?? Optional(r.ask), ask.state.isTerminal, let json = ask.resultJSON else { return }
        let sid = ask.sessionId
        if await Self.toolResultExists(sessionId: sid, toolUseId: ask.toolCallId) {
            markDelivered(toolUseIds: [ask.toolCallId])
            return
        }
        var rows: [RawMessage] = []
        var toolOrder: [String] = [ask.toolCallId]
        if let data = r.assistantRawJSON, let raw = try? JSONDecoder().decode(RawMessage.self, from: data) {
            toolOrder = raw.parts.compactMap { if case .toolUse(let tu) = $0 { return tu.toolUseId }; return nil }
            let toolUseInStore = await Self.toolUseExists(sessionId: sid, toolUseId: ask.toolCallId)
            if !r.assistantPersisted && !toolUseInStore { rows.append(raw) }
        } else if !r.assistantPersisted {
            // §12.5: the saved request cannot be restored — keep the answers
            // and send them as a plain user message instead of losing them.
            logger.warning("[UserAsk] RECOVER req=\(requestId.prefix(8)) — assistant snapshot unreadable, falling back to a plain message")
            let vm = ViewModelCache.shared.getOrCreate(for: sid).vm
            await vm.loadSession()
            let outcome = vm.submitProgrammaticPrompt(UserAskRecovery.plainTextFallback(ask), origin: .cli, silent: false)
            if case .rejected = outcome {
                logger.error("[UserAsk] RECOVER req=\(requestId.prefix(8)) — plain fallback was rejected; keeping durable record")
                return
            }
            markDelivered(toolUseIds: [ask.toolCallId])
            return
        }
        let interrupted = "<system-reminder>The app was closed before this tool finished; it did not run. Run it again if it is still needed.</system-reminder>"
        let parts: [ContentPart] = toolOrder.map { id in
            if id == ask.toolCallId {
                return .toolResult(ToolResult(toolUseId: id, output: json, success: true, mediaRef: nil, snapshot: nil, pageURL: nil, status: "success"))
            }
            return .toolResult(ToolResult(toolUseId: id, output: interrupted, success: false, mediaRef: nil, snapshot: nil, pageURL: nil, status: "cancelled"))
        }
        rows.append(RawMessage(id: UUID().uuidString, sessionId: sid, role: .user, parts: parts, createdAt: Date()))
        await ChatStore.shared.appendMessages(rows)
        guard await Self.toolResultMatches(sessionId: sid, toolUseId: ask.toolCallId, output: json) else { return }
        markDelivered(toolUseIds: [ask.toolCallId])
        logger.info("[UserAsk] RECOVER delivered req=\(requestId.prefix(8)) rows=\(rows.count) — resuming session \(sid.prefix(8))")
        let (vm, _) = ViewModelCache.shared.getOrCreate(for: sid)
        guard !vm.isProcessing else { return }
        await vm.loadSession()
        // A stopped or superseded ask only needed its result written so the
        // transcript stays paired: the user ended that run — do not restart it.
        guard ask.state == .answered || ask.state == .timedOut else {
            logger.info("[UserAsk] RECOVER req=\(requestId.prefix(8)) state=\(ask.state.rawValue) — result written, run not resumed")
            return
        }
        vm.resumeAfterUserAsk()
    }
}

// MARK: - Deferred asks  [T-user-ask-deferred]

extension UserAskCenter {
    /// A deferred ask was answered (or closed): write its real result over the
    /// stored `deferred` one, so the transcript and a reloaded card show what
    /// the user chose, then - for a real answer - send it to the conversation
    /// as the user's next message. Exactly once per ask.
    func deliverDeferred(requestId: String) async {
        guard deliveryInFlight.insert(requestId).inserted else { return }
        defer { deliveryInFlight.remove(requestId) }
        guard let ask = asks[requestId], ask.isDeferred, ask.state.isTerminal,
              !ask.consumed, let json = ask.resultJSON,
              await ChatStore.shared.getSession(ask.sessionId) != nil else { return }
        let (vm, _) = ViewModelCache.shared.getOrCreate(for: ask.sessionId)
        // No reload or artificial new prompt mid-run/compaction. The persisted
        // record is the outbox; foreground/tick retries once the VM is idle.
        guard !vm.isProcessing, !vm.isCompacting else { startTicking(); return }
        guard await Self.replaceToolResult(sessionId: ask.sessionId, toolUseId: ask.toolCallId, output: json) else {
            startTicking(); return // batch not committed yet; don't consume it
        }
        if UserAskDeferred.sendsAnswer(ask), settings.enabled {
            var record = records[requestId] ?? store.record(requestId) ?? UserAskRecord(ask: ask)
            let messageId = record.answerMessageId ?? UUID().uuidString
            record.answerMessageId = messageId
            persist(record) // stable row id BEFORE the DB transaction
            let rows = await ChatStore.shared.loadMessages(sessionId: ask.sessionId)
            if !rows.contains(where: { $0.id == messageId }) {
                let message = RawMessage(id: messageId, sessionId: ask.sessionId, role: .user,
                                         parts: [.text(UserAskDeferred.answerMessage(ask))], createdAt: Date())
                await ChatStore.shared.appendMessages([message])
            }
            guard await ChatStore.shared.loadMessages(sessionId: ask.sessionId).contains(where: { $0.id == messageId }) else {
                startTicking(); return
            }
        }
        // Both result and answer are durable. Never delete recovery first.
        markDeferredConsumed(requestId)
        ViewModelCache.shared.markStale(sessionId: ask.sessionId)
        await vm.loadSession()
        if UserAskDeferred.sendsAnswer(ask), settings.enabled { vm.resumeAfterUserAsk() }
        if !asks.values.contains(where: { $0.state == .pending || ($0.isDeferred && $0.state.isTerminal && !$0.consumed) }) {
            tickTask?.cancel(); tickTask = nil
        }
    }

    /// The answer is being handed on: the record is done (consumed), so it is
    /// neither delivered twice nor restored after a restart.
    private func markDeferredConsumed(_ requestId: String) {
        mutate(requestId) { $0.consumed = true }
        store.remove(requestId)
        records.removeValue(forKey: requestId)
    }

    /// The stored tool_result of `toolUseId`, replaced by `output`.
    static func replaceToolResult(sessionId: String, toolUseId: String, output: String) async -> Bool {
        let messages = await ChatStore.shared.loadMessages(sessionId: sessionId)
        guard let m = messages.first(where: { m in
            m.parts.contains { if case .toolResult(let tr) = $0 { return tr.toolUseId == toolUseId }; return false }
        }) else { return false }
        let parts: [ContentPart] = m.parts.map { part in
            guard case .toolResult(let tr) = part, tr.toolUseId == toolUseId else { return part }
            return .toolResult(ToolResult(toolUseId: tr.toolUseId, output: output, success: tr.success,
                                          mediaRef: tr.mediaRef, snapshot: tr.snapshot, pageURL: tr.pageURL,
                                          status: tr.status))
        }
        await ChatStore.shared.updateMessageParts(messageId: m.id, parts: parts)
        return await Self.toolResultMatches(sessionId: sessionId, toolUseId: toolUseId, output: output)
    }
    static func toolResultMatches(sessionId: String, toolUseId: String, output: String) async -> Bool {
        await ChatStore.shared.loadMessages(sessionId: sessionId).contains { m in
            m.parts.contains { if case .toolResult(let tr) = $0 { return tr.toolUseId == toolUseId && tr.output == output }; return false }
        }
    }
    func acknowledgeBatch(toolUseIds: [String]) async {
        for id in toolUseIds {
            guard let ask = ask(forToolUseId: id), !ask.isDeferred, let json = ask.resultJSON,
                  await Self.toolResultMatches(sessionId: ask.sessionId, toolUseId: id, output: json) else { continue }
            markDelivered(toolUseIds: [id])
        }
    }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
