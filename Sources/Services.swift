import Foundation
import AppKit
import Darwin
import IOKit
import IOKit.ps
import Security

func diskStatus() -> [String: Any] {
    let attrs = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())) ?? [:]
    let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
    let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    let trash = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash"))?.filter { $0 != ".DS_Store" }.count
    return ["total": total, "free": free, "used": max(0, total-free), "trashCount": trash as Any? ?? NSNull(), "home": NSHomeDirectory()]
}
final class Monitor {
    private let sampleLock = NSLock()
    private var previousCPU: [UInt64] = [], previousNetwork: (UInt64, UInt64) = (0,0), lastTime = Date().timeIntervalSince1970
    func sample() -> [String: Any] {
        sampleLock.lock(); defer { sampleLock.unlock() }
        var cpu = host_cpu_load_info(), count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        let ticks = [UInt64(cpu.cpu_ticks.0), UInt64(cpu.cpu_ticks.1), UInt64(cpu.cpu_ticks.2), UInt64(cpu.cpu_ticks.3)]
        var user = 0.0, system = 0.0
        if cpuResult == KERN_SUCCESS && previousCPU.count == 4 {
            let d = zip(ticks, previousCPU).map { Double($0.0 &- $0.1) }, total = d.reduce(0,+)
            if total > 0 { user = (d[0] + d[3])/total*100; system = d[1]/total*100 }
        }
        previousCPU = ticks
        var vm = vm_statistics64(), vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) } }
        let page = UInt64(vm_kernel_page_size), totalMemory = ProcessInfo.processInfo.physicalMemory
        let free = UInt64(vm.free_count + vm.speculative_count) * page
        let cached = UInt64(vm.inactive_count) * page
        let wired = UInt64(vm.wire_count) * page, compressed = UInt64(vm.compressor_page_count) * page
        let used = totalMemory > free + cached ? totalMemory - free - cached : 0
        var download: UInt64 = 0, upload: UInt64 = 0, interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0 {
            var current = interfaces
            while let p = current {
                if let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), String(cString: p.pointee.ifa_name).hasPrefix("en"), let data = p.pointee.ifa_data {
                    let info = data.assumingMemoryBound(to: if_data.self).pointee
                    download += UInt64(info.ifi_ibytes); upload += UInt64(info.ifi_obytes)
                }
                current = p.pointee.ifa_next
            }
            freeifaddrs(interfaces)
        }
        let now = Date().timeIntervalSince1970, delta = max(0.1, now-lastTime)
        let downRate = previousNetwork.0 > 0 && download >= previousNetwork.0 ? Double(download-previousNetwork.0)/delta : 0
        let upRate = previousNetwork.1 > 0 && upload >= previousNetwork.1 ? Double(upload-previousNetwork.1)/delta : 0
        previousNetwork = (download,upload); lastTime = now
        var power: [String:Any] = ["source":"Unknown", "percent": NSNull(), "charging":NSNull()]
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                if let details = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String:Any] {
                    let current = details[kIOPSCurrentCapacityKey] as? Double, maximum = details[kIOPSMaxCapacityKey] as? Double
                    let percent: Any = (current != nil && maximum != nil && maximum! > 0) ? min(100, max(0, current!/maximum!*100)) as Any : NSNull()
                    power = ["source": details[kIOPSPowerSourceStateKey] as? String ?? "Unknown", "percent": percent, "charging": details[kIOPSIsChargingKey] as Any? ?? NSNull()]
                }
            }
        }
        power.merge(batteryMetadata(smartBatteryProperties())) { _, registry in registry }
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let processes = run("/bin/ps", ["-axo","pid=,pcpu=,rss=,comm="], timeout: 3).split(separator:"\n").compactMap { line -> [String:Any]? in
            let parts = line.split(maxSplits:3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 4, let pid = Int(parts[0]), let cpu = Double(parts[1]), let rss = Int64(parts[2]) else { return nil }
            return ["pid":pid,"cpu":cpu,"memory":rss*1024,"name":(String(parts[3]) as NSString).lastPathComponent]
        }.sorted { ($0["cpu"] as! Double) > ($1["cpu"] as! Double) }
        var chipBuffer = [CChar](repeating:0,count:256), chipSize = 256
        _ = sysctlbyname("machdep.cpu.brand_string", &chipBuffer, &chipSize, nil,0)
        return ["cpu":user+system,"user":user,"system":system,"memory":used,"totalMemory":totalMemory,"free":free,"cached":cached,"wired":wired,"compressed":compressed,"swap":swap.xsu_used,"download":downRate,"upload":upRate,"power":power,"processes":Array(processes.prefix(20)),"chip":String(cString:chipBuffer),"cores":ProcessInfo.processInfo.processorCount]
    }
}

