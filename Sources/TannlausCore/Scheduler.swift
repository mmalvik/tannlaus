import Dispatch
import Foundation

public protocol Cancellable {
    func cancel()
}

/// Timing and threads for `PowerCoordinator`. Tests replace it with a scheduler they drive by hand.
@MainActor
public protocol Scheduler {
    /// Runs work on the main actor after a delay.
    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> Cancellable

    /// Runs blocking work off the main thread, one piece at a time in order, and delivers its
    /// result on the main actor.
    func runInBackground<T: Sendable>(
        _ work: @escaping @Sendable () -> T,
        then completion: @escaping @MainActor @Sendable (T) -> Void
    )

    /// Blocks until all background work has finished. Results not yet delivered arrive later.
    func waitForBackgroundWork()

    /// Blocks the current thread. Only the sleep handler uses it, because it must finish before returning.
    func pause(for delay: Duration)
}

@MainActor
public struct TaskScheduler: Scheduler {
    private let background = DispatchQueue(label: "com.tannlaus.app.power", qos: .userInitiated)

    public init() {}

    public func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> Cancellable {
        let task = Task { @MainActor in
            // The suspending clock stops while the Mac sleeps, so a retry scheduled before sleep
            // can't be overdue on wake and run before the wake handler cancels it.
            try? await Task.sleep(for: delay, clock: .suspending)
            guard !Task.isCancelled else { return }
            work()
        }
        return TaskCancellable(task: task)
    }

    public func runInBackground<T: Sendable>(
        _ work: @escaping @Sendable () -> T,
        then completion: @escaping @MainActor @Sendable (T) -> Void
    ) {
        background.async {
            let value = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(value) }
            }
        }
    }

    public func waitForBackgroundWork() {
        background.sync {}
    }

    public func pause(for delay: Duration) {
        let (seconds, attoseconds) = delay.components
        Thread.sleep(forTimeInterval: Double(seconds) + Double(attoseconds) / 1e18)
    }
}

private struct TaskCancellable: Cancellable {
    let task: Task<Void, Never>

    func cancel() {
        task.cancel()
    }
}
