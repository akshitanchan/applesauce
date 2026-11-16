import Foundation

/// Runs `operation` with a time limit. Throws `TIMEOUT` (or the given error) when the limit passes.
/// The caller gets an answer on time even when the operation blocks and ignores cancellation
/// (for example a stuck Apple Event). The operation task is cancelled, and it finishes in the background.
public func withTimeout<T: Sendable>(
    seconds: Double,
    error: ToolError? = nil,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let limitError =
        error
        ?? ToolError(
            .timeout,
            "The operation took longer than \(Int(seconds)) seconds.",
            fix: "Try a smaller request, for example a shorter date range or a lower limit."
        )
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let gate = ResumeOnce(continuation)
        let work = Task {
            do { gate.resume(.success(try await operation())) } catch { gate.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if gate.resume(.failure(limitError)) { work.cancel() }
        }
    }
}

/// Resumes a continuation exactly once, from whichever side finishes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// Returns true when this call resumed the continuation.
    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}
