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

    /// "Keep Bluetooth on when docked". On unless the user turned it off.
    var keepBluetoothOnWhenDocked: Bool {
        get { defaults.object(forKey: "keepBluetoothOnWhenDocked") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "keepBluetoothOnWhenDocked") }
    }
}
