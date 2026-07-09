import Foundation
import FileExplorerCore

@MainActor
func scriptRunnerTests() async {
    func writeScript(_ dir: URL, name: String, body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true,
                                         encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    func invocation(script: URL, cwd: URL,
                    arguments: [String] = []) -> ScriptInvocationPlanner.Invocation {
        ScriptInvocationPlanner.Invocation(executable: script,
                                           arguments: arguments,
                                           workingDirectory: cwd)
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    await test("ScriptRunner reports success banner and completion") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try writeScript(dir, name: "ok.sh", body: "exit 0\n")
        let runner = ScriptRunner()
        var completed = 0
        runner.onCompleted = { completed += 1 }

        runner.run(invocation: invocation(script: script, cwd: dir),
                   timeout: .milliseconds(200))

        let finished = await waitUntil { runner.banner == "ok.sh finished" }
        expect(finished, "success banner appears")
        expectEqual(completed, 1, "completion callback fires")
        expectEqual(runner.pendingAlert, nil, "success does not create alert")
    }

    await test("ScriptRunner reports nonzero exit with stderr") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try writeScript(dir, name: "fail.sh",
                                     body: "echo bad things >&2\nexit 2\n")
        let runner = ScriptRunner()
        var completed = 0
        runner.onCompleted = { completed += 1 }

        runner.run(invocation: invocation(script: script, cwd: dir),
                   timeout: .milliseconds(200))

        let alerted = await waitUntil { runner.pendingAlert != nil }
        expect(alerted, "failure alert appears")
        expect(runner.pendingAlert?.title.contains("exit 2") == true,
               "alert title includes exit code")
        expect(runner.pendingAlert?.message.contains("bad things") == true,
               "alert message includes stderr")
        expectEqual(completed, 1, "completion callback fires on failure")
    }

    await test("ScriptRunner reports timeout then eventual success") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try writeScript(dir, name: "slow.sh",
                                     body: "sleep 0.2\nexit 0\n")
        let runner = ScriptRunner()

        runner.run(invocation: invocation(script: script, cwd: dir),
                   timeout: .milliseconds(60))

        let timedOut = await waitUntil {
            runner.banner == "slow.sh still running…"
        }
        expect(timedOut, "timeout banner appears while process continues")

        let finished = await waitUntil { runner.banner == "slow.sh finished" }
        expect(finished, "eventual completion banner replaces timeout")
        expectEqual(runner.pendingAlert, nil, "eventual success has no alert")
    }

    await test("ScriptRunner reports launch failure") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing.sh")
        let runner = ScriptRunner()

        runner.run(invocation: invocation(script: missing, cwd: dir),
                   timeout: .milliseconds(50))

        let alerted = await waitUntil { runner.pendingAlert != nil }
        expect(alerted, "launch failure alert appears")
        expectEqual(runner.pendingAlert?.title, "missing.sh could not start",
                    "launch failure title names executable")
    }

    await test("ScriptRunner passes argv and cwd") {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try writeScript(
            dir,
            name: "inspect.sh",
            body: "pwd > out.txt\nprintf '%s\\n' \"$@\" >> out.txt\nexit 0\n")
        let runner = ScriptRunner()

        runner.run(invocation: invocation(script: script, cwd: dir,
                                          arguments: ["first", "second"]),
                   timeout: .milliseconds(200))

        let output = dir.appendingPathComponent("out.txt")
        let finished = await waitUntil {
            FileManager.default.fileExists(atPath: output.path)
                && runner.banner == "inspect.sh finished"
        }
        expect(finished, "script writes output and finishes")
        let text = try String(contentsOf: output, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        expect(lines.first?.hasSuffix(dir.lastPathComponent) == true,
               "script runs with invocation cwd")
        expectEqual(Array(lines.dropFirst()), ["first", "second", ""],
                    "script receives argv")
    }
}
