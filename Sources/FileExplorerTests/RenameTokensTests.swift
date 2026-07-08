import Foundation
import FileExplorerCore
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

@MainActor
func renameTokensTests() async {
    let url = URL(fileURLWithPath: "/tmp/IMG_1234.jpg")
    let modified = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 UTC
    let exif = Date(timeIntervalSince1970: 1_600_000_000)     // 2020-09-13 UTC

    await test("expand substitutes date tokens with fixed-locale formatting") {
        let metadata = RenameTokenMetadata(modified: modified, exifDate: exif)
        expectEqual(RenameTokens.expand("shot-{modified:yyyy-MM-dd}", metadata: metadata),
                    "shot-2023-11-14", "modified token")
        expectEqual(RenameTokens.expand("{exif:yyyy}", metadata: metadata),
                    "2020", "exif token")
        expectEqual(RenameTokens.expand("plain", metadata: metadata),
                    "plain", "no tokens pass through")
    }

    await test("exif token falls back to modified when absent") {
        let metadata = RenameTokenMetadata(modified: modified, exifDate: nil)
        expectEqual(RenameTokens.expand("{exif:yyyy-MM-dd}", metadata: metadata),
                    "2023-11-14", "fallback")
    }

    await test("regex find/replace with capture groups") {
        var rules = RenameRules()
        rules.find = #"IMG_(\d+)"#
        rules.replace = "photo-$1"
        rules.useRegex = true
        let items = RenamePlan.plan(urls: [url], rules: rules, existingNames: [])
        expectEqual(items.first?.newName, "photo-1234.jpg", "capture group")
    }

    await test("invalid regex flags every item as invalidPattern") {
        var rules = RenameRules()
        rules.find = "([unclosed"
        rules.useRegex = true
        let items = RenamePlan.plan(urls: [url], rules: rules, existingNames: [])
        expectEqual(items.first?.conflict, .invalidPattern, "bad pattern surfaces")
    }

    await test("case transforms apply to the stem after find/replace") {
        var upper = RenameRules()
        upper.caseTransform = .upper
        expectEqual(RenamePlan.plan(urls: [url], rules: upper,
                                    existingNames: []).first?.newName,
                    "IMG_1234.jpg", "already upper — unchanged content")
        var lower = RenameRules()
        lower.caseTransform = .lower
        expectEqual(RenamePlan.plan(urls: [url], rules: lower,
                                    existingNames: []).first?.newName,
                    "img_1234.jpg", "lowercased stem, extension untouched")
        var title = RenameRules()
        title.caseTransform = .title
        expectEqual(RenamePlan.plan(
                        urls: [URL(fileURLWithPath: "/tmp/my vacation photos.jpg")],
                        rules: title, existingNames: []).first?.newName,
                    "My Vacation Photos.jpg", "title case")
    }

    await test("date tokens expand inside prefix with per-file metadata") {
        var rules = RenameRules()
        rules.prefix = "{modified:yyyy}-"
        let metadata = [url: RenameTokenMetadata(modified: modified, exifDate: nil)]
        let items = RenamePlan.plan(urls: [url], rules: rules,
                                    existingNames: [], metadata: metadata)
        expectEqual(items.first?.newName, "2023-IMG_1234.jpg", "prefix token")
    }

    await test("ExifDateReader round-trips a generated EXIF date") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx-exif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("shot.jpg")
        try ExifTestImage.write(to: photo, dateTimeOriginal: "2021:06:15 10:30:00")
        let date = ExifDateReader.captureDate(of: photo)
        expect(date != nil, "exif date read")
        if let date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            expectEqual(parts.year, 2021, "year")
            expectEqual(parts.month, 6, "month")
            expectEqual(parts.day, 15, "day")
        }
    }
}

/// Test helper: writes a tiny JPEG carrying an EXIF DateTimeOriginal.
enum ExifTestImage {
    static func write(to url: URL, dateTimeOriginal: String) throws {
        let width = 4, height = 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: colorSpace,
                                     components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal,
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ExifTestImage", code: 1)
        }
    }
}
