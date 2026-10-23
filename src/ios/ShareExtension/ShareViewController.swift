import UIKit

/// Stages files before completing the source app's share request.
class ShareViewController: UIViewController {
    private var finished = false
    private var processingTask: Task<Void, Never>?
    private var watchdog: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.center = view.center
        spinner.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin,
                                    .flexibleLeftMargin, .flexibleRightMargin]
        view.addSubview(spinner)
        spinner.startAnimating()

        // A broken provider must not hold the source app's share sheet forever.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.processingTask?.cancel()
            self.finish(openHost: false)
        }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let vm = ShareViewModel()
            let items = (self.extensionContext?.inputItems as? [NSExtensionItem]) ?? []
            await vm.processExtensionItems(items)
            guard !Task.isCancelled, !self.finished else { return }
            let saved = vm.save()
            guard saved, SharedContainerStore.loadPendingShare() != nil else {
                self.finished = true
                self.watchdog?.cancel()
                self.extensionContext?.cancelRequest(withError: NSError(
                    domain: "OpenMinis.Share", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "无法读取或保存共享文件，请在 OpenMinis 内添加文件。"]
                ))
                return
            }
            self.finish(openHost: true)
        }
    }

    @MainActor
    private func finish(openHost: Bool) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel()
        watchdog = nil

        // Capture the application before dismissing the extension. Release the
        // source app first; opening the host synchronously while the source is
        // still waiting on completeRequest can wedge the iOS15 transition.
        var responder: UIResponder? = self
        var application: UIApplication?
        while let current = responder {
            if let app = current as? UIApplication { application = app; break }
            responder = current.next
        }
        let host = application
        extensionContext?.completeRequest(returningItems: []) { _ in
            guard openHost, let host, let url = URL(string: "minis://share") else { return }
            DispatchQueue.main.async {
                if #available(iOS 18.0, *) {
                    host.open(url, options: [:], completionHandler: nil)
                } else {
                    host.perform(sel_registerName("openURL:"), with: url)
                }
            }
        }
    }
}
