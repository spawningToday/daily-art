import Foundation

/// Today's artwork, published by the app for the screensaver.
///
/// Third-party screensavers run inside Apple's sandboxed `legacyScreenSaver` host, which
/// cannot read the app's files in general. The app therefore writes this small snapshot
/// (JSON + one JPEG) both to its own folder and to the screensaver host's container.
struct ScreensaverSnapshot: Codable, Sendable {
    var artwork: Artwork
    var imageFileName: String
    var dayKey: String
    var updatedAt: Date
}

enum ScreensaverSnapshotStore {
    static let metadataFileName = "current.json"

    /// Writes the snapshot to each directory. Returns the directories that failed.
    @discardableResult
    static func publish(artwork: Artwork, imageURL: URL, dayKey: String, to directories: [URL], now: Date = Date()) -> [URL: Error] {
        var failures: [URL: Error] = [:]
        let imageName = "artwork-\(artwork.id).jpg"
        for directory in directories {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(imageName)
                if !fm.fileExists(atPath: destination.path) {
                    try fm.copyItem(at: imageURL, to: destination)
                }
                let snapshot = ScreensaverSnapshot(artwork: artwork, imageFileName: imageName, dayKey: dayKey, updatedAt: now)
                try JSONFileStore.save(snapshot, to: directory.appendingPathComponent(metadataFileName))
                // Remove older images only after the new metadata is in place.
                for file in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
                where file.hasPrefix("artwork-") && file != imageName {
                    try? fm.removeItem(at: directory.appendingPathComponent(file))
                }
            } catch {
                failures[directory] = error
            }
        }
        return failures
    }

    /// The newest readable snapshot among `directories`.
    static func read(from directories: [URL]) -> (snapshot: ScreensaverSnapshot, imageURL: URL)? {
        var best: (snapshot: ScreensaverSnapshot, imageURL: URL)?
        for directory in directories {
            guard let snapshot = try? JSONFileStore.load(ScreensaverSnapshot.self,
                                                         from: directory.appendingPathComponent(metadataFileName))
            else { continue }
            let image = directory.appendingPathComponent(snapshot.imageFileName)
            guard FileManager.default.isReadableFile(atPath: image.path) else { continue }
            if best == nil || snapshot.updatedAt > best!.snapshot.updatedAt {
                best = (snapshot, image)
            }
        }
        return best
    }

    /// Where the app publishes snapshots.
    static func publishDirectories(paths: AppPaths) -> [URL] {
        var dirs = [paths.snapshotDirectory]
        // Only mirror into the screensaver container if macOS has created it (i.e. a
        // third-party screensaver has run at least once); never create Apple's container.
        let container = AppPaths.screensaverContainerSnapshotDirectory
        let containerRoot = container.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: containerRoot.path) {
            dirs.append(container)
        }
        return dirs
    }

    /// Where the screensaver looks, most specific first.
    static var screensaverReadDirectories: [URL] {
        let sandboxHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            sandboxHome.appendingPathComponent("Library/Application Support/DailyArt/Screensaver", isDirectory: true),
            AppPaths.screensaverContainerSnapshotDirectory,
            AppPaths.standard.snapshotDirectory,
        ]
    }
}
