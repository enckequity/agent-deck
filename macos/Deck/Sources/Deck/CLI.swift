import Foundation

/// Runs the agent-deck CLI and the deck-task launcher off the main thread.
enum CLI {
    static let home = NSHomeDirectory()
    static let agentDeck = "\(home)/.local/bin/agent-deck"
    static let deckTask = "\(home)/bin/deck-task"

    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
        var ok: Bool { status == 0 }
        var text: String { String(decoding: stdout, as: UTF8.self) }
        /// Last meaningful line of stderr (or stdout), for showing a failure in one sentence.
        var reason: String {
            let lines = (stderr + "\n" + text).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let line = lines.last { !$0.isEmpty } ?? "exit \(status)"
            return line.replacingOccurrences(of: "deck-task: ", with: "")
        }
    }

    private static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:\(home)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }()

    /// Runs `executable args…`. `login` runs it through a zsh login shell so sessions it
    /// spawns inherit the same environment as a Terminal launch.
    static func run(_ executable: String, _ args: [String], login: Bool = false) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                if login {
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-lc", "exec \"$0\" \"$@\"", executable] + args
                } else {
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = args
                }
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: -1, stdout: Data(), stderr: error.localizedDescription))
                    return
                }
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: outData,
                    stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    static func deck(_ args: String...) async -> Result {
        await run(agentDeck, args)
    }
}
