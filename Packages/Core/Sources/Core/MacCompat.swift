#if os(macOS)
import SwiftUI

// iOS-only SwiftUI spelling, redefined here so the feature packages compile on
// the Mac without being rewritten.
//
// The trackers are phone apps that happen to also build for macOS: the screens
// are full of modifiers AppKit never had — keyboard types, navigation bar title
// modes, full-screen covers. Absorbing them in one file keeps every `#if` in
// Core, so the iOS code that actually ships on TestFlight stays readable and
// stays the thing being tested.
//
// This has to be `#if os(macOS)`, not an availability check. `if #available(iOS
// 26, *)` reads like an iOS gate but the `*` means "and every other platform",
// so on a Mac build that branch is taken unconditionally. Compile-time
// conditionals are the only thing that actually keeps iOS API off the Mac.
//
// On iOS the whole file is empty and the real SwiftUI API is used, unchanged.

// MARK: - Stand-in argument types

// These exist only to give the shimmed modifiers below something to take, so
// the call sites can keep writing `.decimalPad` and `.inline`. The values are
// never read; the names mirror UIKit and SwiftUI so a reader comparing the two
// platforms sees the same vocabulary.

/// UIKit's `UIKeyboardType`. A Mac has one keyboard and it is always the full one.
public enum UIKeyboardType: Sendable {
    case `default`
    case asciiCapable
    case numbersAndPunctuation
    case URL
    case numberPad
    case phonePad
    case namePhonePad
    case emailAddress
    case decimalPad
    case twitter
    case webSearch
    case asciiCapableNumberPad
}

/// SwiftUI's `TextInputAutocapitalization`, which is iOS-only for the same
/// reason: there is no software keyboard to ask for capitals.
public struct TextInputAutocapitalization: Sendable {
    public static let never = TextInputAutocapitalization()
    public static let words = TextInputAutocapitalization()
    public static let sentences = TextInputAutocapitalization()
    public static let characters = TextInputAutocapitalization()
}

/// Stands in for `NavigationBarItem.TitleDisplayMode`.
///
/// Deliberately not named after the SwiftUI type it replaces: SwiftUI still
/// declares `NavigationBarItem` on macOS, just marked unavailable, and a
/// same-named type in Core would make the bare name ambiguous. Nothing calls it
/// by name anyway — every call site writes `.inline`.
public enum NavigationBarTitleDisplayMode: Sendable {
    case automatic
    case inline
    case large
}

// MARK: - Shimmed modifiers

public extension View {
    /// No software keyboard to configure.
    func keyboardType(_ type: UIKeyboardType) -> some View { self }

    /// No software keyboard means no autocapitalisation to ask it for.
    func textInputAutocapitalization(_ style: TextInputAutocapitalization?) -> some View { self }

    /// A window title is always inline; there is no large title to collapse.
    func navigationBarTitleDisplayMode(_ displayMode: NavigationBarTitleDisplayMode) -> some View { self }

    /// A full-screen cover is a phone idiom — the Mac already gave the app a
    /// window. Presenting a sheet instead keeps the modality the screen was
    /// written around rather than dropping the presentation entirely.
    func fullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss, content: content)
    }

    /// As above, for the `isPresented` spelling.
    func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }
}

// MARK: - Stand-in UIKit types

/// UIKit's `UIPasteboard`, as far as copying a string goes.
///
/// SwiftUI has no way to write to the clipboard — `PasteButton` only reads, and
/// `.copyable` is Mac-only — so the Trips module's Codes screen copies through
/// UIKit on iOS. On the Mac the same line lands here and goes through AppKit.
public struct UIPasteboard: Sendable {
    public static let general = UIPasteboard()

    public var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        nonmutating set {
            NSPasteboard.general.clearContents()
            if let newValue {
                NSPasteboard.general.setString(newValue, forType: .string)
            }
        }
    }
}

// MARK: - Stand-in views

/// SwiftUI's `EditButton` in name only.
///
/// On iOS the button flips a list into edit mode so rows sprout delete and
/// reorder handles. AppKit has no such mode — and no `\.editMode` environment
/// value to drive one — because `.onDelete` and `.onMove` are already reachable
/// there by dragging a row or using its context menu. So there is genuinely
/// nothing for this button to toggle, and it draws nothing rather than putting
/// a dead control in the toolbar.
public struct EditButton: View {
    public init() {}

    public var body: some View { EmptyView() }
}
#endif
