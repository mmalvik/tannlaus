import os

/// Turns Bluetooth off on sleep and restores it on wake, only if it was on before, and only with Bluetooth permission.
/// With "Keep Bluetooth on when docked", Bluetooth stays on while the Mac sleeps docked to an external display.
///
/// Every handler runs on the main actor. The sleep handler calls into the controller synchronously and
/// retries in place, so Bluetooth is set and verified before the handler returns and the Mac goes to sleep.
/// The wake restore and dock changes while asleep run in the background with scheduled retries, so they
/// never block the menu.
///
/// Measured on macOS 27 (MacBook, 2026-11-16): brief and dark wakes, for example from plugging in a
/// charger, send system power "will power on" and "has powered on" but never NSWorkspace "did wake".
/// So only `handleDidWake()` restores Bluetooth; dock events only re-check the dock while asleep.
@MainActor
public final class PowerCoordinator {
    private let controller: BluetoothController
    private let scheduler: Scheduler
    private let environment: DockEnvironment
    private let dock: DockTracker
    private let sleepPolicy: RetryPolicy
    private let wakePolicy: RetryPolicy
    private let dockPolicy: RetryPolicy
    private let logger = Logger(category: "power")

    /// "Keep Bluetooth on when docked". When false, sleep and wake behave exactly as in 1.0.
    public var keepOnWhenDocked: Bool

    /// Whether Bluetooth was on before the current sleep. `nil` while awake, or if the sleep was skipped.
    /// Only set at sleep, so a choice the user makes while awake is never overridden on the next wake.
    private var wasOnBeforeSleep: Bool?

    /// What the dock rule last chose while asleep. A dock event that gives the same answer changes
    /// nothing, so a change that gave up isn't retried until the answer changes. `nil` while awake.
    private var dockTarget: BluetoothPower?

    private enum Work: Equatable {
        /// The wake restore.
        case restore
        /// A dock change while asleep.
        case dock(BluetoothPower)

        var target: BluetoothPower {
            switch self {
            case .restore: .on
            case .dock(let target): target
            }
        }
    }

    /// A change running in the background or waiting for a retry.
    private var work: Work?
    private var pendingRetry: Cancellable?
    /// Held while a dock change runs, so a dark wake doesn't end halfway through it.
    private var sleepAssertion: Cancellable?
    /// Bumped by every sleep, wake and new dock change, so results from work they interrupted are ignored.
    private var generation = 0
    /// Calls to the controller running in the background, and system sleep acknowledgements waiting for them.
    private var callsInBackground = 0
    private var pendingAcknowledgements: [@MainActor () -> Void] = []

    /// Creating the coordinator never touches Bluetooth. It reads the displays and power source,
    /// and the displays at launch count as settled.
    public init(
        controller: BluetoothController,
        scheduler: Scheduler,
        environment: DockEnvironment,
        keepOnWhenDocked: Bool = true,
        sleepPolicy: RetryPolicy = .sleep,
        wakePolicy: RetryPolicy = .wake,
        dockPolicy: RetryPolicy = .dock,
        settleDelay: Duration = DockTracker.defaultSettleDelay
    ) {
        self.controller = controller
        self.scheduler = scheduler
        self.environment = environment
        self.keepOnWhenDocked = keepOnWhenDocked
        self.sleepPolicy = sleepPolicy
        self.wakePolicy = wakePolicy
        self.dockPolicy = dockPolicy
        dock = DockTracker(environment: environment, scheduler: scheduler, settleDelay: settleDelay)
        dock.onSettled = { [weak self] in
            self?.recheckDock(after: "displays settled")
        }
    }

    /// The last settled display state.
    public var dockSnapshot: DockSnapshot {
        dock.settled
    }

    // MARK: Sleep and wake (NSWorkspace)

