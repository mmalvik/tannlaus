import os

extension Logger {
    /// The subsystem every Tannlaus log entry uses, so one `log stream` predicate shows them all.
    public static let tannlausSubsystem = "com.tannlaus.app"

    /// A logger in the Tannlaus subsystem.
    public init(category: String) {
        self.init(subsystem: Self.tannlausSubsystem, category: category)
    }
}
