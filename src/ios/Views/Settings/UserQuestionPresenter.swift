import UIKit
import UserNotifications
import Darwin

private enum MinisUserQuestionClock {
    static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()
    static func now() -> TimeInterval { Double(mach_continuous_time()) * secondsPerTick }
}

// MARK: - User question data policy (also exercised by the Swift test harness)
struct MinisUserQuestionState {
    let id: String
    let deadline: TimeInterval
    private(set) var answer: String?
    private(set) var notificationInFlight = false
    private(set) var didNotify = false

    init(id: String, now: TimeInterval) {
        self.id = id
        deadline = now + 300
    }
    static func allowsInteraction(active: Bool, appLocked: Bool, privacy: Bool, sessionLocked: Bool) -> Bool {
        active && !appLocked && !privacy && !sessionLocked
    }
    var isWaiting: Bool { answer == nil }
    mutating func finish(_ value: String) {
        guard isWaiting else { return }
        answer = value // Preserve empty and whitespace-only answers verbatim.
    }
    mutating func expire(now: TimeInterval) {
        if now >= deadline { finish("User question timed out after five minutes.") }
    }
    mutating func reserveNotification(isBackground: Bool, enabled: Bool) -> Bool {
        guard isWaiting, isBackground, enabled, !didNotify, !notificationInFlight else { return false }
        notificationInFlight = true
        return true
    }
    mutating func completeNotification(success: Bool) {
        notificationInFlight = false
        if success { didNotify = true }
    }
}
// MARK: - End user question data policy

