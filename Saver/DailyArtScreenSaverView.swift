import AppKit
import QuartzCore
import ScreenSaver

/// The Daily Art screensaver: today's artwork and its museum label on a dark gallery wall.
///
/// - Reads the snapshot the app publishes (no network access, no API calls).
/// - Renders once per screen size with the same renderer as the wallpaper, then only moves
///   a layer, so it's nearly free while running.
/// - Drifts the composition a few points every so often to avoid burn-in on OLED panels.
///
/// The explicit Objective-C name must stay unique among all installed screensavers and
/// must match `NSPrincipalClass` in the bundle's Info.plist.
@objc(DailyArtScreenSaverView)
final class DailyArtScreenSaverView: ScreenSaverView {
    private let artLayer = CALayer()
    private let messageLayer = CATextLayer()
    private var renderedSize: CGSize = .zero
    private var renderGeneration = 0
    private var lastDrift = Date()
    private var stopObserver: NSObjectProtocol?
    private var isIdle = true
    /// When no snapshot exists yet, look again periodically (the app may publish one).
    private var retryAt: Date?

    private static let driftInterval: TimeInterval = 90
    private var driftMargin: CGFloat { isPreview ? 0 : 16 }
    private static let wallColor = WallpaperPalette.dark.wall

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        if let stopObserver { DistributedNotificationCenter.default().removeObserver(stopObserver) }
    }

    private func setUp() {
        animationTimeInterval = 1.0 // Only drift bookkeeping happens per frame.
        let root = CALayer()
        root.backgroundColor = Self.wallColor
        layer = root
        wantsLayer = true

        artLayer.contentsGravity = .resizeAspect
        artLayer.opacity = 0
        root.addSublayer(artLayer)

        messageLayer.alignmentMode = .center
        messageLayer.isWrapped = true
        messageLayer.fontSize = isPreview ? 11 : 18
        messageLayer.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        messageLayer.foregroundColor = WallpaperPalette.dark.secondary
        messageLayer.isHidden = true
        root.addSublayer(messageLayer)

        // On macOS 14+ the screensaver host often never calls stopAnimation() and keeps
        // the view alive; this notification is the reliable signal to go idle.
        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.goIdle() }
        }
    }

    // MARK: - ScreenSaverView

    override func startAnimation() {
        super.startAnimation()
        isIdle = false
        lastDrift = Date()
        loadArtwork()
    }

    override func stopAnimation() {
        super.stopAnimation()
        goIdle()
    }

    override func animateOneFrame() {
        guard !isIdle else { return }
        if bounds.size != renderedSize {
            loadArtwork()
        } else if let retryAt, Date() >= retryAt {
            self.retryAt = nil
            loadArtwork()
        } else if !isPreview, Date().timeIntervalSince(lastDrift) >= Self.driftInterval {
            drift()
        }
    }

    override func draw(_ rect: NSRect) {
        NSColor(cgColor: Self.wallColor)?.setFill()
        rect.fill()
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    // MARK: - Rendering

    private func loadArtwork() {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        renderedSize = size
        renderGeneration += 1
        let generation = renderGeneration
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let margin = driftMargin
        let preview = isPreview
        let artSize = CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let found = ScreensaverSnapshotStore.read(from: ScreensaverSnapshotStore.screensaverReadDirectories) else {
                DispatchQueue.main.async {
                    guard let self, generation == self.renderGeneration else { return }
                    self.retryAt = Date().addingTimeInterval(30)
                    self.showMessage("Open the Daily Art app once to prepare today’s artwork.")
                }
                Log.screensaver.error("No artwork snapshot found")
                return
            }
            let canvas = RenderCanvas(pixelWidth: max(1, Int(artSize.width * scale)),
                                      pixelHeight: max(1, Int(artSize.height * scale)),
                                      scale: scale, safeInsets: .zero)
            // The System Settings thumbnail is too small for readable text.
            let style = WallpaperStyle(mode: .gallery, showText: !preview, textSize: .medium, backdrop: .neutral, isDark: true)
            let request = WallpaperRenderRequest(artwork: found.snapshot.artwork, imageURL: found.imageURL,
                                                 canvas: canvas, style: style)
            let image: CGImage?
            do {
                image = try WallpaperRenderer.render(request)
            } catch {
                Log.screensaver.error("Render failed: \(error.localizedDescription, privacy: .public)")
                image = nil
            }
            DispatchQueue.main.async {
                guard let self, generation == self.renderGeneration else { return }
                if let image {
                    self.present(image, size: artSize, scale: scale)
                } else {
                    self.showMessage("Today’s artwork couldn’t be displayed.")
                }
            }
        }
    }

    private func present(_ image: CGImage, size: CGSize, scale: CGFloat) {
        messageLayer.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artLayer.contents = image
        artLayer.contentsScale = scale
        artLayer.bounds = CGRect(origin: .zero, size: size)
        artLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = artLayer.presentation()?.opacity ?? 0
        fade.toValue = 1
        fade.duration = isPreview ? 0.3 : 2.0
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        artLayer.opacity = 1
        artLayer.add(fade, forKey: "fade")
    }

    /// Moves the whole composition by a few points with a slow ease, so no pixel shows
    /// the same static content for hours. The wall color matches the background, so the
    /// shift itself is invisible apart from the movement.
    private func drift() {
        lastDrift = Date()
        let m = driftMargin
        guard m > 0, artLayer.contents != nil else { return }
        let target = CGPoint(x: bounds.midX + CGFloat.random(in: -m...m),
                             y: bounds.midY + CGFloat.random(in: -m...m))
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: artLayer.presentation()?.position ?? artLayer.position)
        move.toValue = NSValue(point: target)
        move.duration = 8
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artLayer.position = target
        CATransaction.commit()
        artLayer.add(move, forKey: "drift")
    }

    private func showMessage(_ text: String) {
        artLayer.contents = nil
        messageLayer.string = text
        messageLayer.contentsScale = window?.backingScaleFactor ?? 2
        let width = min(bounds.width - 40, 520)
        messageLayer.frame = CGRect(x: bounds.midX - width / 2, y: bounds.midY - 30, width: width, height: 60)
        messageLayer.isHidden = false
    }

    private func goIdle() {
        isIdle = true
        renderGeneration += 1
        renderedSize = .zero
        artLayer.removeAllAnimations()
        artLayer.contents = nil
        artLayer.opacity = 0
    }
}
