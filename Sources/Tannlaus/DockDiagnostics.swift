import AppKit
import CoreGraphics
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os

/// SPIKE for Tannlaus 1.1 (clamshell and dock handling). Not for release.
///
/// Logs the lid, display, power and wake details at every sleep, wake and dock change, so we can
/// check on real hardware whether the planned 1.1 rule ("keep Bluetooth on while asleep only if an
/// external display is connected, and check again when the dock changes") can be built in the sandbox.
/// It never touches Bluetooth and changes no behaviour; it only logs what the rule would do.
///
/// Entries use the `dock-spike` category at the default (notice) level, so they are kept on disk and
/// `log show` can read them after a sleep. Every C callback is delivered on the main queue.
@MainActor
final class DockDiagnostics {
    private let logger = Logger(category: "dock-spike")
    private let bluetoothIsOn: @MainActor () -> Bool?

    /// When the current sleep started, or `nil` while awake.
    private var willSleepAt: Date?

    private var rootDomain: io_service_t = 0
    private var interestPort: IONotificationPortRef?
    private var interestNotifier: io_object_t = 0
    private var systemPowerPort: IONotificationPortRef?
    private var systemPowerNotifier: io_object_t = 0
    private var systemPowerConnection: io_connect_t = 0
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var lastPowerSource: String?

    init(bluetoothIsOn: @escaping @MainActor () -> Bool?) {
        self.bluetoothIsOn = bluetoothIsOn
    }

    // MARK: - Events from AppDelegate

