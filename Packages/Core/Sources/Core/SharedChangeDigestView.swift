import SwiftUI

/// Every change a tapped notification was about. "Saloni made 12 changes to
/// Household" used to open the tracker and leave finding the twelve to the
/// reader.
public struct SharedChangeDigestView: View {
    let digest: SharedChangeDigest
    let tint: Color
    @Environment(\.dismiss) private var dismiss

    public init(digest: SharedChangeDigest, tint: Color = .accentColor) {
        self.digest = digest
        self.tint = tint
    }

    public var body: some View {
        SheetStack {
            List {
                Section {
                    ForEach(Array(digest.changes.enumerated()), id: \.offset) { _, change in
                        Label {
                            Text(change)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(tint)
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(digest.summary)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(digest.date, format: .relative(presentation: .named))
                            .font(.caption)
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                } footer: {
                    if digest.changes.count >= SharedChangeDigest.maximumChanges {
                        Text("Showing the first \(SharedChangeDigest.maximumChanges) changes.")
                    }
                }
            }
            .navigationTitle(digest.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(tint)
    }
}

public extension View {
    /// Shows a tapped notification's list of changes over the tracker it
    /// opened. Applied by the hub to each tracker's content, inside the
    /// phone's full-screen cover: a sheet from the hub itself would open
    /// underneath it.
    func showsSharedChangeDigest(moduleID: String, tint: Color) -> some View {
        modifier(SharedChangeDigestPresenter(moduleID: moduleID, tint: tint))
    }
}

private struct SharedChangeDigestPresenter: ViewModifier {
    let moduleID: String
    let tint: Color
    @ObservedObject private var router = SharedChangeNotificationRouter.shared
    @State private var pending: SharedChangeDigest?
    @State private var shown: SharedChangeDigest?

    func body(content: Content) -> some View {
        content
            .sheet(item: $shown) { digest in
                SharedChangeDigestView(digest: digest, tint: tint)
            }
            // `initial`, so a tap that opened this tracker is picked up once
            // the tracker exists.
            .onChange(of: router.digestToShow?.id, initial: true) {
                guard let digest = router.digestToShow, digest.moduleID == moduleID else { return }
                router.digestToShow = nil
                pending = digest
            }
            .task(id: pending?.id) {
                guard let digest = pending else { return }
                // A tap that opens the tracker presents its cover first; a
                // sheet asked for mid-transition is dropped.
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                shown = digest
                pending = nil
            }
    }
}
