# Daily Art

A native macOS menu bar app that puts a new artwork from the **Cleveland Museum of Art** on your desktop every day, together with the museum's own description of the work. A companion screensaver shows the same artwork and its label.

- Swift, SwiftUI and AppKit. No third-party dependencies, no web views.
- Uses only the CMA Open Access API. No AI is used to select, rank, summarize or write anything.
- Universal: Apple Silicon and Intel. Requires **macOS 14 Sonoma or later** and **Xcode 16 or later**.

> **Build status:** this project was written on a Windows machine with no Swift toolchain. **It has not been compiled or run yet.** Phase 1 (API validation) ran against the live API. Everything else needs a first build on your Mac; see [What has and hasn't been verified](#what-has-and-hasnt-been-verified).

---

## 1. Verified API findings (Phase 1)

Measured against the live API on 25 October 2026:

| Query | Result |
|---|---|
| `highlight=1` (any license) | **300** highlighted works |
| `highlight=1&cc0&has_image=1` | **246**. All have `share_license_status: "CC0"` and `is_highlight: true`. The other 54 highlights are `Copyrighted`. |
| …with a non-empty `description` | **246 / 246** |
| …with `did_you_know` | 246 / 246 |
| …with `artlens_description` | 2 / 246 (one of them is kiosk UI copy: "INTERACTIVE · Examine this artwork with Look Closer…") |
| **Eligible after the app's filter** | **242**. Four hand scrolls are excluded: their print images are 3400 × 79–231 px, too thin to show on a desktop. |
| All CC0 works with images (`cc0&has_image=1`) | 41,806. Descriptions are sparse: about 90–99 % of records in the first 10,000 have one, 0 % in sampled pages after 30,000. |

**Pool size.** 242 works is about **8 months** of daily art before any repeat. After that the same works come back in a new random order. Settings shows the exact live count and the reasons for each exclusion.

The highlights cover a broad mix of traditions, unaltered by the app. By department: Drawings 28, Japanese 24, Korean 19, European Painting 18, Prints 18, Decorative Art 16, Medieval 16, Greek & Roman 15, Egyptian & Near Eastern 15, Art of the Americas 14, Modern European 13, Chinese 11, African 10, and more.

**Field structure surprises the code handles:**
- Image `width`, `height` and `filesize` are JSON **strings** (`"3400"`), not numbers.
- `images.annotation` is usually `null` but sometimes a string.
- `creators` is an **empty array for 107 / 246** highlights (ancient, non-Western and decorative works). The label then uses the museum's `culture` attribution, e.g. "South India, Tamil Nadu, Chola period (900–1200s)".
- `description` contains HTML: `<em>` (214 uses, titles of other works), `<br>`, `<a>`. The app keeps italics and line breaks, decodes entities, and never changes a word.
- `culture` is an array of strings.
- Dates are free text: "c. 1295–1315", "883–859 BCE", "1185–1275 (radiocarbon date, 95.4% probability)".
- Image renditions: `web` JPEG (about 900 px), `print` JPEG (longest edge 1,957–3,400 px, median 3,400, at most about 10 MB), and `full` **TIFF** (median **100 MB**, max **2.6 GB**). The app uses **print**. It never downloads the TIFFs.

## 2. Eligibility rules

A record is shown only if all of these hold. They are objective, technical checks, with no aesthetic scoring:

1. `is_highlight == true` (unless you opt into the expanded collection).
2. `share_license_status == "CC0"`, checked on the client as well as in the query.
3. A `print` image exists: an HTTPS JPEG with valid dimensions.
4. The image is at least 1600 px on the long edge and 600 px on the short edge, with width/height between 1:4 and 4:1.
5. At least one museum text field has ≥ 40 characters after removing markup, and it isn't just a copy of the catalogue `tombstone`. Preference order: `description` → `artlens_description` → `did_you_know`. The other fields are shown as extras in the app.

**Selection** is a shuffle bag. Each cycle is a uniform random permutation of the eligible pool, so nothing repeats until every work has been shown. The state survives restarts. New works the museum adds join the current cycle at random positions. Removed works disappear from it.

---

## 3. Build and run

1. Open `DailyArt.xcodeproj` in Xcode 16+.
2. Choose the **DailyArt** scheme and **My Mac** as the destination, then press **⌘R**.
3. A frame icon appears in the menu bar. There is no Dock icon (`LSUIElement`). On first launch the app downloads the highlight index (a few hundred KB), picks today's artwork, downloads one image (about 1–3 MB) and sets your wallpaper.

**Signing.** The project signs ad hoc ("Sign to Run Locally": `CODE_SIGN_IDENTITY = -`, no team), so it builds without an Apple ID. If you prefer, choose your Personal Team under *Signing & Capabilities* for both the `DailyArt` and `DailyArtSaver` targets. That makes login-item approval and screensaver loading more predictable across rebuilds.

To get a standalone app: **Product › Archive › Distribute App › Custom › Copy App**. Or build Release and copy `Daily Art.app` from the build products into `/Applications`.

**The app is not sandboxed.** It needs to write the screensaver's snapshot into the screensaver host's container (see §5). It uses the hardened runtime.

### Launch at login

On first launch the app registers itself as a login item with `SMAppService.mainApp`. A daily wallpaper only works while the app is running. Turn this off in **Settings › General** or in **System Settings › General › Login Items**. If registration fails (this happens occasionally with ad-hoc signing), the toggle stays off and the error appears in the menu bar popover. Signing with a team fixes it.

### Running the tests

In Xcode: **⌘U**. From a terminal:

```bash
xcodebuild test -project DailyArt.xcodeproj -scheme DailyArt -destination 'platform=macOS'
```

The tests need no network access. They use a fixture of five real API records (`Tests/Fixtures/cma_highlights_sample.json`) and scripted HTTP responses.

---

## 4. How it works

### Daily change

- The **artwork day** starts at the change time you choose (default midnight). With 07:00, a Mac woken at 06:30 still shows yesterday's work.
- The app stays resident in the menu bar. `DailyArtworkScheduler` re-checks on:
  - a wall-clock timer for the next change time,
  - **wake from sleep**, screens waking and session activation (timers don't fire while asleep, so a Mac that slept through the change time updates as soon as it wakes),
  - calendar-day, clock and time-zone change notifications,
  - a 30-minute heartbeat as a safety net,
  - `NWPathMonitor`, to retry promptly after an offline failure.
- Each check is a string comparison when nothing has changed, so there is no background network or CPU use.
- Manual **Next** doesn't use up the next day's automatic change. Changing the change time never skips the current artwork.

### Wallpaper rendering

The app renders a bitmap per display with Core Graphics, Core Text and Core Image, in Display P3. It then applies it with `NSWorkspace.setDesktopImageURL(_:for:options:)`.

- **Gallery** (default): the artwork hangs on a warm off-white or charcoal wall, with an exhibition-style label (artist, title, date and medium, then the museum's description and accession number). The label goes in a left column because Finder puts desktop icons on the right. It is bottom-aligned with the artwork, the way labels are hung. On portrait monitors the label goes below the work. Long descriptions are first set in slightly smaller type. Only if they still don't fit are they cut at a word boundary with "…". The full text is always in the menu bar.
- **Immersive**: landscape works fill the screen only when at most 20 % of the image would be cropped and it doesn't need enlarging by more than 1.6×. Otherwise the whole work is shown over a backdrop: blurred artwork, matching muted color, or neutral. The optional caption is a frosted card in the lower left.
- **Never stretched.** Aspect ratio is always preserved. Fitted artworks are never enlarged beyond 1.5×, so a smaller image is shown smaller rather than soft.
- The menu bar and Dock areas (from `NSScreen.visibleFrame` and `safeAreaInsets`, which covers the notch) are kept clear.
- Images are decoded with ImageIO thumbnails at exactly the size drawn. Even a 3400 px source never needs a full-resolution decode in memory.
- Render file names encode the artwork, size and style. Identical requests reuse the file. Any change gets a new path, which avoids macOS's habit of caching desktop pictures by path.
- **Multiple displays**: each display gets a bitmap at its own resolution. Choose "All displays" or "Main display only". Connecting, disconnecting or changing a display's resolution triggers a re-render after a 2-second debounce.
- **Spaces**: macOS only lets apps set the wallpaper of the *current* Space on each display. The app re-applies its already-rendered image when you switch Spaces, so every Space picks it up as you visit it.
- **Lock screen**: on macOS 14+ the lock screen shows the desktop wallpaper, so it shows the artwork too, including the label in Gallery mode.

### Offline behavior

- The eligible-artwork index is stored on disk and refreshed weekly. A failed or empty refresh never replaces it.
- The next three works in the shuffle are prefetched opportunistically, skipping expensive and Low Data networks.
- If the day changes while offline, the app uses the next already-downloaded work in the shuffle. If there is none, it keeps the current artwork and shows a note in the menu. It never shows an empty screen.
- Up to 40 recent and upcoming images are kept (about 40–120 MB). **Settings › Storage** shows the size and can clear them. Today's image is never removed.

### Files

| What | Where |
|---|---|
| Index, history, images, rendered wallpapers | `~/Library/Application Support/DailyArt/` |
| Screensaver snapshot | `…/DailyArt/Screensaver/` and the screensaver container (below) |
| Preferences | `UserDefaults` (`local.dailyart.DailyArt`) |
| Logs | Console.app, subsystem `local.dailyart.DailyArt` |

---

## 5. Screensaver

`Daily Art.saver` is a real `ScreenSaver.framework` bundle (`ScreenSaverView` subclass). It is not a fullscreen app. It shows today's artwork and its label on a dark gallery wall, rendered by the same code as the wallpaper. Every 90 seconds the composition drifts a few points over 8 seconds, to protect OLED panels from burn-in. It makes **no network requests**.

### Install

- **From the app:** *Settings › General › Install Screensaver…*. The `.saver` is embedded in the app, and macOS asks whether to install it for you or for all users.
- **Manually:** in Xcode, build the `DailyArtSaver` scheme, then **Product › Show Build Folder in Finder** and double-click `Daily Art.saver`. Or copy it to `~/Library/Screen Savers/`.

Then choose **Daily Art** in **System Settings › Screen Saver**.

### macOS constraints and how they're handled

- **Sandboxing.** Since macOS 10.15, third-party screensavers run inside Apple's sandboxed `legacyScreenSaver` process. A saver can't read other apps' files, and its home directory is redirected to `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/`. The app therefore publishes a small snapshot (today's metadata JSON plus one JPEG) in two places: its own folder, and that container's `Library/Application Support/DailyArt/Screensaver/`. The container copy is written only if the container already exists. **So: after installing, start the screensaver once (or preview it), then click Next or relaunch the app.** The snapshot is refreshed at every artwork change.
- macOS 14+ may ask **"Daily Art would like to access data from other apps"** the first time it writes to that container. Allow it, or the screensaver may only show its "Open the Daily Art app…" message.
- **Known `legacyScreenSaver` bugs (macOS 14+):** the host sometimes never calls `stopAnimation()` and keeps old instances alive. The saver listens for the `com.apple.screensaver.willstop` notification, stops all work and frees its image when it arrives. After reinstalling a new build, run `killall legacyScreenSaver` (or log out) so macOS loads the new code:

```bash
killall legacyScreenSaver
```
- The System Settings thumbnail preview omits the label, since text would be unreadable at that size.
- Apple has no non-legacy screensaver API for third parties, so `.saver` remains the supported route.

---

## 6. Project structure

```
DailyArt.xcodeproj         Xcode 16 project with synchronized folders (new files are picked up automatically)
Core/                      Shared by the app, the screensaver and the tests
  Artwork.swift              Clean Artwork / MuseumText / ArtworkImageRef models
  CMARecord.swift            Lenient Codable for raw API records
  MuseumTextFormatter.swift  HTML → styled text (italics kept, words untouched)
  ArtworkEligibilityFilter   The rules in §2
  ClevelandArtAPIClient      URLSession client, pagination, retry with backoff
  ArtworkRepository          Fetch, filter and cache the eligible index
  ArtworkSelection.swift     ArtworkSelectionManager (shuffle bag) + ArtworkHistoryStore
  ArtworkDay.swift           Change time → artwork-day keys, DST-safe
  ArtworkImageCache          Download once, validate, dedupe, prune
  WallpaperLayout.swift      Pure geometry for both modes (unit-tested)
  WallpaperRenderer.swift    Core Graphics / Core Text / Core Image rendering
  DisplayPlan.swift          Per-display canvases and file naming
  ScreensaverSnapshot.swift  App → screensaver hand-off
  AppPaths.swift             File locations, JSON store, logging
App/                       Menu bar app
  DailyArtApp, AppModel, PreferencesStore, WallpaperManager, DailyArtworkScheduler
  Views/ MenuBarView, ArtworkDetailView, ArtworkImageView, SettingsView, HistoryView
Saver/DailyArtScreenSaverView.swift
Tests/                     XCTest + real API fixture
```

### Menu bar shortcuts (while the popover is open)

| Key | Action |
|---|---|
| ← / → | Previous / next artwork |
| ⌘S | Save the original image |
| ⌘O | Open the work on clevelandart.org |
| ⌘T | Show or hide the description on the wallpaper |
| ⌘Y | History window |
| ⌘, | Settings |
| ⌘Q | Quit |

---

## What has and hasn't been verified

**Verified here:**
- Every API claim in §1 (field types, counts, image sizes, HTML usage, rejections), from live requests.
- The test fixture is made of real records from those requests.

**Not verified (no Mac in this environment):**
- **Nothing has been compiled.** Expect a few compiler fixes on the first build. The code was reviewed carefully against the macOS 14 SDK, but that is no substitute for a compiler.
- Unit tests have not been run.
- Not exercised on real hardware: wallpaper setting, multi-display and Spaces behavior, login-item registration, sleep/wake scheduling, the screensaver inside `legacyScreenSaver`, the container-write permission prompt, and the visual quality of the rendered wallpapers.
- The look of the Gallery and Immersive wallpapers is designed, not yet seen. Spacing and type sizes live in `WallpaperLayout.swift` and `LabelTypesetter.build` if you want to tune them after seeing them on your monitor.

Artwork images and texts: The Cleveland Museum of Art, released under CC0.
