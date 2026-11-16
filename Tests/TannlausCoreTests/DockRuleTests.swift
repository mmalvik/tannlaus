import Testing
import TannlausCore

/// "Keep Bluetooth on when docked": the rule at sleep, the re-check while asleep, and its limits.
@MainActor
struct DockRuleTests {
    let scheduler = FakeScheduler()
    let environment = FakeDockEnvironment(displays: [.dell, .builtIn], source: Power.ac)
    let controller = FakeBluetoothController(power: .on)

    func makeCoordinator(keepOnWhenDocked: Bool = true) -> PowerCoordinator {
        PowerCoordinator(controller: controller, scheduler: scheduler, environment: environment, keepOnWhenDocked: keepOnWhenDocked)
    }

    /// Changes the display list and lets it settle.
    func setDisplays(_ displays: [DisplayInfo], on coordinator: PowerCoordinator) {
        environment.displays = displays
        coordinator.handle(.displaysChanged)
        scheduler.advance(by: DockTracker.defaultSettleDelay)
    }

    // MARK: At sleep

    @Test func dockedSleepKeepsBluetoothOnAndWakeRestores() {
        let coordinator = makeCoordinator()

        coordinator.handleWillSleep()
        #expect(controller.power == .on)
        #expect(controller.calls == [.read])

        coordinator.handleDidWake()
        #expect(controller.power == .on)
        #expect(controller.sets == [.on])
    }

    @Test func notDockedSleepTurnsBluetoothOff() {
        environment.displays = [.builtIn]
        let coordinator = makeCoordinator()

        coordinator.handleWillSleep()

        #expect(controller.power == .off)
        #expect(controller.calls == [.read, .set(.off)])
    }

    @Test func settingOffBehavesAsBefore() {
        let coordinator = makeCoordinator(keepOnWhenDocked: false)

        coordinator.handleWillSleep()
        #expect(controller.power == .off)
        coordinator.handle(.lidChanged(closed: true))
        coordinator.handle(.systemHasPoweredOn)
        #expect(controller.sets == [.off])

        coordinator.handleDidWake()
        #expect(controller.sets == [.off, .on])
        #expect(environment.assertions.isEmpty)
    }

    @Test func settingCanBeChangedWhileRunning() {
        let coordinator = makeCoordinator()
        coordinator.keepOnWhenDocked = false

        coordinator.handleWillSleep()

        #expect(controller.power == .off)
    }

    @Test func bluetoothThatWasOffStaysOffWhenDocked() {
        controller.power = .off
        let coordinator = makeCoordinator()

        coordinator.handleWillSleep()
        coordinator.handle(.systemWillPowerOn)
        setDisplays([.builtIn], on: coordinator)
        setDisplays([.dell], on: coordinator)
        coordinator.handleDidWake()

        #expect(controller.sets.isEmpty)
        #expect(controller.power == .off)
    }

    @Test func sleepUsesSettledStateNotTheListAtThatInstant() {
        // The monitor is briefly missing at will-sleep (T9): the settled state still says docked.
        let coordinator = makeCoordinator()
        environment.displays = [.builtIn]
        coordinator.handle(.displaysChanged)

        coordinator.handleWillSleep()

        #expect(controller.power == .on)
    }

    @Test func monitorJustConnectedIsNotYetDocked() {
        environment.displays = [.builtIn]
        let coordinator = makeCoordinator()
        environment.displays = [.dell, .builtIn]
        coordinator.handle(.displaysChanged)

        coordinator.handleWillSleep()
        #expect(controller.power == .off)

        // Once it settles while asleep, the dock rule turns Bluetooth back on.
        scheduler.advance(by: DockTracker.defaultSettleDelay)
        #expect(controller.power == .on)
        #expect(controller.sets == [.off, .on])
    }

    @Test func secondSleepWhileDockedTurnsBluetoothBackOn() {
        // Docked while asleep, but turning Bluetooth on gave up. A second will-sleep without a
        // wake decides again from the settled state and tries in place.
        environment.displays = [.builtIn]
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        controller.ignoredSets = 100
        setDisplays([.dell], on: coordinator)
        scheduler.runAll()
        #expect(controller.power == .off)

        controller.ignoredSets = 0
        coordinator.handleWillSleep()

        #expect(controller.power == .on)
    }

