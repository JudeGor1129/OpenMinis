//
//  AIChatViewModel+UserAsk.swift
//  Minis
//
//  [T-user-ask] The user_ask tool inside the agent loop: definition, when it
//  is exposed, its system-prompt fragments, execution (persist → card →
//  wait), and the hooks that end a wait early (Stop, a new user message).
//

import Foundation
import UIKit

enum UserAskTool {
    static let name = "user_ask"
}

extension Notification.Name {
    /// [T-user-ask-notsent-merge] A message's run of not-sent user_ask calls
    /// changed (object: the message id); the message list re-plans its rows.
    static let userAskNotSentRegrouped = Notification.Name("userAskNotSentRegrouped")
}

private let userAskLogger = AppLogger(category: "UserAsk")

extension AIChatViewModel {
    func computeUserAskExposure() -> (exposed: Bool, deferred: Bool, reason: String) {
        guard UserAskSettings.load().enabled else { return (false, false, "setting off") }
        guard !isHelper else { return (false, false, "sub agent") }
        let deferred = programmaticSilentTurn || programmaticTurnOrigin != nil
            || UIApplication.shared.applicationState == .background
        return (true, deferred, deferred ? "programmatic/background" : "interactive foreground")
    }
    var userAskExposed: Bool { userAskExposedThisRun ?? computeUserAskExposure().exposed }
    var userAskDeferred: Bool { userAskDeferredThisRun ?? computeUserAskExposure().deferred }
    static var userAskToolDefinition: AgentToolDefinition {
        let option = AgentSchemaNode.object(description: nil, properties: [
            (name: "label", node: .string(description: "Max 12 chars.")),
            (name: "description", node: .string(description: "One line.")),
        ], required: ["label"])
        let question = AgentSchemaNode.object(description: nil, properties: [
            (name: "type", node: .string(description: "Required. options = a decision; confirm = approval for one action.", enumValues: ["options", "confirm"])),
            (name: "question", node: .string(description: "Required. options: the question only, one sentence. confirm: the exact action (real command or target).")),
            (name: "header", node: .string(description: "Short chip, max 12 chars.")),
            (name: "options", node: .array(description: "type=options only. 2-4 genuinely different choices, best first. Omit for an open-ended question.", items: option, minItems: 2, maxItems: 4)),
            (name: "multi_select", node: .boolean(description: "type=options only.")),
            (name: "impact", node: .string(description: "type=confirm only: what can be lost, and whether it can be undone.")),
            (name: "risk", node: .string(description: "type=confirm only. Card colour only (high = red).", enumValues: ["medium", "high"])),
            (name: "default", node: .string(description: "type=options only, optional: 0-based index (e.g. \"0\") of the option you would pick. Never applied; returned to you on timeout as a suggestion.")),
        ], required: ["type", "question"])
        return AgentToolDefinition(
            name: UserAskTool.name,
            description: UserAskPromptText.toolDescription,
            parameters: [
                "questions": AgentToolParam(type: .array, description: "Required. 1-4 question objects, each with `type` and `question`.",
                                            schema: .array(description: nil, items: question, minItems: 1, maxItems: 4)),
            ],
            required: ["questions"]
        )
    }

