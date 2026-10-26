import AppKit
import Observation
import ServiceManagement
import UniformTypeIdentifiers

/// Coordinates the repository, selection, image cache, wallpaper and scheduler, and
/// exposes state to the SwiftUI views.
@MainActor
@Observable
final class AppModel {
    let preferences: PreferencesStore

    private(set) var current: HistoryEntry?
    private(set) var currentImageURL: URL?
    private(set) var history: [HistoryEntry] = []
    private(set) var pool: ArtworkPool?
    private(set) var isBusy = false
    private(set) var isRefreshingIndex = false
    /// A user-facing explanation of the latest problem, or nil when all is well.
    private(set) var statusMessage: String?
    private(set) var canGoBack = false
    private(set) var isViewingPast = false
    private(set) var remainingInCycle = 0
    private(set) var cacheSize: Int64 = 0
    private(set) var launchAtLogin = false

    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let repository: ArtworkRepository
    @ObservationIgnored private let imageCache: ArtworkImageCache
    @ObservationIgnored private let prefetchCache: ArtworkImageCache
    @ObservationIgnored private let historyStore: ArtworkHistoryStore
    @ObservationIgnored private var selection: ArtworkSelectionManager
    @ObservationIgnored private let wallpaper: WallpaperManager
    @ObservationIgnored private let scheduler = DailyArtworkScheduler()
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var themeObserver: NSObjectProtocol?

    static let cacheRetention = 40

    init(preferences: PreferencesStore = PreferencesStore(), paths: AppPaths = .standard) {
        self.preferences = preferences
        self.paths = paths
        repository = ArtworkRepository(paths: paths)
        imageCache = ArtworkImageCache(directory: paths.imagesDirectory)
        prefetchCache = ArtworkImageCache(directory: paths.imagesDirectory, loader: ArtworkImageCache.prefetchSession())
        historyStore = ArtworkHistoryStore(fileURL: paths.stateFile)
        selection = ArtworkSelectionManager(state: historyStore.load())
        wallpaper = WallpaperManager(paths: paths)
        syncSelectionState()
        if let current, imageCache.isCached(current.artwork.id) {
            currentImageURL = imageCache.fileURL(for: current.artwork.id)
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true

        wallpaper.isActive = preferences.dailyChangeEnabled
        wallpaper.onError = { [weak self] error in self?.report(error) }
        scheduler.changeTime = preferences.changeTime
        scheduler.onCheck = { [weak self] in Task { await self?.dailyCheck() } }
        scheduler.onNetworkAvailable = { [weak self] in Task { await self?.recoverAfterOffline() } }
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Give AppKit a moment to update the effective appearance.
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, self.preferences.wallTone == .system, self.preferences.dailyChangeEnabled else { return }
                await self.reapplyWallpaper()
            }
        }
        setUpLaunchAtLoginOnFirstRun()

