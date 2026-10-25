import SwiftUI
import UIKit

/// [T-ios15-inverted-ctxmenu-bridge]
///
/// The legacy iOS 15 transcript renders its ScrollView and each row with a
/// 180° rotation so that native scroll offset 0 lands on the newest message.
/// SwiftUI's `.contextMenu` (and its lifted preview platter) is composited
/// inside that transformed layer tree, so on iOS 15 the preview card and
/// menu appear rotated/vertical — the build123 long-press bug.
///
/// Instead of layering a second rotation on the bubble (which compounds),
/// we install a native `UIContextMenuInteraction` on a transparent overlay
/// `UIView`. UIKit presents the menu and preview in its own window context, so
/// both render upright while remaining anchored to the transformed bubble
/// position (UIKit accounts for the ancestor layer transforms).
///
/// The menu items mirror the build123 SwiftUI labels exactly; disabling is
/// expressed with `UIAction.attributes` rather than `.disabled`.
struct MinisInvertedContextMenuBridge: UIViewRepresentable {
    /// An already-ordered list of long-press menu items.
    let items: [MinisContextMenuAction]
    /// An opaque preview card shown while the user holds the message.
    let previewText: String

    func makeUIView(context: Context) -> UIView {
        let view = ContextMenuHostView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.attachIfNeeded(to: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Rebind the delegate on every update so the coordinator captures
        // the freshest item list / preview text without retaining stale
        // closures (important while `vm.isProcessing` flips during streaming).
        context.coordinator.parent = self
        (uiView as? ContextMenuHostView)?.attachIfNeeded(to: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class ContextMenuHostView: UIView {
        private weak var coordinator: Coordinator?
        private var interaction: UIContextMenuInteraction?

        func attachIfNeeded(to coordinator: Coordinator) {
            guard coordinator !== self.coordinator else { return }
            if let interaction { removeInteraction(interaction) }
            self.coordinator = coordinator
            let interaction = UIContextMenuInteraction(delegate: coordinator)
            self.interaction = interaction
            addInteraction(interaction)
        }
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var parent: MinisInvertedContextMenuBridge

        init(parent: MinisInvertedContextMenuBridge) {
            self.parent = parent
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            let items = parent.items
            let previewText = parent.previewText

            let actions = items.map { item -> UIAction in
                // Capture the closure by value: `item` is a struct, so it
                // cannot be captured weakly.
                let perform = item.action
                return UIAction(
                    title: item.title,
                    image: item.image.flatMap { UIImage(systemName: $0) },
                    attributes: item.isEnabled ? [] : [.disabled]
                ) { _ in
                    perform()
                }
            }

            let menu = UIMenu(
                title: "",
                children: actions,
                options: .displayInline
            )

            return UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: {
                    let controller = UIHostingController(
                        rootView: MinisInvertedContextMenuPreviewCard(text: previewText)
                    )
                    controller.view.backgroundColor = .clear
                    return controller
                },
                actionProvider: { _ in menu }
            )
        }
    }
}

/// A single item in the long-press menu. The order in `MinisInvertedContextMenuBridge.items`
/// determines the vertical order in the native menu (top-to-bottom).
struct MinisContextMenuAction: Identifiable {
    let id = UUID()
    let title: String
    let image: String?
    let isEnabled: Bool
    let action: () -> Void
}

/// An opaque rounded card matching the `tertiarySystemFill` user bubble
/// aesthetic. Rendered in a detached UIKit context, so it never inherits
/// the transcript's 180° rotation.
private struct MinisInvertedContextMenuPreviewCard: View {
    let text: String

    var body: some View {
        let shown = text.isEmpty ? " " : String(text.prefix(600))
        Text(shown)
            .font(.system(size: 15.5))
            .foregroundStyle(ChatColors.primaryText)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(UIColor.tertiarySystemFill))
            )
            .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 8)
            // Defensively re-assert upright orientation.
            .rotationEffect(.degrees(0))
            .environment(\.layoutDirection, .leftToRight)
    }
}
