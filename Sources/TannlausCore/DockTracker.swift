import os

/// Keeps the last *settled* display state, so a flickering display list can't make the Mac look
/// undocked, and filters power source notifications down to real changes of source.
///
/// Measured on macOS 27 (MacBook, Dell U2717D, 2026-11-16):
/// - Connecting the monitor: added, removed 1.5 s later, added again 0.9 s after that.
/// - Every wake: the monitor is removed and added again 0.6–1.2 s later, sometimes with the
///   placeholder display listed in between for about 0.4 s.
/// - Closing the lid on a sleeping docked Mac: a full wake, the wake removal above, and a new
///   will-sleep 0.14 s later, before the monitor was added back.
/// So a display change only counts once the list has been quiet for `settleDelay`, and the sleep
/// handler uses the settled state rather than the list at that instant.
@MainActor
public final class DockTracker {
    /// A few seconds: longer than every flicker above, short enough to act within a dark wake.
    public static let defaultSettleDelay: Duration = .seconds(3)

    private let environment: DockEnvironment
    private let scheduler: Scheduler
    private let settleDelay: Duration
    private let logger = Logger(category: "dock")

    /// The display state once the list stopped changing.
    private(set) var settled: DockSnapshot
    private var pendingSettle: Cancellable?
    private var lastPowerSource: PowerSource

    /// Called every time the display list settles.
    var onSettled: (() -> Void)?

    /// Reads the current displays and power source; the state at launch counts as settled.
    init(environment: DockEnvironment, scheduler: Scheduler, settleDelay: Duration) {
        self.environment = environment
        self.scheduler = scheduler
        self.settleDelay = settleDelay
        settled = DockSnapshot(displays: environment.onlineDisplays())
        lastPowerSource = environment.powerSource()
        logger.info("Displays at launch: \(self.settled.summary, privacy: .public); power: \(self.lastPowerSource.rawValue, privacy: .public)")
    }

    /// Whether a display change is waiting to settle.
    var isSettling: Bool {
        pendingSettle != nil
    }

    /// Restarts the settle timer. The settled state is unchanged until the list is quiet.
    func displaysChanged() {
        pendingSettle?.cancel()
        pendingSettle = scheduler.schedule(after: settleDelay) { [weak self] in
            self?.settle()
        }
    }

    /// Reads the list again after a lid, power or system power event, unless a display change is
    /// still settling. With no display event for `settleDelay`, the list is quiet, so it counts
    /// as settled at once.
    ///
    /// Measured on macOS 27: an undock while asleep may be reported only by the power source and
    /// lid callbacks in a dark wake of about 8 s, with no display callback (T10), and the list
    /// changed exactly when a display callback arrived, never between callbacks. So reading it
    /// here is as safe as a settle, and fast enough to act within that dark wake.
    func refreshIfQuiet() {
        guard pendingSettle == nil else { return }
        update(to: DockSnapshot(displays: environment.onlineDisplays()))
    }

    /// Whether the providing power source changed since the last call. Battery level updates
    /// fire the same notification about once a minute and return false.
    func powerSourceUpdated() -> Bool {
        let source = environment.powerSource()
        guard source != lastPowerSource else { return false }
        logger.info("Power source changed from \(self.lastPowerSource.rawValue, privacy: .public) to \(source.rawValue, privacy: .public)")
        lastPowerSource = source
        return true
    }

    private func settle() {
        pendingSettle = nil
        update(to: DockSnapshot(displays: environment.onlineDisplays()))
        onSettled?()
    }

    private func update(to snapshot: DockSnapshot) {
        if snapshot.isDocked != settled.isDocked {
            logger.info("Displays settled, now \(snapshot.summary, privacy: .public)")
        }
        settled = snapshot
    }
}