/// Registry fields are optional on desktops, external power sources and restricted systems.
func batteryMetadata(_ properties: [String:Any]) -> [String:Any] {
    func number(_ key: String) -> Double? {
        guard let value = properties[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let result = value.doubleValue
        return result.isFinite ? result : nil
    }
    var result: [String:Any] = ["cycleCount":NSNull(), "health":NSNull()]
    if let cycles = number("CycleCount"), cycles >= 0, cycles < Double(Int.max), cycles.rounded(.towardZero) == cycles { result["cycleCount"] = Int(cycles) }
    if let design = number("DesignCapacity"), design > 100 {
        // Apple Silicon MaxCapacity is commonly normalized to 100. NominalChargeCapacity
        // is the stable mAh health measurement; older batteries expose mAh MaxCapacity.
        for key in ["NominalChargeCapacity", "AppleRawMaxCapacity", "MaxCapacity"] {
            if let maximum = number(key), maximum > 100 {
                result["health"] = min(100, max(0, maximum/design*100)); break
            }
        }
    }
    return result
}
private func smartBatteryProperties() -> [String:Any] {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != IO_OBJECT_NULL else { return [:] }
    defer { IOObjectRelease(service) }
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dictionary = properties?.takeRetainedValue() as? [String:Any] else { return [:] }
    return dictionary
}

struct InstalledApp {
    let path: String, name: String, bundleID: String, version: String
    func json() -> [String:Any] { ["path":path,"name":name,"bundleID":bundleID,"version":version] }
}
struct ApplicationIndex { var paths: [String]; var warning: String? }
struct AppServiceEnvironment {
    var home = NSHomeDirectory()
    var systemLibrary = "/Library"
    var applicationRoots: [String]? = nil
    var suppliedApps: [InstalledApp]? = nil
    var entryLimit = 12_000
    var scanNodeLimit = 50_000
    var totalScanNodeLimit = 250_000
    var operationTimeout: TimeInterval = 15
    var indexedApplications: () -> ApplicationIndex = AppServices.applicationIndex
    var groupsForApp: (InstalledApp) -> [String] = AppServices.applicationGroups
    var helperRequirementValid: (String, String) -> Bool = AppServices.helperRequirementValid
}

private final class ServiceBudget {
    let deadline: Date
    var remainingNodes: Int
    var measurementLimited = false
    var timeLimited = false
    init(_ environment: AppServiceEnvironment) {
        deadline = Date().addingTimeInterval(max(0, environment.operationTimeout))
        remainingNodes = max(0, environment.totalScanNodeLimit)
    }
    func hasTime() -> Bool {
        if Date() >= deadline { timeLimited = true; return false }
        return true
    }
    func measure(_ path: String, perItemLimit: Int) -> ScanResult {
        guard hasTime(), remainingNodes > 0 else {
            measurementLimited = true
            return ScanResult(nodes:[], skipped:0, limited:true)
        }
        let control = ScanControl()
        let cancellation = DispatchWorkItem { control.cancel() }
        DispatchQueue.global().asyncAfter(deadline:.now() + max(0, deadline.timeIntervalSinceNow), execute:cancellation)
        let scan = Scanner(control:control, limit:min(max(1, perItemLimit), remainingNodes)).scan(path)
        cancellation.cancel()
        remainingNodes -= scan.nodes.count
        if scan.limited || control.stopped() { measurementLimited = true }
        if control.stopped() { timeLimited = true }
        return ScanResult(nodes:scan.nodes, skipped:scan.skipped, limited:scan.limited || control.stopped())
    }
    var warnings: [String] {
        var result: [String] = []
        if measurementLimited { result.append("Aggregate size measurement budget reached; some sizes and their ranking are partial.") }
        if timeLimited { result.append("Aggregate operation time budget reached; discovery and size measurements are partial.") }
        return result
    }
}

/// All directory and application dependencies can be replaced with fixture locations.
/// A related row is association evidence, never an authorization to remove a helper.
struct AppServices {
    let environment: AppServiceEnvironment
    init(environment: AppServiceEnvironment = AppServiceEnvironment()) { self.environment = environment }
    private let fm = FileManager.default
    private let dataFolders = ["Application Support", "Caches", "Preferences", "Logs", "Containers", "Application Scripts", "Saved Application State", "HTTPStorages", "WebKit"]
    private let sharedLeafNames = Set(["shared", "common", "helper", "helpers", "agent", "daemon", "updater", "update", "services"])

    static func applicationIndex() -> ApplicationIndex {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/mdfind")
        process.arguments = ["-0", "kMDItemContentType == 'com.apple.application-bundle'"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return ApplicationIndex(paths:[], warning:"Spotlight application index could not be queried; portable applications may be missing.") }
        let lock = NSLock(); var timedOut = false
        let timeout = DispatchWorkItem { lock.lock(); timedOut = true; lock.unlock(); if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline:.now()+10, execute:timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        lock.lock(); let expired = timedOut; lock.unlock()
        let paths = String(data:data, encoding:.utf8)?.split(separator:"\0").map(String.init) ?? []
        let warning = expired || process.terminationStatus != 0 ? "Spotlight application index was unavailable or timed out; portable applications may be missing." : (paths.isEmpty ? "Spotlight returned no indexed applications; indexing may be unavailable or incomplete." : nil)
        return ApplicationIndex(paths:paths, warning:warning)
    }
    static func applicationGroups(_ app: InstalledApp) -> [String] {
        let signature = run("/usr/bin/codesign", ["-d", "--entitlements", ":-", app.path], timeout:5)
        guard let start = signature.range(of:"<?xml"), let data = String(signature[start.lowerBound...]).data(using:.utf8),
              let entitlements = (try? PropertyListSerialization.propertyList(from:data, format:nil)) as? [String:Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
    static func helperRequirementValid(_ path: String, _ requirement: String) -> Bool {
        guard !requirement.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return false }
        var code: SecStaticCode?, rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath:path) as CFURL, [], &code) == errSecSuccess,
              let code = code,
              SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              let rule = rule else { return false }
        var signing: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue:kSecCSSigningInformation), &signing) == errSecSuccess,
              let signing = signing as? [String:Any],
              signing[kSecCodeInfoIdentifier as String] as? String == URL(fileURLWithPath:path).lastPathComponent else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue:kSecCSStrictValidate), rule) == errSecSuccess
    }
    private func plist(_ path: String) -> [String:Any]? {
        guard let size = (try? fm.attributesOfItem(atPath:path)[.size]) as? NSNumber, size.intValue <= 2_000_000,
              let data = fm.contents(atPath:path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from:data, format:nil)) as? [String:Any]
    }
    private func info(_ app: InstalledApp) -> [String:Any] { plist(app.path + "/Contents/Info.plist") ?? [:] }
    func apps() -> [InstalledApp] { discoverApps(nil) }
    private func discoverApps(_ budget: ServiceBudget?) -> [InstalledApp] {
        if let supplied = environment.suppliedApps { return supplied }
        var apps: [InstalledApp] = []
        for root in environment.applicationRoots ?? ["/Applications", environment.home + "/Applications"] {
            if budget?.hasTime() == false { break }
            guard let files = fm.enumerator(at:URL(fileURLWithPath:root), includingPropertiesForKeys:[.isDirectoryKey], options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { continue }
            while let url = files.nextObject() as? URL {
                if budget?.hasTime() == false { break }
                if url.pathExtension == "app", let bundle = Bundle(url:url) {
                    let displayName = (bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                    apps.append(InstalledApp(path:url.path, name:displayName.isEmpty ? url.deletingPathExtension().lastPathComponent : displayName, bundleID:bundle.bundleIdentifier ?? "", version:bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—"))
                    files.skipDescendants()
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private func names(_ app: InstalledApp) -> Set<String> {
        let metadata = info(app)
        return Set([app.name, URL(fileURLWithPath:app.path).deletingPathExtension().lastPathComponent, metadata["CFBundleName"] as? String ?? ""].filter { !$0.isEmpty && !$0.contains("/") })
    }
    private func row(_ path: String, kind: String, shared: Bool, evidence: String, owners: [String] = [], budget: ServiceBudget) -> [String:Any] {
        let scan = budget.measure(path, perItemLimit:environment.scanNodeLimit)
        return ["path":path, "name":URL(fileURLWithPath:path).lastPathComponent, "size":scan.nodes.first?.bytes ?? 0,
                "kind":kind, "shared":shared, "system":path.hasPrefix(environment.systemLibrary + "/"),
                "skipped":scan.skipped, "limited":scan.limited, "sizeKnown":!scan.nodes.isEmpty, "evidence":evidence, "owners":owners]
    }
    private func children(_ root: String) -> [String] { ((try? fm.contentsOfDirectory(atPath:root)) ?? []).sorted() }
    private func executable(_ launch: [String:Any]) -> String? {
        let path = launch["Program"] as? String ?? (launch["ProgramArguments"] as? [String])?.first
        guard let path = path, path.hasPrefix("/"), fm.fileExists(atPath:path) else { return nil }
        return URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL.path
    }
    private func within(_ path: String, _ root: String) -> Bool {
        let resolved = URL(fileURLWithPath:root).resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(resolved + "/")
    }
    func related(_ app: InstalledApp) -> [[String:Any]] {
        let budget = ServiceBudget(environment)
        var warnings: [String] = [], discoveryLimited = false
        var result = [row(app.path, kind:"Application", shared:false, evidence:"Selected application bundle", budget:budget)]
        var knownApps = discoverApps(budget)
        if budget.hasTime() {
            let indexed = environment.indexedApplications()
            if let warning = indexed.warning { warnings.append(warning); discoveryLimited = true }
            if indexed.paths.count > max(0, environment.entryLimit) { discoveryLimited = true; warnings.append("Related application index reached the entry budget; ownership list may be incomplete.") }
            for path in indexed.paths.prefix(max(0, environment.entryLimit)) where !knownApps.contains(where: { $0.path == path }) {
                guard budget.hasTime() else { break }
                if let bundle = Bundle(path:path) {
                    knownApps.append(InstalledApp(path:path, name:bundle.object(forInfoDictionaryKey:"CFBundleName") as? String ?? URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent, bundleID:bundle.bundleIdentifier ?? "", version:""))
                }
            }
        }
        let appNames = names(app), id = app.bundleID
        var appNamesByPath: [String:Set<String>] = [:]
        for target in knownApps {
            guard budget.hasTime() else { break }
            appNamesByPath[target.path] = names(target)
        }
        var seen = Set([app.path])
        func entries(_ root: String) -> [String] {
            guard budget.hasTime() else { return [] }
            do {
                let all = try fm.contentsOfDirectory(atPath:root).sorted()
                if all.count > max(0, environment.entryLimit) { discoveryLimited = true; warnings.append("Related discovery entry budget reached in " + root) }
                return Array(all.prefix(max(0, environment.entryLimit)))
            } catch {
                if fm.fileExists(atPath:root) { discoveryLimited = true; warnings.append("Related files could not be read in " + root + "; permissions may hide data.") }
                return []
            }
        }
        func append(_ path: String, _ kind: String, _ shared: Bool, _ evidence: String, _ owners: [String] = []) {
            if seen.insert(path).inserted { result.append(row(path, kind:kind, shared:shared, evidence:evidence, owners:owners, budget:budget)) }
        }
        for (base, system) in [(environment.home + "/Library", false), (environment.systemLibrary, true)] {
            for folder in dataFolders {
                let root = base + "/" + folder
                for name in entries(root) {
                    guard budget.hasTime() else { break }
                    let exactID = !id.isEmpty && [id, id + ".plist", id + ".savedState"].contains(name)
                    let exactName = appNames.contains(name)
                    guard exactID || exactName else { continue }
                    let owners = knownApps.filter { $0.path != app.path && ((!$0.bundleID.isEmpty && $0.bundleID == id) || appNamesByPath[$0.path]?.contains(name) == true) }.map(\.name)
                    append(root + "/" + name, folder, system || !exactID || !owners.isEmpty, exactID ? "Exact bundle identifier" : "Exact application name; review shared use", [app.name] + owners)
                }
            }
        }
        // A label/filename is not proof: resolve inside the bundle, or validate an
        // app-declared helper requirement. These rows always require explicit review.
        var validatedHelpers = Set<String>()
        if let helpers = info(app)["SMPrivilegedExecutables"] as? [String:String] {
            for (label, requirement) in helpers.sorted(by: { $0.key < $1.key }) where !label.isEmpty && !label.contains("/") && label != "." && label != ".." {
                guard budget.hasTime() else { break }
                let path = environment.systemLibrary + "/PrivilegedHelperTools/" + label
                if fm.fileExists(atPath:path), environment.helperRequirementValid(path, requirement) {
                    validatedHelpers.insert(URL(fileURLWithPath:path).resolvingSymlinksInPath().path)
                    append(path, "Privileged helper · review", true, "App-declared helper requirement validates executable")
                }
            }
        }
        for root in [environment.home + "/Library/LaunchAgents", environment.systemLibrary + "/LaunchAgents", environment.systemLibrary + "/LaunchDaemons"] {
            for name in entries(root) where name.hasSuffix(".plist") {
                guard budget.hasTime() else { break }
                let path = root + "/" + name
                guard let launch = plist(path), let program = executable(launch), within(program, app.path) || validatedHelpers.contains(program) else { continue }
                append(path, root.hasSuffix("LaunchDaemons") ? "LaunchDaemon · review" : "LaunchAgent · review", true, "Launch executable belongs to selected app or validated helper")
            }
        }
        var groupsByPath: [String:Set<String>] = [:]
        if budget.hasTime() { groupsByPath[app.path] = Set(environment.groupsForApp(app)) }
        let selectedGroups = groupsByPath[app.path] ?? []
        if !selectedGroups.isEmpty {
            for target in knownApps where groupsByPath[target.path] == nil {
                guard budget.hasTime() else { break }
                groupsByPath[target.path] = Set(environment.groupsForApp(target))
            }
        }
        for group in selectedGroups.sorted() where !group.isEmpty && !group.contains("/") && group != "." && group != ".." {
            let path = environment.home + "/Library/Group Containers/" + group
            guard fm.fileExists(atPath:path) else { continue }
            let owners = knownApps.filter { groupsByPath[$0.path]?.contains(group) == true }.map(\.name).sorted()
            append(path, "Shared Group · review other apps", true, "Application group declared in code signature; unindexed apps may also share it", owners)
        }
        _ = budget.hasTime()
        warnings += budget.warnings
        discoveryLimited = discoveryLimited || budget.timeLimited || budget.measurementLimited
        result[0]["discoveryLimited"] = discoveryLimited
        result[0]["warnings"] = Array(Set(warnings)).sorted()
        return result
    }
    private func embeddedIDs(_ app: InstalledApp, budget: ServiceBudget) -> Set<String> {
        var result = Set<String>()
        for location in ["PlugIns", "XPCServices", "Library/LoginItems", "Frameworks"] {
            guard budget.hasTime() else { break }
            let root = app.path + "/Contents/" + location
            for name in children(root).prefix(500) {
                guard budget.hasTime() else { break }
                let path = root + "/" + name
                for metadata in [path + "/Contents/Info.plist", path + "/Resources/Info.plist", path + "/Info.plist"] {
                    if let id = plist(metadata)?["CFBundleIdentifier"] as? String { result.insert(id); break }
                }
            }
        }
        return result
    }
    private func activeServiceIDs(_ budget: ServiceBudget) -> (Set<String>, [String]) {
        var ids = Set<String>(), warnings: [String] = []
        for root in [environment.home + "/Library/LaunchAgents", environment.systemLibrary + "/LaunchAgents", environment.systemLibrary + "/LaunchDaemons"] {
            guard budget.hasTime() else { break }
            let entries: [String]
            do { entries = try fm.contentsOfDirectory(atPath:root).sorted() }
            catch {
                if fm.fileExists(atPath:root) { warnings.append("Service ownership metadata could not be read in " + root) }
                continue
            }
            if entries.count > max(0, environment.entryLimit) { warnings.append("Service ownership metadata reached its entry budget in " + root) }
            for name in entries.prefix(max(0, environment.entryLimit)) where name.hasSuffix(".plist") {
                guard budget.hasTime() else { break }
                guard let launch = plist(root + "/" + name), executable(launch) != nil else { continue }
                if let id = launch["Label"] as? String { ids.insert(id) }
                ids.insert(String(name.dropLast(6)))
            }
        }
        return (ids, warnings)
    }
    private func metadataIdentity(_ path: String, _ name: String) -> (String, String)? {
        for metadata in [path + "/Info.plist", path + "/Contents/Info.plist"] {
            if let properties = plist(metadata), properties["CFBundlePackageType"] as? String == "APPL",
               let id = properties["CFBundleIdentifier"] as? String, !id.isEmpty,
               [properties["CFBundleName"] as? String, properties["CFBundleDisplayName"] as? String].contains(name) {
                return (id, "Application bundle metadata in " + metadata)
            }
        }
        if let id = plist(path + "/.com.apple.containermanagerd.metadata.plist")?["MCMMetadataIdentifier"] as? String, id == name {
            return (id, "Container manager bundle identifier metadata")
        }
        return nil
    }
    func orphanReport(limit: Int = 300) -> [String:Any] {
        let budget = ServiceBudget(environment)
        var knownApps = discoverApps(budget), warnings = ["Candidates require review. Missing app matches do not prove data is unused; CLI tools, helpers and shared services may still own it.", "Spotlight may omit unindexed, inaccessible, external or offline applications. Only readable user Library folders are inspected."]
        let indexed = budget.hasTime() ? environment.indexedApplications() : ApplicationIndex(paths:[], warning:"Application index skipped because the operation time budget expired.")
        var limited = indexed.warning != nil
        if let warning = indexed.warning { warnings.append(warning) }
        for path in indexed.paths.prefix(max(0, environment.entryLimit)) {
            guard budget.hasTime() else { break }
            if !knownApps.contains(where: { $0.path == path }), let bundle = Bundle(path:path) {
                knownApps.append(InstalledApp(path:path, name:(bundle.object(forInfoDictionaryKey:"CFBundleName") as? String) ?? URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent, bundleID:bundle.bundleIdentifier ?? "", version:""))
            }
        }
        if indexed.paths.count > environment.entryLimit { limited = true; warnings.append("Application index was truncated at \(environment.entryLimit) paths.") }
        var installed = Set(knownApps.map(\.bundleID).filter { !$0.isEmpty })
        var installedNames = Set<String>()
        for app in knownApps {
            guard budget.hasTime() else { break }
            installed.formUnion(embeddedIDs(app, budget:budget)); installedNames.formUnion(names(app))
        }
        // Group stores are excluded below; no per-application codesign subprocess is
        // needed to make conservative leftover suggestions.
        let services = activeServiceIDs(budget)
        installed.formUnion(services.0); warnings += services.1
        if !services.1.isEmpty { limited = true }
        var candidates: [(String,String,String,String,String)] = [], visited = 0, unreadable = 0, discoveryTruncated = false
        let folders = ["Caches", "Preferences", "Saved Application State", "Application Support", "Containers", "HTTPStorages", "WebKit", "Logs"]
        for kind in folders {
            guard budget.hasTime() else { break }
            let root = environment.home + "/Library/" + kind
            let entries: [String]
            do { entries = try fm.contentsOfDirectory(atPath:root).sorted() }
            catch { if fm.fileExists(atPath:root) { unreadable += 1 }; continue }
            for name in entries {
                guard budget.hasTime() else { break }
                if visited >= max(0, environment.entryLimit) { limited = true; discoveryTruncated = true; break }
                visited += 1
                let path = root + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { continue }
                var id = name
                for suffix in [".plist", ".savedState"] where id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
                let metadata = metadataIdentity(path, name)
                if let identity = metadata { id = identity.0 }
                let parts = id.split(separator:".")
                guard metadata != nil || parts.count >= 3, !id.hasPrefix("com.apple."), !id.hasPrefix("group."), !installedNames.contains(name),
                      !sharedLeafNames.contains(parts.last.map { String($0).lowercased() } ?? ""),
                      !installed.contains(where: { id == $0 || id.hasPrefix($0 + ".") || $0.hasPrefix(id + ".") }) else { continue }
                let reason = metadata?.1 ?? "No matching app found; may belong to a CLI/helper/shared service"
                candidates.append((path, name, kind, id, reason))
            }
        }
        if discoveryTruncated { warnings.append("Directory discovery reached the \(environment.entryLimit)-entry budget; results are partial.") }
        if unreadable > 0 { limited = true; warnings.append("\(unreadable) Library folders could not be read; permissions may hide additional data.") }
        var rows: [[String:Any]] = candidates.map { path, name, kind, id, reason in
            var value = row(path, kind:kind, shared:true, evidence:reason, budget:budget)
            value["bundleID"] = id; value["candidate"] = true; value["confidence"] = reason.hasPrefix("No matching") ? "low" : "medium"
            value["uncertain"] = true; value["reason"] = reason
            if (value["limited"] as? Bool) == true || (value["skipped"] as? Int ?? 0) > 0 { limited = true }
            return value
        }
        rows.sort { let a = $0["size"] as? Int64 ?? 0, b = $1["size"] as? Int64 ?? 0; return a == b ? ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") : a > b }
        let requestedLimit = max(0, limit)
        if rows.count > requestedLimit { limited = true; warnings.append("Showing the largest \(requestedLimit) of \(rows.count) discovered candidates; review remains required.") }
        if rows.contains(where: { ($0["limited"] as? Bool) == true || ($0["skipped"] as? Int ?? 0) > 0 }) { warnings.append("Some candidate sizes are partial because of scan budgets or unreadable files.") }
        _ = budget.hasTime()
        warnings += budget.warnings
        limited = limited || budget.timeLimited || budget.measurementLimited
        return ["rows":Array(rows.prefix(requestedLimit)), "warnings":warnings, "limited":limited]
    }
}
func installedApps() -> [InstalledApp] { AppServices().apps() }
func appRelated(_ app: InstalledApp) -> [[String:Any]] { AppServices().related(app) }
func orphanReport() -> [String:Any] { AppServices().orphanReport() }
func orphanCandidates() -> [[String:Any]] { orphanReport()["rows"] as? [[String:Any]] ?? [] }
