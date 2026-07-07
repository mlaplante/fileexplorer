import Foundation
import FileExplorerCore

@MainActor
func fuzzyMatcherTests() async {
    await test("FuzzyMatcher matches subsequences case-insensitively") {
        expect(FuzzyMatcher.score(query: "doc", candidate: "Documents") != nil,
               "doc matches Documents")
        expect(FuzzyMatcher.score(query: "DOC", candidate: "documents") != nil,
               "match is case-insensitive")
        expect(FuzzyMatcher.score(query: "dcm", candidate: "Documents") != nil,
               "scattered subsequence matches")
        expect(FuzzyMatcher.score(query: "xyz", candidate: "Documents") == nil,
               "non-subsequence does not match")
        expect(FuzzyMatcher.score(query: "documentsx", candidate: "Documents") == nil,
               "query longer than matchable is nil")
        expectEqual(FuzzyMatcher.score(query: "", candidate: "anything"), 0,
                    "empty query scores zero (matches)")
    }

    await test("FuzzyMatcher prefers prefixes, word starts, and runs") {
        func s(_ q: String, _ c: String) -> Int { FuzzyMatcher.score(query: q, candidate: c)! }
        expect(s("doc", "Documents") > s("doc", "MyDocs"),
               "prefix run beats camelCase interior run")
        expect(s("doc", "MyDocs") > s("doc", "mydocs"),
               "camelCase boundary beats plain interior")
        expect(s("dow", "Downloads") > s("dow", "dawn-owl-wig"),
               "consecutive run beats scattered boundary hits")
    }

    await test("FuzzyMatcher.rank orders and filters") {
        let names = ["MyDocs", "Documents", "downloads", "notes.txt"]
        let ranked = FuzzyMatcher.rank(names, query: "doc") { $0 }
        expectEqual(ranked.first, "Documents", "best match first")
        expect(!ranked.contains("notes.txt") && !ranked.contains("downloads"),
               "non-matches dropped")
        expectEqual(FuzzyMatcher.rank(names, query: "") { $0 }, names,
                    "empty query returns original order")
        let tied = FuzzyMatcher.rank(["b-doc", "a-doc"], query: "doc") { $0 }
        expectEqual(tied, ["b-doc", "a-doc"], "ties keep source order")
    }
}
