import SwiftUI

/// The root of every editor sheet: a `NavigationStack` for its Cancel/Save
/// toolbar, sized on the Mac as a standard form sheet. Left alone, a Mac sheet
/// takes its content's ideal size, which for a `Form` is a cramped box that
/// cut labels off and scrolled a five-field editor.
public struct SheetStack<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        NavigationStack { content }
            .formStyle(.grouped)
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 540, minHeight: 400, idealHeight: 600)
            #endif
            .presentationSizing(.form)
    }
}
