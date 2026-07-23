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

private let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

@MainActor @Test func lockInvocationIsCGSessionSuspend() {
    let inv = SystemCommandHandler.invocations(for: .lock)
    #expect(inv.count == 1)
    #expect(inv[0].executable == cgSession)
    #expect(inv[0].arguments == ["-suspend"])
}

@MainActor @Test func sleepLocksThenSleeps() {
    let inv = SystemCommandHandler.invocations(for: .sleep)
    #expect(inv.count == 2)
    #expect(inv[0].executable == cgSession)          // lock first
    #expect(inv[0].arguments == ["-suspend"])
    #expect(inv[1].executable == "/usr/bin/pmset")   // then sleep
    #expect(inv[1].arguments == ["sleepnow"])
}

@MainActor @Test func unimplementedCommandsHaveNoInvocations() {
    #expect(SystemCommandHandler.invocations(for: .shutdown).isEmpty)
    #expect(SystemCommandHandler.invocations(for: .restart).isEmpty)
    #expect(SystemCommandHandler.invocations(for: .logout).isEmpty)
    #expect(SystemCommandHandler.invocations(for: .displaySleep).isEmpty)
}

@MainActor @Test func executeSleepImmediatelyRunsLockThenSleep() {
    let runner = MockCommandRunner()
    let handler = SystemCommandHandler(runner: runner)
    let action = Action(profileId: "p", type: .systemCommand, name: "Sleep",
                        parameters: ["command": "sleep", "countdown_seconds": "0"])
    handler.executeAction(action)
    #expect(runner.calls.map { $0.arguments } == [["-suspend"], ["sleepnow"]])
}

@MainActor @Test func executeUnknownCommandRunsNothing() {
    let runner = MockCommandRunner()
    let handler = SystemCommandHandler(runner: runner)
    let action = Action(profileId: "p", type: .systemCommand, name: "Bad",
                        parameters: ["command": "frobnicate"])
    handler.executeAction(action)
    #expect(runner.calls.isEmpty)
}

@MainActor @Test func executeWrongActionTypeRunsNothing() {
    let runner = MockCommandRunner()
    let handler = SystemCommandHandler(runner: runner)
    let action = Action(profileId: "p", type: .notification, name: "N",
                        parameters: ["command": "sleep"])
    handler.executeAction(action)
    #expect(runner.calls.isEmpty)
}

@MainActor @Test func runInvocationsStopsOnFirstError() {
    let runner = MockCommandRunner()
    runner.errorToThrow = CommandError.launchFailed("boom")
    let handler = SystemCommandHandler(runner: runner)
    handler.runInvocations(for: .sleep)
    // sleep = [lock, pmset]; the lock invocation throws, so pmset is never attempted
    #expect(runner.calls.count == 1)
    #expect(runner.calls.first?.arguments == ["-suspend"])
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
    var presented = false
    let handler = SystemCommandHandler(runner: runner,
        presentCountdown: { _, _, _, _ in presented = true })
    handler.executeAction(Action(profileId: "p", type: .systemCommand, name: "S",
        parameters: ["command": "sleep", "countdown_seconds": "0"]))
    #expect(presented == false)
    #expect(runner.calls.count == 2)   // ran immediately
}

@MainActor @Test func countdownPositivePresentsOverlayAndDefersRun() {
    let runner = MockCommandRunner()
    var captured: (() -> Void)?
    let handler = SystemCommandHandler(runner: runner,
        presentCountdown: { _, _, _, onComplete in captured = onComplete })
    handler.executeAction(Action(profileId: "p", type: .systemCommand, name: "S",
        parameters: ["command": "sleep", "countdown_seconds": "30"]))
    #expect(runner.calls.isEmpty)      // deferred until countdown completes
    captured?()                        // simulate countdown finishing
    #expect(runner.calls.map { $0.arguments } == [["-suspend"], ["sleepnow"]])
}
