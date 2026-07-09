import Foundation
import FileExplorerCore

@MainActor
func usageRankingTests() async {
    await test("UsageRanking sorts by bytes descending and name for ties") {
        let root = URL(fileURLWithPath: "/tmp/ranking")
        let alpha = root.appendingPathComponent("Alpha")
        let beta = root.appendingPathComponent("beta")
        let file = root.appendingPathComponent("file.txt")

        let rows = UsageRanking.rows(childTotals: [
            beta: (bytes: 20, items: 2, isDirectory: true),
            file: (bytes: 20, items: 1, isDirectory: false),
            alpha: (bytes: 30, items: 3, isDirectory: true),
        ])

        expectEqual(rows.map(\.url), [alpha, beta, file], "rows sorted by bytes then localized name")
        expectEqual(rows[0].name, "Alpha", "row carries last path component")
        expectEqual(rows[1].itemCount, 2, "directory item count preserved")
        expectEqual(rows[2].itemCount, 1, "file item count is one")
        expect(!rows[2].isDirectory, "file row marks isDirectory false")
    }

    await test("UsageRanking proportions scale to largest child") {
        let root = URL(fileURLWithPath: "/tmp/ranking")
        let big = root.appendingPathComponent("big")
        let small = root.appendingPathComponent("small")

        let rows = UsageRanking.rows(childTotals: [
            big: (bytes: 100, items: 1, isDirectory: true),
            small: (bytes: 25, items: 1, isDirectory: true),
        ])

        expectEqual(rows[0].proportion, 1.0, "largest row is full width")
        expectEqual(rows[1].proportion, 0.25, "smaller row scales against largest")
    }

    await test("UsageRanking zero-byte rows avoid division by zero") {
        let root = URL(fileURLWithPath: "/tmp/ranking")
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")

        let rows = UsageRanking.rows(childTotals: [
            a: (bytes: 0, items: 1, isDirectory: false),
            b: (bytes: 0, items: 1, isDirectory: false),
        ])

        expectEqual(rows.map(\.proportion), [0, 0], "all zero rows have zero proportions")
    }

    await test("UsageRanking subtracting removes trashed row and rescales") {
        let root = URL(fileURLWithPath: "/tmp/ranking")
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        let c = root.appendingPathComponent("c")
        let rows = UsageRanking.rows(childTotals: [
            a: (bytes: 100, items: 1, isDirectory: true),
            b: (bytes: 50, items: 1, isDirectory: true),
            c: (bytes: 25, items: 1, isDirectory: false),
        ])

        let updated = UsageRanking.subtracting(a, bytes: 100, from: rows)

        expectEqual(updated.map(\.url), [b, c], "trashed row removed")
        expectEqual(updated[0].proportion, 1.0, "remaining largest row rescales to full")
        expectEqual(updated[1].proportion, 0.5, "remaining smaller row rescales")
    }
}