    @Test func desktopMacBehavesAsBefore() {
        // A desktop always has a monitor, so the docked rule would keep Bluetooth on forever.
        let environment = FakeDockEnvironment(displays: [.dell], source: Power.ac, laptop: false)
        let coordinator = PowerCoordinator(controller: controller, scheduler: scheduler, environment: environment)
        #expect(!coordinator.isLaptop)

        coordinator.handleWillSleep()
        #expect(controller.power == .off)
        environment.displays = [.dell]
        coordinator.handle(.displaysChanged)
        var acknowledged = false
        coordinator.handleSystemWillSleep { acknowledged = true }
        #expect(acknowledged) // Not held back for the settle.
        scheduler.advance(by: .seconds(10))
        coordinator.handle(.lidChanged(closed: false))
        #expect(controller.sets == [.off])
        #expect(environment.assertions.isEmpty)

        coordinator.handleDidWake()
        #expect(controller.sets == [.off, .on])
    }

    @Test func launchDoesNotTouchBluetoothWhenDocked() {
        _ = makeCoordinator()

        #expect(controller.calls.isEmpty)
    }

    // MARK: While asleep

    @Test func undockWhileAsleepTurnsBluetoothOffOnce() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()

        setDisplays([.builtIn], on: coordinator)
        #expect(controller.power == .off)
        #expect(controller.sets == [.off])

