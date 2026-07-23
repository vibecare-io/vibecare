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
