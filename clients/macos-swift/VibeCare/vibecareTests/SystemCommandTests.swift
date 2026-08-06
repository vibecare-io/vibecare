import Testing
@testable import vibecare

// A recording mock so tests never touch the real system.
final class MockCommandRunner: CommandRunner {
    struct Call: Equatable { let executable: String; let arguments: [String] }
    private(set) var calls: [Call] = []
    var errorToThrow: Error?
    func run(executable: String, arguments: [String]) throws {
        calls.append(Call(executable: executable, arguments: arguments))
        if let e = errorToThrow { throw e }
    }
}

// A recording lock mock so tests never actually lock the screen.
final class MockScreenLocker: ScreenLocker {
    private(set) var lockCount = 0
    var errorToThrow: Error?
    func lock() throws {
        lockCount += 1
        if let e = errorToThrow { throw e }
    }
}

@Test func mockRunnerRecordsCalls() throws {
    let runner = MockCommandRunner()
    try runner.run(executable: "/usr/bin/pmset", arguments: ["sleepnow"])
    #expect(runner.calls == [.init(executable: "/usr/bin/pmset", arguments: ["sleepnow"])])
}

@Test func parsesFullSleepRequest() {
    let req = SystemCommandRequest.parse(from: [
        "command": "sleep", "countdown_seconds": "30",
        "cancelable": "true", "message": "Time to wind down"
    ])
    #expect(req == SystemCommandRequest(type: .sleep, countdownSeconds: 30,
                                        cancelable: true, message: "Time to wind down"))
}

@Test func parseDefaultsCountdownZeroAndCancelableTrue() {
    let req = SystemCommandRequest.parse(from: ["command": "lock"])
    #expect(req == SystemCommandRequest(type: .lock, countdownSeconds: 0,
                                        cancelable: true, message: nil))
}

@Test func parseReturnsNilForMissingCommand() {
    #expect(SystemCommandRequest.parse(from: ["countdown_seconds": "30"]) == nil)
}

@Test func parseReturnsNilForUnknownCommand() {
    #expect(SystemCommandRequest.parse(from: ["command": "frobnicate"]) == nil)
}

@MainActor @Test func lockCommandUsesLockerNotSubprocess() {
    let runner = MockCommandRunner()
    let locker = MockScreenLocker()
    SystemCommandHandler(runner: runner, screenLocker: locker).perform(.lock)
    #expect(locker.lockCount == 1)
    #expect(runner.calls.isEmpty)   // login.framework lock is in-process, no subprocess
}

@MainActor @Test func lockFallsBackToDisplaySleepWhenLockerUnavailable() {
    let runner = MockCommandRunner()
    let locker = MockScreenLocker()
    locker.errorToThrow = LoginFrameworkLocker.LockError.symbolUnavailable
    SystemCommandHandler(runner: runner, screenLocker: locker).perform(.lock)
    #expect(locker.lockCount == 1)
    #expect(runner.calls.map { $0.arguments } == [["displaysleepnow"]])
}

@MainActor @Test func sleepLocksThenSleeps() {
    let runner = MockCommandRunner()
    let locker = MockScreenLocker()
    SystemCommandHandler(runner: runner, screenLocker: locker).perform(.sleep)
    #expect(locker.lockCount == 1)                              // lock first...
    #expect(runner.calls.map { $0.arguments } == [["sleepnow"]]) // ...then sleep
}

// Regression for the CGSession bug: a failed lock must NOT prevent the sleep.
@MainActor @Test func sleepStillSleepsWhenEveryLockMechanismFails() {
    let runner = MockCommandRunner()
    runner.errorToThrow = CommandError.launchFailed("boom")   // displaysleepnow AND sleepnow throw
    let locker = MockScreenLocker()
    locker.errorToThrow = LoginFrameworkLocker.LockError.symbolUnavailable
    SystemCommandHandler(runner: runner, screenLocker: locker).perform(.sleep)
    // locker fails -> fallback displaysleepnow fails -> sleepnow is STILL attempted
    #expect(locker.lockCount == 1)
    #expect(runner.calls.map { $0.arguments } == [["displaysleepnow"], ["sleepnow"]])
}

@MainActor @Test func unimplementedCommandsRunNothing() {
    for type in [SystemCommandType.shutdown, .restart, .logout, .displaySleep] {
        let runner = MockCommandRunner()
        let locker = MockScreenLocker()
        SystemCommandHandler(runner: runner, screenLocker: locker).perform(type)
        #expect(runner.calls.isEmpty)
        #expect(locker.lockCount == 0)
    }
}

