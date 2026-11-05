/// How often a power change that didn't take effect is retried.
public struct RetryPolicy: Sendable, Equatable {
    /// The delay before each retry. The number of retries is `delays.count`.
    public var delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    /// Three retries spread over about ten seconds.
    public static let standard = RetryPolicy(delays: [.seconds(1), .seconds(3), .seconds(6)])
}
