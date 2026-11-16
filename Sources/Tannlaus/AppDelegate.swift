import AppKit
import os
import TannlausCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(category: "app")
    private let monitor = BluetoothMonitor()
    private var coordinator: PowerCoordinator?
    private var dockEvents: DockEvents?
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        logger.info("Tannlaus \(version, privacy: .public) launched")

        // Launching never changes Bluetooth.
        let controller = SystemBluetoothController()
        let settings = Settings()
        let coordinator = PowerCoordinator(
            controller: controller,
            scheduler: TaskScheduler(),
            environment: SystemDockEnvironment(),
            keepOnWhenDocked: settings.keepBluetoothOnWhenDocked
        )
        self.coordinator = coordinator
        let statusMenu = StatusMenu(
            settings: settings,
            loginItem: LoginItem(),
            monitor: monitor,
            canControlBluetooth: controller.isAvailable
        )
        self.statusMenu = statusMenu
        statusMenu.onKeepOnWhenDockedChange = { [weak coordinator, logger] enabled in
            logger.info("Keep Bluetooth on when docked: \(enabled ? "on" : "off", privacy: .public)")
            coordinator?.keepOnWhenDocked = enabled
        }
        monitor.onChange = { [weak statusMenu] in statusMenu?.update() }
        monitor.start()
        statusMenu.update()

        // Display, power, lid and system power changes, to keep or turn off Bluetooth while docked.
        let dockEvents = DockEvents(
            onEvent: { [weak coordinator] event in coordinator?.handle(event) },
            onSystemWillSleep: { [weak coordinator] acknowledge in
                if let coordinator {
                    coordinator.handleSystemWillSleep(acknowledge: acknowledge)
                } else {
                    acknowledge()
                }
            }
        )
        self.dockEvents = dockEvents
        dockEvents.start()

        // The sleep handler must finish its work before returning, so the Mac can't sleep first.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coordinator?.handleWillSleep()
                self?.statusMenu?.update()
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coordinator?.handleDidWake()
                self?.statusMenu?.update()
            }
        }
    }

    /// Opening the app again while it runs brings a hidden icon back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logger.info("Reopened; showing the menu bar icon")
        statusMenu?.showIcon()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Tannlaus quitting")
    }
}
