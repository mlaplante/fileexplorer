import Foundation
import FileExplorerCore

@MainActor
func scriptResultFormatterTests() async {
    await test("ScriptResultFormatter formats banner text") {
        expectEqual(ScriptResultFormatter.bannerText(name: "resize.sh",
                                                     outcome: .finished),
                    "resize.sh finished",
                    "finished outcome names the script")
        expectEqual(ScriptResultFormatter.bannerText(name: "resize.sh",
                                                     outcome: .stillRunning),
                    "resize.sh still running…",
                    "timeout outcome names the still-running script")
    }

    await test("ScriptResultFormatter formats failure alerts") {
        let alert = ScriptResultFormatter.alert(name: "resize.sh",
                                                exitCode: 2,
                                                stderr: " bad input \n")
        expectEqual(alert.title, "resize.sh failed (exit 2)",
                    "title includes script name and exit code")
        expectEqual(alert.message, " bad input",
                    "message trims trailing whitespace")

        let empty = ScriptResultFormatter.alert(name: "resize.sh",
                                                exitCode: 1,
                                                stderr: " \n\t")
        expectEqual(empty.message, "(no error output)",
                    "empty stderr gets fallback message")
    }

    await test("ScriptResultFormatter truncates stderr tail") {
        let small = Data("short stderr".utf8)
        expectEqual(ScriptResultFormatter.truncatedStderr(small),
                    "short stderr",
                    "small stderr is preserved")

        let long = Data((String(repeating: "a", count: 16) +
                         String(repeating: "b", count: 4096)).utf8)
        let truncated = ScriptResultFormatter.truncatedStderr(long)
        expect(truncated.hasPrefix("…"), "truncated stderr is prefixed")
        expectEqual(truncated.dropFirst().count, 4096,
                    "truncated stderr keeps the last 4096 bytes")
        expect(truncated.hasSuffix(String(repeating: "b", count: 4096)),
               "truncated stderr keeps the tail")

        let invalid = ScriptResultFormatter.truncatedStderr(Data([0xff, 0xfe]))
        expect(!invalid.isEmpty, "invalid UTF-8 decodes lossily")
    }

    await test("ScriptResultFormatter formats launch failure alerts") {
        struct LaunchError: Error, CustomStringConvertible {
            var description: String { "permission denied" }
        }

        let alert = ScriptResultFormatter.launchFailureAlert(
            name: "resize.sh", error: LaunchError())
        expectEqual(alert.title, "resize.sh could not start",
                    "launch failure title names script")
        expectEqual(alert.message, "permission denied",
                    "launch failure message uses error text")
    }
}
