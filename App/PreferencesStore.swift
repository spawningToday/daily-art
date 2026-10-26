import Foundation
import Observation

enum WallTone: String, CaseIterable, Codable {
    case system, light, dark
}

/// User preferences, persisted in UserDefaults.
@Observable
final class PreferencesStore {
    @ObservationIgnored private let defaults: UserDefaults
    /// Prevents writes while `init` is still reading stored values.
    @ObservationIgnored private var isLoaded = false

    var dailyChangeEnabled: Bool = true { didSet { save() } }
    var changeTime: ChangeTime = .midnight { didSet { save() } }
    var wallpaperMode: WallpaperMode = .gallery { didSet { save() } }
    var showTextOnWallpaper: Bool = true { didSet { save() } }
    var textSize: TextSize = .medium { didSet { save() } }
    var backdrop: BackdropStyle = .blurred { didSet { save() } }
    var wallTone: WallTone = .system { didSet { save() } }
    var displayPolicy: DisplayPolicy = .allDisplays { didSet { save() } }
    var collectionScope: CollectionScope = .highlights { didSet { save() } }

    private enum Key {
        static let dailyChangeEnabled = "dailyChangeEnabled"
        static let changeHour = "changeHour"
        static let changeMinute = "changeMinute"
        static let wallpaperMode = "wallpaperMode"
        static let showText = "showTextOnWallpaper"
        static let textSize = "textSize"
        static let backdrop = "backdrop"
        static let wallTone = "wallTone"
        static let displayPolicy = "displayPolicy"
        static let collectionScope = "collectionScope"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        dailyChangeEnabled = defaults.object(forKey: Key.dailyChangeEnabled) as? Bool ?? true
        changeTime = ChangeTime(hour: defaults.object(forKey: Key.changeHour) as? Int ?? 0,
                                minute: defaults.object(forKey: Key.changeMinute) as? Int ?? 0)
        wallpaperMode = value(Key.wallpaperMode, WallpaperMode.gallery)
        showTextOnWallpaper = defaults.object(forKey: Key.showText) as? Bool ?? true
        textSize = value(Key.textSize, TextSize.medium)
        backdrop = value(Key.backdrop, BackdropStyle.blurred)
        wallTone = value(Key.wallTone, WallTone.system)
        displayPolicy = value(Key.displayPolicy, DisplayPolicy.allDisplays)
        collectionScope = value(Key.collectionScope, CollectionScope.highlights)
        isLoaded = true
    }

    private func save() {
        guard isLoaded else { return }
        defaults.set(dailyChangeEnabled, forKey: Key.dailyChangeEnabled)
        defaults.set(changeTime.hour, forKey: Key.changeHour)
        defaults.set(changeTime.minute, forKey: Key.changeMinute)
        defaults.set(wallpaperMode.rawValue, forKey: Key.wallpaperMode)
        defaults.set(showTextOnWallpaper, forKey: Key.showText)
        defaults.set(textSize.rawValue, forKey: Key.textSize)
        defaults.set(backdrop.rawValue, forKey: Key.backdrop)
        defaults.set(wallTone.rawValue, forKey: Key.wallTone)
        defaults.set(displayPolicy.rawValue, forKey: Key.displayPolicy)
        defaults.set(collectionScope.rawValue, forKey: Key.collectionScope)
    }

    func wallpaperStyle(systemIsDark: Bool) -> WallpaperStyle {
        let dark: Bool
        switch wallTone {
        case .system: dark = systemIsDark
        case .light: dark = false
        case .dark: dark = true
        }
        return WallpaperStyle(mode: wallpaperMode, showText: showTextOnWallpaper, textSize: textSize,
                              backdrop: backdrop, isDark: dark)
    }
}
