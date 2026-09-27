import Foundation
import Subprocess
import System

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
    public var status: TerminationStatus
    public var stderr: String
    public var description: String { "\(executable) \(status): \(stderr)" }
}

enum ProcessRunner {
    /// Runs a process and returns up to `maxBytes` of stdout, stopping it once the limit is hit.
    ///
    /// Standard error is read while standard output is, so a child that writes a lot of errors
    /// can't block on a full pipe; cancelling the calling task stops the child. A non-zero exit
    /// is an error unless output was cut off by the limit (the process was stopped on purpose)
    /// or `acceptedStatuses` includes it.
    static func output(
        executable: String, arguments: [String], maxBytes: Int, acceptedStatuses: Set<Int32> = [0]
    ) async throws -> Data {
        let result = try await run(
            .path(FilePath(executable)), arguments: Arguments(arguments),
            input: .none, output: .sequence, error: .sequence
        ) { execution in
            async let errorHead = head(of: execution.standardError, maxBytes: 500)
            var data = Data()
            var truncated = false
            for try await buffer in execution.standardOutput {
                buffer.withUnsafeBytes { data.append(contentsOf: $0) }
                if data.count >= maxBytes {
                    truncated = true
                    await execution.teardown(using: [])
                    break
                }
            }
            return (data: data.prefix(maxBytes), truncated: truncated, errors: try await errorHead)
        }
        let output = result.closureResult
        if output.truncated { return output.data }
        if case let .exited(code) = result.terminationStatus, acceptedStatuses.contains(code) { return output.data }
        throw ProcessFailure(
            executable: executable, status: result.terminationStatus,
            stderr: String(decoding: output.errors, as: UTF8.self)
        )
    }

    /// Reads `stream` to its end (so the child never blocks writing it), keeping the first
    /// `maxBytes`.
    static func head(of stream: SubprocessOutputSequence, maxBytes: Int) async throws -> Data {
        var data = Data()
        for try await buffer in stream where data.count < maxBytes {
            buffer.withUnsafeBytes { data.append(contentsOf: $0.prefix(maxBytes - data.count)) }
        }
        return data
    }
}
