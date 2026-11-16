import AppleSauceCore
import Foundation
import Testing

@Suite struct ProcessRunnerTests {
    @Test func readsStdoutAndStatus() async throws {
        let result = try await runProcess(executable: "/bin/echo", arguments: ["hello", "wor ld"])
        #expect(result.status == 0)
        #expect(result.stdoutText == "hello wor ld\n")
        #expect(result.stderr.isEmpty)
    }

    @Test func passesArgumentsWithoutAShell() async throws {
        let result = try await runProcess(executable: "/bin/echo", arguments: ["$HOME; echo x", "'q'"])
        #expect(result.stdoutText == "$HOME; echo x 'q'\n")
    }

    @Test func feedsStdin() async throws {
        let result = try await runProcess(executable: "/bin/cat", stdin: Data("from stdin".utf8))
        #expect(result.stdoutText == "from stdin")
    }

    @Test func readsBigStdinAndStdoutWithoutBlocking() async throws {
        let data = Data(repeating: 65, count: 2_000_000)
        let result = try await runProcess(executable: "/bin/cat", stdin: data)
        #expect(result.stdout.count == 2_000_000)
    }

    @Test func returnsNonZeroStatusAndStderr() async throws {
        let result = try await runProcess(executable: "/bin/ls", arguments: ["/no/such/path/applesauce"])
        #expect(result.status != 0)
        #expect(!result.stderrText.isEmpty)
    }

    @Test func timeoutEndsTheProgram() async {
        let start = Date()
        do {
            _ = try await runProcess(executable: "/bin/sleep", arguments: ["30"], timeout: 0.3)
            Issue.record("expected a timeout")
        } catch let error as ToolError {
            #expect(error.code == .timeout)
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func outputOverTheLimitIsAnError() async {
        do {
            _ = try await runProcess(
                executable: "/bin/cat", stdin: Data(repeating: 66, count: 100_000), outputLimit: 1000)
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("MB"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func stopAtOutputLimitReturnsWhatWasRead() async throws {
        let result = try await runProcess(
            executable: "/bin/cat", stdin: Data(repeating: 66, count: 100_000), outputLimit: 1000,
            stopAtOutputLimit: true)
        #expect(result.truncated)
        #expect(result.stdout.count == 1000)
        #expect(result.stdout.allSatisfy { $0 == 66 })
    }

    @Test func stopAtOutputLimitEndsAProgramThatKeepsRunning() async throws {
        let started = Date()
        let result = try await runProcess(
            executable: "/bin/sh", arguments: ["-c", "printf 'aaaaaaaaaa'; printf 'bbbbbbbbbb'; sleep 30"], timeout: 20,
            outputLimit: 15, stopAtOutputLimit: true)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(result.truncated)
        #expect(result.stdout.count <= 15)
    }

    @Test func stopAtOutputLimitIsQuietWhenOutputIsSmall() async throws {
        let result = try await runProcess(
            executable: "/bin/echo", arguments: ["hi"], outputLimit: 1000, stopAtOutputLimit: true)
        #expect(!result.truncated)
        #expect(result.stdoutText == "hi\n")
    }

    @Test func missingProgramIsAnInternalError() async {
        do {
            _ = try await runProcess(executable: "/no/such/program")
            Issue.record("expected an error")
        } catch let error as ToolError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("/no/such/program"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func cancelEndsTheProgram() async throws {
        let start = Date()
        let task = Task {
            try await runProcess(executable: "/bin/sleep", arguments: ["30"], timeout: 60)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = try? await task.value
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
