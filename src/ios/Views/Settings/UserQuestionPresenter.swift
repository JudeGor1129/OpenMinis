import UIKit
import Combine
import UserNotifications

/// iOS15 A appearance is a presentation Adapter. UserAskCenter remains the
/// only owner of official user_ask answers, deadlines, cancellation and recovery.
@MainActor
final class MinisUserAskSheetPresenter: NSObject {
    static let shared = MinisUserAskSheetPresenter()
    private var controller: MinisUserAskSheetViewController?
    private var requestId: String?
    private var presenting = false
    private var dismissing = false
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var permissionTask: Task<Void, Never>?

    private override init() {
        super.init()
        UserAskCenter.shared.$asks.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        SessionLockStore.shared.objectWillChange.sink { [weak self] _ in
            // A published lock value is changing; conceal synchronously, then
            // inspect the landed values before permitting presentation/actions.
            self?.controller?.setPrivacyHidden(true)
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(resign),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(active),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    @objc private func resign() {
        controller?.setPrivacyHidden(true)
        suspendForPrivacy()
    }
    @objc private func active() { refresh(); prepareNotificationPermission() }

    func prepareNotificationPermission() {
        let lock = SessionLockStore.shared
        guard permissionTask == nil, UIApplication.shared.applicationState == .active,
              !lock.appIsLocked, !lock.showPrivacyScreen,
              UserAskSettings.load().notifyInBackground,
              BackgroundKeepAliveManager.shared.backgroundNotificationsEnabled else { return }
        permissionTask = Task { @MainActor [weak self] in
            defer { self?.permissionTask = nil }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined,
                  UIApplication.shared.applicationState == .active,
                  !SessionLockStore.shared.appIsLocked, !SessionLockStore.shared.showPrivacyScreen else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }
    func handleNotificationTap(_ id: String) -> Bool {
        guard let ask = UserAskCenter.shared.asks[id], canInteract(ask) else { return false }
        // Never rebind a presented controller to a different request. Its
        // action closures are tied to the question that created it.
        if controller != nil { return requestId == id }
        requestId = id
        refresh()
        return true
    }
    private func canInteract(_ ask: PendingAsk) -> Bool {
        let lock = SessionLockStore.shared
        return UIApplication.shared.applicationState == .active && !lock.appIsLocked
            && !lock.showPrivacyScreen && !lock.isVisuallyLocked(ask.sessionId)
            && ask.state == .pending && !ask.isExpired(at: Date())
    }
    private func host() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard var host = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow && !$0.isHidden })?.rootViewController else { return nil }
        while let next = host.presentedViewController { host = next }
        guard !host.isBeingDismissed, !host.isBeingPresented, host.viewIfLoaded?.window != nil else { return nil }
        return host
    }
    private func refresh() {
        guard !presenting, !dismissing else { return }
        if let id = requestId, let sheet = controller {
            guard let ask = UserAskCenter.shared.asks[id], ask.state == .pending,
                  !ask.isExpired(at: Date()) else { dismissResolved(); return }
            guard canInteract(ask) else { suspendForPrivacy(); return }
            sheet.render(ask)
            if sheet.presentingViewController != nil { sheet.setPrivacyHidden(false); return }
            present(sheet, ask: ask)
            return
        }
        let waiting = UserAskCenter.shared.asks.values.filter { canInteract($0) }
            .sorted { $0.createdAt < $1.createdAt }
        guard let ask = waiting.first(where: { $0.requestId == requestId }) ?? waiting.first else { return }
        requestId = ask.requestId
        let sheet = MinisUserAskSheetViewController(ask: ask)
        sheet.onAction = { [weak self] action in self?.perform(action, requestId: ask.requestId) }
        sheet.onDismissed = { [weak self] in
            if let live = UserAskCenter.shared.asks[ask.requestId], live.state == .pending,
               self?.controller?.isSuspendingForPrivacy != true {
                UserAskCenter.shared.dismiss(requestId: ask.requestId, reason: .userClosedCard)
            }
        }
        controller = sheet
        present(sheet, ask: ask)
    }
    private func perform(_ action: MinisUserAskSheetAction, requestId: String) {
        guard let ask = UserAskCenter.shared.asks[requestId], canInteract(ask) else { return }
        let center = UserAskCenter.shared
        switch action {
        case .answer(let index, let answer): center.updateAnswer(requestId: requestId, index: index, answer)
        case .submit(let index): center.submitQuestion(requestId: requestId, index: index)
        case .confirm(let index, let choice, let note): center.confirm(requestId: requestId, index: index, choice: choice, note: note)
        case .previous(let index): center.goTo(requestId: requestId, index: index)
        case .close: center.dismiss(requestId: requestId, reason: .userClosedCard)
        }
    }
    private func present(_ sheet: MinisUserAskSheetViewController, ask: PendingAsk) {
        guard canInteract(ask), let host = host() else { return }
        sheet.isSuspendingForPrivacy = false
        sheet.setPrivacyHidden(false)
        presenting = true
        host.present(sheet, animated: true) { [weak self] in
            self?.presenting = false
            self?.refresh()
            self?.prepareNotificationPermission()
        }
    }
    private func suspendForPrivacy() {
        guard let sheet = controller else { return }
        sheet.setPrivacyHidden(true)
        guard !presenting, !dismissing, sheet.presentingViewController != nil else { return }
        sheet.isSuspendingForPrivacy = true
        dismissing = true
        sheet.dismiss(animated: false) { [weak self] in self?.dismissing = false }
    }
    private func dismissResolved() {
        guard let sheet = controller else { requestId = nil; return }
        let done = { [weak self] in
            self?.controller = nil; self?.requestId = nil; self?.dismissing = false
            self?.refresh()
        }
        dismissing = true
        if sheet.presentingViewController != nil {
            sheet.dismiss(animated: UIApplication.shared.applicationState == .active, completion: done)
        } else { done() }
    }
}