    public func handleWillSleep() {
        logger.info("Will sleep")
        if interruptWork() == .restore, wasOnBeforeSleep == nil {
            // A wake restore was still in progress, so the user's Bluetooth was on. Record it even
            // without access, so the next wake still restores it.
            wasOnBeforeSleep = true
            logger.info("Wake restore was still in progress, recording Bluetooth as on")
        }
        // A restore call still running in the background could otherwise land after the change below.
        scheduler.waitForBackgroundWork()

        guard isAuthorized(for: "sleep") else { return }

        var current: BluetoothPower?
        if let wasOn = wasOnBeforeSleep {
            // A second sleep without a wake in between, or an interrupted restore: keep what was recorded.
            logger.info("Bluetooth already recorded as \(wasOn ? "on" : "off", privacy: .public) before sleep, keeping it")
        } else {
            do {
                let state = try controller.powerState()
                wasOnBeforeSleep = state == .on
                current = state
                logger.info("Bluetooth is \(state.rawValue, privacy: .public) before sleep")
            } catch {
                logger.error("Could not read Bluetooth state before sleep: \(String(describing: error), privacy: .public). Leaving Bluetooth unchanged")
                return
            }
        }

        guard wasOnBeforeSleep == true else {
            logger.info("Bluetooth was off before sleep, leaving it off")
            return
        }

        // Recorded as on either way, so the wake restore and the undock rule still work.
        let target: BluetoothPower = keepOnWhenDocked && dock.settled.isDocked ? .on : .off
        dockTarget = target
        if keepOnWhenDocked {
            let action = target == .on && current == .on ? "keeping Bluetooth on" : "turning Bluetooth \(target.rawValue)"
            logDockDecision(at: "will sleep", action: action)
        }
        guard current != target else { return }
        switchBeforeSleep(to: target)
    }

    public func handleDidWake() {
        logger.info("Did wake")
        let interrupted = interruptWork()
        dockTarget = nil

        let wasOn: Bool
        if let recorded = wasOnBeforeSleep {
            wasOn = recorded
        } else if interrupted == .restore {
            // A second wake while a restore was still in progress: start the restore again.
            wasOn = true
            logger.info("Wake restore was still in progress, restarting it")
        } else {
            logger.info("No sleep recorded, leaving Bluetooth unchanged")
            return
        }
        wasOnBeforeSleep = nil

        guard wasOn else {
            logger.info("Bluetooth was off before sleep, leaving it off")
            return
        }
        guard isAuthorized(for: "wake") else { return }
        runInBackground(.restore, attempt: 0)
    }

    // MARK: Dock events (IOKit, CoreGraphics)

    /// A display, power, lid or system power change. While asleep with Bluetooth recorded as on,
    /// it re-checks the dock: docked makes sure Bluetooth is on, not docked turns it off.
    /// It never restores Bluetooth on its own; only `handleDidWake()` does.
    public func handle(_ event: DockEvent) {
        switch event {
        case .displaysChanged:
            dock.displaysChanged()
        case .powerSourceUpdated:
            guard dock.powerSourceUpdated() else { return }
        case .lidChanged, .systemWillPowerOn, .systemHasPoweredOn, .systemWillSleep:
            break
        }
        recheckDock(after: event.description)
    }

    /// System power "will sleep". Re-checks the dock, then acknowledges once no Bluetooth call is
    /// running, so a dark wake can't end halfway through a change. macOS waits up to 30 s for this.
    public func handleSystemWillSleep(acknowledge: @escaping @MainActor () -> Void) {
        handle(.systemWillSleep)
        if callsInBackground > 0 {
            logger.info("Delaying the sleep acknowledgement until the Bluetooth call finishes")
            pendingAcknowledgements.append(acknowledge)
        } else {
            acknowledge()
        }
    }

    private func recheckDock(after event: String) {
        // Only while asleep with Bluetooth recorded as on: awake, or with Bluetooth off, there is nothing to keep.
        guard keepOnWhenDocked, wasOnBeforeSleep == true else { return }
        guard isAuthorized(for: "dock check") else { return }

        let target: BluetoothPower = dock.settled.isDocked ? .on : .off
        if work == .dock(target) {
            logDockDecision(at: event, action: "already turning Bluetooth \(target.rawValue)")
            return
        }
        if work == nil, dockTarget == target {
            logDockDecision(at: event, action: "Bluetooth stays \(target.rawValue)")
            return
        }
        logDockDecision(at: event, action: "turning Bluetooth \(target.rawValue)")
        interruptWork()
        dockTarget = target
        sleepAssertion = environment.preventSleep(reason: "Tannlaus is turning Bluetooth \(target.rawValue) while the Mac sleeps")
        runInBackground(.dock(target), attempt: 0)
    }

    /// One line per dock decision, for bug reports.
    private func logDockDecision(at event: String, action: String) {
        logger.notice("Dock check (\(event, privacy: .public)): \(self.dock.settled.summary, privacy: .public); \(action, privacy: .public)")
    }

    // MARK: Switching

