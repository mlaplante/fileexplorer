import Foundation

@MainActor var testFailures = 0
@MainActor var testCount = 0

@MainActor
func test(_ name: String, _ body: () async throws -> Void) async {
    print("• \(name)")
    do { try await body() } catch {
        testFailures += 1
        print("  FAIL - threw \(error)")
    }
}

@MainActor
func expect(_ condition: Bool, _ message: String,
            file: StaticString = #filePath, line: UInt = #line) {
    testCount += 1
    if condition {
        print("  ok - \(message)")
    } else {
        testFailures += 1
        print("  FAIL - \(message)  (\(file):\(line))")
    }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
    expect(actual == expected, "\(message) [got: \(actual), want: \(expected)]",
           file: file, line: line)
}

@MainActor
func finish() -> Never {
    print(testFailures == 0
        ? "PASS (\(testCount) assertions)"
        : "FAILED (\(testFailures) failures / \(testCount) assertions)")
    exit(testFailures == 0 ? 0 : 1)
}
