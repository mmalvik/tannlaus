import os

/// Turns Bluetooth off on sleep and restores it on wake, only if it was on before, and only with Bluetooth permission.
///
/// Every call happens on the main actor. The sleep handler calls into the controller synchronously,
/// so Bluetooth is off and verified before the handler returns and the Mac goes to sleep.
@MainActor
public final class PowerCoordinator {
    private let controller: BluetoothController
    private let scheduler: Scheduler
    private let policy: RetryPolicy
    private let logger = Logger(subsystem: "com.tannlaus.app", category: "power")

    /// Whether Bluetooth was on before the current sleep. `nil` while awake, or if the sleep was skipped.
    /// A restore that couldn't finish without Bluetooth access sets it to `true` early, for the next wake.
    private var wasOnBeforeSleep: Bool?
    private var pendingRetry: (target: BluetoothPower, cancellable: Cancellable)?

    /// Creating the coordinator never touches Bluetooth.
    public init(controller: BluetoothController, scheduler: Scheduler, policy: RetryPolicy = .standard) {
        self.controller = controller
        self.scheduler = scheduler
        self.policy = policy
    }

    public func handleWillSleep() {
        logger.info("Will sleep")
        if cancelPendingRetry() == .on, wasOnBeforeSleep == nil {
            // A wake restore was still in progress, so the user's Bluetooth was on. Record it even
            // without access, so the next wake still restores it.
            wasOnBeforeSleep = true
            logger.info("Wake restore was still pending, recording Bluetooth as on")
        }

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
        apply(.off, attempt: 0)
    }

    public func handleDidWake() {
        logger.info("Did wake")
        cancelPendingRetry()

        guard let wasOn = wasOnBeforeSleep else {
            logger.info("No sleep recorded, leaving Bluetooth unchanged")
            return
        }
        wasOnBeforeSleep = nil

        guard wasOn else {
            logger.info("Bluetooth was off before sleep, leaving it off")
            return
        }
        guard isAuthorized(for: "wake") else { return }
        apply(.on, attempt: 0)
    }

    private func isAuthorized(for event: String) -> Bool {
        let authorization = controller.authorization
        guard authorization == .allowed else {
            logger.error("Skipping \(event, privacy: .public): Bluetooth access is \(String(describing: authorization), privacy: .public)")
            return false
        }
        return true
    }

    /// Sets the power state, checks the state the controller read back, and schedules a retry if it didn't take effect.
    private func apply(_ target: BluetoothPower, attempt: Int) {
        pendingRetry = nil
        // Access can be revoked between retries; the sleep and wake handlers check it for the first attempt.
        if attempt > 0, !isAuthorized(for: "retry") {
            if target == .on {
                // Keep the restore for the next wake, like a sleep during a pending restore does.
                wasOnBeforeSleep = true
            }
            return
        }
        logger.info("Turning Bluetooth \(target.rawValue, privacy: .public) (attempt \(attempt + 1))")
        do {
            let state = try controller.setPower(target)
            if state == target {
                logger.info("Read back: Bluetooth is \(state.rawValue, privacy: .public)")
                return
            }
            logger.error("Read back: Bluetooth is \(state.rawValue, privacy: .public), expected \(target.rawValue, privacy: .public)")
        } catch {
            logger.error("Turning Bluetooth \(target.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }

        guard attempt < policy.delays.count else {
            logger.fault("Giving up turning Bluetooth \(target.rawValue, privacy: .public) after \(attempt + 1) attempts")
            return
        }
        let delay = policy.delays[attempt]
        logger.info("Retrying in \(String(describing: delay), privacy: .public)")
        let cancellable = scheduler.schedule(after: delay) { [weak self] in
            self?.apply(target, attempt: attempt + 1)
        }
        pendingRetry = (target, cancellable)
    }

    /// Cancels a pending retry and returns the power state it was trying to reach.
    @discardableResult
    private func cancelPendingRetry() -> BluetoothPower? {
        guard let pending = pendingRetry else { return nil }
        pending.cancellable.cancel()
        pendingRetry = nil
        logger.info("Cancelled pending retry to turn Bluetooth \(pending.target.rawValue, privacy: .public)")
        return pending.target
    }
}
