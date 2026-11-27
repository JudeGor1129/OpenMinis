import SwiftUI
import UIKit

/// Content design for navigation destinations. Lists stay native (including
/// swipe actions, selection and edit mode); text and editors get an opaque floor.
enum MinisPageInk {
    static let thought = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.09, green: 0.14, blue: 0.20, alpha: 1) : UIColor(red: 0.94, green: 0.97, blue: 1, alpha: 1)
    })
    static let sentMessage = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.14, green: 0.19, blue: 0.25, alpha: 1) : UIColor(red: 0.90, green: 0.94, blue: 0.98, alpha: 1)
    })
}

private struct MinisCatalogRhythm: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 50
    func body(content: Content) -> some View {
        content.environment(\.defaultMinListRowHeight, rowHeight)
            .headerProminence(.increased)
    }
}

extension View {
    func minisCatalogList() -> some View {
        listStyle(InsetGroupedListStyle())
            .modifier(MinisCatalogRhythm())
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
    }
    func minisCatalogForm() -> some View {
        modifier(MinisCatalogRhythm())
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
    }
    // No listStyle here: search results, multi-select and file trees keep their layout.
    func minisPickerRows() -> some View { environment(\.defaultMinListRowHeight, 44) }
    func minisReadingSurface() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(UIColor.systemBackground))
    }
}

/// Compact destination intro: one clear headline, a short purpose statement,
/// and optional at-a-glance facts. Kept opaque; controls and lists remain native.
struct MinisPageIntro: View {
    struct Fact: Identifiable {
        let label: Text
        let value: Text
        let id: String

        init(label: String, value: String, id: String? = nil) {
            self.label = Text(LocalizedStringKey(label))
            self.value = Text(verbatim: value)
            self.id = id ?? label
        }

        init(label: String, value: Text, id: String? = nil) {
            self.label = Text(LocalizedStringKey(label))
            self.value = value
            self.id = id ?? label
        }
    }

    let title: Text
    let message: Text
    var systemImage: String? = nil
    var tint: Color = .accentColor
    var facts: [Fact] = []

    init(title: String, message: String,
         systemImage: String? = nil, tint: Color = .accentColor, facts: [Fact] = []) {
        self.title = Text(LocalizedStringKey(title))
        self.message = Text(LocalizedStringKey(message))
        self.systemImage = systemImage
        self.tint = tint
        self.facts = facts
    }

    init(title: Text, message: Text,
         systemImage: String? = nil, tint: Color = .accentColor, facts: [Fact] = []) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.facts = facts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 42, height: 42)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    title.font(.headline).accessibilityAddTraits(.isHeader)
                    message.font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !facts.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(facts) { fact in
                        VStack(alignment: .leading, spacing: 3) {
                            fact.value.font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            fact.label.font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(Color(UIColor.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

struct MinisSectionGlyph: View {
    let name: String
    let tint: Color
    var body: some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.13)))
            .accessibilityHidden(true)
    }
}

// Use a soft gradient inside the shape, not a stroke or a blur pass.
// Shadows are reserved for floating controls; dense list badges stay cheap.
private struct MinisReliefSurface<Outline: Shape, Fill: ShapeStyle>: View {
    let outline: Outline
    let fill: Fill
    let raised: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(outline: Outline, fill: Fill, raised: Bool) {
        self.outline = outline
        self.fill = fill
        self.raised = raised
    }

