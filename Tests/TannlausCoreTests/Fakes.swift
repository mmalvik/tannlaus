import TannlausCore

/// Used from one thread at a time: the fake scheduler runs "background" work inline.
final class FakeBluetoothController: BluetoothController, @unchecked Sendable {
    enum Call: Equatable {
        case read
        case set(BluetoothPower)
    }

    var authorization: BluetoothAuthorization = .allowed
    var power: BluetoothPower
    /// The number of upcoming `setPower` calls that have no effect.
    var ignoredSets = 0
    /// Thrown by every call while set.
    var error: BluetoothControllerError?
    private(set) var calls: [Call] = []

    init(power: BluetoothPower) {
        self.power = power
    }

    func powerState() throws -> BluetoothPower {
        calls.append(.read)
        if let error { throw error }
        return power
    }

    func setPower(_ power: BluetoothPower) throws -> BluetoothPower {
        calls.append(.set(power))
        if let error { throw error }
        if ignoredSets > 0 {
            ignoredSets -= 1
        } else {
            self.power = power
        }
        return self.power
    }

    var sets: [BluetoothPower] {
        calls.compactMap { if case .set(let power) = $0 { power } else { nil } }
    }
}

/// Collects scheduled work so tests can run it by hand, without waiting. Background work runs
/// inline unless `runsBackgroundInline` is false; then it waits for `finishBackgroundWork()`.
@MainActor
final class FakeScheduler: Scheduler {
    final class Item: Cancellable {
        let delay: Duration
        let work: @MainActor () -> Void
        private(set) var isCancelled = false

        init(delay: Duration, work: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.work = work
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var items: [Item] = []
    private(set) var pauses: [Duration] = []
    /// Called on every pause, to change state between attempts in the sleep handler.
    var onPause: (() -> Void)?
    var runsBackgroundInline = true
    private var backgroundWork: [() -> @MainActor () -> Void] = []
    private var undelivered: [@MainActor () -> Void] = []

    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> Cancellable {
        let item = Item(delay: delay, work: work)
        items.append(item)
        return item
    }

    func runInBackground<T: Sendable>(
        _ work: @escaping @Sendable () -> T,
        then completion: @escaping @MainActor @Sendable (T) -> Void
    ) {
        let job: () -> @MainActor () -> Void = {
            let value = work()
            return { completion(value) }
        }
        if runsBackgroundInline {
            job()()
        } else {
            backgroundWork.append(job)
        }
    }

    func waitForBackgroundWork() {
        let jobs = backgroundWork
        backgroundWork = []
        undelivered += jobs.map { $0() }
    }

    /// Runs queued background work and delivers its results.
    func finishBackgroundWork() {
        waitForBackgroundWork()
        while !undelivered.isEmpty {
            undelivered.removeFirst()()
            waitForBackgroundWork()
        }
    }

    func pause(for delay: Duration) {
        pauses.append(delay)
        onPause?()
    }

    var pending: [Item] {
        items.filter { !$0.isCancelled }
    }

    /// Runs and removes the oldest pending item. Returns false if nothing is pending.
    @discardableResult
    func runNext() -> Bool {
        guard let index = items.firstIndex(where: { !$0.isCancelled }) else { return false }
        let item = items.remove(at: index)
        item.work()
        return true
    }

    func runAll() {
        while runNext() {}
    }
}
