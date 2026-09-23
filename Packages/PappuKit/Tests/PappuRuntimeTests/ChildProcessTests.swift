import Foundation
import PappuRuntime
import Testing

/// RUN-3d: a process PappuClip started can be read from and stopped. Real processes, because the
/// pipes and the signals are the thing under test.
@Suite struct ChildProcessTests {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func inputGoesInAndBothOutputsComeOut() async throws {
        let process = try ChildProcess(.init(
            executable: Self.shell,
            arguments: ["-c", "tr a-z A-Z; echo oops >&2; exit 3"],
            standardInput: Data("shout".utf8)
        ))
        let result = await process.result()
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "SHOUT")
        #expect(String(decoding: result.standardError, as: UTF8.self) == "oops\n")
        #expect(result.status == 3)
        #expect(result.succeeded == false)
    }

    /// More than a pipe holds, which deadlocks a reader that waits for the exit first.
    @Test func aLargeOutputDoesNotStallTheProcess() async throws {
        let process = try ChildProcess(.init(executable: Self.shell, arguments: ["-c", "head -c 300000 /dev/zero"]))
        let result = await process.result()
        #expect(result.succeeded)
        #expect(result.standardOutput.count == 300_000)
    }

    @Test func cancellingStopsItAndSaysSo() async throws {
        let process = try ChildProcess(
            .init(executable: Self.shell, arguments: ["-c", "sleep 30"]),
            terminationGrace: .milliseconds(200)
        )
        #expect(await process.cancel() == .stopped)
        let result = await process.result()
        #expect(result.cancelled)
        #expect(result.succeeded == false)
    }

    /// A process that ignores SIGTERM is killed once the grace runs out.
    @Test func aProcessThatIgnoresTheSignalIsKilled() async throws {
        let process = try ChildProcess(
            .init(executable: Self.shell, arguments: ["-c", "trap '' TERM; sleep 30 & wait"]),
            terminationGrace: .milliseconds(100)
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(await process.cancel() == .stopped)
        let result = await process.result()
        #expect(result.signalled)
    }

    @Test func delegatedWorkIsOnlyAskedToStop() async throws {
        let process = try ChildProcess(
            .init(executable: Self.shell, arguments: ["-c", "sleep 30"]),
            ownership: .delegated,
            terminationGrace: .milliseconds(100)
        )
        #expect(await process.cancel() == .askedToStop)
        _ = await process.result()
    }

    /// A script that leaves something running with its standard output: the result is the script's,
    /// on the script's exit, and not whenever the thing it left behind lets go of the pipe.
    @Test func aBackgroundedChildDoesNotHoldTheResult() async throws {
        let started = ContinuousClock.now
        let process = try ChildProcess(
            .init(executable: Self.shell, arguments: ["-c", "echo done; sleep 3 &"]),
            outputDrain: .milliseconds(100)
        )
        let result = await process.result()
        #expect(result.succeeded)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "done\n")
        #expect(started.duration(to: .now) < .seconds(5))
        _ = await process.cancel()
    }

    @Test func aMissingExecutableThrows() {
        #expect(throws: (any Error).self) {
            try ChildProcess(.init(executable: URL(fileURLWithPath: "/nonexistent/tool")))
        }
    }
}