    @ViewBuilder private var face: some View {
        if contrast == .increased {
            outline.fill(fill)
        } else {
            let dark = scheme == .dark
            outline.fill(fill)
                .overlay {
                    outline.fill(LinearGradient(stops: [
                        .init(color: Color.white.opacity(dark ? 0.12 : 0.25), location: 0),
                        .init(color: .clear, location: 0.44),
                        .init(color: .clear, location: 0.59),
                        .init(color: Color.black.opacity(dark ? 0.16 : 0.075), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
        }
    }

    var body: some View {
        Group {
            if raised && contrast != .increased {
                face.shadow(color: Color.black.opacity(scheme == .dark ? 0.32 : 0.13), radius: 5, x: 0, y: 2)
            } else {
                face
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct MinisCapsuleMaterial: ViewModifier {
    let material: Material
    let raised: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let fill = reduceTransparency || contrast == .increased
            ? AnyShapeStyle(Color(UIColor.secondarySystemBackground))
            : AnyShapeStyle(material)
        content.minisCapsuleSurface(fill, raised: raised)
    }
}

extension View {
    func minisCapsuleSurface<S: ShapeStyle>(_ fill: S, raised: Bool = false) -> some View {
        background { MinisReliefSurface(outline: Capsule(), fill: fill, raised: raised) }
    }

    func minisMaterialCapsule(_ material: Material = .ultraThinMaterial, raised: Bool = false) -> some View {
        modifier(MinisCapsuleMaterial(material: material, raised: raised))
    }
}

enum MinisHomeGroupInk {
    // Match the different system canvases rather than imposing a page tint.
    static let legacy = groupFill(on: .systemGroupedBackground)
    static let modern = groupFill(on: .systemBackground)

    private static func groupFill(on page: UIColor) -> Color {
        Color(UIColor { traits in
            let base = page.resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard base.getRed(&r, green: &g, blue: &b, alpha: &a) else { return base }
            let dark = traits.userInterfaceStyle == .dark
            let amount: CGFloat = traits.accessibilityContrast == .high ? 0.13 : (dark ? 0.075 : 0.038)
            let tone: CGFloat = dark ? 1 : 0
            func blend(_ channel: CGFloat) -> CGFloat { channel * (1 - amount) + tone * amount }
            return UIColor(red: blend(r), green: blend(g), blue: blend(b), alpha: 1)
        })
    }
}

struct MinisCountBadge: View {
    let value: Int
    var body: some View {
        Text(verbatim: String(value)).font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 3)
            .minisCapsuleSurface(Color(UIColor.secondarySystemFill))
    }
}

/// Restricts translucent material to navigation chrome; destination content remains opaque.
private struct MinisNavigationChromeScope: ViewModifier {
    private let keepNativeBackdropVisible: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(keepNativeBackdropVisible: Bool) {
        self.keepNativeBackdropVisible = keepNativeBackdropVisible
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Use the system's material and accessibility handling on Liquid Glass.
            if keepNativeBackdropVisible {
                content.toolbarBackground(.visible, for: .navigationBar)
            } else {
                content
            }
        } else if #available(iOS 16.0, *) {
            // Change the style value, not the view branch, so toggling an
            // accessibility setting does not replace a stateful destination.
            let backdrop = reduceTransparency || colorSchemeContrast == .increased
                ? AnyShapeStyle(Color(UIColor.secondarySystemBackground))
                : AnyShapeStyle(Material.ultraThin)
            content
                .toolbarBackground(backdrop, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            content.background {
                MinisLegacyBarBackdrop(solid: reduceTransparency || colorSchemeContrast == .increased)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// iOS 15 has no toolbarBackground. Style the owning page's item only;
/// never change the shared navigation bar, its delegate, or its buttons.
private struct MinisLegacyBarBackdrop: UIViewControllerRepresentable {
    let solid: Bool

    func makeUIViewController(context: Context) -> BackdropController { BackdropController() }
    func updateUIViewController(_ controller: BackdropController, context: Context) {
        controller.solid = solid
        controller.applyIfAttached()
    }
    static func dismantleUIViewController(_ controller: BackdropController, coordinator: ()) {
        controller.restore()
    }

    final class BackdropController: UIViewController {
        var solid = false
        private weak var item: UINavigationItem?
        private var lastSolid: Bool?
        private typealias Slot = ReferenceWritableKeyPath<UINavigationItem, UINavigationBarAppearance?>
        private var overrides: [(Slot, UINavigationBarAppearance?, UINavigationBarAppearance?)] = []

        override func loadView() {
            let anchor = UIView()
            anchor.isUserInteractionEnabled = false
            anchor.isAccessibilityElement = false
            view = anchor
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyIfAttached()
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyIfAttached()
        }
        func restore() {
            if let item = item {
                for (slot, original, applied) in overrides where item[keyPath: slot] === applied {
                    item[keyPath: slot] = original
                }
            }
            overrides.removeAll()
            item = nil
            lastSolid = nil
        }
        func applyIfAttached() {
            guard let nav = navigationController else { return }
            var owner = parent
            while let candidate = owner, !nav.viewControllers.contains(where: { $0 === candidate }) {
                owner = candidate.parent
            }
            guard let target = owner?.navigationItem else { return }
            guard item !== target || lastSolid != solid else { return }
            restore()
            item = target
            lastSolid = solid
            let slots: [Slot] = [\.standardAppearance, \.scrollEdgeAppearance,
                                 \.compactAppearance, \.compactScrollEdgeAppearance]
            for slot in slots {
                let original = target[keyPath: slot]
                let base = original ?? nav.navigationBar.standardAppearance
                guard let style = base.copy() as? UINavigationBarAppearance else { continue }
                style.backgroundImage = nil
                style.backgroundEffect = solid ? nil : UIBlurEffect(style: .systemThinMaterial)
                style.backgroundColor = solid ? .secondarySystemBackground : .clear
                style.shadowImage = nil
                style.shadowColor = .clear
                target[keyPath: slot] = style
                overrides.append((slot, original, target[keyPath: slot]))
            }
        }
    }
}

/// A shaped control surface; opaque when the user requests more contrast.
struct MinisLegacyControlSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let fill = reduceTransparency || contrast == .increased
            ? AnyShapeStyle(Color(UIColor.secondarySystemBackground))
            : AnyShapeStyle(Material.thin)
        content.background { MinisReliefSurface(outline: shape, fill: fill, raised: true) }
    }
}

struct MinisLegacyPrimarySurface<S: Shape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        content.background { MinisReliefSurface(outline: shape, fill: Color(UIColor.systemBlue), raised: true) }
    }
}

extension View {
    /// Set the preference on the hosted page, not on the surrounding stack.
    /// Full-screen previews can ask for a visible native backdrop on iOS 26+.
    func minisNavigationChrome(keepNativeBackdropVisible: Bool = false) -> some View {
        modifier(MinisNavigationChromeScope(keepNativeBackdropVisible: keepNativeBackdropVisible))
    }
}

/// A navigation Module for modal roots without programmatic path bindings.
///
/// Its Interface intentionally accepts only content: no NavigationPath,
/// navigationDestination registration or externally managed push/pop state.
/// Those flows need a separate iOS 15 Implementation, not a text replacement.
struct MinisNavigationContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content
                    .minisMotionAccessibility()
                    .minisNavigationChrome()
            }
        } else {
            NavigationView {
                content.minisMotionAccessibility()
            }
            .navigationViewStyle(.stack)
        }
    }
}

// A sheet-height Module whose Interface does not expose PresentationDetent,
// which cannot appear in iOS 15 callers. Only height degrades; callers retain
// ownership of approval, cancellation and interactive-dismissal policy.
extension View {
    @ViewBuilder
    func minisFractionalSheetHeight(_ fraction: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.fraction(fraction)])
        } else {
            self
        }
    }
}

