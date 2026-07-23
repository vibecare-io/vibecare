import Foundation

/// Side-effecting seam for launching external commands. Injected so the
/// pure command logic can be unit-tested without touching the real system.
protocol CommandRunner {
    func run(executable: String, arguments: [String]) throws
}

enum CommandError: Error, Equatable {
    case nonZeroExit(status: Int32, stderr: String)
    case launchFailed(String)
}

/// Real runner: launches `executable`, waits, throws on non-zero exit.
struct ProcessCommandRunner: CommandRunner {
    func run(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(error.localizedDescription)
        }
        // FIXME: stderr is read only after waitUntilExit(); a child that floods >~64KB to
        // stderr before exiting could deadlock on a full pipe. Safe for pmset/CGSession
        // (near-silent), but harden (read pipe on a background queue) before reusing this
        // runner for run_script or other chatty commands.
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw CommandError.nonZeroExit(status: process.terminationStatus, stderr: stderr)
        }
    }
}