    func executeUserAsk(args: [String: Any], toolUseId: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool) {
        let request: UserAskRequest
        switch UserAskParser.parse(args) {
        case .success(let r): request = r
        case .failure(let e):
            let out = "Error: \(e.message)"
            setBlockContent(msgIdx: msgIdx, blockIdx: blockIdx, out)
            // Never asked: same as a preflight rejection for the card and the
            // not-sent run (the caller would mark it failed a moment later).
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].toolStatus = .failed(message: out)
            }
            return (out, false)
        }
        guard let sessionId else {
            let out = UserAskResolver.encode(UserAskResolver.unavailable(request.questions))
            setBlockContent(msgIdx: msgIdx, blockIdx: blockIdx, out)
            return (out, true)
        }
        let s = UserAskSettings.load()
        // [T-user-ask-deferred] No one waits in a deferred run: no countdown.
        let deferred = userAskDeferred
        var ask = PendingAsk(requestId: UUID().uuidString, sessionId: sessionId, toolCallId: toolUseId,
                             questions: request.questions, createdAt: Date(),
                             timeoutMinutes: deferred ? 0 : s.timeoutMinutes)
        if deferred { ask.deferred = true }
        ask.sessionTitle = await ChatStore.shared.getSession(sessionId)?.title
        // §12.3 step 1: the snapshot is written before the card or any
        // notification can reference the request.
        let assistantJSON = currentUserAskAssistantRaw.flatMap { try? JSONEncoder().encode($0) }
        let record = UserAskRecord(ask: ask, assistantRawJSON: assistantJSON,
                                   siblingToolUseIds: currentUserAskBatchToolIds.filter { $0 != toolUseId })
        if deferred {
            // [T-user-ask-deferred] Card up (and a notification when the app is
            // not active), then return at once: the answer comes back later as
            // the user's next message (UserAskCenter.deliverDeferred).
            UserAskCenter.shared.beginDeferred(record)
            notifyUserAskHeightChanged(msgIdx: msgIdx, blockIdx: blockIdx)
            let out = UserAskDeferred.toolResult(questionCount: request.questions.count)
            userAskLogger.info("[UserAsk] DEFERRED sid=\(sessionId.prefix(8)) tool=\(toolUseId.prefix(16)) questions=\(request.questions.count) — card left open, run continues")
            setBlockContent(msgIdx: msgIdx, blockIdx: blockIdx, out)
            return (out, true)
        }
        userAskLogger.info("[UserAsk] waiting_user ENTER sid=\(sessionId.prefix(8)) tool=\(toolUseId.prefix(16))")
        UserAskCenter.shared.begin(record)
        notifyUserAskHeightChanged(msgIdx: msgIdx, blockIdx: blockIdx)
        let result = await UserAskCenter.shared.wait(requestId: ask.requestId)
        // Statuses and length only: the result carries the user's own words
        // (Other / note), which stay out of the log files (design §8).
        let statuses = (((try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any])?["results"] as? [[String: Any]])?
            .map { $0["status"] as? String ?? "?" } ?? []
        userAskLogger.info("[UserAsk] waiting_user EXIT sid=\(sessionId.prefix(8)) statuses=\(statuses) resultLen=\(result.count)")
        setBlockContent(msgIdx: msgIdx, blockIdx: blockIdx, result)
        notifyUserAskHeightChanged(msgIdx: msgIdx, blockIdx: blockIdx)
        return (result, true)
    }

    private func setBlockContent(msgIdx: Int, blockIdx: Int, _ text: String) {
        guard msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count else { return }
        messages[msgIdx].blocks[blockIdx].content = text
    }

    func notifyUserAskHeightChanged(msgIdx: Int, blockIdx: Int) {
        guard msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count else { return }
        NotificationCenter.default.post(name: .thinkingBlockToggled,
                                        object: messages[msgIdx].blocks[blockIdx].id)
    }
    func supersedePendingUserAsk() {
        guard let sessionId else { return }
        UserAskCenter.shared.dismissPending(inSession: sessionId, reason: .supersededByUserMessage)
    }
    func cancelPendingUserAsk() {
        guard let sessionId else { return }
        UserAskCenter.shared.dismissPending(inSession: sessionId, reason: .stopped)
    }
    func resumeAfterUserAsk() {
        guard !isProcessing else { return }
        // A durable answer is now a user turn; resume through the established
        // unanswered-message path, not submitProgrammaticPrompt (double persist).
        programmaticTurnOrigin = nil
        programmaticSilentTurn = false
        userAskExposedThisRun = nil
        userAskDeferredThisRun = nil
        canResume = true
        resume()
    }
}
