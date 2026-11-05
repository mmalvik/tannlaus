public protocol Cancellable {
    func cancel()
}

/// Runs work on the main actor after a delay. Tests replace it with a scheduler they advance by hand.
@MainActor
public protocol Scheduler {
    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> Cancellable
}

@MainActor
public struct TaskScheduler: Scheduler {
    public init() {}

    public func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> Cancellable {
        let task = Task { @MainActor in
            // The suspending clock stops while the Mac sleeps, so a retry scheduled at sleep can't
            // be overdue on wake and run before the wake handler cancels it.
            try? await Task.sleep(for: delay, clock: .suspending)
            guard !Task.isCancelled else { return }
            work()
        }
        return TaskCancellable(task: task)
    }
}

private struct TaskCancellable: Cancellable {
    let task: Task<Void, Never>

    func cancel() {
        task.cancel()
    }
}
