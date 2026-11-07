import AppKit
import ServiceManagement
import TannlausCore

/// The menu bar icon and its menu: status, Launch at login, Hide icon and Quit.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let settings: Settings
    private let loginItem: LoginItem
    private let monitor: BluetoothMonitor
    private var statusItem: NSStatusItem?

    init(settings: Settings, loginItem: LoginItem, monitor: BluetoothMonitor) {
        self.settings = settings
        self.loginItem = loginItem
        self.monitor = monitor
    }

    private var isAuthorized: Bool {
        BluetoothAuthorization.current == .allowed
    }

    /// Creates or removes the status item. Without Bluetooth access the icon is shown even
    /// when hidden, so the user can see that Tannlaus isn't working.
    func update() {
        let visible = !settings.hideIcon || !isAuthorized
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        updateIcon()
    }

    func showIcon() {
        settings.hideIcon = false
        update()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let (name, description) = isAuthorized
            ? ("MenuBarIcon", "Tannlaus")
            : ("MenuBarIcon-denied", "Tannlaus: Bluetooth access needed")
        // Copied so the settings below don't change the shared image NSImage(named:) caches.
        let image = NSImage(named: name)?.copy() as? NSImage
        image?.accessibilityDescription = description
        image?.isTemplate = true
        button.image = image
        button.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateIcon()
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        switch BluetoothAuthorization.current {
        case .denied, .restricted:
            menu.addItem(item("Open Privacy Settings…", #selector(openPrivacySettings)))
        case .allowed, .notDetermined:
            break
        }
        menu.addItem(.separator())

        let login = item(loginTitle, #selector(toggleLaunchAtLogin))
        switch loginItem.status {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)

        let hide = item("Hide icon", #selector(toggleHideIcon))
        hide.state = settings.hideIcon ? .on : .off
        menu.addItem(hide)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Tannlaus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private var statusText: String {
        switch BluetoothAuthorization.current {
        case .allowed:
            switch monitor.isPoweredOn {
            case true?: "Active: Bluetooth is on"
            case false?: "Active: Bluetooth is off"
            case nil: "Active"
            }
        case .notDetermined:
            "Waiting for Bluetooth permission"
        case .denied, .restricted:
            "Bluetooth access denied"
        }
    }

    private var loginTitle: String {
        loginItem.status == .requiresApproval ? "Launch at login (needs approval)" : "Launch at login"
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        loginItem.toggle()
    }

    @objc private func toggleHideIcon() {
        settings.hideIcon.toggle()
        if settings.hideIcon {
            NSApp.activate()
            let alert = NSAlert()
            if isAuthorized {
                alert.messageText = "Menu bar icon hidden"
                alert.informativeText = "Tannlaus keeps running. To show the icon again, open Tannlaus again from your Applications folder."
            } else {
                // update() keeps the icon visible without access, so don't claim it is hidden.
                alert.messageText = "Menu bar icon stays visible for now"
                alert.informativeText = "Tannlaus needs Bluetooth access to work, so the icon stays until you allow it. After that it is hidden; open Tannlaus again from your Applications folder to show it."
            }
            alert.runModal()
        }
        update()
    }
}
