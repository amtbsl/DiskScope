import Foundation

@main
struct AppServiceTests {
    static var failures = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { failures += 1; print("FAIL: \(message)") }
    }
    static func writePlist(_ value: [String:Any], _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
    }
    static func file(_ path: String, bytes: Int = 8192) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: URL(fileURLWithPath: path))
    }
    static func contains(_ rows: [[String:Any]], _ path: String) -> Bool { rows.contains { $0["path"] as? String == path } }
    static func main() throws {
        if CommandLine.arguments.contains("--live") {
            let started = Date()
            let report = orphanReport()
            let summary: [String:Any] = ["elapsed":Date().timeIntervalSince(started), "candidateCount":(report["rows"] as? [[String:Any]])?.count ?? 0, "limited":report["limited"] ?? true, "warnings":report["warnings"] ?? [], "power":Monitor().sample()["power"] ?? [:]]
            print(String(data:try JSONSerialization.data(withJSONObject:summary, options:[.prettyPrinted,.sortedKeys]), encoding:.utf8)!)
            return
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("DiskScopeServices-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: fixture) }
        let home = fixture + "/home", library = fixture + "/Library", appPath = fixture + "/Applications/Orbit.app"
        try writePlist(["CFBundleIdentifier":"com.example.orbit", "CFBundleName":"Orbit", "CFBundlePackageType":"APPL", "SMPrivilegedExecutables":["com.example.orbit.helper":"identifier com.example.orbit.helper"]], appPath + "/Contents/Info.plist")
        let app = InstalledApp(path: appPath, name: "Orbit", bundleID: "com.example.orbit", version: "1")
        let peer = InstalledApp(path: fixture + "/Applications/Studio.app", name: "Studio", bundleID: "com.example.studio", version: "1")
        let ownedExecutable = appPath + "/Contents/Library/LoginItems/OrbitAgent.app/Contents/MacOS/OrbitAgent"
        try file(ownedExecutable)
        let ownedAgent = home + "/Library/LaunchAgents/unrelated.label.plist"
        try writePlist(["Label":"unrelated.label", "ProgramArguments":[ownedExecutable,"--background"]], ownedAgent)
        let misleadingAgent = home + "/Library/LaunchAgents/com.example.orbit.plist"
        try writePlist(["Label":"com.example.orbit", "Program":"/usr/bin/true"], misleadingAgent)
        let siblingAgent = home + "/Library/LaunchAgents/vendor-match.plist"
        try writePlist(["Label":"com.example.orbit.extra", "ProgramArguments":[appPath + "-Other/Contents/MacOS/Agent"]], siblingAgent)
        let systemCache = library + "/Caches/com.example.orbit"
        try file(systemCache + "/data")
        let vendor = home + "/Library/Application Support/Example Vendor"
        try file(vendor + "/data")
        let group = home + "/Library/Group Containers/group.example.shared"
        try file(group + "/data")
        let privileged = library + "/PrivilegedHelperTools/com.example.orbit.helper"
        try file(privileged)
        let daemon = library + "/LaunchDaemons/com.example.orbit.helper.plist"
        try writePlist(["Label":"com.example.orbit.helper", "ProgramArguments":[privileged]], daemon)
        var env = AppServiceEnvironment()
        env.home = home; env.systemLibrary = library; env.suppliedApps = [app, peer]
        env.indexedApplications = { ApplicationIndex(paths: [], warning: nil) }
        env.groupsForApp = { _ in ["group.example.shared"] }
        env.helperRequirementValid = { path, requirement in path == privileged && requirement == "identifier com.example.orbit.helper" }
        let service = AppServices(environment: env)
        let related = service.related(app)
        expect(contains(related, ownedAgent), "helper ownership follows exact ProgramArguments executable under selected app")
        expect(!contains(related, misleadingAgent), "helper label and exact plist name alone do not prove app ownership")
        expect(!contains(related, siblingAgent), "app path prefix without path separator cannot prove ownership")
        expect(contains(related, systemCache), "exact bundle cache is discovered in system Library")
        expect(!contains(related, vendor), "shared vendor folder is not associated by vendor substring")
        let genericPath = fixture + "/Applications/Generic.app"
        try writePlist(["CFBundleIdentifier":"com.example.generic", "CFBundleName":"Example Vendor", "CFBundlePackageType":"APPL"], genericPath + "/Contents/Info.plist")
        // This peer exists outside both supplied applications and the Spotlight fixture.
        let unindexedPeer = fixture + "/Offline/Unindexed Peer.app"
        try writePlist(["CFBundleIdentifier":"com.example.unindexed", "CFBundleName":"Example Vendor", "CFBundlePackageType":"APPL"], unindexedPeer + "/Contents/Info.plist")
        var genericEnv = env
        genericEnv.suppliedApps = [InstalledApp(path:genericPath, name:"Generic", bundleID:"com.example.generic", version:"1")]
        let genericRows = AppServices(environment:genericEnv).related(genericEnv.suppliedApps![0])
        let genericVendor = genericRows.first { $0["path"] as? String == vendor }
        expect(genericVendor != nil, "exact CFBundleName association remains available for explicit review")
        expect(genericVendor?["shared"] as? Bool == true, "name-only vendor folder defaults unchecked even when its peer is unindexed")
        expect(related.filter { $0["path"] as? String == systemCache }.first?["shared"] as? Bool == true, "system Library entries default unchecked")
        expect(related.filter { $0["path"] as? String == ownedAgent }.first?["shared"] as? Bool == true, "launch helpers default unchecked")
        let groupRow = related.first { $0["path"] as? String == group }
        expect(groupRow?["shared"] as? Bool == true, "shared group defaults unchecked")
        expect((groupRow?["owners"] as? [String])?.contains("Studio") == true, "group ownership accounts for other installed apps")
        expect(contains(related, privileged) && contains(related, daemon), "declared and signature-validated privileged helper metadata is discoverable")
        expect(!AppServices.helperRequirementValid("/usr/bin/true", "anchor apple"), "generic signer requirement cannot associate a differently identified system executable")
        var rejectedEnv = env; rejectedEnv.helperRequirementValid = { _, _ in false }
        expect(!contains(AppServices(environment: rejectedEnv).related(app), privileged), "helper declaration without valid executable requirement is excluded")

        let stalePlain = home + "/Library/Application Support/Old Orbit"
        try writePlist(["CFBundleIdentifier":"com.old.orbit", "CFBundleName":"Old Orbit", "CFBundlePackageType":"APPL"], stalePlain + "/Info.plist")
        try file(stalePlain + "/payload", bytes: 24576)
        let cli = home + "/Library/Caches/org.example.command"
        try file(cli + "/data")
        let cliAgent = home + "/Library/LaunchAgents/org.example.command.plist"
        let cliExecutable = fixture + "/bin/command"
        try file(cliExecutable)
        try writePlist(["Label":"org.example.command", "Program":cliExecutable], cliAgent)
        let unknown = home + "/Library/Caches/com.unknown.product"
        try file(unknown + "/data")
        let generic = home + "/Library/Application Support/Definitely Deleted"
        try file(generic + "/data")
        let indexedPeerPath = fixture + "/Portable/Studio.app"
        try writePlist(["CFBundleIdentifier":"com.example.portable", "CFBundleName":"Portable Studio", "CFBundlePackageType":"APPL"], indexedPeerPath + "/Contents/Info.plist")
        var portableEnv = env; portableEnv.suppliedApps = [app]
        portableEnv.indexedApplications = { ApplicationIndex(paths: [indexedPeerPath], warning: nil) }
        let portableGroup = AppServices(environment: portableEnv).related(app).first { $0["path"] as? String == group }
        expect((portableGroup?["owners"] as? [String])?.contains("Portable Studio") == true, "group ownership includes indexed applications outside standard folders")
        let escapedAgent = home + "/Library/LaunchAgents/escaped.plist"
        let externalProgram = fixture + "/External/program"
        try file(externalProgram)
        let link = appPath + "/Contents/MacOS/escaped"
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: externalProgram)
        try writePlist(["ProgramArguments":[link]], escapedAgent)
        expect(!contains(service.related(app), escapedAgent), "helper executable symlink escaping the app does not prove ownership")
        let live = home + "/Library/Preferences/com.example.orbit.plist"
        try writePlist(["setting":true], live)
        let report = service.orphanReport()
        let rows = report["rows"] as? [[String:Any]] ?? []
        expect(contains(rows, stalePlain), "plain app-name folder needs verifiable application metadata")
        expect(!contains(rows, generic), "plain directory names alone never imply a removed app")
        expect(!contains(rows, cli), "live launch-service executable evidence excludes known CLI ownership")
        expect(!contains(rows, live), "installed app preferences are excluded from leftover candidates")
        let uncertain = rows.first { $0["path"] as? String == unknown }
        expect(uncertain?["confidence"] as? String == "low", "bare reverse-DNS evidence remains explicitly uncertain")
        expect(uncertain?["shared"] as? Bool == true, "uncertain leftovers default unchecked")
        expect(rows.first?["path"] as? String == stalePlain, "all bounded candidates are sorted by size before result limit")
        let short = service.orphanReport(limit: 1)
        expect(short["limited"] as? Bool == true, "result truncation is exposed")
        expect((short["warnings"] as? [String])?.isEmpty == false, "partial and index limitations are explained")
        var unindexed = env
        unindexed.indexedApplications = { ApplicationIndex(paths: [], warning: "Spotlight index unavailable") }
        let missing = AppServices(environment: unindexed).orphanReport()
        expect((missing["warnings"] as? [String])?.contains(where: { $0.contains("Spotlight index unavailable") }) == true, "index failure is preserved in report")
        expect(missing["limited"] as? Bool == true, "index uncertainty prevents complete claim")

        let nominal = batteryMetadata(["CycleCount":253, "DesignCapacity":6249, "NominalChargeCapacity":5664, "AppleRawMaxCapacity":5512, "MaxCapacity":100])
        expect(nominal["cycleCount"] as? Int == 253, "battery cycle count uses actual registry count")
        expect(abs((nominal["health"] as? Double ?? 0) - 90.63850216034565) < 0.001, "health prefers stable nominal mAh capacity over normalized percent")
        expect(batteryMetadata(["DesignCapacity":5000,"AppleRawMaxCapacity":4500])["health"] as? Double == 90, "raw mAh fallback works")
        expect(batteryMetadata(["DesignCapacity":5000,"MaxCapacity":4000])["health"] as? Double == 80, "older mAh MaxCapacity fallback works")
        expect(batteryMetadata(["DesignCapacity":5000,"MaxCapacity":100])["health"] is NSNull, "normalized percentage is never misread as battery mAh")
        expect(batteryMetadata(["DesignCapacity":5000,"NominalChargeCapacity":5500])["health"] as? Double == 100, "health is clamped to 100")
        expect(batteryMetadata([:])["cycleCount"] is NSNull && batteryMetadata([:])["health"] is NSNull, "missing battery fields stay nullable")
        expect(batteryMetadata(["CycleCount":-1,"DesignCapacity":0,"NominalChargeCapacity":4500])["cycleCount"] is NSNull, "invalid cycle count never becomes fake zero")
        // More than the old 300-row early return: the largest final candidate must survive.
        let manyHome = fixture + "/many-home"
        for i in 0..<305 { try file(manyHome + "/Library/Caches/com.fixture.item" + String(format:"%03d", i) + "/data") }
        let largestLate = manyHome + "/Library/Caches/com.fixture.zz-largest"
        try file(largestLate + "/data", bytes:131072)
        var manyEnv = env; manyEnv.home = manyHome
        let manyReport = AppServices(environment: manyEnv).orphanReport()
        let manyRows = manyReport["rows"] as? [[String:Any]] ?? []
        expect(manyRows.count == 300 && manyRows.first?["path"] as? String == largestLate, "candidate 306 is ranked before applying the 300-result cap")
        expect(manyReport["limited"] as? Bool == true, "300-result cap is reported as partial")
        manyEnv.entryLimit = 3
        let budgetReport = AppServices(environment: manyEnv).orphanReport()
        expect(budgetReport["limited"] as? Bool == true && (budgetReport["warnings"] as? [String])?.contains(where: { $0.contains("budget") }) == true, "entry budget exhaustion is explicit")
        var tinyMeasureEnv = manyEnv; tinyMeasureEnv.entryLimit = 2000; tinyMeasureEnv.totalScanNodeLimit = 2
        let tinyMeasurement = AppServices(environment: tinyMeasureEnv).orphanReport()
        expect(tinyMeasurement["limited"] as? Bool == true && (tinyMeasurement["warnings"] as? [String])?.contains(where: { $0.contains("measurement") }) == true, "aggregate measurement budget exhaustion is explicit")
        var noTimeEnv = env; noTimeEnv.operationTimeout = 0
        let noTime = AppServices(environment: noTimeEnv).orphanReport()
        expect(noTime["limited"] as? Bool == true && (noTime["warnings"] as? [String])?.contains(where: { $0.contains("time") }) == true, "aggregate wall-time budget prevents complete claim")
        var shortRelatedEnv = env; shortRelatedEnv.entryLimit = 1
        let shortRelated = AppServices(environment: shortRelatedEnv).related(app)
        expect(shortRelated.first?["discoveryLimited"] as? Bool == true && (shortRelated.first?["warnings"] as? [String])?.isEmpty == false, "related discovery truncation is surfaced")
        var groupsRead: [String:Int] = [:]
        var cachedEnv = env
        cachedEnv.groupsForApp = { target in groupsRead[target.path, default:0] += 1; return ["group.example.shared"] }
        _ = AppServices(environment: cachedEnv).related(app)
        expect(groupsRead.values.allSatisfy { $0 == 1 }, "entitlement ownership is read once per app in a request")
        let monitor = Monitor()
        let power = monitor.sample()["power"] as? [String:Any] ?? [:]
        expect(power["cycleCount"] != nil && power["health"] != nil, "real monitor includes nullable registry battery fields")
        var monitorSamples = 0
        let sampleLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 3) { _ in
            let value = monitor.sample()
            sampleLock.lock(); if value["power"] is [String:Any] { monitorSamples += 1 }; sampleLock.unlock()
        }
        expect(monitorSamples == 3, "monitor can be sampled from concurrent queues")
        print("Real battery: \(power)")
        if failures > 0 { exit(1) }
        print("PASS: app services ownership, leftovers, battery, concurrency")
    }
}
