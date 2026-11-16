import Testing
@testable import TannlausCore

/// Classification with the values recorded on the spike MacBook (macOS 27, 2026-11-16).
struct DisplayTests {
    @Test func classifiesRecordedDisplays() {
        #expect(DisplayInfo.builtIn.kind == .builtIn)
        #expect(DisplayInfo.dell.kind == .external)
        #expect(DisplayInfo.placeholder.kind == .placeholder)
    }

    @Test func placeholderValuesAreAsciiUnknVirt() {
        #expect(DisplayKind.placeholderVendor == 1970170734)
        #expect(DisplayKind.placeholderModel == 1986622068)
    }

    @Test func anyUnknVendorIsAPlaceholder() {
        let other = DisplayInfo(vendor: DisplayKind.placeholderVendor, model: 1, isBuiltin: false)
        #expect(other.kind == .placeholder)
    }

    @Test func externalDisplayWithoutVendorIsNotCounted() {
        let display = DisplayInfo(vendor: 0, model: 0, isBuiltin: false)
        #expect(display.kind == .unidentified)
        #expect(!DockSnapshot(displays: [.builtIn, display]).isDocked)
    }

    @Test func builtInWinsOverVendor() {
        // The built-in flag decides, whatever the vendor says.
        #expect(DisplayInfo(vendor: DisplayKind.placeholderVendor, model: 0, isBuiltin: true).kind == .builtIn)
    }

    @Test(arguments: [
        ([DisplayInfo.builtIn], false),
        ([.dell, .builtIn], true),
        ([.dell], true), // Clamshell: the built-in display is not listed.
        ([.placeholder], false), // Unplugged with the lid closed (T6).
        ([.placeholder, .builtIn], false), // During wake (T4).
        ([], false),
    ])
    func dockedNeedsAPhysicalExternalDisplay(_ displays: [DisplayInfo], _ docked: Bool) {
        #expect(DockSnapshot(displays: displays).isDocked == docked)
    }

    @Test func summaryExplainsTheDecision() {
        #expect(DockSnapshot(displays: [.dell, .builtIn]).summary == "docked: external display 4268/16619")
        #expect(DockSnapshot(displays: [.placeholder]).summary == "not docked: no display, ignored placeholder")
        #expect(DockSnapshot(displays: [.builtIn]).summary == "not docked: built-in only")
        #expect(DockSnapshot(displays: [.builtIn, DisplayInfo(vendor: 0, model: 7, isBuiltin: false)]).summary
            == "not docked: built-in only, ignored unidentified display 0/7")
    }

    @Test func powerSourceNames() {
        #expect(PowerSource(name: "AC Power") == .ac)
        #expect(PowerSource(name: "Battery Power") == .battery)
        #expect(PowerSource(name: "UPS Power") == .ups)
        #expect(PowerSource(name: "Something new") == .unknown)
        #expect(PowerSource(name: nil) == .unknown)
    }
}

@MainActor
struct DockTrackerTests {
    let scheduler = FakeScheduler()
    let environment = FakeDockEnvironment(displays: [.dell, .builtIn], source: .ac)

    func makeTracker() -> DockTracker {
        DockTracker(environment: environment, scheduler: scheduler, settleDelay: .seconds(3))
    }

    @Test func displaysAtLaunchCountAsSettled() {
        let tracker = makeTracker()
        #expect(tracker.settled.isDocked)
    }

    @Test func changeCountsOnlyOnceTheListIsQuiet() {
        let tracker = makeTracker()
        var settles = 0
        tracker.onSettled = { settles += 1 }

        environment.displays = [.builtIn]
        tracker.displaysChanged()
        scheduler.advance(by: .milliseconds(2999))
        #expect(tracker.settled.isDocked)
        #expect(settles == 0)

        scheduler.advance(by: .milliseconds(1))
        #expect(!tracker.settled.isDocked)
        #expect(settles == 1)
    }

    @Test func flickerRestartsTheTimer() {
        // Connecting the monitor (T3): added, removed 1.5 s later, added again 0.9 s after that.
        environment.displays = [.builtIn]
        let tracker = makeTracker()
        var settles = 0
        tracker.onSettled = { settles += 1 }

        environment.displays = [.dell, .builtIn]
        tracker.displaysChanged()
        scheduler.advance(by: .milliseconds(1457))
        environment.displays = [.builtIn]
        tracker.displaysChanged()
        scheduler.advance(by: .milliseconds(906))
        environment.displays = [.dell, .builtIn]
        tracker.displaysChanged()
        #expect(!tracker.settled.isDocked)

        scheduler.advance(by: .seconds(3))
        #expect(tracker.settled.isDocked)
        #expect(settles == 1)
    }

    @Test func batteryLevelUpdatesAreNotPowerChanges() {
        let tracker = makeTracker()

        #expect(!tracker.powerSourceUpdated())
        environment.source = .battery
        #expect(tracker.powerSourceUpdated())
        #expect(!tracker.powerSourceUpdated())
        environment.source = .ac
        #expect(tracker.powerSourceUpdated())
    }
}
