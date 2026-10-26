import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            WallpaperSettings()
                .tabItem { Label("Wallpaper", systemImage: "photo.on.rectangle") }
            CollectionSettings()
                .tabItem { Label("Collection", systemImage: "building.columns") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Toggle("Change wallpaper automatically each day", isOn: $prefs.dailyChangeEnabled)
                    .onChange(of: prefs.dailyChangeEnabled) { Task { await model.dailyChangeSettingChanged() } }
                DatePicker("New artwork at", selection: changeTimeBinding, displayedComponents: .hourAndMinute)
                    .disabled(!prefs.dailyChangeEnabled)
            } footer: {
                Text("If your Mac is asleep or off at that time, the artwork changes as soon as it wakes.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open Daily Art at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
            } footer: {
                Text("Daily Art lives in the menu bar and must be running to change your wallpaper.")
                    .foregroundStyle(.secondary)
            }

            Section("Screensaver") {
                Button("Install Screensaver…") { model.installScreensaver() }
                Text("Shows the same artwork and its story when your Mac is idle. After installing, choose “Daily Art” in System Settings › Screen Saver.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var changeTimeBinding: Binding<Date> {
        Binding(
            get: {
                let t = model.preferences.changeTime
                return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.preferences.changeTime = ChangeTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
                model.changeTimeChanged()
            })
    }
}

private struct WallpaperSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Picker("Style", selection: $prefs.wallpaperMode) {
                    Text("Gallery").tag(WallpaperMode.gallery)
                    Text("Immersive").tag(WallpaperMode.immersive)
                }
                .pickerStyle(.segmented)
                Text(prefs.wallpaperMode == .gallery
                     ? "The artwork hangs on a quiet wall beside its museum label."
                     : "The artwork fills the screen when its shape allows; otherwise it floats over a backdrop made from the image.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Text") {
                Toggle("Show title and description on wallpaper", isOn: $prefs.showTextOnWallpaper)
                Picker("Text size", selection: $prefs.textSize) {
                    Text("Small").tag(TextSize.small)
                    Text("Medium").tag(TextSize.medium)
                    Text("Large").tag(TextSize.large)
                }
                .disabled(!prefs.showTextOnWallpaper)
            }

            Section("Appearance") {
                Picker("Gallery wall", selection: $prefs.wallTone) {
                    Text("Match System").tag(WallTone.system)
                    Text("Light").tag(WallTone.light)
                    Text("Dark").tag(WallTone.dark)
                }
                Picker("Background for portrait works", selection: $prefs.backdrop) {
                    Text("Blurred artwork").tag(BackdropStyle.blurred)
                    Text("Matching color").tag(BackdropStyle.colorMatched)
                    Text("Neutral").tag(BackdropStyle.neutral)
                }
                .disabled(prefs.wallpaperMode != .immersive)
            }

            Section("Displays") {
                Picker("Show artwork on", selection: $prefs.displayPolicy) {
                    Text("All displays").tag(DisplayPolicy.allDisplays)
                    Text("Main display only").tag(DisplayPolicy.mainOnly)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.wallpaperMode) { restyle() }
        .onChange(of: prefs.showTextOnWallpaper) { restyle() }
        .onChange(of: prefs.textSize) { restyle() }
        .onChange(of: prefs.wallTone) { restyle() }
        .onChange(of: prefs.backdrop) { restyle() }
        .onChange(of: prefs.displayPolicy) { restyle() }
    }

    private func restyle() {
        Task { await model.reapplyWallpaper() }
    }
}

private struct CollectionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Picker("Artworks", selection: $prefs.collectionScope) {
                    Text("Museum highlights (recommended)").tag(CollectionScope.highlights)
                    Text("Expanded collection").tag(CollectionScope.expanded)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: prefs.collectionScope) { Task { await model.collectionScopeChanged() } }
                Text(scopeExplanation(prefs.collectionScope))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Current collection") {
                if let pool = model.pool {
                    LabeledContent("Eligible artworks", value: pool.artworks.count.formatted())
                    LabeledContent("Still to come before repeats", value: model.remainingInCycle.formatted())
                    if let total = pool.stats.apiTotal {
                        LabeledContent("Returned by the museum", value: total.formatted())
                    }
                    ForEach(pool.stats.rejections.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                        LabeledContent("Excluded: \(item.key)", value: item.value.formatted())
                    }
                    if pool.stats.malformedRecords > 0 {
                        LabeledContent("Unreadable records", value: pool.stats.malformedRecords.formatted())
                    }
                    LabeledContent("Updated", value: pool.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(durationNote(count: pool.artworks.count))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not downloaded yet.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh from Museum") { Task { await model.refreshPool() } }
                        .disabled(model.isRefreshingIndex)
                    if model.isRefreshingIndex { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func scopeExplanation(_ scope: CollectionScope) -> String {
        switch scope {
        case .highlights:
            return "Works the Cleveland Museum of Art itself features as highlights of its collection. Only CC0 images with a museum-written description are included."
        case .expanded:
            return "Every CC0 artwork with an image and a museum-written description — tens of thousands of works, not curated as highlights. Downloading the list takes a few minutes and about 50 MB."
        }
    }

    private func durationNote(count: Int) -> String {
        let months = Double(count) / 30.4
        if months < 24 {
            return "That’s about \(Int(months.rounded())) months of daily art before anything repeats. After that, the same works return in a new random order."
        }
        return "That’s about \(Int((months / 12).rounded())) years of daily art before anything repeats."
    }
}

private struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Downloaded artwork images",
                               value: ByteCountFormatter.string(fromByteCount: model.cacheSize, countStyle: .file))
                Button("Clear Downloaded Images") { Task { await model.clearCache() } }
            } footer: {
                Text("Up to \(AppModel.cacheRetention) recent and upcoming images are kept so Daily Art works offline. Today’s image is never removed.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Artworks in history", value: model.history.count.formatted())
                Button("Reset Artwork History…", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Forgets which works you’ve seen, so the full collection is reshuffled.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset artwork history?", isPresented: $confirmReset) {
            Button("Reset History", role: .destructive) { model.resetHistory() }
        } message: {
            Text("Your viewing history will be cleared. Today’s artwork stays on your desktop.")
        }
    }
}
