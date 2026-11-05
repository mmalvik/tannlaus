import CoreBluetooth
import Foundation
import os
import TannlausCore

/// Controls Bluetooth power through the private IOBluetooth preference functions.
///
/// Measured on macOS 27 (M2 Max), sandboxed with `com.apple.security.device.bluetooth`:
/// - The functions go through CoreBluetooth, so macOS asks for Bluetooth permission. Without
///   `NSBluetoothAlwaysUsageDescription` in Info.plist, macOS kills the app on the first call.
/// - Permission is charged to the process that launched the app, which is why a build run
///   from a terminal behaves differently from one opened in Finder.
/// - While the permission dialog is open, the first call blocks with no timeout.
/// - A change takes effect 0.1–0.4 s after the set call returns.
///
/// So every call runs on a serial queue and is abandoned after a timeout. While an abandoned
/// call is still stuck, new calls fail straight away with `.busy` instead of piling up behind it.
final class SystemBluetoothController: BluetoothController {
    private typealias GetPower = @convention(c) () -> Int32
    private typealias SetPower = @convention(c) (Int32) -> Void

    private struct Functions: @unchecked Sendable {
        let get: GetPower
        let set: SetPower
    }

    private let functions: Functions?
    private let queue = DispatchQueue(label: "com.tannlaus.app.bluetooth")
    private let inFlight = OSAllocatedUnfairLock(initialState: false)
    private let callTimeout: DispatchTimeInterval
    private let settleTimeout: TimeInterval
    private let logger = Logger(subsystem: "com.tannlaus.app", category: "bluetooth")

    init(callTimeout: DispatchTimeInterval = .seconds(3), settleTimeout: TimeInterval = 2) {
        self.callTimeout = callTimeout
        self.settleTimeout = settleTimeout
        functions = Self.loadFunctions()
        if functions == nil {
            logger.fault("IOBluetooth power functions not found; Tannlaus cannot control Bluetooth on this macOS version")
        }
    }

    var authorization: BluetoothAuthorization {
        .current
    }

    func powerState() throws -> BluetoothPower {
        let functions = try loadedFunctions()
        return try perform { functions.get() } == 0 ? .off : .on
    }

    func setPower(_ power: BluetoothPower) throws -> BluetoothPower {
        let functions = try loadedFunctions()
        let value: Int32 = power == .on ? 1 : 0
        try perform { functions.set(value) }

        // The change takes effect a moment after the call returns (see the type comment).
        let deadline = Date().addingTimeInterval(settleTimeout)
        var state = try powerState()
        while state != power, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            state = try powerState()
        }
        return state
    }

    private func loadedFunctions() throws -> Functions {
        guard let functions else { throw BluetoothControllerError.unavailable }
        return functions
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) throws -> T {
        let started = inFlight.withLock { busy in
            if busy { return false }
            busy = true
            return true
        }
        guard started else {
            logger.error("A previous Bluetooth call is still stuck; skipping this one")
            throw BluetoothControllerError.busy
        }

        let result = OSAllocatedUnfairLock<T?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        queue.async { [inFlight] in
            let value = body()
            result.withLock { $0 = value }
            inFlight.withLock { $0 = false }
            done.signal()
        }
        guard done.wait(timeout: .now() + callTimeout) == .success, let value = result.withLock({ $0 }) else {
            logger.error("Bluetooth call timed out")
            throw BluetoothControllerError.timedOut
        }
        return value
    }

    private static func loadFunctions() -> Functions? {
        guard let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW),
              let get = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState"),
              let set = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState")
        else { return nil }
        return Functions(get: unsafeBitCast(get, to: GetPower.self), set: unsafeBitCast(set, to: SetPower.self))
    }
}

extension BluetoothAuthorization {
    /// The app's Bluetooth authorization from CoreBluetooth. Never blocks or shows UI.
    static var current: BluetoothAuthorization {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }
}