    func start() {
        logger.notice("Spike started. Logs lid, displays and power at every sleep, wake and dock change; changes nothing")
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if rootDomain == 0 {
            logger.error("Could not find IOPMrootDomain; lid state will be unreadable")
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        registerPowerSourceChanges(context)
        registerDisplayChanges(context)
        registerLidChanges(context)
        registerSystemPower(context)
        record("Launch")
    }

    func willSleep() {
        willSleepAt = Date()
        record("NSWorkspace will sleep")
    }

    func sleepHandlerFinished() {
        record("Sleep handler finished")
    }

    func didWake() {
        record("NSWorkspace did wake")
        willSleepAt = nil
    }

    func screensDidSleep() { record("Screens did sleep") }
    func screensDidWake() { record("Screens did wake") }

    // MARK: - Snapshot

    private func record(_ event: String) {
        let timing = willSleepAt.map { String(format: "%.1f s after will-sleep", Date().timeIntervalSince($0)) } ?? "awake"
        let displays = onlineDisplays()
        let docked = displays.contains { !$0.isBuiltin }
        let bluetooth = bluetoothIsOn().map { $0 ? "on" : "off" } ?? "unknown"
        let rule = docked ? "keep Bluetooth on (docked)" : "turn Bluetooth off (not docked)"

        logger.notice("""
            [\(event, privacy: .public)] \(timing, privacy: .public) | \
            lid closed: \(self.boolProperty("AppleClamshellState"), privacy: .public), \
            closing lid sleeps: \(self.boolProperty("AppleClamshellCausesSleep"), privacy: .public) | \
            power: \(Self.powerSource(), privacy: .public) | \
            displays: \(displays.map(\.summary).joined(separator: "; "), privacy: .public) | \
            docked: \(docked ? "yes" : "no", privacy: .public) | \
            Bluetooth now: \(bluetooth, privacy: .public) | \
            1.1 rule if Bluetooth was on: \(rule, privacy: .public)
            """)
        logger.notice("""
            [\(event, privacy: .public)] wake type: \(self.stringProperty("Wake Type"), privacy: .public) | \
            wake reason: \(self.stringProperty("Wake Reason"), privacy: .public) | \
            last sleep reason: \(self.stringProperty("Last Sleep Reason"), privacy: .public) | \
            user-triggered full wake: \(self.boolProperty("IOPMUserTriggeredFullWake"), privacy: .public)
            """)
    }

    private func property(_ key: String) -> Any? {
        guard rootDomain != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func boolProperty(_ key: String) -> String {
        guard let value = property(key) as? Bool else { return "unreadable" }
        return value ? "yes" : "no"
    }

    private func stringProperty(_ key: String) -> String {
        guard let value = property(key) else { return "unreadable" }
        return "\(value)"
    }

    private static func powerSource() -> String {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() else { return "unreadable" }
        return type as String
    }

    private struct Display {
        let isBuiltin: Bool
        let summary: String
    }

    private func onlineDisplays() -> [Display] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let error = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        guard error == .success else {
            logger.error("CGGetOnlineDisplayList failed: \(error.rawValue)")
            return []
        }
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return ids.prefix(Int(count)).map { id in
            let builtin = CGDisplayIsBuiltin(id) != 0
            let name = names[id] ?? "no NSScreen"
            var flags: [String] = [builtin ? "built-in" : "external"]
            flags.append(CGDisplayIsActive(id) != 0 ? "active" : "inactive")
            if CGDisplayIsAsleep(id) != 0 { flags.append("asleep") }
            if CGDisplayIsInMirrorSet(id) != 0 { flags.append("mirrored") }
            let summary = "\(id) '\(name)' vendor \(CGDisplayVendorNumber(id)) model \(CGDisplayModelNumber(id)) [\(flags.joined(separator: ", "))]"
            return Display(isBuiltin: builtin, summary: summary)
        }
    }

    // MARK: - Change notifications

    private func registerPowerSourceChanges(_ context: UnsafeMutableRawPointer) {
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            DockDiagnostics.deliver(context) { $0.powerSourceUpdated() }
        }, context)?.takeRetainedValue() else {
            logger.error("Could not watch power source changes")
            return
        }
        powerSourceRunLoopSource = source
        lastPowerSource = Self.powerSource()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        logger.notice("Watching power source changes")
    }

    /// The notification also fires about once a minute for battery level updates; only a change
    /// of source (battery, charger) is logged.
    private func powerSourceUpdated() {
        let source = Self.powerSource()
        guard source != lastPowerSource else { return }
        let previous = lastPowerSource ?? "unknown"
        lastPowerSource = source
        record("Power source changed from \(previous) to \(source)")
    }

    private func registerDisplayChanges(_ context: UnsafeMutableRawPointer) {
        let error = CGDisplayRegisterReconfigurationCallback({ display, flags, context in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            let change = DockDiagnostics.describe(flags)
            DockDiagnostics.deliver(context) { $0.record("Display \(display) changed: \(change)") }
        }, context)
        if error == .success {
            logger.notice("Watching display changes")
        } else {
            logger.error("Could not watch display changes: \(error.rawValue)")
        }
    }

    /// Lid open/close, delivered as a general-interest message on the root power domain.
    private func registerLidChanges(_ context: UnsafeMutableRawPointer) {
        guard rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("Could not watch lid changes: no notification port")
            return
        }
        IONotificationPortSetDispatchQueue(port, .main)
        interestPort = port
        let result = IOServiceAddInterestNotification(port, rootDomain, "IOGeneralInterest", { context, _, messageType, argument in
            let bits = Int(bitPattern: argument)
            DockDiagnostics.deliver(context) { diagnostics in
                if messageType == DockDiagnostics.clamshellStateChange {
                    let closed = bits & 1 != 0 ? "closed" : "open"
                    let sleeps = bits & 2 != 0 ? "yes" : "no"
                    diagnostics.record("Lid changed: \(closed), closing lid sleeps: \(sleeps)")
                } else if messageType != DockDiagnostics.driverAssertionsChanged {
                    diagnostics.logger.notice("Root domain message 0x\(String(messageType, radix: 16), privacy: .public), argument 0x\(String(bits, radix: 16), privacy: .public)")
                }
            }
        }, context, &interestNotifier)
        if result == KERN_SUCCESS {
            logger.notice("Watching lid changes")
        } else {
            logger.error("Could not watch lid changes: IOServiceAddInterestNotification returned 0x\(String(result, radix: 16), privacy: .public)")
        }
    }

    /// System power messages, to see brief and dark wakes that NSWorkspace may not report.
    /// Sleep requests must be acknowledged, or macOS waits up to 30 s before sleeping.
    private func registerSystemPower(_ context: UnsafeMutableRawPointer) {
        var port: IONotificationPortRef?
        let connection = IORegisterForSystemPower(context, &port, { context, _, messageType, argument in
            let notificationID = Int(bitPattern: argument)
            DockDiagnostics.deliver(context) { diagnostics in
                diagnostics.handleSystemPower(messageType, notificationID: notificationID)
            }
        }, &systemPowerNotifier)
        guard connection != 0, let port else {
            logger.error("IORegisterForSystemPower failed (sandbox?); brief and dark wakes won't be logged")
            return
        }
        systemPowerConnection = connection
        systemPowerPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        logger.notice("Watching system power messages")
    }

    private func handleSystemPower(_ messageType: UInt32, notificationID: Int) {
        switch messageType {
        case Self.canSystemSleep:
            let result = IOAllowPowerChange(systemPowerConnection, notificationID)
            logger.notice("System power: can sleep? Allowed, result 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
        case Self.systemWillSleep:
            record("System power: will sleep")
            let result = IOAllowPowerChange(systemPowerConnection, notificationID)
            logger.notice("System power: acknowledged will sleep, result 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public) (0 = success)")
        case Self.systemWillNotSleep:
            record("System power: will not sleep")
        case Self.systemWillPowerOn:
            record("System power: will power on")
        case Self.systemHasPoweredOn:
            record("System power: has powered on")
        default:
            logger.notice("System power message 0x\(String(messageType, radix: 16), privacy: .public)")
        }
    }

    // MARK: - Helpers

    // IOKit message values; the C macros that define them aren't imported into Swift.
    private nonisolated static let clamshellStateChange: UInt32 = 0xE003_4100 // kIOPMMessageClamshellStateChange
    private nonisolated static let driverAssertionsChanged: UInt32 = 0xE003_4150 // kIOPMMessageDriverAssertionsChanged; noise
    private nonisolated static let canSystemSleep: UInt32 = 0xE000_0270 // kIOMessageCanSystemSleep
    private nonisolated static let systemWillSleep: UInt32 = 0xE000_0280 // kIOMessageSystemWillSleep
    private nonisolated static let systemWillNotSleep: UInt32 = 0xE000_0290 // kIOMessageSystemWillNotSleep
    private nonisolated static let systemHasPoweredOn: UInt32 = 0xE000_0300 // kIOMessageSystemHasPoweredOn
    private nonisolated static let systemWillPowerOn: UInt32 = 0xE000_0320 // kIOMessageSystemWillPowerOn

    /// Runs `body` on the main actor with the instance behind a C callback's context pointer.
    private nonisolated static func deliver(
        _ context: UnsafeMutableRawPointer?,
        _ body: @escaping @MainActor @Sendable (DockDiagnostics) -> Void
    ) {
        guard let context else { return }
        let diagnostics = Unmanaged<DockDiagnostics>.fromOpaque(context).takeUnretainedValue()
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(diagnostics) }
        } else {
            DispatchQueue.main.async { body(diagnostics) }
        }
    }

    private nonisolated static func describe(_ flags: CGDisplayChangeSummaryFlags) -> String {
        let names: [(CGDisplayChangeSummaryFlags, String)] = [
            (.addFlag, "added"), (.removeFlag, "removed"), (.enabledFlag, "enabled"), (.disabledFlag, "disabled"),
            (.movedFlag, "moved"), (.setMainFlag, "main"), (.setModeFlag, "mode"), (.mirrorFlag, "mirrored"),
            (.unMirrorFlag, "unmirrored"), (.desktopShapeChangedFlag, "desktop shape"),
        ]
        let matched = names.filter { flags.contains($0.0) }.map(\.1)
        return matched.isEmpty ? "flags 0x\(String(flags.rawValue, radix: 16))" : matched.joined(separator: ", ")
    }
}
