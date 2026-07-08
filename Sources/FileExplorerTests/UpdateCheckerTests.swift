import Foundation
import FileExplorerCore

@MainActor
func updateCheckerTests() async {
    await test("isNewer compares dotted versions numerically") {
        expect(UpdateChecker.isNewer(remote: "0.2.0", local: "0.1.0"), "minor bump")
        expect(UpdateChecker.isNewer(remote: "1.0.0", local: "0.9.9"), "major beats nines")
        expect(UpdateChecker.isNewer(remote: "0.1.10", local: "0.1.9"), "numeric not lexical")
        expect(!UpdateChecker.isNewer(remote: "0.1.0", local: "0.1.0"), "equal is not newer")
        expect(!UpdateChecker.isNewer(remote: "0.0.9", local: "0.1.0"), "older is not newer")
    }

    await test("isNewer tolerates v-prefixes and ragged lengths") {
        expect(UpdateChecker.isNewer(remote: "v0.2", local: "0.1.5"), "v-prefix + short remote")
        expect(!UpdateChecker.isNewer(remote: "v0.1", local: "0.1.0"), "0.1 == 0.1.0")
        expect(!UpdateChecker.isNewer(remote: "garbage", local: "0.1.0"), "unparseable → not newer")
    }

    await test("update check due only after the throttle interval") {
        let now = Date(timeIntervalSince1970: 2_000_000)
        expect(UpdateChecker.isDue(lastCheck: nil, now: now), "never checked → due")
        expect(!UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-3600), now: now),
               "1h ago → not due")
        expect(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-90_000), now: now),
               "25h ago → due")
    }
}