extension View {
    /// Medium/large on modern iOS; an ordinary sheet on iOS 15.
    @ViewBuilder
    func minisResizableSheet() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium, .large])
        } else {
            self
        }
    }

    /// Preserve modern toolbar visibility behavior without exposing Visibility
    /// or ToolbarPlacement in the iOS 15 Interface.
    @ViewBuilder
    func minisNavigationBarHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbar(hidden ? .hidden : .visible, for: .navigationBar)
        } else {
            self.navigationBarHidden(hidden)
        }
    }
}

/// Sheet configurations used by chat callers. No iOS 16-only types escape
/// this Interface; the iOS 15 Implementation leaves sheet sizing to UIKit.
enum MinisChatSheetSize {
    case large
    case medium
    case tokenUsage
    case attachmentChoice
}

extension View {
    @ViewBuilder
    func minisChatSheetSize(_ size: MinisChatSheetSize) -> some View {
        if #available(iOS 16.0, *) {
            switch size {
            case .large:
                self.presentationDetents([.large])
            case .medium:
                self.presentationDetents([.medium])
            case .tokenUsage:
                self.presentationDetents([.fraction(0.8), .large])
            case .attachmentChoice:
                self.presentationDetents([.height(360), .medium])
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func minisSheetGrabberHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDragIndicator(hidden ? .hidden : .visible)
        } else {
            self
        }
    }
}

extension View {
    @ViewBuilder
    func minisFixedSheetHeight(_ height: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.height(height)])
        } else {
            self
        }
    }
}

