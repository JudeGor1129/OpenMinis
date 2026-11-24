import Foundation

func expect(_ test: @autoclosure () -> Bool, _ label: String) {
    guard test() else { fatalError(label) }
    print("PASS Swift: \(label)")
}

let pick: [String: Any] = ["type": "options", "question": "Choose formats", "multi_select": true,
                           "options": [["label": "Text"], ["label": "PDF"]], "default": "1"]
let confirm: [String: Any] = ["type": "confirm", "question": "Overwrite draft?", "risk": "high"]
let input = try UserAskParser.parse(["questions": [pick, confirm]]).get()
expect(input.questions.map(\.type) == [.options, .confirm], "structured question order")
expect(input.questions[0].multiSelect && input.questions[0].timeoutSuggestion == "PDF", "options and unconfirmed default")
let invalidInputs: [[String: Any]] = [["question": "legacy"], ["questions": []],
    ["questions": Array(repeating: pick, count: 5)], ["questions": ["not an object"]]]
for invalid in invalidInputs {
    if case .success = UserAskParser.parse(invalid) { fatalError("invalid input accepted") }
}
let now = Date(timeIntervalSince1970: 1000)
func makeAsk(minutes: Int = 5) -> PendingAsk {
    PendingAsk(requestId: "request", sessionId: "session", toolCallId: "call", questions: input.questions,
               createdAt: now, timeoutMinutes: minutes)
}
var ask = makeAsk()
expect(!ask.isExpired(at: now.addingTimeInterval(299.9)) && ask.isExpired(at: now.addingTimeInterval(300)), "wall-clock expiration boundary")
expect(!makeAsk(minutes: 0).isExpired(at: .distantFuture), "explicit indefinite wait")
expect(ask.submit(0, now: now) == .rejected, "empty selection cannot submit")
var selection = UserAskAnswer()
selection.selected = [1, 0]
selection.otherText = "中文\n第二行"
ask.setAnswer(selection, at: 0)
expect(ask.submit(0, now: now.addingTimeInterval(10)) == .advanced(to: 1), "multi-question advance")
expect(ask.expiresAt == now.addingTimeInterval(310), "interaction resets deadline")
expect(ask.submit(1, now: now) == .rejected, "confirm requires an explicit choice")
var timeout = ask
var decision = UserAskAnswer()
decision.confirmChoice = .approve
// An unsubmitted confirmation draft must NOT become an approval at timeout.
timeout.setAnswer(decision, at: 1)
expect(timeout.resolveTimedOut() && timeout.resultStatuses == [.answered, .timeout], "timeout preserves submitted answers only")
let timeoutOnly = UserAskResolver.timedOut(input.questions[0], index: 0, timeoutMinutes: 5).jsonObject()
expect(timeoutOnly["default"] as? String == "PDF" && timeoutOnly["answer"] == nil, "timeout default never becomes an answer")
let selected = UserAskResolver.answered(input.questions[0], index: 0, answer: selection)
expect(selected.answer == ["Text", "PDF", "中文\n第二行"], "stable multi-select and multiline answer")
decision.confirmChoice = .deny
ask.setAnswer(decision, at: 1)
expect(ask.submit(1, now: now) == .complete, "explicit deny settles confirmation")
expect(ask.resolveAnswered(source: .app) && ask.resultStatuses == [.answered, .denied], "structured wire statuses")
expect(!ask.resolveTimedOut(), "late resolutions cannot replace a result")
let record = UserAskRecord(ask: ask, answerMessageId: "outbox-row")
let restored = try JSONDecoder().decode(UserAskRecord.self, from: JSONEncoder().encode(record))
expect(restored == record, "durable record and outbox identity survive decoding")
expect(UserAskRecovery.action(for: restored, now: now, toolResultInStore: false) == .deliver, "retry undelivered result")
expect(UserAskRecovery.action(for: restored, now: now, toolResultInStore: true) == .alreadyDelivered, "skip already delivered result")
var deferred = restored
 deferred.ask.deferred = true
expect(UserAskRecovery.action(for: deferred, now: now, toolResultInStore: true) == .deliverDeferred, "deferred placeholder is not an answer")
expect(ask.consume() != nil && ask.consume() == nil, "result consumed at most once")
var cancelled = makeAsk()
expect(cancelled.resolveDismissed(.stopped) && cancelled.state == .cancelled && cancelled.resultStatuses == [.dismissed, .dismissed], "Stop resolves every waiting question")
expect(UserAskSettings.defaultTimeoutMinutes == 5 && UserAskSettings.clampTimeout(-1) == 0, "timeout setting defaults and clamps")
