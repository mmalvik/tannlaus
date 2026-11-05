import CoreBluetooth
import os

/// Asks for Bluetooth permission at launch and reports authorization and power changes,
/// using only public CoreBluetooth API so the menu never has to call the private functions.
@MainActor
final class BluetoothMonitor: NSObject, CBCentralManagerDelegate {
    var onChange: (() -> Void)?

    /// The power state as CoreBluetooth sees it, or `nil` while unknown or unauthorized.
    private(set) var isPoweredOn: Bool?

    private var central: CBCentralManager?
    private let logger = Logger(subsystem: "com.tannlaus.app", category: "permission")

    /// Creating the manager shows the permission prompt if the user hasn't answered yet.
    /// It is kept for the app's lifetime to receive authorization changes.
    func start() {
        logger.info("Bluetooth authorization at launch: \(CBManager.authorization.rawValue)")
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated {
            switch state {
            case .poweredOn: isPoweredOn = true
            case .poweredOff: isPoweredOn = false
            default: isPoweredOn = nil
            }
            logger.info("Bluetooth state changed: \(state.rawValue), authorization: \(CBManager.authorization.rawValue)")
            onChange?()
        }
    }
}
