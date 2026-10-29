import Foundation
import Darwin

struct Checks {
    var failures = 0
    var count = 0
    mutating func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !value() { failures += 1; print("FAIL: \(message)") }
    }
}

func fixtureEntry(_ path: String, _ size: Int64, directory: Bool = false, tags: [String] = []) -> DiskEntry {
    DiskEntry(path: path, name: (path as NSString).lastPathComponent, directory: directory, symlink: false,
              bytes: size, logical: size, modified: 0, category: "Other", tags: tags)
}
func candidateSource(_ paths: [String]) -> SpotlightCandidateSource {
    { consume in
        for path in paths { if !consume(path) { break } }
        return SpotlightEnumerationReport()
    }
}

@main
struct SafetySearchTests {
    static func main() throws {
        var checks = Checks()
        // A UUID-named fixture is the only directory created or removed by these tests.
        // Nothing is sent to Trash, and no existing user file is changed.
        let home = NSHomeDirectory()
        let fixture = home + "/.diskscope-native-fixture-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: fixture) }
        try FileManager.default.createSymbolicLink(atPath: fixture + "/home-alias", withDestinationPath: home)
        try FileManager.default.createSymbolicLink(atPath: fixture + "/root-alias", withDestinationPath: "/")
        try FileManager.default.createSymbolicLink(atPath: fixture + "/library-alias", withDestinationPath: "/Library")

        checks.expect(!safeToTrash(fixture + "/home-alias/Documents"), "a parent alias cannot expose the protected Documents root")
        checks.expect(!safeToTrash(fixture + "/home-alias/Downloads"), "a parent alias cannot expose the protected Downloads root")
        checks.expect(!safeToTrash(home + "/dOcUmEnTs"), "case aliases of an existing protected root remain protected")
        checks.expect(!safeToTrash(fixture + "/root-alias/Users"), "joining a resolved root parent cannot bypass the Users guard")
        checks.expect(!safeToTrash(fixture + "/root-alias/Applications"), "joining a resolved root parent cannot bypass the Applications guard")
        checks.expect(!safeToTrash(fixture + "/library-alias/LaunchDaemons/helper.plist"), "a parent alias cannot permit system helper deletion")
        checks.expect(safeToTrash(fixture + "/home-alias"), "deleting the symlink itself does not follow its protected target")
        checks.expect(safeToTrash(fixture + "/root-alias"), "a leaf symlink to root can itself be removed")
        checks.expect(safeToTrash(home + "/Downloads/fixture.bin"), "an ordinary Downloads child remains removable")
        checks.expect(!safeToTrash("/Library/LaunchDaemons/fixture.plist"), "system helper paths remain outside allowed removal roots")
        checks.expect(!safeToTrash(Bundle.main.bundlePath + "/Contents/MacOS/fixture"), "the running bundle's descendants are protected")
        checks.expect(!safeToTrash(URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().path), "a directory containing the running bundle is protected")

        let app = fixture + "/Applications/Example.app"
        try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture + "/apps-alias", withDestinationPath: fixture + "/Applications")
        try FileManager.default.createSymbolicLink(atPath: fixture + "/app-link", withDestinationPath: app)
        checks.expect(runningAppConflict(paths: [app], running: [app]), "a running app cannot be removed")
        checks.expect(runningAppConflict(paths: [fixture + "/Applications"], running: [app]), "a running app's ancestor cannot be removed")
        checks.expect(runningAppConflict(paths: [app + "/Contents/MacOS/Example"], running: [app]), "a running app's executable cannot be removed")
        checks.expect(runningAppConflict(paths: [fixture + "/apps-alias/Example.app/Contents"], running: [app]), "running-app protection resolves parent aliases")
        checks.expect(!runningAppConflict(paths: [fixture + "/app-link"], running: [app]), "removing a separate leaf symlink does not remove its running target")
        checks.expect(!runningAppConflict(paths: [app + ".backup"], running: [app]), "similarly prefixed sibling names do not conflict")

        let irrelevant = (0..<500).map { fixtureEntry("/fixture/match-\($0).txt", 1) }
        let late = fixtureEntry("/fixture/match-model.gguf", 50, tags: ["AI Models"])
        let all = irrelevant + [late]
        let entries = Dictionary(uniqueKeysWithValues: all.map { ($0.path, $0) })
        let filtered = searchSpotlightCandidates(query: "match", filters: ["AI Models"], type: "", large: false,
            source: candidateSource(all.map(\.path)), entryForPath: { entries[$0] })
        let filteredRows = filtered["rows"] as? [[String:Any]] ?? []
        checks.expect(filteredRows.first?["path"] as? String == "/fixture/match-model.gguf", "a filtered match after candidate 500 is retained")
        checks.expect(filtered["total"] as? Int == 1, "total counts all filtered matches examined")

