import SwiftUI

/// Every artwork shown so far, newest first.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(entries, selection: $selection) { entry in
                HStack(spacing: 10) {
                    ArtworkImageView(url: cachedURL(for: entry), maxPixelSize: 120,
                                     accessibilityLabel: entry.artwork.title)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.artwork.title)
                            .lineLimit(1)
                        Text(entry.shownAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(entry.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let entry = entries.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ArtworkImageView(url: cachedURL(for: entry), maxPixelSize: 1400,
                                         accessibilityLabel: entry.artwork.title)
                            .frame(maxHeight: 360)
                        ArtworkDetailView(artwork: entry.artwork)
                        HStack {
                            Button("Show on Desktop") { Task { await model.showHistoryEntry(entry.id) } }
                            if let url = entry.artwork.webURL {
                                Link("Open in Browser", destination: url)
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 640, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Select an artwork", systemImage: "photo.artframe")
            }
        }
        .onAppear { selection = selection ?? model.current?.id }
    }

    private var entries: [HistoryEntry] { model.history.reversed() }

    private func cachedURL(for entry: HistoryEntry) -> URL? {
        let url = AppPaths.standard.imagesDirectory.appendingPathComponent("\(entry.artwork.id)-print.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
