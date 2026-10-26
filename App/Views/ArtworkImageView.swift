import SwiftUI

/// Displays a locally cached artwork image, decoded off the main thread at preview size.
struct ArtworkImageView: View {
    let url: URL?
    var maxPixelSize = 1000
    var accessibilityLabel: String

    @State private var image: NSImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if url != nil { ProgressView().controlSize(.small) }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: loadedURL)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isImage)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            loadedURL = nil
            return
        }
        guard url != loadedURL else { return }
        let size = maxPixelSize
        let cgImage = await Task.detached(priority: .userInitiated) {
            WallpaperRenderer.loadImage(at: url, maxPixelSize: size)
        }.value
        guard !Task.isCancelled else { return }
        if let cgImage {
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } else {
            image = nil
        }
        loadedURL = url
    }
}