        // Show what we already have immediately (works offline), then catch up.
        if let current, currentImageURL != nil, preferences.dailyChangeEnabled {
            await show(current, applyWallpaper: true)
        }
        await loadPool()
        await dailyCheck()
        scheduler.start()
        await updateCacheSize()
    }

    // MARK: - Collection index

    func loadPool() async {
        let scope = preferences.collectionScope
        if let cached = await repository.cachedPool(scope: scope) {
            adopt(cached)
        } else {
            pool = nil
        }
        if await repository.needsRefresh(scope: scope) {
            if pool == nil {
                await refreshPool()
            } else {
                Task { await self.refreshPool() }
            }
        }
    }

    func refreshPool() async {
        guard !isRefreshingIndex else { return }
        isRefreshingIndex = true
        defer { isRefreshingIndex = false }
        do {
            adopt(try await repository.refreshPool(scope: preferences.collectionScope))
            if statusMessage != nil && current != nil { statusMessage = nil }
        } catch {
            Log.network.error("Index refresh failed: \(error.localizedDescription, privacy: .public)")
            if pool == nil {
                statusMessage = "Couldn’t reach the Cleveland Museum of Art. \(error.localizedDescription) Daily Art will try again automatically."
            }
        }
    }

    private func adopt(_ newPool: ArtworkPool) {
        pool = newPool
        selection.reconcile(poolIDs: newPool.ids, scope: newPool.scope, using: &rng)
        persist()
    }

    // MARK: - Selection

    /// Advances to a new artwork if the artwork day has changed. Cheap when it hasn't.
    func dailyCheck() async {
        guard preferences.dailyChangeEnabled else { return }
        let key = ArtworkDay.key(for: Date(), changeTime: preferences.changeTime)
        if let last = selection.state.lastDailyDayKey, last >= key, current != nil {
            await prefetchUpcoming()
            return
        }
        await advance(reason: .daily, dayKey: key)
    }

    func next() async {
        if selection.isViewingPast, let entry = selection.goForwardInHistory() {
            persist()
            await show(entry, applyWallpaper: true)
            return
        }
        await advance(reason: .manual, dayKey: ArtworkDay.key(for: Date(), changeTime: preferences.changeTime))
    }

    func previous() async {
        guard let entry = selection.goBack() else { return }
        persist()
        await show(entry, applyWallpaper: true)
    }

    func showHistoryEntry(_ id: UUID) async {
        guard let entry = selection.select(historyEntryID: id) else { return }
        persist()
        await show(entry, applyWallpaper: true)
    }

    private func advance(reason: HistoryEntry.Reason, dayKey: String) async {
        guard !isBusy else { return }
        if pool == nil { await loadPool() }
        guard let pool, !pool.artworks.isEmpty else {
            statusMessage = statusMessage ?? "The artwork list hasn’t been downloaded yet. Daily Art will retry when you’re online."
            return
        }
        isBusy = true
        defer { isBusy = false }

        // Make sure the next work in the shuffle is downloaded. If that fails (offline),
        // fall back to an already-downloaded work from later in the shuffle.
        if let head = selection.upcoming(count: 1, poolIDs: pool.ids, using: &rng).first,
           let artwork = pool.artwork(id: head) {
            do {
                _ = try await imageCache.image(for: artwork)
            } catch ImageCacheError.notFound, ImageCacheError.invalidImageData {
                Log.network.error("Image unavailable for artwork \(head); skipping it this cycle")
                selection.markUnavailable(head)
            } catch {
                Log.network.error("Download failed for artwork \(head): \(error.localizedDescription, privacy: .public)")
            }
        }
        let cached = await imageCache.cachedArtworkIDs()
        guard let entry = selection.drawNext(pool: pool, dayKey: dayKey, reason: reason, using: &rng,
                                             isAvailable: { cached.contains($0) })
        else {
            statusMessage = "You’re offline and no new artwork has been downloaded yet. Keeping the current artwork; Daily Art will try again automatically."
            return
        }
        persist()
        await show(entry, applyWallpaper: true)
        Task {
            await self.prefetchUpcoming()
            await self.pruneCache()
        }
    }

    private func show(_ entry: HistoryEntry, applyWallpaper: Bool) async {
        syncSelectionState()
        do {
            let url = try await imageCache.image(for: entry.artwork)
            guard selection.current?.id == entry.id else { return } // superseded meanwhile
            currentImageURL = url
            if applyWallpaper {
                try await wallpaper.apply(artwork: entry.artwork, imageURL: url,
                                          style: currentStyle(), policy: preferences.displayPolicy)
            }
            publishScreensaverSnapshot(entry: entry, imageURL: url)
            statusMessage = nil
        } catch {
            report(error)
        }
    }

    private func recoverAfterOffline() async {
        if pool == nil || statusMessage != nil {
            if pool == nil { await loadPool() }
            await dailyCheck()
            if let current, currentImageURL == nil { await show(current, applyWallpaper: true) }
        }
    }

    private func prefetchUpcoming() async {
        guard let pool else { return }
        let upcoming = selection.upcoming(count: 3, poolIDs: pool.ids, using: &rng)
        persist()
        for id in upcoming {
            guard !prefetchCache.isCached(id), let artwork = pool.artwork(id: id) else { continue }
            do {
                _ = try await prefetchCache.image(for: artwork)
            } catch {
                Log.network.info("Prefetch of \(id) deferred: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }

    private func pruneCache() async {
        var keep = Set(selection.state.history.suffix(20).map(\.artwork.id))
        keep.formUnion(selection.state.bag.prefix(3))
        if let current { keep.insert(current.artwork.id) }
        await imageCache.prune(keeping: keep, maxCount: Self.cacheRetention)
        await updateCacheSize()
    }

    // MARK: - Actions

    func reapplyWallpaper() async {
        guard let current, let url = currentImageURL else { return }
        do {
            try await wallpaper.apply(artwork: current.artwork, imageURL: url,
                                      style: currentStyle(), policy: preferences.displayPolicy)
            statusMessage = nil
        } catch {
            report(error)
        }
    }

    func toggleWallpaperText() async {
        preferences.showTextOnWallpaper.toggle()
        await reapplyWallpaper()
    }

    func dailyChangeSettingChanged() async {
        wallpaper.isActive = preferences.dailyChangeEnabled
        if preferences.dailyChangeEnabled { await dailyCheck() }
    }

    func changeTimeChanged() {
        scheduler.changeTime = preferences.changeTime
        // Don't jump to a new artwork just because the boundary moved: the day that
        // already has an artwork keeps it.
        if let current {
            selection.state.lastDailyDayKey = max(current.dayKey,
                                                  ArtworkDay.key(for: Date(), changeTime: preferences.changeTime))
            persist()
        }
    }

    func collectionScopeChanged() async {
        await loadPool()
        syncSelectionState()
    }

    func saveOriginalImage() {
        guard let current, let source = currentImageURL else { return }
        let panel = NSSavePanel()
        let safeTitle = current.artwork.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle) (CMA \(current.artwork.accessionNumber ?? String(current.artwork.id))).jpg"
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            report(error)
        }
    }

    func openInBrowser() {
        guard let url = current?.artwork.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    func clearCache() async {
        var keep = Set<Int>()
        if let current { keep.insert(current.artwork.id) }
        await imageCache.clear(except: keep)
        wallpaper.clearRenderedFiles()
        await updateCacheSize()
    }

    func resetHistory() {
        selection.reset()
        persist()
        syncSelectionState()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            report(error)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Opens the bundled screensaver so macOS offers to install it.
    func installScreensaver() {
        guard let saver = Bundle.main.url(forResource: "Daily Art", withExtension: "saver") else {
            statusMessage = "The screensaver isn’t bundled in this build. See the README to install it manually."
            return
        }
        NSWorkspace.shared.open(saver)
    }

    // MARK: - Helpers

    private func currentStyle() -> WallpaperStyle {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return preferences.wallpaperStyle(systemIsDark: dark)
    }

    private func publishScreensaverSnapshot(entry: HistoryEntry, imageURL: URL) {
        let directories = ScreensaverSnapshotStore.publishDirectories(paths: paths)
        Task.detached(priority: .background) {
            let failures = ScreensaverSnapshotStore.publish(artwork: entry.artwork, imageURL: imageURL,
                                                            dayKey: entry.dayKey, to: directories)
            for (dir, error) in failures {
                Log.screensaver.error("Snapshot not written to \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func persist() {
        do {
            try historyStore.save(selection.state)
        } catch {
            report(error)
        }
        syncSelectionState()
    }

    private func syncSelectionState() {
        current = selection.current
        history = selection.state.history
        canGoBack = selection.canGoBack
        isViewingPast = selection.isViewingPast
        remainingInCycle = selection.remainingInCycle
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func updateCacheSize() async {
        cacheSize = await imageCache.diskUsage()
    }

    private func report(_ error: Error) {
        Log.general.error("\(error.localizedDescription, privacy: .public)")
        statusMessage = error.localizedDescription
    }

    private func setUpLaunchAtLoginOnFirstRun() {
        let key = "didConfigureLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        // A daily wallpaper only works if the app is running, so opt in once by default.
        // The user can turn this off in Settings (or System Settings › Login Items).
        setLaunchAtLogin(true)
    }
}
