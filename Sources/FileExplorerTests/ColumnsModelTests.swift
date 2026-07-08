import Foundation
import FileExplorerCore

@MainActor
func columnsModelTests() async {
    await test("columnChain yields capped ancestors plus current") {
        let url = URL(fileURLWithPath: "/a/b/c/d/e")
        let chain = ColumnsModel.columnChain(for: url, maxColumns: 3)
        expectEqual(chain.map(\.path), ["/a/b/c", "/a/b/c/d", "/a/b/c/d/e"],
                    "last three path levels")
        let short = ColumnsModel.columnChain(for: URL(fileURLWithPath: "/tmp"),
                                             maxColumns: 4)
        expectEqual(short.map(\.path), ["/", "/tmp"], "root-bounded chain")
    }

    await test("refresh loads listings for every column") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-col-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("f.txt"),
                      atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ColumnsModel()
        await model.refresh(for: sub, showHidden: false, maxColumns: 2)
        expectEqual(model.columns.count, 2, "two columns")
        expectEqual(model.columns.last?.url.lastPathComponent, "sub", "current last")
        expectEqual(model.columns.last?.entries.map(\.name), ["f.txt"],
                    "current column lists contents")
        expect(model.columns.first?.entries.contains { $0.name == "sub" } == true,
               "ancestor column lists the child dir")
    }
}
