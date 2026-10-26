import Foundation
import os

enum Log {
    static let subsystem = "local.dailyart.DailyArt"
    static let general = Logger(subsystem: subsystem, category: "general")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let wallpaper = Logger(subsystem: subsystem, category: "wallpaper")
    static let scheduler = Logger(subsystem: subsystem, category: "scheduler")
    static let screensaver = Logger(subsystem: subsystem, category: "screensaver")
}

/// File locations. Everything lives under one root so tests can use a temp directory.
struct AppPaths: Sendable {
    var root: URL

    /// ~/Library/Application Support/DailyArt (the real home, even inside a sandbox).
    static var standard: AppPaths {
        AppPaths(root: realHomeDirectory
            .appendingPathComponent("Library/Application Support/DailyArt", isDirectory: true))
    }

    /// The sandbox container that macOS uses for third-party `.saver` bundles
    /// (`legacyScreenSaver`, macOS 10.15+). The app mirrors today's artwork here so the
    /// sandboxed screensaver can read it.
    static var screensaverContainerSnapshotDirectory: URL {
        realHomeDirectory.appendingPathComponent(
            "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/DailyArt/Screensaver",
            isDirectory: true)
    }

    /// The user's actual home directory. Inside a sandbox `NSHomeDirectory()` returns the
    /// container, so ask the password database instead.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    var poolIndexDirectory: URL { root.appendingPathComponent("Index", isDirectory: true) }
    var stateFile: URL { root.appendingPathComponent("State/selection.json") }
    var imagesDirectory: URL { root.appendingPathComponent("Images", isDirectory: true) }
    var wallpapersDirectory: URL { root.appendingPathComponent("Wallpapers", isDirectory: true) }
    var snapshotDirectory: URL { root.appendingPathComponent("Screensaver", isDirectory: true) }

    func poolIndexFile(for scope: CollectionScope) -> URL {
        poolIndexDirectory.appendingPathComponent("pool-\(scope.rawValue).json")
    }
}

/// Atomic JSON persistence.
enum JSONFileStore {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
