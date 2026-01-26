import Foundation

extension Process {
    public func launching() async throws -> (out: Pipe, err: Pipe) {
        let stdout = Pipe()
        let stderr = Pipe()

        standardOutput = stdout
        standardError = stderr

        try run()

        return try await withCheckedThrowingContinuation { continuation in
            terminationHandler = { [stdout, stderr] process in
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let stdoutString = String(data: stdoutData, encoding: .utf8)
                    let stderrString = String(data: stderrData, encoding: .utf8)

                    continuation.resume(throwing: ProcessError.execution(
                        process: process,
                        standardOutput: stdoutString,
                        standardError: stderrString
                    ))
                    return
                }

                continuation.resume(returning: (stdout, stderr))
            }
        }
    }

    public enum ProcessError: Error {
        case execution(process: Process, standardOutput: String?, standardError: String?)
    }
}

extension Process.ProcessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .execution(process: let task, standardOutput: _, standardError: _):
            return "Failed executing: `\(task)` (\(task.terminationStatus))."
        }
    }
}

extension Process {
    open override var description: String {
        let launchPath = self.launchPath ?? "$0"
        var args = [launchPath]
        arguments.flatMap{ args += $0 }
        return args.map { arg in
            if arg.contains(" ") {
                return "\"\(arg)\""
            } else if arg == "" {
                return "\"\""
            } else {
                return arg
            }
        }.joined(separator: " ")
    }
}
