import Foundation

/// Limits how many operations run at once (used to keep OCR from saturating the machine).
public actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = limit
    }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Error from a subprocess that exited unsuccessfully.
public struct ProcessFailure: Error, CustomStringConvertible {
    public var executable: String
    public var status: Int32
    public var stderr: String
    public var description: String { "\(executable) exited with \(status): \(stderr)" }
}

enum ProcessRunner {
    /// Runs a process and returns up to `maxBytes` of stdout, terminating it once the limit is hit.
    ///
    /// Blocking pipe reads happen on a GCD thread so the Swift concurrency pool isn't blocked.
    /// A non-zero exit is an error unless output was truncated by the limit (the process was
    /// killed on purpose) or `acceptedStatuses` includes it.
    static func output(
        executable: String, arguments: [String], maxBytes: Int, acceptedStatuses: Set<Int32> = [0]
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                // Not `waitUntilExit()`, which spins a run loop and can miss the exit (see
                // `RegexSearcher.ripgrepBatch`).
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                var data = Data()
                var truncated = false
                let reader = stdout.fileHandleForReading
                while let chunk = try? reader.read(upToCount: 65536), !chunk.isEmpty {
                    data.append(chunk)
                    if data.count >= maxBytes {
                        truncated = true
                        process.terminate()
                        break
                    }
                }
                let errorOutput = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                exited.wait()
                if truncated || acceptedStatuses.contains(process.terminationStatus) {
                    continuation.resume(returning: data.prefix(maxBytes))
                } else {
                    continuation.resume(throwing: ProcessFailure(
                        executable: executable, status: process.terminationStatus,
                        stderr: String(decoding: errorOutput.prefix(500), as: UTF8.self)
                    ))
                }
            }
        }
    }
}
