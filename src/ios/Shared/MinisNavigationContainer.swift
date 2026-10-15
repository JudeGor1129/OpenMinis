import SwiftUI

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
            }
        } else {
            NavigationView {
                content
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
