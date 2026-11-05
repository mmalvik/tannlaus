import Foundation

/// User settings, stored in the app's own defaults (inside its sandbox container).
struct Settings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hideIcon: Bool {
        get { defaults.bool(forKey: "hideIcon") }
        nonmutating set { defaults.set(newValue, forKey: "hideIcon") }
    }
}
