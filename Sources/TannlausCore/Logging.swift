import os

// Log levels: `notice` for each decision or change that happens once per event (sleep, wake,
// each attempt and read-back, dock and power source changes, settings), so `log show` finds it
// after a problem. macOS keeps `info` only in memory, so use it only for what can repeat many
// times per sleep (dock checks that change nothing or are waiting, delayed sleep
// acknowledgements, sleep assertion renewals).
extension Logger {
    /// The subsystem every Tannlaus log entry uses, so one `log show` or `log stream` predicate
    /// shows them all.
    public static let tannlausSubsystem = "com.tannlaus.app"

    /// A logger in the Tannlaus subsystem.
    public init(category: String) {
        self.init(subsystem: Self.tannlausSubsystem, category: category)
    }
}
