import Testing
@testable import TannlausCore

/// Classification with the values recorded on the spike MacBook (macOS 27, 2026-11-16).
struct DisplayTests {
    @Test func classifiesRecordedDisplays() {
        #expect(!DisplayInfo.builtIn.isPhysicalExternal)
        #expect(DisplayInfo.dell.isPhysicalExternal)
        #expect(!DisplayInfo.placeholder.isPhysicalExternal)
    }

    @Test func placeholderVendorIsAsciiUnkn() {
        #expect(DisplayInfo.placeholderVendor == 1970170734)
        #expect(DisplayInfo.placeholder.vendor == DisplayInfo.placeholderVendor)
    }

    @Test func anyUnknVendorIsIgnored() {
        #expect(!DisplayInfo(vendor: DisplayInfo.placeholderVendor, model: 1, isBuiltin: false).isPhysicalExternal)
    }

    @Test func externalDisplayWithoutVendorIsNotCounted() {
        let display = DisplayInfo(vendor: 0, model: 0, isBuiltin: false)
        #expect(!display.isPhysicalExternal)
        #expect(!DockSnapshot(displays: [.builtIn, display]).isDocked)
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
        #expect(DockSnapshot(displays: [.dell, .builtIn]).summary == "docked: 4268/16619 external, 1552/41041 built-in")
        #expect(DockSnapshot(displays: [.placeholder]).summary == "not docked: 1970170734/1986622068 ignored")
        #expect(DockSnapshot(displays: []).summary == "not docked: no displays")
    }
}

@MainActor
struct DockTrackerTests {
    let scheduler = FakeScheduler()
    let environment = FakeDockEnvironment(displays: [.dell, .builtIn], source: Power.ac)

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
        environment.source = Power.battery
        #expect(tracker.powerSourceUpdated())
        #expect(!tracker.powerSourceUpdated())
        environment.source = Power.ac
        #expect(tracker.powerSourceUpdated())
    }
}
