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

    public var kind: DisplayKind {
        DisplayKind(self)
    }
}

public enum DisplayKind: Sendable, Equatable {
    /// The laptop's own screen.
    case builtIn
    /// A physical monitor with a vendor ID. Only these count as docked.
    case external
    /// macOS's stand-in display, which is not a real monitor.
    case placeholder
    /// An external display with no vendor ID, so it can't be identified as a physical monitor.
    case unidentified

    /// The vendor and model macOS gives its placeholder display: ASCII `unkn` and `virt`.
    ///
    /// Measured on macOS 27 (MacBook, 2026-11-16): it appears when an external display is
    /// unplugged with the lid closed, and briefly during wake. `CGDisplayIsBuiltin` calls it
    /// external, and after an unplug it stayed in the list for the whole sleep, so counting it
    /// made an undocked Mac look docked.
    public static let placeholderVendor: UInt32 = 0x756E_6B6E // "unkn", 1970170734
    public static let placeholderModel: UInt32 = 0x7669_7274 // "virt", 1986622068

    /// Sorts a display conservatively: anything that might not be a physical monitor is not
    /// `external`, so Tannlaus falls back to turning Bluetooth off. Sidecar, AirPlay and other
    /// virtual displays are untested; with a vendor ID they would count as external.
    public init(_ display: DisplayInfo) {
        if display.isBuiltin {
            self = .builtIn
        } else if display.vendor == Self.placeholderVendor {
            // Any `unkn` vendor, not only the `virt` model seen so far: none is a real monitor.
            self = .placeholder
        } else if display.vendor == 0 {
            self = .unidentified
        } else {
            self = .external
        }
    }
}

/// The online displays at one moment, and whether they make the Mac docked.
public struct DockSnapshot: Sendable, Equatable {
    public var displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.displays = displays
    }

    public var externalDisplays: [DisplayInfo] {
        displays.filter { $0.kind == .external }
    }

    /// Docked means at least one physical external display.
    public var isDocked: Bool {
        !externalDisplays.isEmpty
    }

    /// A short, log-friendly explanation, for example
    /// "docked: external display 4268/16619" or "not docked: built-in only, ignored placeholder".
    public var summary: String {
        let external = externalDisplays.map { "\($0.vendor)/\($0.model)" }
        var parts: [String]
        if external.isEmpty {
            let builtIn = displays.contains { $0.kind == .builtIn }
            parts = ["not docked: " + (builtIn ? "built-in only" : "no display")]
        } else {
            parts = ["docked: external display " + external.joined(separator: ", ")]
        }
        let placeholders = displays.filter { $0.kind == .placeholder }.count
        if placeholders > 0 {
            parts.append("ignored \(placeholders == 1 ? "placeholder" : "\(placeholders) placeholders")")
        }
        let unidentified = displays.filter { $0.kind == .unidentified }.map { "0/\($0.model)" }
        if !unidentified.isEmpty {
            parts.append("ignored unidentified display " + unidentified.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }
}
