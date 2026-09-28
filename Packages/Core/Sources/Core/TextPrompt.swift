import SwiftUI

public extension View {
    /// Asks for one line of text — a new vehicle's name, a category, a person.
    ///
    /// An alert with a field on the phone, which is iOS's own way. On the Mac
    /// (`ModuleLayout.sidebar`) a small form sheet instead: an alert with a
    /// text field there is the old centred panel with a squashed field, the
    /// look the Mac app was called out for ("even the popups aren't modern").
    /// The sheet's Add stays disabled until something's typed, and Return adds.
    func textPrompt(
        _ title: String,
        isPresented: Binding<Bool>,
        text: Binding<String>,
        prompt: String,
        actionTitle: String = "Add",
        action: @escaping () -> Void
    ) -> some View {
        modifier(TextPrompt(title: title, isPresented: isPresented, text: text, prompt: prompt, actionTitle: actionTitle, action: action))
    }
}

private struct TextPrompt: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    @Binding var text: String
    let prompt: String
    let actionTitle: String
    let action: () -> Void

    @Environment(\.moduleLayout) private var layout

    func body(content: Content) -> some View {
        switch layout {
        case .tabs:
            content.alert(title, isPresented: $isPresented) {
                TextField(prompt, text: $text)
                Button("Cancel", role: .cancel) {}
                Button(actionTitle, action: action)
            }
        case .sidebar:
            content.sheet(isPresented: $isPresented) {
                TextPromptSheet(title: title, text: $text, prompt: prompt, actionTitle: actionTitle) {
                    isPresented = false
                    action()
                }
            }
        }
    }
}

private struct TextPromptSheet: View {
    let title: String
    @Binding var text: String
    let prompt: String
    let actionTitle: String
    let submit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var canSubmit: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                TextField(prompt, text: $text)
                    .focused($focused)
                    .onSubmit { if canSubmit { submit() } }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        .frame(minWidth: 360, idealWidth: 400)
        .presentationSizing(.fitted)
        .onAppear { focused = true }
    }
}
