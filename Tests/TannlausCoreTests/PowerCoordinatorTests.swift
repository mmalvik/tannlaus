import Testing
import TannlausCore

@MainActor
struct PowerCoordinatorTests {
    let scheduler = FakeScheduler()

    func makeCoordinator(_ controller: FakeBluetoothController) -> PowerCoordinator {
        PowerCoordinator(controller: controller, scheduler: scheduler)
    }

    // MARK: Sleep and wake

    @Test func sleepTurnsBluetoothOffAndWakeRestoresIt() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)

        coordinator.handleWillSleep()
        #expect(controller.power == .off)
        #expect(controller.calls == [.read, .set(.off)])

        coordinator.handleDidWake()
        #expect(controller.power == .on)
        #expect(controller.sets == [.off, .on])
        #expect(scheduler.items.isEmpty)
    }

    @Test func bluetoothThatWasOffStaysOff() {
        let controller = FakeBluetoothController(power: .off)
        let coordinator = makeCoordinator(controller)

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        #expect(controller.power == .off)
        #expect(controller.sets.isEmpty)
    }

    @Test func wakeWithoutSleepChangesNothing() {
        let controller = FakeBluetoothController(power: .off)
        let coordinator = makeCoordinator(controller)

        coordinator.handleDidWake()

        #expect(controller.calls.isEmpty)
    }

    @Test func secondWakeDoesNotRestoreAgain() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)

        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        controller.power = .off // The user turns Bluetooth off while awake.
        coordinator.handleDidWake()

        #expect(controller.power == .off)
        #expect(controller.sets == [.off, .on])
    }

    @Test func readFailureBeforeSleepLeavesBluetoothAlone() {
        let controller = FakeBluetoothController(power: .on)
        controller.error = .timedOut
        let coordinator = makeCoordinator(controller)

        coordinator.handleWillSleep()
        controller.error = nil
        coordinator.handleDidWake()

        #expect(controller.sets.isEmpty)
        #expect(scheduler.items.isEmpty)
    }

    // MARK: Launch

    @Test func launchDoesNotTouchBluetooth() {
        let controller = FakeBluetoothController(power: .on)
        _ = makeCoordinator(controller)

        #expect(controller.calls.isEmpty)
    }

    // MARK: Verify, retry, give up

    @Test func failedRestoreIsRetriedUntilItWorks() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)
        coordinator.handleWillSleep()

        controller.ignoredSets = 2
        coordinator.handleDidWake()
        #expect(controller.power == .off)
        #expect(scheduler.pending.count == 1)

        scheduler.runAll()

        #expect(controller.power == .on)
        #expect(controller.sets == [.off, .on, .on, .on])
        #expect(scheduler.pending.isEmpty)
    }

    @Test func givesUpAfterAllRetriesWithBackoff() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)
        coordinator.handleWillSleep()

        controller.ignoredSets = 100
        coordinator.handleDidWake()
        var delays: [Duration] = []
        while let item = scheduler.pending.first {
            delays.append(item.delay)
            scheduler.runNext()
        }

        #expect(delays == RetryPolicy.standard.delays)
        #expect(controller.sets == [.off] + Array(repeating: .on, count: 1 + RetryPolicy.standard.delays.count))
        #expect(controller.power == .off)
    }

    @Test(arguments: [BluetoothControllerError.timedOut, .busy, .unavailable])
    func controllerErrorsCountAsFailures(_ error: BluetoothControllerError) {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)
        coordinator.handleWillSleep()

        controller.error = error
        coordinator.handleDidWake()
        #expect(scheduler.pending.count == 1)

        controller.error = nil
        scheduler.runAll()
        #expect(controller.power == .on)
    }

    @Test func wakeCancelsPendingSleepRetry() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)
        controller.ignoredSets = 1

        coordinator.handleWillSleep()
        #expect(scheduler.pending.count == 1)

        coordinator.handleDidWake()
        scheduler.runAll()

        #expect(controller.power == .on)
        #expect(controller.sets == [.off, .on])
    }

    @Test func sleepDuringPendingRestoreRecordsBluetoothAsOn() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)
        coordinator.handleWillSleep()
        controller.ignoredSets = 1
        coordinator.handleDidWake()
        #expect(controller.power == .off)

        coordinator.handleWillSleep()
        #expect(scheduler.pending.isEmpty)
        coordinator.handleDidWake()

        #expect(controller.power == .on)
    }

    @Test func secondSleepKeepsFirstRecordedState() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)

        coordinator.handleWillSleep()
        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        #expect(controller.power == .on)
    }

    // MARK: Authorization

    @Test(arguments: [BluetoothAuthorization.denied, .restricted, .notDetermined])
    func withoutAccessNothingIsTouched(_ authorization: BluetoothAuthorization) {
        let controller = FakeBluetoothController(power: .on)
        controller.authorization = authorization
        let coordinator = makeCoordinator(controller)

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        #expect(controller.calls.isEmpty)
    }

    @Test func accessRevokedDuringSleepSkipsRestore() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)
        coordinator.handleWillSleep()

        controller.authorization = .denied
        coordinator.handleDidWake()
        controller.authorization = .allowed
        coordinator.handleDidWake()

        #expect(controller.sets == [.off])
    }

    @Test func retryAfterAccessIsRevokedLeavesBluetoothAlone() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)
        controller.ignoredSets = 1
        coordinator.handleWillSleep()
        #expect(scheduler.pending.count == 1)

        controller.authorization = .denied
        scheduler.runAll()

        #expect(controller.sets == [.off])
        #expect(scheduler.pending.isEmpty)
    }

    @Test func restoreRetryWithoutAccessWaitsForNextWake() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)
        coordinator.handleWillSleep()
        controller.ignoredSets = 1
        coordinator.handleDidWake()

        controller.authorization = .denied
        scheduler.runAll()
        #expect(controller.sets == [.off, .on])

        controller.authorization = .allowed
        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        #expect(controller.power == .on)
        #expect(controller.sets == [.off, .on, .off, .on])
    }

    @Test func sleepWithoutAccessKeepsPendingRestore() {
        let controller = FakeBluetoothController(power: .on)
        let coordinator = makeCoordinator(controller)
        coordinator.handleWillSleep()
        controller.ignoredSets = 1
        coordinator.handleDidWake()
        #expect(scheduler.pending.count == 1)

        controller.authorization = .denied
        coordinator.handleWillSleep()
        #expect(scheduler.pending.isEmpty)
        #expect(controller.sets == [.off, .on])

        controller.authorization = .allowed
        coordinator.handleDidWake()

        #expect(controller.power == .on)
        #expect(controller.sets == [.off, .on, .on])
    }

    @Test func worksOnceAccessIsGranted() {
        let controller = FakeBluetoothController(power: .on)
        controller.authorization = .denied
        let coordinator = makeCoordinator(controller)
        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        controller.authorization = .allowed
        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        #expect(controller.sets == [.off, .on])
    }
}
