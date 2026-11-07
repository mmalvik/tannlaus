/// How often a power change that didn't take effect is retried.
public struct RetryPolicy: Sendable, Equatable {
    /// The delay before each retry. The number of retries is `delays.count`.
    public var delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    /// Turning Bluetooth off at sleep. The sleep handler waits through these retries before the
    /// Mac may sleep, and macOS only allows about 30 seconds, so they are few and short.
    public static let sleep = RetryPolicy(delays: [.milliseconds(500), .seconds(1)])

    /// Restoring Bluetooth on wake. Three retries spread over about ten seconds.
    public static let wake = RetryPolicy(delays: [.seconds(1), .seconds(3), .seconds(6)])
}
