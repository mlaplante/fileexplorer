import Foundation

await test("harness sanity") {
    expect(true, "expect(true) passes")
    expectEqual(2 + 2, 4, "arithmetic works")
}

finish()
