import AppKit
import Network

/// Decides *when* to check for a new artwork day.
///
/// The app is a login item that stays resident in the menu bar, so scheduling is done
/// in-process rather than with a launchd job:
///  - a wall-clock timer for the next change time,
///  - re-evaluation on wake, screen wake, calendar-day change, clock and time-zone changes
///    (a timer doesn't fire while the Mac sleeps — the wake check covers that),
///  - a low-frequency heartbeat as a safety net,
///  - a network-path monitor to retry promptly after an offline failure.
/// Each trigger only calls `onCheck`, which is cheap when the day hasn't changed.
@MainActor
final class DailyArtworkScheduler {
    var changeTime: ChangeTime = .midnight {
        didSet { if changeTime != oldValue { reschedule() } }
    }
    /// Called whenever the day may have changed or a retry is due.
    var onCheck: (() -> Void)?
    /// Called when the network becomes available again.
    var onNetworkAvailable: (() -> Void)?

    private var timer: Timer?
    private var heartbeat: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let pathMonitor = NWPathMonitor()
    private var wasOnline = true

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let local = NotificationCenter.default
        observe(workspace, NSWorkspace.didWakeNotification)
        observe(workspace, NSWorkspace.screensDidWakeNotification)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification)
        observe(local, .NSCalendarDayChanged)
        observe(local, .NSSystemClockDidChange)
        observe(local, .NSSystemTimeZoneDidChange)

        let heartbeat = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire(reason: "heartbeat") }
        }
        heartbeat.tolerance = 5 * 60
        RunLoop.main.add(heartbeat, forMode: .common)
        self.heartbeat = heartbeat

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if online && !self.wasOnline { self.onNetworkAvailable?() }
                self.wasOnline = online
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "DailyArt.network-monitor"))
        reschedule()
    }

    func reschedule(now: Date = Date()) {
        timer?.invalidate()
        let fireDate = ArtworkDay.nextChange(after: now, changeTime: changeTime)
        // Timers are suspended during sleep; the wake notification handles missed fires.
        let timer = Timer(fire: fireDate.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fire(reason: "scheduled")
                self?.reschedule()
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.scheduler.info("Next artwork change at \(fireDate, privacy: .public)")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.fire(reason: note.name.rawValue)
                self?.reschedule()
            }
        }
        observers.append((center, token))
    }

    private func fire(reason: String) {
        Log.scheduler.debug("Day check (\(reason, privacy: .public))")
        onCheck?()
    }
}
