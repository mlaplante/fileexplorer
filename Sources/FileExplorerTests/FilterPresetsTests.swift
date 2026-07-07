import Foundation
import UniformTypeIdentifiers
import FileExplorerCore

@MainActor
func filterPresetsTests() async {
    await test("TypePreset matches by UTType conformance") {
        expect(TypePreset.images.matches(UTType(filenameExtension: "png")),
               "png is an image")
        expect(TypePreset.images.matches(UTType(filenameExtension: "heic")),
               "heic is an image")
        expect(!TypePreset.images.matches(UTType(filenameExtension: "txt")),
               "txt is not an image")
        expect(TypePreset.pdfs.matches(UTType(filenameExtension: "pdf")),
               "pdf matches PDFs")
        expect(!TypePreset.images.matches(UTType(filenameExtension: "pdf")),
               "pdf is not an image")
        expect(TypePreset.videos.matches(UTType(filenameExtension: "mp4")),
               "mp4 is a video")
        expect(TypePreset.videos.matches(UTType(filenameExtension: "mov")),
               "mov is a video")
        expect(TypePreset.documents.matches(UTType(filenameExtension: "txt")),
               "txt is a document")
        expect(TypePreset.documents.matches(UTType(filenameExtension: "docx")),
               "docx is a document")
        expect(!TypePreset.documents.matches(UTType(filenameExtension: "png")),
               "png is not a document")
        expect(!TypePreset.images.matches(nil), "nil content type never matches")
    }

    await test("DatePreset ranges are anchored to injected now") {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 7, hour: 15))!

        let today = DatePreset.today.range(now: now, calendar: calendar)
        expect(today.contains(now), "today contains now")
        expect(!today.contains(calendar.date(byAdding: .day, value: -1, to: now)!),
               "today excludes yesterday")

        let week = DatePreset.last7Days.range(now: now, calendar: calendar)
        expect(week.contains(calendar.date(byAdding: .day, value: -6, to: now)!),
               "last 7 days contains 6 days ago")
        expect(!week.contains(calendar.date(byAdding: .day, value: -8, to: now)!),
               "last 7 days excludes 8 days ago")

        let year = DatePreset.thisYear.range(now: now, calendar: calendar)
        expect(year.contains(calendar.date(from: DateComponents(year: 2026, month: 1, day: 2))!),
               "this year contains January 2nd")
        expect(!year.contains(calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!),
               "this year excludes last December")
    }

    await test("SizePreset ranges partition sensibly") {
        expect(SizePreset.under1MB.range.contains(500_000), "500 KB is under 1 MB")
        expect(!SizePreset.under1MB.range.contains(2_000_000), "2 MB is not under 1 MB")
        expect(SizePreset.oneTo100MB.range.contains(50 * 1_048_576), "50 MB is in 1–100 MB")
        expect(SizePreset.over100MB.range.contains(Int64(1) << 40), "1 TB is over 100 MB")
        expect(!SizePreset.over100MB.range.contains(1_048_576), "1 MB is not over 100 MB")
    }
}
