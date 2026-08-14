import SwiftUI

/// Poster artwork from TMDB.
///
/// Images are fetched per device and left to `URLCache` rather than stored
/// alongside the watch history, so nothing image-sized ever syncs through
/// iCloud — the artwork is free to re-fetch, the watch history is not.
struct PosterView: View {
    let path: String
    var width: CGFloat = 44

    private var height: CGFloat { width * 3 / 2 }  // TMDB posters are 2:3.

    private var url: URL? {
        guard !path.isEmpty else { return nil }
        return URL(string: TMDBClient.imageBaseURL + path)
    }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    case .empty:
                        ZStack {
                            placeholder
                            ProgressView()
                                .controlSize(.small)
                        }
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .overlay(
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            )
    }
}
