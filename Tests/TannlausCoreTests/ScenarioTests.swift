import Testing
import TannlausCore

/// The event sequences recorded by the clamshell spike (branch `spike/clamshell-logging`,
/// `docs/clamshell-spike.md`; MacBook, macOS 27, DELL U2717D, 2026-11-16), replayed through the
/// fakes in their order and with their gaps. Times are seconds from the first event of each test.
///
/// The fake clock runs through the gaps, so timers fire as early as they could. On a real Mac the
/// clock stops while fully asleep and timers fire in the next wake (dark or full).
@MainActor
struct ScenarioTests {
    enum Step {
        /// The lid message from the root power domain.
        case lid(closed: Bool)
        /// The power source notification after the source changed.
        case power(PowerSource)
        /// The display list changed to these displays.
        case displays([DisplayInfo])
        /// A display event with the list unchanged (the "flags 0x0" events at wake).
        case displaysTouched
        case systemWillSleep, systemWillPowerOn, systemHasPoweredOn
        /// NSWorkspace notifications.
        case willSleep, didWake
        /// Checks Bluetooth's power at this point.
        case expect(BluetoothPower)
    }

    let scheduler = FakeScheduler()
    let controller = FakeBluetoothController(power: .on)

    /// Launches with these displays and power source, then replays the steps.
    @discardableResult
    func replay(
        displays: [DisplayInfo],
        power: PowerSource,
        keepOnWhenDocked: Bool = true,
        _ steps: [(Double, Step)],
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> (PowerCoordinator, FakeDockEnvironment) {
        let environment = FakeDockEnvironment(displays: displays, source: power)
        let coordinator = PowerCoordinator(
            controller: controller,
            scheduler: scheduler,
            environment: environment,
            keepOnWhenDocked: keepOnWhenDocked
        )
        var unacknowledged = 0
        for (time, step) in steps {
            scheduler.advance(to: .milliseconds(Int((time * 1000).rounded())))
            switch step {
            case .lid(let closed): coordinator.handle(.lidChanged(closed: closed))
            case .power(let source):
                environment.source = source
                coordinator.handle(.powerSourceUpdated)
            case .displays(let displays):
                environment.displays = displays
                coordinator.handle(.displaysChanged)
            case .displaysTouched: coordinator.handle(.displaysChanged)
            case .systemWillSleep:
                unacknowledged += 1
                coordinator.handleSystemWillSleep { unacknowledged -= 1 }
            case .systemWillPowerOn: coordinator.handle(.systemWillPowerOn)
            case .systemHasPoweredOn: coordinator.handle(.systemHasPoweredOn)
            case .willSleep: coordinator.handleWillSleep()
            case .didWake: coordinator.handleDidWake()
            case .expect(let power):
                #expect(controller.power == power, "at \(time) s", sourceLocation: sourceLocation)
            }
        }
        scheduler.advance(by: .seconds(60))
        #expect(unacknowledged == 0, "every system sleep was acknowledged", sourceLocation: sourceLocation)
        #expect(environment.heldAssertions == 0, "no sleep assertion left", sourceLocation: sourceLocation)
        #expect(scheduler.pending.isEmpty, "nothing left to do", sourceLocation: sourceLocation)
        return (coordinator, environment)
    }

    // MARK: Not docked: as 1.0

    @Test func t1LidClosedOnBattery() {
        replay(displays: [.builtIn], power: .battery, [
            (0.000, .lid(closed: true)),
            (0.007, .systemWillSleep),
            (0.014, .willSleep),
            (0.015, .expect(.off)),
            (76.660, .lid(closed: false)),
            (76.726, .systemWillPowerOn),
            (76.762, .displaysTouched),
            (76.913, .systemHasPoweredOn),
            (76.914, .expect(.off)),
            (76.919, .didWake),
            (76.920, .expect(.on)),
        ])
        #expect(controller.sets == [.off, .on])
    }

    @Test func t2LidClosedOnChargerWithDarkWake() {
        replay(displays: [.builtIn], power: .battery, [
            (0.000, .lid(closed: false)),
            (0.084, .power(.ac)),
            (5.066, .lid(closed: true)),
            (5.070, .systemWillSleep),
            (5.074, .willSleep),
            (5.075, .expect(.off)),
            (10.700, .lid(closed: true)), // In a wifibt dark wake 1 s after sleep.
            (10.701, .expect(.off)),
            (75.560, .lid(closed: false)),
            (75.608, .systemWillPowerOn),
            (75.641, .displaysTouched),
            (75.759, .systemHasPoweredOn),
            (75.766, .didWake),
            (75.767, .expect(.on)),
        ])
        #expect(controller.sets == [.off, .on])
    }

    @Test func t8ChargerWhileAsleepIsNotAWake() {
        // Docked earlier, then the monitor unplugged with the lid open, then asleep on battery.
        // Plugging in a charger causes a notification wake with system power messages but no
        // NSWorkspace "did wake": Bluetooth stays off until the lid is opened.
        replay(displays: [.dell, .builtIn], power: .ac, [
            (0.000, .displays([.builtIn])),
            (0.804, .lid(closed: false)),
            (0.811, .power(.battery)),
            (59.424, .lid(closed: true)),
            (59.432, .systemWillSleep),
            (59.438, .willSleep),
            (59.439, .expect(.off)),
            (127.750, .lid(closed: true)),
            (128.218, .lid(closed: true)),
            (128.245, .power(.ac)),
            (128.306, .systemWillPowerOn),
            (128.359, .displaysTouched),
            (128.373, .systemHasPoweredOn),
            (128.374, .expect(.off)),
            (132.609, .systemWillSleep),
            (142.088, .lid(closed: true)),
            (166.361, .lid(closed: true)),
            (167.650, .lid(closed: true)),
            (167.656, .power(.battery)),
            (167.657, .expect(.off)),
            (201.385, .lid(closed: false)),
            (201.430, .systemWillPowerOn),
            (201.503, .displaysTouched),
            (201.624, .systemHasPoweredOn),
            (201.625, .expect(.off)),
            (201.629, .didWake),
            (201.630, .expect(.on)),
        ])
        #expect(controller.sets == [.off, .on])
    }

    // MARK: Docked

    /// Connecting the monitor flickers, then Apple menu > Sleep with the lid open, then wake with
    /// the monitor briefly removed.
    static let t3Steps: [(Double, Step)] = [
        (0.000, .displays([.dell, .builtIn])),
        (1.457, .displays([.builtIn])),
        (2.363, .displays([.dell, .builtIn])),
        (22.829, .systemWillSleep),
        (22.838, .willSleep),
        (53.557, .lid(closed: false)), // A lid message 30 s after will-sleep, as macOS sleeps.
        (99.601, .lid(closed: false)),
        (99.602, .systemWillPowerOn),
        (99.671, .displaysTouched),
        (99.795, .displays([.builtIn])),
        (100.016, .systemHasPoweredOn),
        (100.022, .didWake),
        (100.863, .displays([.dell, .builtIn])),
    ]

    @Test func t3MenuSleepWithLidOpenKeepsBluetoothOn() {
        let (coordinator, _) = replay(displays: [.builtIn], power: .ac, Self.t3Steps)
        #expect(!controller.sets.contains(.off))
        #expect(controller.power == .on)
        #expect(coordinator.dockSnapshot.isDocked) // The wake flicker settled back to docked.
    }

    @Test func t3WithSettingOffTurnsBluetoothOff() {
        replay(displays: [.builtIn], power: .ac, keepOnWhenDocked: false, Self.t3Steps)
        #expect(controller.sets == [.off, .on])
    }

    @Test func t4ClamshellKeepsBluetoothOnThroughPlaceholderAtWake() {
        replay(displays: [.dell, .builtIn], power: .ac, [
            (0.000, .lid(closed: true)),
            (0.086, .displays([.dell])),
            (20.655, .systemWillSleep),
            (20.665, .willSleep),
            (20.666, .expect(.on)),
            (51.357, .lid(closed: true)),
            (115.465, .lid(closed: false)),
            (115.512, .systemWillPowerOn),
            (115.556, .displays([.placeholder])), // The placeholder replaces the monitor during wake.
            (115.557, .expect(.on)),
            (115.692, .systemHasPoweredOn),
            (115.694, .didWake),
            (115.925, .displays([.builtIn])),
            (116.784, .displays([.dell, .builtIn])),
            (116.785, .expect(.on)),
        ])
        #expect(!controller.sets.contains(.off))
    }

    @Test func t5LidClosedOnBatteryWithMonitorKeepsBluetoothOn() {
        // This Mac sleeps when the lid closes on battery even with a monitor. The monitor is
        // still connected, so it counts as docked.
        replay(displays: [.dell, .builtIn], power: .ac, [
            (0.000, .lid(closed: false)),
            (0.008, .power(.battery)),
            (9.513, .lid(closed: true)),
            (9.522, .systemWillSleep),
            (9.530, .willSleep),
            (9.531, .expect(.on)),
            (9.741, .displays([.dell])),
            (29.202, .lid(closed: false)), // Opened before macOS had actually slept.
            (29.410, .displays([.dell, .builtIn])),
            (39.542, .systemWillPowerOn),
            (39.548, .systemHasPoweredOn),
            (39.551, .didWake),
            (39.552, .expect(.on)),
        ])
        #expect(!controller.sets.contains(.off))
    }

    @Test func t6UndockBeforeWillSleepThenT7RedockWhileAsleep() {
        replay(displays: [.dell, .builtIn], power: .battery, [
            (0.000, .lid(closed: false)),
            (0.019, .power(.ac)),
            (6.416, .lid(closed: true)),
            (6.498, .displays([.dell])), // Clamshell.
            // T6: unplugging the charger and the monitor. Both arrive 0.2 s before will-sleep,
            // and macOS lists its placeholder instead of the monitor.
            (32.201, .lid(closed: true)),
            (32.202, .power(.battery)),
            (32.222, .displays([.placeholder])),
            (32.433, .systemWillSleep),
            (32.435, .willSleep),
            (32.436, .expect(.on)), // Not settled yet: the last settled state is docked.
            (35.300, .expect(.off)), // Settled 3 s after the change: not docked.
            // T7: charger plugged in again while asleep. The monitor is never reported, so
            // Bluetooth stays off (known limit with separate cables).
            (163.260, .lid(closed: true)),
            (163.667, .lid(closed: true)),
            (163.692, .power(.ac)),
            (163.730, .systemWillPowerOn),
            (163.817, .systemHasPoweredOn),
            (165.335, .systemWillSleep),
            (165.336, .expect(.off)),
            (188.196, .lid(closed: false)),
            (188.201, .systemWillPowerOn),
            (188.219, .systemHasPoweredOn),
            (188.386, .displays([.builtIn])),
            (188.647, .didWake),
            (188.648, .expect(.on)),
            (188.958, .displays([.dell, .builtIn])),
        ])
        #expect(controller.sets == [.off, .on])
    }

    @Test func t9LidClosedOnSleepingDockedMacThenT10Undock() {
        let (coordinator, _) = replay(displays: [.builtIn], power: .battery, [
            (0.000, .lid(closed: false)),
            (0.027, .power(.ac)),
            (4.548, .displays([.dell, .builtIn])),
            (6.030, .displays([.builtIn])),
            (6.935, .displays([.dell, .builtIn])),
            (42.111, .systemWillSleep),
            (42.118, .willSleep),
            (42.119, .expect(.on)),
            (72.829, .lid(closed: false)),
            // T9: closing the lid on the sleeping Mac causes a full wake; the monitor is
            // removed (wake flicker) and the Mac sleeps again 0.14 s after "did wake".
            (109.845, .lid(closed: true)),
            (109.846, .systemWillPowerOn),
            (109.892, .displaysTouched),
            (110.002, .displays([.builtIn])),
            (110.217, .systemHasPoweredOn),
            (110.218, .didWake),
            (110.362, .willSleep),
            (110.363, .expect(.on)), // The last settled state is still docked.
            (110.734, .systemWillSleep),
            // The monitor never came back before sleep, so the list settles as not docked.
            (113.100, .expect(.off)),
            // T10: monitor and charger unplugged while asleep, seen in a dark wake.
            (121.209, .lid(closed: true)),
            (124.804, .lid(closed: true)),
            (124.810, .power(.battery)),
            (124.811, .expect(.off)),
            (192.037, .lid(closed: false)),
            (192.079, .systemWillPowerOn),
            (192.110, .displaysTouched),
            (192.293, .systemHasPoweredOn),
            (192.298, .didWake),
            (192.299, .expect(.on)),
        ])
        #expect(controller.sets == [.on, .off, .on])
        #expect(!coordinator.dockSnapshot.isDocked)
    }
}
