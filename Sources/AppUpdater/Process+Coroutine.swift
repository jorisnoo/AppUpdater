import Foundation

extension Process {
    /// Drains both streams concurrently so verbose child processes cannot fill a pipe.
    public func launching(timeout: TimeInterval = 120) async throws -> (out: Data, err: Data) {
        let stdout = Pipe()
        let stderr = Pipe()
        standardOutput = stdout
        standardError = stderr
        standardInput = FileHandle.nullDevice

        let output = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
        let errors = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if self.isRunning { self.terminate() }
        }
        defer { timer.cancel() }

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    terminationHandler = { process in
                        continuation.resume(returning: process.terminationStatus)
                    }
                    do {
                        try Task.checkCancellation()
                        try run()
                        try? stdout.fileHandleForWriting.close()
                        try? stderr.fileHandleForWriting.close()
                        if Task.isCancelled, isRunning { terminate() }
                    } catch {
                        terminationHandler = nil
                        try? stdout.fileHandleForWriting.close()
                        try? stderr.fileHandleForWriting.close()
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                if self.isRunning { self.terminate() }
            }
        } catch {
            _ = await output.value
            _ = await errors.value
            throw error
        }

        let out = await output.value
        let err = await errors.value
        try Task.checkCancellation()
        guard terminationReason == .exit, status == 0 else {
            throw ProcessError.execution(
                process: self,
                standardOutput: String(data: out, encoding: .utf8),
                standardError: String(data: err, encoding: .utf8)
            )
        }
        return (out, err)
    }

    public enum ProcessError: Error {
        case execution(process: Process, standardOutput: String?, standardError: String?)
    }
}

extension Process.ProcessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .execution(process: let task, standardOutput: _, standardError: _):
            return "Failed executing: `\(Self.commandString(for: task))` (\(task.terminationStatus))."
        }
    }

    private static func commandString(for task: Process) -> String {
        let executable = task.executableURL?.path ?? "$0"
        return ([executable] + (task.arguments ?? [])).map { arg in
            if arg.isEmpty || arg.contains(" ") {
                return "\"\(arg)\""
            }
            return arg
        }.joined(separator: " ")
    }
}
