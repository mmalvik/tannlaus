/// Whether macOS lets the app use Bluetooth.
public enum BluetoothAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case allowed
}

public enum BluetoothPower: String, Sendable, Equatable {
    case on
    case off
}

public enum BluetoothControllerError: Error, Equatable {
    /// The system functions for controlling Bluetooth power are missing.
    case unavailable
    /// A previous call has not returned yet.
    case busy
    /// The call did not return in time.
    case timedOut
}

/// Access to the Bluetooth controller. The app provides the real implementation; tests use a fake.
public protocol BluetoothController: AnyObject {
    /// The current authorization. Must not block or show any UI.
    var authorization: BluetoothAuthorization { get }

    func powerState() throws -> BluetoothPower

    /// Requests a power state, waits briefly for it to take effect, and returns the state read back.
    /// Callers compare the returned state with the requested one to verify the change.
    func setPower(_ power: BluetoothPower) throws -> BluetoothPower
}
