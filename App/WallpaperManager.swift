import AppKit

/// Renders wallpapers for each display and applies them with
/// `NSWorkspace.setDesktopImageURL(_:for:options:)`.
///
/// macOS limitation: that API changes the wallpaper of the *active Space* on each display.
/// To cover other Spaces, the manager re-applies the (already rendered) image whenever the
/// user switches Spaces. The lock screen on macOS 14+ uses the desktop wallpaper.
@MainActor
final class WallpaperManager {
    private let paths: AppPaths
    private var lastApplied: [String: URL] = [:]
    private var current: (artwork: Artwork, imageURL: URL, style: WallpaperStyle, policy: DisplayPolicy)?
    private var screenChangeTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    var onError: ((Error) -> Void)?
    /// When false (daily wallpaper turned off) the manager never touches the desktop on its own.
    var isActive = true

    init(paths: AppPaths) {
        self.paths = paths
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyRenderedFiles() }
        })
    }

    /// Composes and applies the wallpaper on the targeted displays.
    func apply(artwork: Artwork, imageURL: URL, style: WallpaperStyle, policy: DisplayPolicy) async throws {
        current = (artwork, imageURL, style, policy)
        let displays = WallpaperPlanner.targets(for: Self.currentDisplays(), policy: policy)
        let directory = paths.wallpapersDirectory
        var firstError: Error?
        var used = Set<String>()

        for display in displays {
            let canvas = WallpaperPlanner.canvas(for: display)
            let url = directory.appendingPathComponent(WallpaperPlanner.fileName(artworkID: artwork.id, canvas: canvas, style: style))
            used.insert(url.lastPathComponent)
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    let request = WallpaperRenderRequest(artwork: artwork, imageURL: imageURL, canvas: canvas, style: style)
                    // Rendering a 5K/6K bitmap takes ~0.5 s; keep it off the main thread.
                    try await Task.detached(priority: .utility) {
                        try WallpaperRenderer.renderToFile(request, url: url)
                    }.value
                }
                try setWallpaper(url, displayID: display.id)
                lastApplied[display.id] = url
            } catch {
                Log.wallpaper.error("Wallpaper for display \(display.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                firstError = firstError ?? error
            }
        }
        cleanUp(keeping: used.union(lastApplied.values.map(\.lastPathComponent)))
        if let firstError { throw firstError }
    }

    /// Re-renders after display or appearance changes, if anything is applied.
    func refresh(style: WallpaperStyle? = nil, policy: DisplayPolicy? = nil) async {
        guard isActive, let current else { return }
        do {
            try await apply(artwork: current.artwork, imageURL: current.imageURL,
                            style: style ?? current.style, policy: policy ?? current.policy)
        } catch {
            onError?(error)
        }
    }

    /// Removes rendered files (they're recreated on demand).
    func clearRenderedFiles() {
        cleanUp(keeping: Set(lastApplied.values.map(\.lastPathComponent)))
    }

    // MARK: - Private

    private func setWallpaper(_ url: URL, displayID: String) throws {
        guard let screen = NSScreen.screens.first(where: { Self.identifier(for: $0) == displayID }) else { return }
        // The bitmap already matches the display, so these options only matter if the
        // display mode changes before we re-render.
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
            .fillColor: NSColor.black,
        ]
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    private func reapplyRenderedFiles() {
        guard isActive else { return }
        for screen in NSScreen.screens {
            let id = Self.identifier(for: screen)
            guard let url = lastApplied[id], FileManager.default.fileExists(atPath: url.path) else { continue }
            if NSWorkspace.shared.desktopImageURL(for: screen) != url {
                try? setWallpaper(url, displayID: id)
            }
        }
    }

    private func screensChanged() {
        // Coalesce bursts of notifications (connecting a display sends several).
        screenChangeTask?.cancel()
        screenChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func cleanUp(keeping keep: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: paths.wallpapersDirectory.path) else { return }
        for file in files where file.hasPrefix("wallpaper-") && !keep.contains(file) {
            try? fm.removeItem(at: paths.wallpapersDirectory.appendingPathComponent(file))
        }
    }

    static func identifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return screen.localizedName
    }

    static func currentDisplays() -> [DisplayDescriptor] {
        let main = NSScreen.screens.first // The screen with the menu bar.
        return NSScreen.screens.map { screen in
            let frame = screen.frame
            let visible = screen.visibleFrame
            // Menu bar + notch at the top, Dock at the bottom or sides.
            var insets = Insets(top: frame.maxY - visible.maxY,
                                left: visible.minX - frame.minX,
                                bottom: visible.minY - frame.minY,
                                right: frame.maxX - visible.maxX)
            insets.top = max(insets.top, screen.safeAreaInsets.top, NSStatusBar.system.thickness)
            return DisplayDescriptor(id: identifier(for: screen), name: screen.localizedName,
                                     pointSize: frame.size, scale: screen.backingScaleFactor,
                                     safeInsets: insets, isMain: screen == main)
        }
    }
}