/// One outstanding question. Background requests stay pending until an active
/// window is available; no UIKit presentation or permission prompt in background.
@MainActor
final class MinisUserQuestionPresenter: NSObject {
    static let shared = MinisUserQuestionPresenter()
    private final class Request {
        var state: MinisUserQuestionState
        let question: String
        let sessionId: String?
        var controller: MinisUserQuestionViewController?
        var notificationTask: Task<Void, Never>?
        var presentationInFlight = false
        var suspensionInFlight = false
        var needsPrivacySuspension = false
        var cleanup: (() -> Void)?
        var dismissalStarted = false
        var notificationIdentifier: String { "minis-user-question-" + state.id }
        init(question: String, sessionId: String?) {
            state = MinisUserQuestionState(id: UUID().uuidString, now: MinisUserQuestionClock.now())
            self.question = question
            self.sessionId = sessionId
        }
    }
    private var pending: Request?
    private var permissionTask: Task<Void, Never>?
    private let logger = AppLogger(category: "UserQuestion")

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func ask(_ question: String, sessionId: String? = nil) async -> String {
        guard pending == nil else { return "Another user question is already open." }
        guard !Task.isCancelled else { return "Question cancelled because the task stopped." }
        let request = Request(question: question, sessionId: sessionId)
        pending = request
        if UIApplication.shared.applicationState == .active {
            guard UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive })
                .flatMap(\.windows).contains(where: { $0.isKeyWindow && !$0.isHidden && $0.rootViewController != nil }) else {
                pending = nil
                return "User interaction unavailable: no active window."
            }
            presentIfPossible(request)
            prepareNotificationPermission()
        } else {
            notifyIfBackgrounded(request)
        }
        // Monotonic wall lifetime: suspension must not restart the five minutes.
        while request.state.isWaiting {
            if Task.isCancelled {
                request.state.finish("Question cancelled because the task stopped.")
                break
            }
            request.state.expire(now: MinisUserQuestionClock.now())
            if !request.state.isWaiting { break }
            if canInteract(request) { presentIfPossible(request) }
            else { suspendForPrivacy(request) }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { request.state.finish("Question cancelled because the task stopped.") }
        }
        request.notificationTask?.cancel()
        clearNotification(request)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            request.cleanup = { continuation.resume() }
            dismissIfReady(request)
        }
        // Hold the single-question lock until presentation/dismissal completes.
        if pending === request { pending = nil }
        return request.state.answer ?? "Question cancelled because the task stopped."
    }

    /// On the first foreground question / Tools page only. Respect denial;
    /// never repeatedly prompt and never attempt a system prompt in background.
    func prepareNotificationPermission() {
        guard permissionTask == nil, UIApplication.shared.applicationState == .active,
              !SessionLockStore.shared.appIsLocked, !SessionLockStore.shared.showPrivacyScreen,
              BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled else { return }
        permissionTask = Task { @MainActor [weak self] in
            defer { self?.permissionTask = nil }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined,
                  UIApplication.shared.applicationState == .active,
                  !SessionLockStore.shared.appIsLocked, !SessionLockStore.shared.showPrivacyScreen else { return }
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { self?.logger.info("notification authorization unavailable") }
            if let request = self?.pending { self?.notifyIfBackgrounded(request) }
        }
    }

    @objc private func willResignActive() {
        if let request = pending { suspendForPrivacy(request) }
    }
    @objc private func becameActive() {
        guard let request = pending else { return }
        request.state.expire(now: MinisUserQuestionClock.now())
        clearNotification(request)
        if request.state.isWaiting {
            presentIfPossible(request)
            prepareNotificationPermission()
        }
    }
    @objc private func enteredBackground() {
        if let request = pending { notifyIfBackgrounded(request) }
    }

    /// A live tap reveals the existing sheet (and keeps its draft). A stale
    /// notification can navigate to its session, but never recreates a question.
    func handleNotificationTap(_ id: String) -> Bool {
        guard let request = pending, request.state.id == id else { return false }
        request.state.expire(now: MinisUserQuestionClock.now())
        clearNotification(request)
        if request.state.isWaiting { presentIfPossible(request) }
        // Route through the existing session gate when its unlock is required.
        return canInteract(request)
    }

    private func presentationHost() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard var host = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow && !$0.isHidden })?.rootViewController else { return nil }
        while let next = host.presentedViewController { host = next }
        guard !host.isBeingDismissed, !host.isBeingPresented, host.viewIfLoaded?.window != nil else { return nil }
        return host
    }
    private func canInteract(_ request: Request) -> Bool {
        let lock = SessionLockStore.shared
        return MinisUserQuestionState.allowsInteraction(
            active: UIApplication.shared.applicationState == .active,
            appLocked: lock.appIsLocked, privacy: lock.showPrivacyScreen,
            sessionLocked: request.sessionId.map { lock.isVisuallyLocked($0) } ?? false)
    }
    private func suspendForPrivacy(_ request: Request) {
        guard let controller = request.controller else { return }
        controller.setPrivacyHidden(true) // synchronous, before switcher snapshot
        request.needsPrivacySuspension = true
        guard !request.presentationInFlight, !request.suspensionInFlight,
              !request.dismissalStarted, controller.presentingViewController != nil else { return }
        request.suspensionInFlight = true
        controller.isSuspendingForPrivacy = true
        controller.dismiss(animated: false) { [weak self, weak request] in
            guard let request else { return }
            request.suspensionInFlight = false
            request.needsPrivacySuspension = false
            if request.cleanup != nil { self?.dismissIfReady(request) }
        }
    }
    private func presentIfPossible(_ request: Request) {
        guard pending === request, request.state.isWaiting, canInteract(request),
              !request.presentationInFlight, !request.suspensionInFlight,
              !request.dismissalStarted, request.controller?.presentingViewController == nil,
              let host = presentationHost() else { return }
        let controller = request.controller ?? MinisUserQuestionViewController(question: request.question)
        controller.isSuspendingForPrivacy = false
        controller.setPrivacyHidden(false)
        request.needsPrivacySuspension = false
        controller.onAnswer = { [weak self, weak request] value in
            guard let self, let request, self.canInteract(request) else { return }
            request.state.expire(now: MinisUserQuestionClock.now())
            request.state.finish(value)
        }
        controller.onDismissed = { [weak self, weak request] in
            guard let request else { return }
            request.state.finish("User cancelled the question.")
            if request.dismissalStarted { self?.completeDismissal(request) }
        }
        request.controller = controller
        request.presentationInFlight = true
        host.present(controller, animated: true) { [weak self, weak request] in
            guard let request else { return }
            request.presentationInFlight = false
            if request.cleanup != nil { self?.dismissIfReady(request) }
            else if request.needsPrivacySuspension { self?.suspendForPrivacy(request) }
            else { self?.prepareNotificationPermission() }
        }
    }
    private func dismissIfReady(_ request: Request) {
        guard !request.presentationInFlight, !request.suspensionInFlight, !request.dismissalStarted else { return }
        request.dismissalStarted = true
        guard let controller = request.controller, controller.presentingViewController != nil else {
            completeDismissal(request)
            return
        }
        if controller.isBeingDismissed { return } // onDismissed completes it.
        controller.dismiss(animated: UIApplication.shared.applicationState == .active) { [weak self] in
            self?.completeDismissal(request)
        }
    }
    private func completeDismissal(_ request: Request) {
        let cleanup = request.cleanup
        request.cleanup = nil
        cleanup?() // Presentation, disappearance and dismissal may all race.
    }

    private func clearNotification(_ request: Request) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [request.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [request.notificationIdentifier])
    }
    private func notifyIfBackgrounded(_ request: Request) {
        request.state.expire(now: MinisUserQuestionClock.now())
        guard request.state.reserveNotification(
            isBackground: UIApplication.shared.applicationState == .background,
            enabled: BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled) else { return }
        request.notificationTask = Task { @MainActor [weak self, weak request] in
            guard let self, let request else { return }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral
            request.state.expire(now: MinisUserQuestionClock.now())
            guard authorized, !Task.isCancelled, self.pending === request, request.state.isWaiting,
                  UIApplication.shared.applicationState == .background,
                  BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled else {
                request.state.completeNotification(success: false)
                self.logger.info("background reminder skipped (permission, state or setting)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = AppLocalized("Minis is waiting for your answer")
            content.body = AppLocalized("A user interaction needs your reply. Tap to return to Minis.")
            content.sound = .default
            content.userInfo = ["userQuestionId": request.state.id]
            if let sessionId = request.sessionId { content.userInfo["sessionId"] = sessionId }
            // No badge or category registration: don't overwrite other tools'
            // categories or disturb their existing task-count badge.
            let notice = UNNotificationRequest(identifier: request.notificationIdentifier, content: content, trigger: nil)
            do {
                try await center.add(notice)
                request.state.completeNotification(success: true)
                request.state.expire(now: MinisUserQuestionClock.now())
                // add() can finish after a reply/foreground transition. Remove
                // that stale delivery too; willPresent suppresses the race banner.
                if Task.isCancelled || self.pending !== request || !request.state.isWaiting
                    || UIApplication.shared.applicationState != .background
                    || !BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled {
                    self.clearNotification(request)
                }
            } catch {
                request.state.completeNotification(success: false)
                self.logger.info("background reminder could not be scheduled")
            }
        }
    }
}

/// A-style sheet: one complete, left-aligned question, multiline draft and an
/// explicit send button. UITextView Return inserts a newline, never submits.
@MainActor
private final class MinisUserQuestionViewController: UIViewController, UITextViewDelegate {
    var onAnswer: ((String) -> Void)?
    var onDismissed: (() -> Void)?
    var isSuspendingForPrivacy = false
    private let privacyCover = UIView()
    private let question: String
    private let titleLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let formScroll = UIScrollView()
    private let questionScroll = UIScrollView()
    private let questionLabel = UILabel()
    private let answerLabel = UILabel()
    private let answerView = UITextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private var questionHeight: NSLayoutConstraint!
    private var answerHeight: NSLayoutConstraint!
    private var selectedInitialDetent = false

    init(question: String) {
        self.question = question
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .pad ? .formSheet : .pageSheet
        isModalInPresentation = true // No accidental swipe/backdrop draft loss.
        preferredContentSize = CGSize(width: 540, height: 640)
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersEdgeAttachedInCompactHeight = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        titleLabel.text = AppLocalized("User Interaction")
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        cancelButton.setTitle(AppLocalized("Cancel"), for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        questionLabel.text = question // Never split, summarize or discard warning text.
        questionLabel.numberOfLines = 0
        questionLabel.textAlignment = .left
        questionLabel.lineBreakMode = .byWordWrapping
        answerLabel.text = AppLocalized("Your response")
        answerView.delegate = self
        answerView.isScrollEnabled = true
        answerView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        answerView.layer.cornerRadius = 15
        answerView.layer.borderWidth = 1
        answerView.returnKeyType = .default
        answerView.accessibilityLabel = AppLocalized("Your response")
        answerView.accessibilityIdentifier = "userQuestion.answer"
        placeholderLabel.text = AppLocalized("Your answer")
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.isAccessibilityElement = false
        sendButton.setTitle(AppLocalized("Send answer"), for: .normal)
        sendButton.layer.cornerRadius = 15
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.accessibilityIdentifier = "userQuestion.send"
        cancelButton.accessibilityIdentifier = "userQuestion.cancel"
        questionLabel.accessibilityIdentifier = "userQuestion.question"
        formScroll.keyboardDismissMode = .interactive
        questionScroll.alwaysBounceVertical = false
        for child in [titleLabel, cancelButton, formScroll, sendButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        for child in [questionScroll, answerLabel, answerView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            formScroll.addSubview(child)
        }
        questionLabel.translatesAutoresizingMaskIntoConstraints = false
        questionScroll.addSubview(questionLabel)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        answerView.addSubview(placeholderLabel)
        let safe = view.safeAreaLayoutGuide
        let content = formScroll.contentLayoutGuide
        let frame = formScroll.frameLayoutGuide
        questionHeight = questionScroll.heightAnchor.constraint(equalToConstant: 100)
        answerHeight = answerView.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 22),
            cancelButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: cancelButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -68),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: 12),
            formScroll.topAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: 10),
            formScroll.topAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor, constant: 10),
            formScroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            formScroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            formScroll.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -18),
            questionScroll.topAnchor.constraint(equalTo: content.topAnchor),
            questionScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            questionScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            questionScroll.widthAnchor.constraint(equalTo: frame.widthAnchor),
            questionHeight,
            questionLabel.leadingAnchor.constraint(equalTo: questionScroll.contentLayoutGuide.leadingAnchor),
            questionLabel.trailingAnchor.constraint(equalTo: questionScroll.contentLayoutGuide.trailingAnchor),
            questionLabel.topAnchor.constraint(equalTo: questionScroll.contentLayoutGuide.topAnchor),
            questionLabel.bottomAnchor.constraint(equalTo: questionScroll.contentLayoutGuide.bottomAnchor),
            questionLabel.widthAnchor.constraint(equalTo: questionScroll.frameLayoutGuide.widthAnchor),
            answerLabel.topAnchor.constraint(equalTo: questionScroll.bottomAnchor, constant: 20),
            answerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            answerLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            answerView.topAnchor.constraint(equalTo: answerLabel.bottomAnchor, constant: 10),
            answerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            answerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            answerView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            answerHeight,
            placeholderLabel.leadingAnchor.constraint(equalTo: answerView.leadingAnchor, constant: 17),
            placeholderLabel.topAnchor.constraint(equalTo: answerView.topAnchor, constant: 14),
            placeholderLabel.widthAnchor.constraint(equalTo: answerView.widthAnchor, constant: -34),
            sendButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            sendButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            sendButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
        ])
        privacyCover.backgroundColor = .systemBackground
        privacyCover.isAccessibilityElement = true
        privacyCover.accessibilityLabel = AppLocalized("User Interaction")
        privacyCover.isHidden = true
        privacyCover.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(privacyCover)
        NSLayoutConstraint.activate([
            privacyCover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            privacyCover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            privacyCover.topAnchor.constraint(equalTo: view.topAnchor),
            privacyCover.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        applyAppearance()
    }
    func setPrivacyHidden(_ hidden: Bool) {
        loadViewIfNeeded()
        privacyCover.isHidden = !hidden
        formScroll.accessibilityElementsHidden = hidden
        titleLabel.accessibilityElementsHidden = hidden
        cancelButton.isEnabled = !hidden
        sendButton.isEnabled = !hidden
        if hidden { view.endEditing(true) }
    }

    private func applyAppearance() {
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 19, weight: .semibold))
        questionLabel.font = .preferredFont(forTextStyle: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = UIFontMetrics(forTextStyle: .body).scaledValue(for: 5)
        questionLabel.attributedText = NSAttributedString(string: question, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body), .paragraphStyle: paragraph,
            .foregroundColor: UIColor.label
        ])
        answerLabel.font = .preferredFont(forTextStyle: .subheadline)
        answerView.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        sendButton.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        for label in [titleLabel, questionLabel, answerLabel, placeholderLabel] { label.adjustsFontForContentSizeCategory = true }
        answerView.adjustsFontForContentSizeCategory = true
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        sendButton.titleLabel?.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        questionLabel.textColor = .label
        answerLabel.textColor = .secondaryLabel
        placeholderLabel.textColor = .secondaryLabel
        answerView.textColor = .label
        answerView.backgroundColor = .tertiarySystemBackground
        answerView.layer.borderColor = (answerView.isFirstResponder ? UIColor.systemBlue : UIColor.separator)
            .resolvedColor(with: traitCollection).cgColor
        // Blue matches the approved preview; white remains readable in both modes.
        sendButton.backgroundColor = UIColor(red: 38/255.0, green: 99/255.0, blue: 217/255.0, alpha: 1)
        sendButton.setTitleColor(.white, for: .normal)
        answerHeight.constant = max(100, min(220, UIFontMetrics(forTextStyle: .body).scaledValue(for: 100)))
        view.setNeedsLayout()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyAppearance()
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            sheetPresentationController?.selectedDetentIdentifier = .large
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = formScroll.bounds.width
        guard width > 0 else { return }
        let measured = questionLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let limit = max(80, formScroll.bounds.height * 0.55)
        let desired = min(measured, limit)
        if abs(questionHeight.constant - desired) > 1 { questionHeight.constant = desired }
        if !selectedInitialDetent, view.window != nil {
            selectedInitialDetent = true
            // Medium for ordinary questions. Long/dynamic text starts expanded.
            if traitCollection.preferredContentSizeCategory.isAccessibilityCategory
                || measured + answerHeight.constant + 180 > view.bounds.height {
                sheetPresentationController?.selectedDetentIdentifier = .large
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // App backgrounding / another overlay is not a user cancellation.
        if !isSuspendingForPrivacy && (isBeingDismissed || presentingViewController == nil) { onDismissed?() }
    }
    func textViewDidChange(_ textView: UITextView) { placeholderLabel.isHidden = !textView.text.isEmpty }
    func textViewDidBeginEditing(_ textView: UITextView) { applyAppearance() }
    func textViewDidEndEditing(_ textView: UITextView) { applyAppearance() }
    @objc private func cancel() { onAnswer?("User cancelled the question.") }
    @objc private func send() { onAnswer?(answerView.text ?? "") }
}