        // Further events with the same answer change nothing.
        coordinator.handle(.lidChanged(closed: true))
        coordinator.handle(.lidChanged(closed: true))
        coordinator.handle(.systemWillPowerOn)
        coordinator.handle(.systemHasPoweredOn)
        environment.source = Power.battery
        coordinator.handle(.powerSourceUpdated)
        #expect(controller.sets == [.off])
    }

    @Test(arguments: [DockEvent.powerSourceUpdated, .lidChanged(closed: true), .systemWillPowerOn, .systemHasPoweredOn])
    func undockSeenWithoutDisplayEventTurnsBluetoothOff(_ event: DockEvent) {
        // Unplugged while asleep: a dark wake reports the power source and lid, but no display
        // change (T10). The list is read again and is quiet, so it counts after the wake grace.
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()

        environment.displays = [.builtIn]
        environment.source = Power.battery
        coordinator.handle(event)
        #expect(controller.power == .on)
        #expect(environment.heldAssertions == 1)

        scheduler.advance(by: PowerCoordinator.wakeGrace)
        #expect(controller.power == .off)
        #expect(controller.sets == [.off])
        #expect(environment.heldAssertions == 0)
    }

    @Test func fullWakeDoesNotSwitchBeforeRestoring() {
        // Unplugged while asleep and not noticed until the lid opens: system power "will power
        // on" comes 0.01–0.45 s before NSWorkspace "did wake". Bluetooth must not go off and on.
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        environment.displays = [.builtIn]

        coordinator.handle(.lidChanged(closed: false))
        coordinator.handle(.systemWillPowerOn)
        scheduler.advance(by: .milliseconds(300))
        coordinator.handle(.systemHasPoweredOn)
        coordinator.handleDidWake()
        scheduler.advance(by: .seconds(10))

        #expect(!controller.sets.contains(.off))
        #expect(controller.power == .on)
        #expect(environment.heldAssertions == 0)
    }

    @Test func repeatedEventsDontPostponeTheWakeGrace() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        environment.displays = [.builtIn]

        coordinator.handle(.lidChanged(closed: true))
        scheduler.advance(by: .milliseconds(600))
        coordinator.handle(.lidChanged(closed: true))
        scheduler.advance(by: .milliseconds(400))

        #expect(controller.power == .off)
    }

    @Test func batteryLevelUpdateDoesNotReadDisplays() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()

        environment.displays = [.builtIn]
        coordinator.handle(.powerSourceUpdated) // Same source: a battery level update.

        #expect(controller.power == .on)
        #expect(coordinator.dockSnapshot.isDocked)
    }

    @Test func otherEventsDontCutShortASettle() {
        // Wake flicker: the monitor is removed and its display event starts the settle; lid and
        // system power events during it must not take the list at that instant.
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        environment.displays = [.builtIn]
        coordinator.handle(.displaysChanged)

        coordinator.handle(.lidChanged(closed: true))
        coordinator.handle(.systemHasPoweredOn)
        #expect(coordinator.dockSnapshot.isDocked)
        #expect(controller.power == .on)

        environment.displays = [.dell, .builtIn]
        coordinator.handle(.displaysChanged)
        scheduler.advance(by: .seconds(10))
        #expect(controller.sets.isEmpty)
    }

    @Test func dockedAgainWhileAsleepTurnsBluetoothOn() {
        // Untested on hardware: with separate cables macOS doesn't report the monitor while
        // asleep (T7). A single-cable dock might, and then the rule applies.
        environment.displays = [.builtIn]
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        #expect(controller.power == .off)

        setDisplays([.dell], on: coordinator)

        #expect(controller.power == .on)
        #expect(controller.sets == [.off, .on])
    }

    @Test func eventsWhileAwakeChangeNothing() {
        let coordinator = makeCoordinator()
        setDisplays([.builtIn], on: coordinator)
        coordinator.handle(.lidChanged(closed: false))
        coordinator.handle(.systemWillPowerOn)
        coordinator.handle(.systemHasPoweredOn)
        environment.source = Power.battery
        coordinator.handle(.powerSourceUpdated)

        #expect(controller.calls.isEmpty)
        #expect(!coordinator.dockSnapshot.isDocked)
    }

    @Test func briefWakeNeverRestoresBluetooth() {
        // A charger plugged in while asleep and not docked (T8): system power reports a wake,
        // NSWorkspace doesn't. Bluetooth stays off until the real wake.
        environment.displays = [.builtIn]
        environment.source = Power.battery
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()

        environment.source = Power.ac
        coordinator.handle(.powerSourceUpdated)
        coordinator.handle(.systemWillPowerOn)
        coordinator.handle(.systemHasPoweredOn)
        coordinator.handle(.displaysChanged)
        scheduler.advance(by: .seconds(4))
        coordinator.handleSystemWillSleep {}

        #expect(controller.power == .off)
        #expect(controller.sets == [.off])
    }

    @Test func holdsSleepAssertionWhileSettlingAsleep() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()

        environment.displays = [.builtIn]
        coordinator.handle(.displaysChanged)
        #expect(environment.heldAssertions == 1)

        scheduler.advance(by: DockTracker.defaultSettleDelay)
        #expect(controller.power == .off)
        #expect(environment.heldAssertions == 0)
    }

    @Test func noAssertionWhileSettlingAwake() {
        let coordinator = makeCoordinator()
        environment.displays = [.builtIn]
        coordinator.handle(.displaysChanged)

        #expect(environment.heldAssertions == 0)
    }

    @Test func holdsSleepAssertionOnlyWhileSwitching() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        scheduler.runsBackgroundInline = false

        environment.displays = [.builtIn]
        coordinator.handle(.displaysChanged)
        scheduler.advance(by: DockTracker.defaultSettleDelay)
        #expect(environment.heldAssertions == 1)

        scheduler.finishBackgroundWork()
        #expect(controller.power == .off)
        #expect(environment.heldAssertions == 0)
    }

    @Test func expiredSleepAssertionIsTakenAgain() {
        // macOS releases the assertion after its 30 s timeout, for example across a sleep in the
        // middle of a settle. The next event takes a new one.
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        environment.displays = [.builtIn]
        coordinator.handle(.displaysChanged)
        #expect(environment.heldAssertions == 1)

        environment.expireAssertions()
        coordinator.handle(.lidChanged(closed: true))

        #expect(environment.heldAssertions == 1)
        scheduler.advance(by: DockTracker.defaultSettleDelay)
        #expect(environment.heldAssertions == 0)
    }

    @Test func neverHoldsMoreThanOneAssertion() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        scheduler.runsBackgroundInline = false
        controller.ignoredSets = 1

        environment.displays = [.builtIn]
        coordinator.handle(.displaysChanged)
        coordinator.handle(.lidChanged(closed: true))
        #expect(environment.heldAssertions == 1)
        scheduler.advance(by: DockTracker.defaultSettleDelay)
        #expect(environment.heldAssertions == 1)
        scheduler.finishBackgroundWork() // Fails; a retry is scheduled.
        #expect(environment.heldAssertions == 1)
        scheduler.advance(by: RetryPolicy.dock.delays[0])
        scheduler.finishBackgroundWork()

        #expect(controller.power == .off)
        #expect(environment.heldAssertions == 0)
    }

    @Test func noAssertionWhenNothingChanges() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        coordinator.handle(.lidChanged(closed: true))
        coordinator.handleDidWake()

        #expect(environment.assertions.isEmpty)
    }

    // MARK: Retries

    @Test func failedDockChangeIsRetriedWithBackoffThenGivesUp() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        controller.ignoredSets = 100

        environment.displays = [.builtIn]
        coordinator.handle(.displaysChanged)
        scheduler.advance(by: DockTracker.defaultSettleDelay)
        var delays: [Duration] = []
        while let item = scheduler.pending.first {
            delays.append(item.delay)
            scheduler.runNext()
        }

        #expect(delays == RetryPolicy.dock.delays)
        #expect(controller.sets == Array(repeating: .off, count: 1 + RetryPolicy.dock.delays.count))
        #expect(environment.heldAssertions == 0)

        // Never loops: more events with the same answer don't start again.
        coordinator.handle(.lidChanged(closed: true))
        coordinator.handle(.systemHasPoweredOn)
        #expect(controller.sets.count == 1 + RetryPolicy.dock.delays.count)
        #expect(scheduler.pending.isEmpty)
    }

    @Test func failedDockChangeSucceedsOnRetry() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        controller.ignoredSets = 1

        setDisplays([.builtIn], on: coordinator)
        #expect(controller.power == .on)
        #expect(environment.heldAssertions == 1) // Held across the retry.

        scheduler.advance(by: RetryPolicy.dock.delays[0])
        #expect(controller.power == .off)
        #expect(controller.sets == [.off, .off])
        #expect(environment.heldAssertions == 0)
    }

    @Test func wakeCancelsPendingDockRetry() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        controller.ignoredSets = 1
        setDisplays([.builtIn], on: coordinator)
        #expect(scheduler.pending.count == 1)

        coordinator.handleDidWake()

        #expect(scheduler.pending.isEmpty)
        #expect(environment.heldAssertions == 0)
        #expect(controller.power == .on)
        #expect(controller.sets == [.off, .on])
    }

    @Test func newSleepCancelsPendingDockRetry() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        controller.ignoredSets = 1
        setDisplays([.builtIn], on: coordinator)
        #expect(scheduler.pending.count == 1)

        coordinator.handleWillSleep()

        // The second sleep decides again in place, from the settled state: not docked.
        #expect(scheduler.pending.isEmpty)
        #expect(environment.heldAssertions == 0)
        #expect(controller.power == .off)
    }

    @Test func newerDockAnswerReplacesPendingChange() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        controller.ignoredSets = 2
        setDisplays([.builtIn], on: coordinator)
        #expect(scheduler.pending.count == 1)

        // Docked again before the second retry (due 1 s + 3 s after the first attempt).
        setDisplays([.dell], on: coordinator)

        #expect(controller.power == .on)
        #expect(controller.sets == [.off, .off, .on])
        #expect(scheduler.pending.isEmpty)
        #expect(environment.heldAssertions == 0)
    }

    // MARK: Permission

    @Test func withoutAccessDockEventsChangeNothing() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        controller.authorization = .denied

        setDisplays([.builtIn], on: coordinator)
        coordinator.handle(.lidChanged(closed: true))

        #expect(controller.sets.isEmpty)
        #expect(environment.assertions.isEmpty)
    }

    @Test func sleepWithoutAccessIgnoresDockEvents() {
        controller.authorization = .denied
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        controller.authorization = .allowed

        setDisplays([.builtIn], on: coordinator)

        #expect(controller.calls.isEmpty)
    }

    // MARK: System sleep acknowledgement

    @Test func systemSleepIsAcknowledgedAtOnceWhenIdle() {
        let coordinator = makeCoordinator()
        var acknowledged = 0

        coordinator.handleSystemWillSleep { acknowledged += 1 }
        #expect(acknowledged == 1)

        coordinator.handleWillSleep()
        coordinator.handleSystemWillSleep { acknowledged += 1 }
        #expect(acknowledged == 2)
    }

    @Test func systemSleepWaitsForBluetoothCallInProgress() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        scheduler.runsBackgroundInline = false
        setDisplays([.builtIn], on: coordinator)
        var acknowledged = 0

        coordinator.handleSystemWillSleep { acknowledged += 1 }
        #expect(acknowledged == 0)

        scheduler.finishBackgroundWork()
        #expect(acknowledged == 1)
        #expect(controller.power == .off)
    }

    @Test func systemSleepWaitsForPendingSettle() {
        // T6: the undock arrives 0.2 s before system will-sleep, which comes before NSWorkspace's.
        let coordinator = makeCoordinator()
        environment.displays = [.placeholder]
        coordinator.handle(.displaysChanged)
        var acknowledged = 0

        coordinator.handleSystemWillSleep { acknowledged += 1 }
        coordinator.handleWillSleep()
        #expect(acknowledged == 0)
        #expect(controller.power == .on) // The settled state still says docked.
        #expect(environment.heldAssertions == 1)

        scheduler.advance(by: DockTracker.defaultSettleDelay)
        #expect(acknowledged == 1)
        #expect(controller.power == .off)
        #expect(environment.heldAssertions == 0)
    }

    @Test func systemSleepWaitsForPendingDockRetry() {
        // An undock seen in a brief wake, and the first attempt doesn't take: the Mac must not
        // sleep between the attempt and its retry.
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        controller.ignoredSets = 1
        environment.displays = [.builtIn]
        var acknowledged = 0

        coordinator.handleSystemWillSleep { acknowledged += 1 }
        #expect(acknowledged == 0) // Waiting out the wake grace.
        scheduler.advance(by: PowerCoordinator.wakeGrace)
        #expect(controller.sets == [.off])
        #expect(controller.power == .on)
        #expect(acknowledged == 0) // The retry is still pending.

        scheduler.advance(by: RetryPolicy.dock.delays[0])
        #expect(controller.power == .off)
        #expect(acknowledged == 1)
    }

    @Test func systemSleepIsAcknowledgedAfterDockChangeGivesUp() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        controller.ignoredSets = 100
        environment.displays = [.builtIn]
        var acknowledged = 0

        coordinator.handleSystemWillSleep { acknowledged += 1 }
        scheduler.advance(by: .seconds(30))

        #expect(controller.sets.count == 1 + RetryPolicy.dock.delays.count)
        #expect(acknowledged == 1)
        #expect(environment.heldAssertions == 0)
    }

    @Test func settingOffDoesNotWaitForBluetoothCall() {
        // 1.0 never held back sleep; with the setting off, a running wake restore doesn't either.
        let coordinator = makeCoordinator(keepOnWhenDocked: false)
        coordinator.handleWillSleep()
        scheduler.runsBackgroundInline = false
        coordinator.handleDidWake()
        var acknowledged = 0

        coordinator.handleSystemWillSleep { acknowledged += 1 }

        #expect(acknowledged == 1)
    }

    @Test func settingOffDoesNotWaitForSettle() {
        let coordinator = makeCoordinator(keepOnWhenDocked: false)
        environment.displays = [.builtIn]
        coordinator.handle(.displaysChanged)
        var acknowledged = 0

        coordinator.handleSystemWillSleep { acknowledged += 1 }

        #expect(acknowledged == 1)
    }

    @Test func systemSleepIsAcknowledgedEvenIfTheCallWasInterrupted() {
        let coordinator = makeCoordinator()
        coordinator.handleWillSleep()
        scheduler.runsBackgroundInline = false
        setDisplays([.builtIn], on: coordinator)
        var acknowledged = 0
        coordinator.handleSystemWillSleep { acknowledged += 1 }

        coordinator.handleDidWake()
        scheduler.finishBackgroundWork()

        #expect(acknowledged == 1)
        #expect(controller.power == .on)
    }
}
