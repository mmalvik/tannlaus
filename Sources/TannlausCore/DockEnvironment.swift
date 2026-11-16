/// Where the Mac gets its power from, as IOKit names it.
public enum PowerSource: String, Sendable, Equatable {
    case ac = "AC Power"
    case battery = "Battery Power"
    case ups = "UPS Power"
    case unknown

    public init(name: String?) {
        self = name.flatMap(PowerSource.init(rawValue:)) ?? .unknown
    }
}

/// A change that may mean the Mac was docked or undocked. The app reports these from IOKit and
/// CoreGraphics; `PowerCoordinator` decides what they mean.
public enum DockEvent: Sendable, Equatable, CustomStringConvertible {
    /// The online display list changed. It flickers, so it only counts once it has settled.
    case displaysChanged
    /// The power source notification fired. It also fires about once a minute for battery level
    /// updates, so only a change of source counts.
    case powerSourceUpdated
    case lidChanged(closed: Bool)
    /// System power "will power on" and "has powered on". These also arrive for brief and dark
    /// wakes (for example when a charger is plugged in) that NSWorkspace never reports as a wake.
    case systemWillPowerOn
    case systemHasPoweredOn
    /// System power "will sleep". It also arrives when a brief wake ends, without NSWorkspace.
    case systemWillSleep

    public var description: String {
        switch self {
        case .displaysChanged: "displays changed"
        case .powerSourceUpdated: "power source changed"
        case .lidChanged(let closed): closed ? "lid closed" : "lid opened"
        case .systemWillPowerOn: "system will power on"
        case .systemHasPoweredOn: "system has powered on"
        case .systemWillSleep: "system will sleep"
        }
    }
}

/// What `PowerCoordinator` needs to know about displays and power to decide whether the Mac is
/// docked. The app reads CoreGraphics and IOKit; tests use a fake.
@MainActor
public protocol DockEnvironment: AnyObject {
    /// The online displays right now, including mirrored and sleeping ones.
    func onlineDisplays() -> [DisplayInfo]

    func powerSource() -> PowerSource

    /// Asks macOS not to sleep, including from a dark wake, until the result is cancelled.
    /// Returns `nil` if macOS refused.
    func preventSleep(reason: String) -> Cancellable?
}