@MainActor @Test func executeSleepImmediatelyLocksThenSleeps() {
    let runner = MockCommandRunner()
    let locker = MockScreenLocker()
    let handler = SystemCommandHandler(runner: runner, screenLocker: locker)
    let action = Action(profileId: "p", type: .systemCommand, name: "Sleep",
                        parameters: ["command": "sleep", "countdown_seconds": "0"])
    handler.executeAction(action)
    #expect(locker.lockCount == 1)
    #expect(runner.calls.map { $0.arguments } == [["sleepnow"]])
}

@MainActor @Test func executeUnknownCommandRunsNothing() {
    let runner = MockCommandRunner()
    let locker = MockScreenLocker()
    let handler = SystemCommandHandler(runner: runner, screenLocker: locker)
    let action = Action(profileId: "p", type: .systemCommand, name: "Bad",
                        parameters: ["command": "frobnicate"])
    handler.executeAction(action)
    #expect(runner.calls.isEmpty)
    #expect(locker.lockCount == 0)
}

@MainActor @Test func executeWrongActionTypeRunsNothing() {
    let runner = MockCommandRunner()
    let locker = MockScreenLocker()
    let handler = SystemCommandHandler(runner: runner, screenLocker: locker)
    let action = Action(profileId: "p", type: .notification, name: "N",
                        parameters: ["command": "sleep"])
    handler.executeAction(action)
    #expect(runner.calls.isEmpty)
    #expect(locker.lockCount == 0)
}

@MainActor @Test func countdownCompletesAfterTicks() {
    var completed = 0, canceled = 0
    let c = SleepCountdownController(seconds: 2, cancelable: true,
                                    onComplete: { completed += 1 },
                                    onCancel: { canceled += 1 })
    #expect(c.remaining == 2)
    c.tick(); #expect(c.remaining == 1)
    c.tick(); #expect(c.remaining == 0)
    #expect(completed == 1 && canceled == 0)
    c.tick()   // extra ticks must not re-fire
    #expect(completed == 1)
}

@MainActor @Test func countdownCancelFiresOnceAndBlocksCompletion() {
    var completed = 0, canceled = 0
    let c = SleepCountdownController(seconds: 3, cancelable: true,
                                    onComplete: { completed += 1 },
                                    onCancel: { canceled += 1 })
    c.cancel(); c.cancel()
    #expect(canceled == 1 && completed == 0)
    c.tick(); c.tick(); c.tick()
    #expect(completed == 0)   // canceled: no completion
}

@MainActor @Test func nonCancelableIgnoresCancel() {
    var canceled = 0
    let c = SleepCountdownController(seconds: 2, cancelable: false,
                                    onComplete: {}, onCancel: { canceled += 1 })
    c.cancel()
    #expect(canceled == 0)
}

@MainActor @Test func countdownZeroRunsImmediatelyNoOverlay() {
    let runner = MockCommandRunner()
    let locker = MockScreenLocker()
    var presented = false
    let handler = SystemCommandHandler(runner: runner, screenLocker: locker,
        presentCountdown: { _, _, _, _ in presented = true })
    handler.executeAction(Action(profileId: "p", type: .systemCommand, name: "S",
        parameters: ["command": "sleep", "countdown_seconds": "0"]))
    #expect(presented == false)
    #expect(locker.lockCount == 1)              // ran immediately: lock...
    #expect(runner.calls.map { $0.arguments } == [["sleepnow"]])  // ...then sleep
}

@MainActor @Test func countdownPositivePresentsOverlayAndDefersRun() {
    let runner = MockCommandRunner()
    let locker = MockScreenLocker()
    var captured: (() -> Void)?
    let handler = SystemCommandHandler(runner: runner, screenLocker: locker,
        presentCountdown: { _, _, _, onComplete in captured = onComplete })
    handler.executeAction(Action(profileId: "p", type: .systemCommand, name: "S",
        parameters: ["command": "sleep", "countdown_seconds": "30"]))
    #expect(runner.calls.isEmpty && locker.lockCount == 0)  // deferred until countdown completes
    captured?()                                             // simulate countdown finishing
    #expect(locker.lockCount == 1)
    #expect(runner.calls.map { $0.arguments } == [["sleepnow"]])
}
