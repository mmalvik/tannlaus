/// One display in the online display list, as CoreGraphics reports it.
public struct DisplayInfo: Sendable, Equatable {
    public var vendor: UInt32
    public var model: UInt32
    /// What `CGDisplayIsBuiltin` says. macOS's placeholder display is reported as external.
    public var isBuiltin: Bool

    public init(vendor: UInt32, model: UInt32, isBuiltin: Bool) {
        self.vendor = vendor
        self.model = model
        self.isBuiltin = isBuiltin
    }

    /// The vendor macOS gives its placeholder display: ASCII `unkn` (its model is `virt`, 0x76697274).
    ///
    /// Measured on macOS 27 (MacBook, 2026-11-16): it appears when an external display is
    /// unplugged with the lid closed, and briefly during wake. `CGDisplayIsBuiltin` calls it
    /// external, and after an unplug it stayed in the list for the whole sleep, so counting it
    /// made an undocked Mac look docked.
    public static let placeholderVendor: UInt32 = 0x756E_6B6E // 1970170734

    /// Whether this is a physical external monitor, the only kind that makes the Mac docked.
    ///
    /// Conservative: anything that might not be a real monitor doesn't count, so Tannlaus falls
    /// back to turning Bluetooth off. That excludes the placeholder (any `unkn` vendor) and
    /// displays with no vendor ID. Sidecar, AirPlay and other virtual displays are untested; with
    /// a vendor ID they would count.
    public var isPhysicalExternal: Bool {
        !isBuiltin && vendor != Self.placeholderVendor && vendor != 0
    }
}

/// The online displays at one moment, and whether they make the Mac docked.
public struct DockSnapshot: Sendable, Equatable {
    public var displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.displays = displays
    }

    /// Docked means at least one physical external display.
    public var isDocked: Bool {
        displays.contains { $0.isPhysicalExternal }
    }

    /// A short, log-friendly explanation, for example
    /// "docked: 4268/16619 external, 1552/41041 built-in".
    public var summary: String {
        let list = displays.map { display in
            let kind = display.isBuiltin ? "built-in" : display.isPhysicalExternal ? "external" : "ignored"
            return "\(display.vendor)/\(display.model) \(kind)"
        }
        return (isDocked ? "docked: " : "not docked: ") + (list.isEmpty ? "no displays" : list.joined(separator: ", "))
    }
}
