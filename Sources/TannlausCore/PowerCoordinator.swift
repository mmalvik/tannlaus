import os

/// Turns Bluetooth off on sleep and restores it on wake, only if it was on before, and only with Bluetooth permission.
/// With "Keep Bluetooth on when docked", Bluetooth stays on while a Mac laptop sleeps docked to an external display.
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

    /// Whether this Mac is a laptop. A desktop Mac always has a monitor connected, so it would
    /// always count as docked and Bluetooth would never go off; the docked rule only applies to laptops.
    public let isLaptop: Bool

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
    /// Held while asleep and docked-rule work is pending, so a dark wake doesn't end halfway
    /// through. See `updateSleepHold()`.
    private var sleepAssertion: Cancellable?
    /// A re-check that would switch Bluetooth, waiting out `wakeGrace` in case this is a full wake.
    private var pendingRecheck: Cancellable?

    /// How long a re-check from a lid, power or system power event waits before switching.
    ///
    /// Measured on macOS 27 (2026-11-16): on a full wake, system power "will power on" and the lid
    /// event arrive 0.01–0.45 s before NSWorkspace "did wake" (T1–T10). Acting on them at once could
    /// turn Bluetooth off just before the wake restore turns it on again. Brief charger wakes
    /// lasted 1.6–4.3 s from "will power on" to "will sleep", and sleep waits for this anyway.
    public static let wakeGrace: Duration = .seconds(1)
    /// Bumped by every sleep, wake and new dock change, so results from work they interrupted are ignored.
    private var generation = 0
    /// Calls to the controller running in the background, and system sleep acknowledgements waiting
    /// for them or for a display change to settle.
    private var callsInBackground = 0
    private var pendingAcknowledgements: [@MainActor () -> Void] = []

    /// Creating the coordinator never touches Bluetooth. It reads the displays, power source and
    /// whether this Mac is a laptop, and the displays at launch count as settled.
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
        isLaptop = environment.isLaptop()
        dock = DockTracker(environment: environment, scheduler: scheduler, settleDelay: settleDelay)
        dock.onSettled = { [weak self] in
            self?.displaysSettled()
        }
        if !isLaptop {
            logger.notice("Not a laptop: Bluetooth goes off at every sleep, docked or not")
        }
    }

    /// Whether the docked rule is in use: the setting is on and this Mac is a laptop.
    private var dockRuleApplies: Bool {
        keepOnWhenDocked && isLaptop
    }

    /// What the docked rule wants while asleep with Bluetooth recorded as on.
    private var dockRuleTarget: BluetoothPower {
        dockRuleApplies && dock.settled.isDocked ? .on : .off
    }

    /// The last settled display state.
    public var dockSnapshot: DockSnapshot {
        dock.settled
    }

    // MARK: Sleep and wake (NSWorkspace)

    public func handleWillSleep() {
        logger.notice("Will sleep")
        // A display change still settling (an undock right before sleep) needs the Mac awake.
        defer { updateSleepHold() }
        if interruptWork() == .restore, wasOnBeforeSleep == nil {
            // A wake restore was still in progress, so the user's Bluetooth was on. Record it even
            // without access, so the next wake still restores it.
            wasOnBeforeSleep = true
            logger.notice("Wake restore was still in progress, recording Bluetooth as on")
        }
        // A restore call still running in the background could otherwise land after the change below.
        scheduler.waitForBackgroundWork()

        guard isAuthorized(for: "sleep") else { return }

        var current: BluetoothPower?
        if let wasOn = wasOnBeforeSleep {
            // A second sleep without a wake in between, or an interrupted restore: keep what was recorded.
            logger.notice("Bluetooth already recorded as \(wasOn ? "on" : "off", privacy: .public) before sleep, keeping it")
        } else {
            do {
                let state = try controller.powerState()
                wasOnBeforeSleep = state == .on
                current = state
                logger.notice("Bluetooth is \(state.rawValue, privacy: .public) before sleep")
            } catch {
                logger.error("Could not read Bluetooth state before sleep: \(String(describing: error), privacy: .public). Leaving Bluetooth unchanged")
                return
            }
        }

        guard wasOnBeforeSleep == true else {
            logger.notice("Bluetooth was off before sleep, leaving it off")
            return
        }

        // Recorded as on either way, so the wake restore and the undock rule still work.
        let target = dockRuleTarget
        dockTarget = target
        if dockRuleApplies {
            let action = target == .on && current == .on ? "keeping Bluetooth on" : "turning Bluetooth \(target.rawValue)"
            logDockDecision(at: "will sleep", action: action, persist: true)
        }
        guard current != target else { return }
        switchBeforeSleep(to: target)
    }

    public func handleDidWake() {
        logger.notice("Did wake")
        defer { updateSleepHold() }
        let interrupted = interruptWork()
        dockTarget = nil

        let wasOn: Bool
        if let recorded = wasOnBeforeSleep {
            wasOn = recorded
        } else if interrupted == .restore {
            // A second wake while a restore was still in progress: start the restore again.
            wasOn = true
            logger.notice("Wake restore was still in progress, restarting it")
        } else {
            logger.notice("No sleep recorded, leaving Bluetooth unchanged")
            return
        }
        wasOnBeforeSleep = nil

        guard wasOn else {
            logger.notice("Bluetooth was off before sleep, leaving it off")
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
        defer { updateSleepHold() }
        switch event {
        case .displaysChanged:
            dock.displaysChanged()
        case .powerSourceUpdated:
            guard dock.powerSourceUpdated() else { return }
            dock.refreshIfQuiet()
        case .lidChanged, .systemWillPowerOn, .systemHasPoweredOn, .systemWillSleep:
            // An undock while asleep may come with no display event at all, so read the list again.
            dock.refreshIfQuiet()
        }
        recheckDock(after: event.description, immediately: false)
    }

    /// System power "will sleep". Re-checks the dock, then acknowledges once no docked-rule work is
    /// pending and no Bluetooth call is running, so the Mac can't sleep halfway through.
    /// macOS waits up to 30 s for this. The longest wait is a settle (3 s), the wake grace (1 s)
    /// and a dock change with all its retries (about 19 s with the controller's timeouts).
    public func handleSystemWillSleep(acknowledge: @escaping @MainActor () -> Void) {
        pendingAcknowledgements.append(acknowledge)
        handle(.systemWillSleep)
        if !pendingAcknowledgements.isEmpty {
            logger.info("Delaying the sleep acknowledgement until the dock check finishes")
        }
    }

    private func displaysSettled() {
        recheckDock(after: "displays settled", immediately: true)
        updateSleepHold()
    }

    /// Re-checks the dock while asleep. A change found after a lid, power or system power event
    /// waits `wakeGrace` first, and a wake or new sleep in between cancels it.
    private func recheckDock(after event: String, immediately: Bool) {
        // Only while asleep with Bluetooth recorded as on: awake, or with Bluetooth off, there is nothing to keep.
        guard dockRuleApplies, wasOnBeforeSleep == true else { return }
        guard isAuthorized(for: "dock check") else { return }

        let target = dockRuleTarget
        guard target != dockTarget else {
            // Already there, already switching, or gave up: never start again for the same answer.
            let action = work == nil ? "Bluetooth stays \(target.rawValue)" : "already turning Bluetooth \(target.rawValue)"
            logDockDecision(at: event, action: action, persist: false)
            return
        }
        guard immediately else {
            guard pendingRecheck == nil else { return } // Don't postpone the one already waiting.
            logger.info("Dock check (\(event, privacy: .public)): would turn Bluetooth \(target.rawValue, privacy: .public); waiting in case this is a full wake")
            pendingRecheck = scheduler.schedule(after: Self.wakeGrace) { [weak self] in
                guard let self else { return }
                self.pendingRecheck = nil
                self.recheckDock(after: event, immediately: true)
                self.updateSleepHold()
            }
            return
        }
        logDockDecision(at: event, action: "turning Bluetooth \(target.rawValue)", persist: true)
        interruptWork()
        dockTarget = target
        runInBackground(.dock(target), attempt: 0)
    }

    /// One line per dock decision, for bug reports. The decision at each sleep, even "keeping
    /// Bluetooth on", and every later one that changes Bluetooth are kept on disk (notice); the
    /// many re-checks that change nothing, from repeated lid and power messages, are info.
    private func logDockDecision(at event: String, action: String, persist: Bool) {
        let level: OSLogType = persist ? .default : .info
        logger.log(level: level, "Dock check (\(event, privacy: .public)): \(self.dock.settled.summary, privacy: .public); \(action, privacy: .public)")
    }

    /// Docked-rule work that may still change Bluetooth: a display change settling, a re-check
    /// waiting out the wake grace, or a dock change running or waiting for a retry.
    private var dockWorkPending: Bool {
        guard dockRuleApplies else { return false }
        if dock.isSettling || pendingRecheck != nil { return true }
        if case .dock = work { return true }
        return false
    }

    /// Keeps the Mac from sleeping while docked-rule work is pending, and lets it sleep once done.
    /// Called at the end of every entry point: each event, sleep, wake, settle, attempt and retry.
    ///
    /// - While asleep with Bluetooth recorded as on, holds a sleep assertion. Dark wakes lasted
    ///   8–22 s when measured, and the settle alone takes 3 s. The assertion times out after 30 s,
    ///   and macOS may sleep while it is held (on battery), so it is renewed on every call; taking
    ///   the new one before releasing the old leaves no gap.
    /// - Acknowledges system sleep once no docked-rule work is pending and no Bluetooth call is
    ///   running. With the docked rule off, it acknowledges at once, as 1.0 never waited.
    private func updateSleepHold() {
        let needed = wasOnBeforeSleep == true && dockWorkPending && controller.authorization == .allowed
        let previous = sleepAssertion
        sleepAssertion = needed ? environment.preventSleep(reason: "Tannlaus is checking the dock while the Mac sleeps") : nil
        previous?.cancel()

        let busy = dockRuleApplies && (callsInBackground > 0 || dockWorkPending)
        guard !busy, !pendingAcknowledgements.isEmpty else { return }
        let acknowledgements = pendingAcknowledgements
        pendingAcknowledgements = []
        acknowledgements.forEach { $0() }
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
                logger.notice("Retrying in \(String(describing: delay), privacy: .public)")
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
            self.work = nil
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
            self.callsInBackground -= 1
            // Ignored if a sleep, wake or newer dock change took over.
            if self.generation == generation {
                self.attemptFinished(work, attempt: attempt, succeeded: succeeded)
            }
            // After scheduling any retry, so a pending retry still holds back the sleep acknowledgement.
            self.updateSleepHold()
        })
    }

    private func attemptFinished(_ work: Work, attempt: Int, succeeded: Bool) {
        guard !succeeded else {
            self.work = nil
            return
        }
        let policy = work == .restore ? wakePolicy : dockPolicy
        guard attempt < policy.delays.count else {
            logger.fault("Giving up turning Bluetooth \(work.target.rawValue, privacy: .public) after \(attempt + 1) attempts")
            self.work = nil
            return
        }
        let delay = policy.delays[attempt]
        logger.notice("Retrying in \(String(describing: delay), privacy: .public)")
        pendingRetry = scheduler.schedule(after: delay) { [weak self] in
            self?.runInBackground(work, attempt: attempt + 1)
            self?.updateSleepHold()
        }
    }

    /// Stops the work in progress: cancels its pending retry and any re-check waiting out the wake
    /// grace, and ignores the result of a call still running. Returns the work that was in progress, if any.
    @discardableResult
    private func interruptWork() -> Work? {
        generation += 1
        pendingRetry?.cancel()
        pendingRetry = nil
        pendingRecheck?.cancel()
        pendingRecheck = nil
        guard let work else { return nil }
        self.work = nil
        switch work {
        case .restore: logger.notice("Interrupted the wake restore in progress")
        case .dock(let target): logger.notice("Interrupted turning Bluetooth \(target.rawValue, privacy: .public) for the dock")
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
        logger.notice("Turning Bluetooth \(target.rawValue, privacy: .public) (attempt \(number + 1))")
        do {
            let state = try controller.setPower(target)
            if state == target {
                logger.notice("Read back: Bluetooth is \(state.rawValue, privacy: .public)")
                return true
            }
            logger.error("Read back: Bluetooth is \(state.rawValue, privacy: .public), expected \(target.rawValue, privacy: .public)")
        } catch {
            logger.error("Turning Bluetooth \(target.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        return false
    }
}
