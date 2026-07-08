import Foundation
import FileExplorerCore

@MainActor
func volumeSpaceTests() async {
    await test("VolumeSpace formats available bytes") {
        let bytes: Int64 = 1_500_000_000
        expectEqual(VolumeSpace.label(bytes: bytes),
                    ByteCountFormatter.string(fromByteCount: bytes,
                                              countStyle: .file) + " available",
                    "byte count label")
        expectEqual(VolumeSpace.label(bytes: nil), nil, "nil bytes omit label")
    }

    await test("VolumeSpace reads local temporary volume capacity") {
        let bytes = VolumeSpace.availableBytes(
            for: FileManager.default.temporaryDirectory)

        expect(bytes != nil, "temporary directory volume reports capacity")
        expect((bytes ?? 0) > 0, "available capacity is positive")
    }
}