private enum MinisUserAskSheetAction {
    case answer(Int, UserAskAnswer)
    case submit(Int)
    case confirm(Int, UserAskConfirmChoice, String?)
    case previous(Int)
    case close
}

@MainActor
private final class MinisUserAskSheetViewController: UIViewController, UITextViewDelegate {
    var onAction: ((MinisUserAskSheetAction) -> Void)?
    var onDismissed: (() -> Void)?
    var isSuspendingForPrivacy = false
    private var ask: PendingAsk
    private let titleLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let progressLabel = UILabel()
    private let formScroll = UIScrollView()
    private let content = UIStackView()
    private let questionLabel = UILabel()
    private let impactLabel = UILabel()
    private let optionsStack = UIStackView()
    private let answerLabel = UILabel()
    private let answerView = UITextView()
    private let placeholder = UILabel()
    private let delegateButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let denyButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private let footer = UIStackView()
    private let privacyCover = UIView()
    private var renderedIndex: Int?
    private var optionButtons: [UIButton] = []
    private var expandedForContent = false
    private var answerHeight: NSLayoutConstraint!
    private var updating = false

    init(ask: PendingAsk) {
        self.ask = ask
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .pad ? .formSheet : .pageSheet
        isModalInPresentation = true
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
        cancelButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        progressLabel.textAlignment = .center
        questionLabel.numberOfLines = 0
        questionLabel.textAlignment = .left
        impactLabel.numberOfLines = 0
        impactLabel.textColor = .secondaryLabel
        optionsStack.axis = .vertical
        optionsStack.spacing = 10
        content.axis = .vertical
        content.spacing = 14
        formScroll.keyboardDismissMode = .interactive
        answerLabel.text = AppLocalized("Your response")
        answerView.delegate = self
        answerView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        answerView.returnKeyType = .default
        answerView.layer.cornerRadius = 15
        answerView.layer.borderWidth = 1
        answerView.accessibilityLabel = AppLocalized("Your response")
        answerView.accessibilityIdentifier = "userAsk.answer"
        placeholder.text = AppLocalized("Your answer")
        placeholder.numberOfLines = 0
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        delegateButton.addTarget(self, action: #selector(delegate), for: .touchUpInside)
        previousButton.setTitle(AppLocalized("Previous question"), for: .normal)
        previousButton.addTarget(self, action: #selector(previous), for: .touchUpInside)
        denyButton.setTitle(AppLocalized("Deny"), for: .normal)
        denyButton.addTarget(self, action: #selector(deny), for: .touchUpInside)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.layer.cornerRadius = 15
        denyButton.layer.cornerRadius = 15
        footer.axis = .horizontal
        footer.spacing = 10
        footer.distribution = .fillEqually
        for button in [previousButton, denyButton, sendButton] { footer.addArrangedSubview(button) }
        for child in [titleLabel, cancelButton, progressLabel, formScroll, footer, privacyCover] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        formScroll.addSubview(content)
        for child in [questionLabel, impactLabel, optionsStack, answerLabel, answerView, delegateButton] {
            content.addArrangedSubview(child)
        }
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        answerView.addSubview(placeholder)
        privacyCover.backgroundColor = .systemBackground
        privacyCover.isHidden = true
        privacyCover.isAccessibilityElement = true
        privacyCover.accessibilityLabel = AppLocalized("User Interaction")
        let safe = view.safeAreaLayoutGuide
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
            progressLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            progressLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            progressLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            formScroll.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 14),
            formScroll.topAnchor.constraint(greaterThanOrEqualTo: cancelButton.bottomAnchor, constant: 10),
            formScroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            formScroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            formScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: formScroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: formScroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: formScroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: formScroll.contentLayoutGuide.bottomAnchor, constant: -8),
            content.widthAnchor.constraint(equalTo: formScroll.frameLayoutGuide.widthAnchor),
            answerHeight,
            placeholder.leadingAnchor.constraint(equalTo: answerView.leadingAnchor, constant: 17),
            placeholder.topAnchor.constraint(equalTo: answerView.topAnchor, constant: 14),
            placeholder.widthAnchor.constraint(equalTo: answerView.widthAnchor, constant: -34),
            delegateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            footer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            privacyCover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            privacyCover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            privacyCover.topAnchor.constraint(equalTo: view.topAnchor),
            privacyCover.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        applyAppearance()
        render(ask)
    }

    func render(_ live: PendingAsk) {
        ask = live
        guard isViewLoaded, live.questions.indices.contains(live.currentIndex) else { return }
        let index = live.currentIndex
        let q = live.questions[index]
        let a = live.answers[index]
        updating = true
        defer { updating = false }
        let changedQuestion = renderedIndex != index
        if changedQuestion {
            renderedIndex = index
            expandedForContent = false
            questionLabel.text = q.question
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = UIFontMetrics(forTextStyle: .body).scaledValue(for: 5)
            questionLabel.attributedText = NSAttributedString(string: q.question, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ])
            impactLabel.text = q.impact
            impactLabel.isHidden = (q.impact ?? "").isEmpty
            optionsStack.arrangedSubviews.forEach { optionsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
            optionButtons = []
            for (i, choice) in (q.options ?? []).enumerated() {
                let button = UIButton(type: .system)
                button.tag = i
                button.contentHorizontalAlignment = .left
                button.titleLabel?.numberOfLines = 0
                button.titleLabel?.font = .preferredFont(forTextStyle: .body)
                button.titleLabel?.adjustsFontForContentSizeCategory = true
                button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
                button.layer.cornerRadius = 12
                button.layer.borderWidth = 1
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                button.addTarget(self, action: #selector(selectOption(_:)), for: .touchUpInside)
                optionsStack.addArrangedSubview(button)
                optionButtons.append(button)
                let detail = (choice.description ?? "").isEmpty ? "" : "\n" + (choice.description ?? "")
                button.setTitle(choice.label + detail, for: .normal)
            }
            formScroll.setContentOffset(.zero, animated: false)
        }
        optionsStack.isHidden = optionButtons.isEmpty || q.type == .confirm
        for (i, button) in optionButtons.enumerated() {
            let chosen = a.selected.contains(i)
            button.backgroundColor = chosen ? UIColor.systemBlue.withAlphaComponent(0.13) : .tertiarySystemBackground
            button.layer.borderColor = (chosen ? UIColor.systemBlue : UIColor.separator).resolvedColor(with: traitCollection).cgColor
            button.setTitleColor(.label, for: .normal)
            button.accessibilityTraits = chosen ? [.button, .selected] : [.button]
        }
        // Don't replace the UITextView on every keystroke/publication: that
        // would reset its selection and Chinese marked text.
        let text = q.type == .confirm ? (a.note ?? "") : (a.otherText ?? "")
        if changedQuestion || (!answerView.isFirstResponder && answerView.text != text) { answerView.text = text }
        placeholder.isHidden = !answerView.text.isEmpty
        previousButton.isHidden = index == 0
        denyButton.isHidden = q.type != .confirm
        delegateButton.isHidden = q.type == .confirm
        delegateButton.setTitle(a.delegated ? AppLocalized("You decide ✓") : AppLocalized("You decide"), for: .normal)
        delegateButton.accessibilityTraits = a.delegated ? [.button, .selected] : [.button]
        let isLast = live.questions.indices.allSatisfy { live.submitted.contains($0) || $0 == index }
        sendButton.setTitle(q.type == .confirm ? AppLocalized("Allow") :
                            (isLast ? AppLocalized("Send answer") : AppLocalized("Next question")), for: .normal)
        sendButton.isEnabled = q.type == .confirm || a.isComplete(for: q)
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.55
        var progress = "\(index + 1) / \(live.questions.count)"
        if let expires = live.expiresAt {
            let seconds = max(0, Int(expires.timeIntervalSinceNow.rounded(.up)))
            progress += String(format: "  ·  %02d:%02d", seconds / 60, seconds % 60)
        }
        progressLabel.text = progress
    }

    private func applyAppearance() {
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 19, weight: .semibold))
        questionLabel.font = .preferredFont(forTextStyle: .body)
        impactLabel.font = .preferredFont(forTextStyle: .subheadline)
        answerLabel.font = .preferredFont(forTextStyle: .subheadline)
        answerView.font = .preferredFont(forTextStyle: .body)
        placeholder.font = .preferredFont(forTextStyle: .body)
        progressLabel.font = .preferredFont(forTextStyle: .caption1)
        for label in [titleLabel, questionLabel, impactLabel, answerLabel, placeholder, progressLabel] { label.adjustsFontForContentSizeCategory = true }
        answerView.adjustsFontForContentSizeCategory = true
        progressLabel.textColor = .secondaryLabel
        answerLabel.textColor = .secondaryLabel
        placeholder.textColor = .secondaryLabel
        questionLabel.textColor = .label
        answerView.textColor = .label
        answerView.backgroundColor = .tertiarySystemBackground
        answerView.layer.borderColor = (answerView.isFirstResponder ? UIColor.systemBlue : UIColor.separator).resolvedColor(with: traitCollection).cgColor
        for button in [cancelButton, previousButton, denyButton, sendButton, delegateButton] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
        }
        sendButton.backgroundColor = UIColor(red: 38 / 255.0, green: 99 / 255.0, blue: 217 / 255.0, alpha: 1)
        sendButton.setTitleColor(.white, for: .normal)
        denyButton.backgroundColor = .tertiarySystemBackground
        answerHeight.constant = min(220, max(100, UIFontMetrics(forTextStyle: .body).scaledValue(for: 100)))
    }
    func setPrivacyHidden(_ hidden: Bool) {
        loadViewIfNeeded()
        privacyCover.isHidden = !hidden
        content.accessibilityElementsHidden = hidden
        footer.accessibilityElementsHidden = hidden
        cancelButton.isEnabled = !hidden
        footer.isUserInteractionEnabled = !hidden
        if hidden { view.endEditing(true) }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        let index = ask.currentIndex
        applyAppearance()
        renderedIndex = nil
        render(ask)
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            sheetPresentationController?.selectedDetentIdentifier = .large
        }
        if ask.questions.indices.contains(index) { renderedIndex = index }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !expandedForContent, view.window != nil, formScroll.bounds.height > 0 else { return }
        expandedForContent = true
        if content.systemLayoutSizeFitting(CGSize(width: formScroll.bounds.width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height > formScroll.bounds.height
            || traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            sheetPresentationController?.selectedDetentIdentifier = .large
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isSuspendingForPrivacy && (isBeingDismissed || presentingViewController == nil) { onDismissed?() }
    }
    func textViewDidChange(_ textView: UITextView) {
        guard !updating, ask.answers.indices.contains(ask.currentIndex) else { return }
        let index = ask.currentIndex
        var a = ask.answers[index]
        if ask.questions[index].type == .confirm { a.note = textView.text }
        else {
            a.otherText = textView.text
            a.delegated = false
            if !ask.questions[index].multiSelect && !textView.text.isEmpty { a.selected = [] }
        }
        ask.answers[index] = a
        placeholder.isHidden = !textView.text.isEmpty
        onAction?(.answer(index, a))
    }
    func textViewDidBeginEditing(_ textView: UITextView) {
        applyAppearance()
        // The footer stays above the keyboard. Bring the answer field into the
        // outer scroll viewport, not a clipped fixed-height question area.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.formScroll.scrollRectToVisible(self.answerView.convert(self.answerView.bounds, to: self.formScroll), animated: true)
        }
    }
    func textViewDidEndEditing(_ textView: UITextView) { applyAppearance() }
    @objc private func selectOption(_ button: UIButton) {
        let index = ask.currentIndex
        guard ask.questions.indices.contains(index), ask.answers.indices.contains(index) else { return }
        var a = ask.answers[index]
        if ask.questions[index].multiSelect {
            if a.selected.contains(button.tag) { a.selected.removeAll { $0 == button.tag } }
            else { a.selected.append(button.tag) }
        } else { a.selected = [button.tag]; a.otherText = nil; answerView.text = "" }
        a.delegated = false
        onAction?(.answer(index, a))
    }
    @objc private func delegate() {
        let index = ask.currentIndex
        guard ask.answers.indices.contains(index) else { return }
        var a = ask.answers[index]
        a.delegated.toggle()
        if a.delegated { a.selected = []; a.otherText = nil; answerView.text = "" }
        onAction?(.answer(index, a))
    }
    @objc private func previous() { onAction?(.previous(max(0, ask.currentIndex - 1))) }
    @objc private func deny() { onAction?(.confirm(ask.currentIndex, .deny, answerView.text)) }
    @objc private func close() { onAction?(.close) }
    @objc private func send() {
        guard ask.questions.indices.contains(ask.currentIndex) else { return }
        if ask.questions[ask.currentIndex].type == .confirm { onAction?(.confirm(ask.currentIndex, .approve, nil)) }
        else { onAction?(.submit(ask.currentIndex)) }
    }
}
