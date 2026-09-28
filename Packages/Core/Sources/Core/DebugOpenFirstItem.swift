import SwiftUI

public extension View {
    /// `-MacOpenFirstItem YES` (Debug) runs `open` shortly after launch, so a
    /// script can look at a screen only a double-click reaches — an account,
    /// a month, a guide, an order. Navigation only; a no-op in Release.
    func debugOpensFirstItem(_ open: @escaping () -> Void) -> some View {
        #if DEBUG
        task {
            guard UserDefaults.standard.bool(forKey: "MacOpenFirstItem") else { return }
            // The store is still loading when a list first appears.
            try? await Task.sleep(for: .seconds(2))
            open()
        }
        #else
        self
        #endif
    }
}
