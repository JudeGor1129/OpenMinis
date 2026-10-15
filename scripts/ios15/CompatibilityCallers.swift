import SwiftUI

/// Compile-only callers: no credentials, networking, persistence, or app state.
/// Keep both prompt closure forms, the two labeled-row initializers, and both
/// multiline input Modules covered.
private struct IOS15CompatibilityCallers: View {
    @State private var presented = false
    @State private var text = ""
    @FocusState private var transcriptFocused: Bool

    var body: some View {
        MinisNavigationContainer {
            Form {
                MinisLabeledRow("Name", value: text)
                MinisLabeledRow("Status") {
                    HStack {
                        Image(systemName: "checkmark")
                        Text("Ready")
                    }
                }
                MinisMultilineInput(title: "Instructions", text: $text,
                                    minimumLines: 4, maximumLines: 12)
                MinisFocusableMultilineInput(title: "Transcript", text: $text,
                                             isFocused: $transcriptFocused,
                                             legacyHeight: 96)
                TextEditor(text: $text)
                    .minisScrollBackgroundHidden()
                Button("Edit") { presented = true }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {}
                }
            }
        }
        .minisTextPrompt("Name", isPresented: $presented,
                         text: $text, placeholder: "Name",
                         message: "Enter a name.", confirmation: "Save") {}
        .minisTextPrompt("Folder", isPresented: $presented,
                         text: $text, placeholder: "Folder name",
                         message: "Enter a folder name.", confirmation: "Create",
                         onCancel: { text = "" }) {}
        .minisResizableSheet()
        .minisFixedSheetHeight(240)
        .minisInteractiveKeyboardDismissal()
    }
}
