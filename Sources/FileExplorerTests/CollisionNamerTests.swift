import Foundation
import FileExplorerCore

@MainActor
func collisionNamerTests() async {
    await test("copyName leaves a free name unchanged") {
        expectEqual(CollisionNamer.copyName(for: "photo.jpg", existing: []),
                    "photo.jpg", "free name passes through")
    }

    await test("copyName appends ' copy' before the extension") {
        expectEqual(CollisionNamer.copyName(for: "photo.jpg", existing: ["photo.jpg"]),
                    "photo copy.jpg", "first collision")
        expectEqual(CollisionNamer.copyName(
                        for: "photo.jpg",
                        existing: ["photo.jpg", "photo copy.jpg"]),
                    "photo copy 2.jpg", "second collision counts from 2")
        expectEqual(CollisionNamer.copyName(
                        for: "photo.jpg",
                        existing: ["photo.jpg", "photo copy.jpg", "photo copy 2.jpg"]),
                    "photo copy 3.jpg", "counter keeps climbing")
    }

    await test("copyName handles extensionless and dotfile names") {
        expectEqual(CollisionNamer.copyName(for: "Makefile", existing: ["Makefile"]),
                    "Makefile copy", "no extension → suffix at end")
        expectEqual(CollisionNamer.copyName(for: ".env", existing: [".env"]),
                    ".env copy", "dotfile keeps the whole name as stem")
    }

    await test("sequentialName finds the first free numbered name") {
        expectEqual(CollisionNamer.sequentialName(base: "untitled", existing: []),
                    "untitled", "free base name")
        expectEqual(CollisionNamer.sequentialName(base: "untitled",
                                                  existing: ["untitled"]),
                    "untitled 2", "first collision → 2")
        expectEqual(CollisionNamer.sequentialName(
                        base: "untitled", existing: ["untitled", "untitled 2"]),
                    "untitled 3", "keeps climbing")
    }
}