extension View {
    /// Preserve native iOS 15 backgrounds without global appearance mutations.
    @ViewBuilder
    func minisScrollBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

/// Label/value Module for settings rows. Its Interface uses only iOS 15 types;
/// modern systems keep native LabeledContent, while the legacy Implementation
/// aligns values without changing caller-owned buttons or editing behavior.
struct MinisLabeledRow<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            LabeledContent {
                content
            } label: {
                Text(LocalizedStringKey(title))
            }
        } else {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer(minLength: 12)
                content
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

extension MinisLabeledRow where Content == Text {
    init(_ title: String, value: String) {
        self.init(title) {
            Text(verbatim: value).foregroundColor(.secondary)
        }
    }
}

/// Multiline input Module. The Interface keeps text and approximate visible
/// line counts; the iOS 15 Adapter uses a scrolling TextEditor rather than
/// exposing the newer TextField axis and range-based line limit to callers.
struct MinisMultilineInput: View {
    let title: String
    @Binding var text: String
    let minimumLines: Int
    let maximumLines: Int

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            TextField(title, text: $text, axis: .vertical)
                .lineLimit(minimumLines...maximumLines)
        } else {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(height: CGFloat(max(1, minimumLines)) * 24 + 16)
                    .accessibilityLabel(Text(title))
                if text.isEmpty {
                    Text(title)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Focusable multiline input Module for callers that own keyboard lifecycle:
/// the voice transcript editor drives `@FocusState` and force-resigns the
/// responder on panel dismissal. The Interface keeps text and a Bool focus
/// binding only, because that caller relies on unbounded intrinsic growth — no
/// line range is exposed. The iOS 15 Adapter uses a fixed-height TextEditor that
/// scrolls internally; unbounded growth is the one behaviour it cannot preserve.
struct MinisFocusableMultilineInput: View {
    let title: String
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding
    /// iOS 15 Adapter only: visible height of the scrolling TextEditor.
    let legacyHeight: CGFloat

    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            TextField(title, text: $text, axis: .vertical)
                .focused(isFocused)
        } else {
            TextEditor(text: $text)
                .focused(isFocused)
                .frame(height: legacyHeight)
                .accessibilityLabel(Text(title))
        }
    }
}

/// Single-value prompt Module shared by backup flows. A sheet avoids SwiftUI
/// alert text fields, which are unsupported on iOS 15. Validation and side
/// effects remain with the caller; confirmation is deliberately always shown.
private struct MinisTextPrompt: View {
    let title: String
    let message: String
    let placeholder: String
    let confirmation: String
    @Binding var text: String
    @Binding var isPresented: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        MinisNavigationContainer {
            Form {
                Section {
                    TextField(placeholder, text: $text)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .focused($focused)
                } footer: {
                    Text(message)
                }
            }
            .minisNavigationChrome()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmation) {
                        isPresented = false
                        onConfirm()
                    }
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                focused = true
            }
        }
        // Require an explicit choice so swipe dismissal cannot skip onCancel.
        .interactiveDismissDisabled(true)
    }
}

extension View {
    func minisTextPrompt(_ title: String, isPresented: Binding<Bool>,
                         text: Binding<String>, placeholder: String,
                         message: String, confirmation: String,
                         onCancel: @escaping () -> Void = {},
                         onConfirm: @escaping () -> Void) -> some View {
        sheet(isPresented: isPresented) {
            MinisTextPrompt(title: title, message: message,
                            placeholder: placeholder, confirmation: confirmation,
                            text: text, isPresented: isPresented,
                            onCancel: onCancel, onConfirm: onConfirm)
        }
    }
}

extension View {
    /// Preserve interactive keyboard dismissal on iOS 16; iOS 15 uses its default.
    @ViewBuilder
    func minisInteractiveKeyboardDismissal() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }
}

// MARK: - iOS 15 presentation compatibility

extension View {
    @ViewBuilder
    func minisHideSystemOverlays() -> some View {
        if #available(iOS 16.0, *) {
            self.persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func minisContextMenu<MenuItems: View, Preview: View>(
        @ViewBuilder menuItems: () -> MenuItems,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.contextMenu(menuItems: menuItems, preview: preview)
        } else {
            self.contextMenu(menuItems: menuItems)
        }
    }
}

struct MinisBottomRoundedShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect,
                          byRoundingCorners: [.bottomLeft, .bottomRight],
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

private struct MinisGeometryValue<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
}

extension View {
    @ViewBuilder
    func minisOnGeometryChange<Value: Equatable & Sendable>(
        for type: Value.Type,
        of transform: @escaping @Sendable (GeometryProxy) -> Value,
        action: @escaping (Value) -> Void
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.onGeometryChange(for: type, of: transform, action: action)
        } else {
            self.background {
                GeometryReader { proxy in
                    let measured = MinisGeometryValue(value: transform(proxy))
                    Color.clear
                        .onAppear {
                            DispatchQueue.main.async { action(measured.value) }
                        }
                        .onChange(of: measured) { updated in
                            DispatchQueue.main.async { action(updated.value) }
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    func minisVisibleScrollIndicators() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(.visible)
        } else {
            // ScrollView shows indicators by default on iOS 15.
            self
        }
    }
}

// Shared, deliberately brief motion vocabulary (HIG motion.md › Providing
// feedback). Apply at the changed control, never at the app root: streaming,
// progress and restored history have no animation. Native navigation/sheets
// keep their system transitions and interactive cancellation.
@MainActor
enum MinisMotion {
    private static let base = Animation.spring(response: 0.30, dampingFraction: 0.86)

    static var feedback: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : base.speed(2.1)
    }
    static var transition: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : base
    }
    static var layout: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : base
    }
}

private struct MinisMotionAccessibility: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

extension View {
    func minisMotionAccessibility() -> some View {
        modifier(MinisMotionAccessibility())
    }
}

/// Lightweight feedback for custom plain buttons; native buttons keep their
/// platform press treatment. Geometry only changes while the finger is down.
struct MinisPressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(MinisMotion.feedback, value: configuration.isPressed)
    }
}