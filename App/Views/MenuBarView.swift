import SwiftUI

/// The popover shown from the menu bar icon.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if let entry = model.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(for: entry)
                        ArtworkImageView(url: model.currentImageURL,
                                         accessibilityLabel: "\(entry.artwork.title), \(entry.artwork.attribution)")
                            .frame(maxWidth: .infinity, maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        ArtworkDetailView(artwork: entry.artwork)
                    }
                    .padding(20)
                }
                .frame(maxHeight: 560)
                .id(entry.id)
                .transition(.opacity)
            } else {
                emptyState
            }

            if let message = model.statusMessage {
                statusBanner(message)
            }

            Divider()
            controls
        }
        .frame(width: 400)
        .animation(.easeInOut(duration: 0.25), value: model.current?.id)
    }

    private func header(for entry: HistoryEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(headerTitle(for: entry))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            if let pool = model.pool {
                Text("\(model.remainingInCycle) of \(pool.artworks.count) \(pool.scope == .highlights ? "highlights" : "works") still to come")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Every eligible work is shown once, in random order, before any repeats.")
            }
        }
    }

    private func headerTitle(for entry: HistoryEntry) -> String {
        if model.isViewingPast {
            return entry.shownAt.formatted(date: .abbreviated, time: .omitted)
        }
        return Calendar.current.isDateInToday(entry.shownAt) ? "Today’s artwork" : "Current artwork"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.artframe")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            if model.isBusy || model.isRefreshingIndex {
                ProgressView("Fetching artworks from the Cleveland Museum of Art…")
                    .controlSize(.small)
            } else {
                Text("No artwork yet")
                    .font(.headline)
                Button("Get Today’s Artwork") { Task { await model.next() } }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            iconButton("Previous Artwork", systemImage: "chevron.backward", shortcut: .leftArrow) {
                Task { await model.previous() }
            }
            .disabled(!model.canGoBack || model.isBusy)

            iconButton("Next Artwork", systemImage: "chevron.forward", shortcut: .rightArrow) {
                Task { await model.next() }
            }
            .disabled(model.isBusy || model.pool == nil)

            if model.isBusy {
                ProgressView().controlSize(.small).padding(.horizontal, 6)
            }

            Spacer()

            iconButton(model.preferences.showTextOnWallpaper ? "Hide Description on Wallpaper" : "Show Description on Wallpaper",
                       systemImage: model.preferences.showTextOnWallpaper ? "text.below.photo.fill" : "photo",
                       shortcut: "t") {
                Task { await model.toggleWallpaperText() }
            }
            iconButton("Save Original Image…", systemImage: "square.and.arrow.down", shortcut: "s") {
                model.saveOriginalImage()
            }
            .disabled(model.currentImageURL == nil)
            iconButton("Open in Browser", systemImage: "safari", shortcut: "o") {
                model.openInBrowser()
            }
            .disabled(model.current?.artwork.webURL == nil)

            Menu {
                Button("History…") {
                    openWindow(id: "history")
                    NSApp.activate()
                }
                .keyboardShortcut("y")
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                .keyboardShortcut(",")
                Divider()
                Button("Quit Daily Art") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func iconButton(_ title: String, systemImage: String, shortcut: KeyEquivalent,
                            action: @escaping () -> Void) -> some View {
        let modifiers: EventModifiers = (shortcut == .leftArrow || shortcut == .rightArrow) ? [] : .command
        return Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(shortcut, modifiers: modifiers)
        .help(title)
        .accessibilityLabel(title)
    }
}
