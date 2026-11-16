import Foundation

/// What a finished program wrote and how it ended.
public struct ProcessResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let status: Int32
    /// True when `stopAtOutputLimit` ended the program early. `stdout` then holds the first `outputLimit` bytes.
    /// The exit status of a program that was stopped is not meaningful.
    public let truncated: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Largest stdout that `runProcess` keeps (10 MB).
public let processOutputLimit = 10 * 1024 * 1024

/// Runs a program with an argv array. It never uses a shell.
/// - Reads stdout and stderr at the same time, so big output cannot block the program.
/// - After `timeout` seconds it ends the program and throws `TIMEOUT`. A cancelled task ends it too.
/// - More than `outputLimit` bytes on stdout ends the program and throws `INTERNAL_ERROR`.
///   With `stopAtOutputLimit` it ends the program too, but it returns the first `outputLimit` bytes
///   with `truncated` set, and it does not throw.
/// - A program that cannot start throws `INTERNAL_ERROR`. A non-zero exit status is not an error here:
///   the caller reads `status` and `stderr`.
public func runProcess(
    executable: String,
    arguments: [String] = [],
    stdin: Data? = nil,
    timeout: Double = 30,
    outputLimit: Int = processOutputLimit,
    stopAtOutputLimit: Bool = false
) async throws -> ProcessResult {
    let job = ProcessJob(
        executable: executable, arguments: arguments, stdin: stdin, timeout: timeout, outputLimit: outputLimit,
        stopAtOutputLimit: stopAtOutputLimit)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            job.start(continuation)
        }
    } onCancel: {
        job.cancel()
    }
}

/// One running program. A lock guards the state, because pipe handlers and timers run on other threads.
private final class ProcessJob: @unchecked Sendable {
    private enum Stop { case timeout, overflow, cancelled, truncated }

    private let process = Process()
    private let executable: String
    private let timeout: Double
    private let outputLimit: Int
    private let stopAtOutputLimit: Bool
    private let stdinData: Data?

    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stop: Stop?
    private var truncated = false
    private var launched = false
    private var cancelledEarly = false
    private var continuation: CheckedContinuation<ProcessResult, Error>?

    /// Stderr is kept up to this size. More is read and dropped.
    private let stderrLimit = 1024 * 1024

    init(
        executable: String, arguments: [String], stdin: Data?, timeout: Double, outputLimit: Int,
        stopAtOutputLimit: Bool
    ) {
        self.executable = executable
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.stopAtOutputLimit = stopAtOutputLimit
        self.stdinData = stdin
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    }

    func cancel() {
        lock.lock()
        let running = launched
        if !running { cancelledEarly = true }
        lock.unlock()
        if running { terminate(.cancelled) }
    }

    /// Gives the caller its answer. Only the first call counts.
    private func complete(_ result: Result<ProcessResult, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    private func limitFailure(_ reason: Stop?) -> Error? {
        switch reason {
        case .timeout:
            return ToolError(
                .timeout, "The program took longer than \(Int(timeout)) seconds and was stopped.",
                fix: "Try a smaller request.")
        case .overflow:
            return ToolError(
                .internalError, "The program wrote more than \(outputLimit / (1024 * 1024)) MB of output.",
                fix: "Use a more specific request, for example a narrower query or a lower limit.")
        case .cancelled:
            return CancellationError()
        case .truncated, nil:
            return nil
        }
    }

    func start(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = stdinData == nil ? nil : Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe ?? FileHandle.nullDevice

        // Wait for: stdout end, stderr end, and the program exit.
        let group = DispatchGroup()
        group.enter()
        group.enter()
        group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
                return
            }
            lock.lock()
            let keep = stop == nil && !truncated
            if keep { stdout.append(chunk) }
            let tooBig = keep && stdout.count > outputLimit
            if tooBig && stopAtOutputLimit {
                stdout = stdout.prefix(outputLimit)
                truncated = true
            }
            lock.unlock()
            if tooBig { terminate(stopAtOutputLimit ? .truncated : .overflow) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
                return
            }
            lock.lock()
            if stderr.count < stderrLimit { stderr.append(chunk.prefix(stderrLimit - stderr.count)) }
            lock.unlock()
        }
        process.terminationHandler = { _ in group.leave() }

        lock.lock()
        let skip = cancelledEarly
        lock.unlock()
        if skip {
            complete(.failure(CancellationError()))
            return
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            complete(
                .failure(
                    ToolError(
                        .internalError, "Could not start \(executable): \(error.localizedDescription)",
                        fix: "Check that the program exists. If this stays, report it.")))
            return
        }
        lock.lock()
        launched = true
        let late = cancelledEarly
        lock.unlock()
        if late { terminate(.cancelled) }

        // The parent copies of the child ends must close, or the reads never see the end.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        try? inPipe?.fileHandleForReading.close()

        if let inPipe, let data = stdinData {
            let writer = inPipe.fileHandleForWriting
            // A write to a program that already exited must fail with an error, not a signal.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async {
                try? writer.write(contentsOf: data)
                try? writer.close()
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            terminate(.timeout)
        }
        // A child of the program can keep a pipe open after the program exits. Do not wait for it forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 3) { [self] in
            lock.lock()
            let reason = stop
            lock.unlock()
            guard reason == .timeout else { return }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            complete(.failure(limitFailure(reason) ?? CancellationError()))
        }

        group.notify(queue: .global()) { [self] in
            lock.lock()
            let reason = stop
            let result = ProcessResult(
                stdout: stdout, stderr: stderr, status: process.terminationStatus, truncated: truncated)
            lock.unlock()
            if let failure = limitFailure(reason) {
                complete(.failure(failure))
            } else {
                complete(.success(result))
            }
        }
    }

    /// Ends the program once. The first reason wins. It sends SIGTERM, then SIGKILL after 2 seconds.
    private func terminate(_ reason: Stop) {
        guard process.isRunning else { return }
        lock.lock()
        let first = stop == nil
        if first { stop = reason }
        lock.unlock()
        guard first else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
