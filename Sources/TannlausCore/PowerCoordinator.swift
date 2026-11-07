import os

/// Turns Bluetooth off on sleep and restores it on wake, only if it was on before, and only with Bluetooth permission.
///
/// Every handler runs on the main actor. The sleep handler calls into the controller synchronously and
/// retries in place, so Bluetooth is off and verified before the handler returns and the Mac goes to sleep.
/// The wake restore runs in the background with scheduled retries, so it never blocks the menu.
@MainActor
public final class PowerCoordinator {
    private let controller: BluetoothController
    private let scheduler: Scheduler
    private let sleepPolicy: RetryPolicy
    private let wakePolicy: RetryPolicy
    private let logger = Logger(category: "power")

    /// Whether Bluetooth was on before the current sleep. `nil` while awake, or if the sleep was skipped.
    /// Only set at sleep, so a choice the user makes while awake is never overridden on the next wake.
    private var wasOnBeforeSleep: Bool?

    /// Whether a wake restore is running in the background or waiting for a retry.
    private var isRestoring = false
    private var pendingRetry: Cancellable?
    /// Bumped by every sleep and wake, so results from a restore they interrupted are ignored.
    private var generation = 0

    /// Creating the coordinator never touches Bluetooth.
    public init(
        controller: BluetoothController,
        scheduler: Scheduler,
        sleepPolicy: RetryPolicy = .sleep,
        wakePolicy: RetryPolicy = .wake
    ) {
        self.controller = controller
        self.scheduler = scheduler
        self.sleepPolicy = sleepPolicy
        self.wakePolicy = wakePolicy
    }

    public func handleWillSleep() {
        logger.info("Will sleep")
        if interruptRestore(), wasOnBeforeSleep == nil {
            // A wake restore was still in progress, so the user's Bluetooth was on. Record it even
            // without access, so the next wake still restores it.
            wasOnBeforeSleep = true
            logger.info("Wake restore was still in progress, recording Bluetooth as on")
        }
        // A restore call still running in the background could otherwise land after the change below.
        scheduler.waitForBackgroundWork()

        guard isAuthorized(for: "sleep") else { return }

        if let wasOn = wasOnBeforeSleep {
            // A second sleep without a wake in between, or an interrupted restore: keep what was recorded.
            logger.info("Bluetooth already recorded as \(wasOn ? "on" : "off", privacy: .public) before sleep, keeping it")
        } else {
            do {
                let state = try controller.powerState()
                wasOnBeforeSleep = state == .on
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
        turnOffBeforeSleep()
    }

    public func handleDidWake() {
        logger.info("Did wake")
        let wasRestoring = interruptRestore()

        let wasOn: Bool
        if let recorded = wasOnBeforeSleep {
            wasOn = recorded
        } else if wasRestoring {
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
        restore(attempt: 0)
    }

    private func isAuthorized(for event: String) -> Bool {
        let authorization = controller.authorization
        guard authorization == .allowed else {
            logger.error("Skipping \(event, privacy: .public): Bluetooth access is \(String(describing: authorization), privacy: .public)")
            return false
        }
        return true
    }

    /// Turns Bluetooth off, retrying in place: the Mac may sleep as soon as the sleep handler returns,
    /// so a retry scheduled for later would never run.
    private func turnOffBeforeSleep() {
        for attempt in 0...sleepPolicy.delays.count {
            if attempt > 0 {
                let delay = sleepPolicy.delays[attempt - 1]
                logger.info("Retrying in \(String(describing: delay), privacy: .public)")
                scheduler.pause(for: delay)
                guard isAuthorized(for: "retry") else { return }
            }
            if Self.attempt(.off, number: attempt, controller: controller, logger: logger) {
                return
            }
        }
        logger.fault("Giving up turning Bluetooth off after \(self.sleepPolicy.delays.count + 1) attempts")
    }

    /// Turns Bluetooth on in the background, and schedules a retry if it didn't take effect.
    private func restore(attempt: Int) {
        pendingRetry = nil
        // Access can be revoked between retries. Drop the restore then, as a wake without access does.
        if attempt > 0, !isAuthorized(for: "retry") {
            isRestoring = false
            return
        }
        isRestoring = true
        let generation = generation
        let controller = controller
        let logger = logger
        scheduler.runInBackground({
            Self.attempt(.on, number: attempt, controller: controller, logger: logger)
        }, then: { [weak self] succeeded in
            guard let self, self.generation == generation else { return } // A sleep or wake took over.
            self.restoreFinished(attempt: attempt, succeeded: succeeded)
        })
    }

    private func restoreFinished(attempt: Int, succeeded: Bool) {
        guard !succeeded else {
            isRestoring = false
            return
        }
        guard attempt < wakePolicy.delays.count else {
            logger.fault("Giving up turning Bluetooth on after \(attempt + 1) attempts")
            isRestoring = false
            return
        }
        let delay = wakePolicy.delays[attempt]
        logger.info("Retrying in \(String(describing: delay), privacy: .public)")
        pendingRetry = scheduler.schedule(after: delay) { [weak self] in
            self?.restore(attempt: attempt + 1)
        }
    }

    /// Stops a wake restore in progress: cancels its pending retry and ignores the result of a call
    /// still running. Returns whether one was in progress.
    private func interruptRestore() -> Bool {
        generation += 1
        pendingRetry?.cancel()
        pendingRetry = nil
        guard isRestoring else { return false }
        isRestoring = false
        logger.info("Interrupted the wake restore in progress")
        return true
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