        let rankedEntries = [fixtureEntry("/fixture/match-directory", 9000, directory: true), fixtureEntry("/fixture/match-small.bin", 2), fixtureEntry("/fixture/match-large.bin", 200), fixtureEntry("/fixture/match-medium.bin", 20)]
        let byRankedPath = Dictionary(uniqueKeysWithValues: rankedEntries.map { ($0.path, $0) })
        let ranked = searchSpotlightCandidates(query: "match", filters: [], type: "", large: true, limit: 2,
            source: candidateSource(rankedEntries.map(\.path)), entryForPath: { byRankedPath[$0] })
        let rankedRows = ranked["rows"] as? [[String:Any]] ?? []
        checks.expect(rankedRows.compactMap { $0["path"] as? String } == ["/fixture/match-large.bin", "/fixture/match-medium.bin"], "large results exclude directories and rank before the result limit")
        checks.expect(ranked["total"] as? Int == 3, "the result limit does not undercount matches")
        checks.expect(ranked["truncated"] as? Bool == true, "a display limit explicitly reports truncation")

        let capped = searchSpotlightCandidates(query: "match", filters: [], type: "", large: false, candidateLimit: 2,
            source: candidateSource(rankedEntries.map(\.path)), entryForPath: { byRankedPath[$0] })
        checks.expect(capped["examined"] as? Int == 2, "a source candidate cap bounds examination")
        checks.expect(capped["incomplete"] as? Bool == true, "a candidate cap marks the total as incomplete")
        checks.expect((capped["reasons"] as? [String] ?? []).contains("candidateLimit"), "a candidate cap explains its limitation")

        var clockCalls = 0
        let timed = searchSpotlightCandidates(query: "match", filters: [], type: "", large: false, timeLimit: 1,
            source: candidateSource(rankedEntries.map(\.path)), entryForPath: { byRankedPath[$0] },
            now: { clockCalls += 1; return clockCalls <= 2 ? 0 : 2 })
        checks.expect(timed["examined"] as? Int == 1, "a time budget stops candidate examination")
        checks.expect((timed["reasons"] as? [String] ?? []).contains("timeLimit"), "a time budget explains its limitation")

        let emptyLarge = searchSpotlightCandidates(query: "", filters: [], type: "", large: true,
            source: candidateSource(rankedEntries.map(\.path)), entryForPath: { byRankedPath[$0] })
        checks.expect(emptyLarge["total"] as? Int == 3, "an empty large-file query still searches indexed candidates")
        checks.expect(spotlightExpression(query: "a\\b\"c*d?e", large: false) == #"kMDItemFSName == "*a\\b\"c\*d\?e*"cd"#, "query syntax characters remain literal in a filename search")
        checks.expect(spotlightExpression(query: "", large: true)?.contains("kMDItemFSSize > 0") == true, "empty large-file search requests indexed file sizes")
        checks.expect(spotlightExpression(query: "bad\0query", large: false) == nil, "NUL cannot reach a process argument")
        checks.expect(spotlightExpression(query: "bad\nquery", large: false) == nil, "control characters cannot alter the index expression")

        let noNameMatch = searchSpotlightCandidates(query: "absent", filters: [], type: "", large: false,
            source: candidateSource(rankedEntries.map(\.path)), entryForPath: { byRankedPath[$0] })
        checks.expect(noNameMatch["total"] as? Int == 0, "the pipeline independently validates filename matches")
        let noTypeMatch = searchSpotlightCandidates(query: "match", filters: [], type: "Image", large: false,
            source: candidateSource(rankedEntries.map(\.path)), entryForPath: { byRankedPath[$0] })
        checks.expect(noTypeMatch["total"] as? Int == 0, "file category filtering happens before counting")
        let unavailable = searchSpotlightCandidates(query: "", filters: [], type: "", large: false,
            source: { _ in SpotlightEnumerationReport(limited: true, warnings: ["Index unavailable"], reasons: ["sourceError"]) })
        checks.expect(unavailable["incomplete"] as? Bool == true, "an unavailable index is not an exact empty result")
        checks.expect((unavailable["warnings"] as? [String] ?? []).contains("Index unavailable"), "index failures retain their warning")
        let unreadable = searchSpotlightCandidates(query: "", filters: [], type: "", large: false,
            source: candidateSource(["/fixture/missing"]), entryForPath: { _ in nil })
        checks.expect(unreadable["skipped"] as? Int == 1 && unreadable["totalIsExact"] as? Bool == false, "unreadable indexed paths remain explicit")

        let many = (0..<1002).map { fixtureEntry(String(format: "/fixture/match-%04d", $0), Int64(($0 * 397) % 1002)) }
        let byManyPath = Dictionary(uniqueKeysWithValues: many.map { ($0.path, $0) })
        let top = searchSpotlightCandidates(query: "match", filters: [], type: "", large: true, limit: 3,
            source: candidateSource(many.map(\.path)), entryForPath: { byManyPath[$0] })
        checks.expect((top["rows"] as? [[String:Any]] ?? []).compactMap { $0["size"] as? Int64 } == [1001, 1000, 999], "bounded ranking retains the largest results across a long unordered stream")
        checks.expect(top["total"] as? Int == 1002 && top["incomplete"] as? Bool == false, "all filtered stream matches contribute to an exact total")

        print("Safety/search checks: \(checks.count - checks.failures)/\(checks.count) passed")
        if checks.failures > 0 { exit(1) }
    }
}