    private func isAuthorized(for event: String) -> Bool {
        let authorization = controller.authorization
        guard authorization == .allowed else {
            logger.error("Skipping \(event, privacy: .public): Bluetooth access is \(String(describing: authorization), privacy: .public)")
            return false
        }
        return true
    }

    /// Switches Bluetooth, retrying in place: the Mac may sleep as soon as the sleep handler returns,
    /// so a retry scheduled for later would never run.
    private func switchBeforeSleep(to target: BluetoothPower) {
        for attempt in 0...sleepPolicy.delays.count {
            if attempt > 0 {
                let delay = sleepPolicy.delays[attempt - 1]
                logger.info("Retrying in \(String(describing: delay), privacy: .public)")
                scheduler.pause(for: delay)
                guard isAuthorized(for: "retry") else { return }
            }
            if Self.attempt(target, number: attempt, controller: controller, logger: logger) {
                return
            }
        }
        logger.fault("Giving up turning Bluetooth \(target.rawValue, privacy: .public) after \(self.sleepPolicy.delays.count + 1) attempts")
    }

    /// Switches Bluetooth in the background, and schedules a retry if it didn't take effect.
    private func runInBackground(_ work: Work, attempt: Int) {
        pendingRetry = nil
        // Access can be revoked between retries. Drop the change then, as a wake without access does.
        if attempt > 0, !isAuthorized(for: "retry") {
            finishWork()
            return
        }
        self.work = work
        let generation = generation
        let target = work.target
        let controller = controller
        let logger = logger
        callsInBackground += 1
        scheduler.runInBackground({
            Self.attempt(target, number: attempt, controller: controller, logger: logger)
        }, then: { [weak self] succeeded in
            guard let self else { return }
            self.backgroundCallFinished()
            guard self.generation == generation else { return } // A sleep, wake or newer dock change took over.
            self.attemptFinished(work, attempt: attempt, succeeded: succeeded)
        })
    }

    private func attemptFinished(_ work: Work, attempt: Int, succeeded: Bool) {
        guard !succeeded else {
            finishWork()
            return
        }
        let policy = work == .restore ? wakePolicy : dockPolicy
        guard attempt < policy.delays.count else {
            logger.fault("Giving up turning Bluetooth \(work.target.rawValue, privacy: .public) after \(attempt + 1) attempts")
            finishWork()
            return
        }
        let delay = policy.delays[attempt]
        logger.info("Retrying in \(String(describing: delay), privacy: .public)")
        pendingRetry = scheduler.schedule(after: delay) { [weak self] in
            self?.runInBackground(work, attempt: attempt + 1)
        }
    }

    private func finishWork() {
        work = nil
        releaseSleepAssertion()
    }

    private func backgroundCallFinished() {
        callsInBackground -= 1
        guard callsInBackground == 0, !pendingAcknowledgements.isEmpty else { return }
        let acknowledgements = pendingAcknowledgements
        pendingAcknowledgements = []
        logger.info("Bluetooth call finished, acknowledging system sleep")
        acknowledgements.forEach { $0() }
    }

    private func releaseSleepAssertion() {
        sleepAssertion?.cancel()
        sleepAssertion = nil
    }

    /// Stops the work in progress: cancels its pending retry and ignores the result of a call
    /// still running. Returns the work that was in progress, if any.
    @discardableResult
    private func interruptWork() -> Work? {
        generation += 1
        pendingRetry?.cancel()
        pendingRetry = nil
        releaseSleepAssertion()
        guard let work else { return nil }
        self.work = nil
        switch work {
        case .restore: logger.info("Interrupted the wake restore in progress")
        case .dock(let target): logger.info("Interrupted turning Bluetooth \(target.rawValue, privacy: .public) for the dock")
        }
        return work
    }

    /// Sets the power state once and checks the state the controller read back. Blocks; safe off the main actor.
    private nonisolated static func attempt(
        _ target: BluetoothPower,
        number: Int,
        controller: BluetoothController,
        logger: Logger
    ) -> Bool {
        logger.info("Turning Bluetooth \(target.rawValue, privacy: .public) (attempt \(number + 1))")
        do {
            let state = try controller.setPower(target)
            if state == target {
                logger.info("Read back: Bluetooth is \(state.rawValue, privacy: .public)")
                return true
            }
            logger.error("Read back: Bluetooth is \(state.rawValue, privacy: .public), expected \(target.rawValue, privacy: .public)")
        } catch {
            logger.error("Turning Bluetooth \(target.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        return false
    }
}
