import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os
import TannlausCore

/// Watches the power source, displays, lid and system power, and passes each change on as a
/// `DockEvent`. No decisions here; `PowerCoordinator` makes them.
///
/// Measured on macOS 27 (MacBook, 2026-11-16): all four registrations work in the sandbox with
/// only the Bluetooth entitlement, and their callbacks also run during dark wakes. System power
/// sends "will power on", "has powered on" and "will sleep" for brief wakes (a charger plugged
/// in) that NSWorkspace never reports.
@MainActor
final class DockEvents {
    private let onEvent: @MainActor (DockEvent) -> Void
    private let onSystemWillSleep: @MainActor (_ acknowledge: @escaping @MainActor () -> Void) -> Void
    private let logger = Logger(category: "dock")

    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var rootDomain: io_service_t = 0
    private var interestPort: IONotificationPortRef?
    private var interestNotifier: io_object_t = 0
    private var systemPowerPort: IONotificationPortRef?
    private var systemPowerNotifier: io_object_t = 0
    private var systemPowerConnection: io_connect_t = 0

    /// `onSystemWillSleep` must call `acknowledge` once (it may wait), or macOS waits 30 s before sleeping.
    init(
        onEvent: @escaping @MainActor (DockEvent) -> Void,
        onSystemWillSleep: @escaping @MainActor (_ acknowledge: @escaping @MainActor () -> Void) -> Void
    ) {
        self.onEvent = onEvent
        self.onSystemWillSleep = onSystemWillSleep
    }

    /// Registers for every change. Kept for the app's lifetime, so nothing is unregistered.
    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        registerPowerSource(context)
        registerDisplays(context)
        registerLid(context)
        registerSystemPower(context)
    }

    private func registerPowerSource(_ context: UnsafeMutableRawPointer) {
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            DockEvents.deliver(context) { $0.onEvent(.powerSourceUpdated) }
        }, context)?.takeRetainedValue() else {
            logger.error("Could not watch power source changes")
            return
        }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func registerDisplays(_ context: UnsafeMutableRawPointer) {
        let error = CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            // Every change is reported twice: before (begin flag) and after. Only the second counts.
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DockEvents.deliver(context) { $0.onEvent(.displaysChanged) }
        }, context)
        if error != .success {
            logger.error("Could not watch display changes: \(error.rawValue)")
        }
    }

    /// Lid open and close arrive as a general-interest message on the root power domain.
    private func registerLid(_ context: UnsafeMutableRawPointer) {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("Could not watch lid changes")
            return
        }
        IONotificationPortSetDispatchQueue(port, .main)
        interestPort = port
        let result = IOServiceAddInterestNotification(port, rootDomain, "IOGeneralInterest", { context, _, messageType, argument in
            guard messageType == DockEvents.clamshellStateChange else { return }
            let closed = Int(bitPattern: argument) & 1 != 0
            DockEvents.deliver(context) { $0.onEvent(.lidChanged(closed: closed)) }
        }, context, &interestNotifier)
        if result != KERN_SUCCESS {
            logger.error("Could not watch lid changes: 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
        }
    }

    private func registerSystemPower(_ context: UnsafeMutableRawPointer) {
        var port: IONotificationPortRef?
        let connection = IORegisterForSystemPower(context, &port, { context, _, messageType, argument in
            let notificationID = Int(bitPattern: argument)
            DockEvents.deliver(context) { $0.systemPower(messageType, notificationID: notificationID) }
        }, &systemPowerNotifier)
        guard connection != 0, let port else {
            logger.error("Could not watch system power messages")
            return
        }
        systemPowerConnection = connection
        systemPowerPort = port
        IONotificationPortSetDispatchQueue(port, .main)
    }

    private func systemPower(_ messageType: UInt32, notificationID: Int) {
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(systemPowerConnection, notificationID)
        case Self.systemWillSleep:
            let connection = systemPowerConnection
            onSystemWillSleep {
                IOAllowPowerChange(connection, notificationID)
            }
        case Self.systemWillPowerOn:
            onEvent(.systemWillPowerOn)
        case Self.systemHasPoweredOn:
            onEvent(.systemHasPoweredOn)
        default:
            break
        }
    }

    // IOKit message values; the C macros that define them aren't imported into Swift.
    private nonisolated static let clamshellStateChange: UInt32 = 0xE003_4100 // kIOPMMessageClamshellStateChange
    private nonisolated static let canSystemSleep: UInt32 = 0xE000_0270 // kIOMessageCanSystemSleep
    private nonisolated static let systemWillSleep: UInt32 = 0xE000_0280 // kIOMessageSystemWillSleep
    private nonisolated static let systemHasPoweredOn: UInt32 = 0xE000_0300 // kIOMessageSystemHasPoweredOn
    private nonisolated static let systemWillPowerOn: UInt32 = 0xE000_0320 // kIOMessageSystemWillPowerOn

    /// Runs `body` on the main actor with the instance behind a C callback's context pointer.
    /// C callbacks can't capture context, so this names the type rather than using `Self`.
    private nonisolated static func deliver(
        _ context: UnsafeMutableRawPointer?,
        _ body: @escaping @MainActor @Sendable (DockEvents) -> Void
    ) {
        guard let context else { return }
        let events = Unmanaged<DockEvents>.fromOpaque(context).takeUnretainedValue()
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(events) }
        } else {
            DispatchQueue.main.async { body(events) }
        }
    }
}
