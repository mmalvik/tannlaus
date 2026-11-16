import CoreGraphics
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import os
import TannlausCore

/// Reads displays and the power source, and takes sleep assertions. No decisions here: they are in
/// `TannlausCore` (`DisplayKind`, `DockTracker`, `PowerCoordinator`).
@MainActor
final class SystemDockEnvironment: DockEnvironment {
    private let logger = Logger(category: "dock")

    func onlineDisplays() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let error = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        guard error == .success else {
            logger.error("CGGetOnlineDisplayList failed: \(error.rawValue)")
            return []
        }
        return ids.prefix(Int(count)).map { id in
            DisplayInfo(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
    }

    func powerSource() -> PowerSource {
        PowerSource(name: IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?)
    }

    /// A laptop has an internal battery among its power sources. If they can't be read, this
    /// says no, so Tannlaus falls back to turning Bluetooth off at every sleep.
    func isLaptop() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            logger.error("Could not read power sources; treating this Mac as a desktop")
            return false
        }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// `NetworkClientActive` is the only public assertion that IOPMLib.h says keeps the Mac awake
    /// in a dark wake (on AC power; on battery macOS may still sleep). `PreventUserIdleSystemSleep`
    /// "has no effect if the system is in Dark Wake", and `PreventSystemSleep` is deprecated.
    /// A timeout releases it even if Tannlaus never does.
    func preventSleep(reason: String) -> Cancellable? {
        var id: IOPMAssertionID = 0
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertNetworkClientActive as String,
            kIOPMAssertionNameKey: reason,
            kIOPMAssertionTimeoutKey: 30,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
        guard result == kIOReturnSuccess else {
            logger.error("Could not prevent sleep: IOPMAssertionCreateWithProperties returned 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
            return nil
        }
        logger.info("Preventing sleep while switching Bluetooth (assertion \(id))")
        return SleepAssertion(id: id)
    }
}

private final class SleepAssertion: Cancellable {
    private let id: IOPMAssertionID
    private var released = false

    init(id: IOPMAssertionID) {
        self.id = id
    }

    func cancel() {
        guard !released else { return }
        released = true
        IOPMAssertionRelease(id)
    }
}
