import Foundation
import AppKit
import Darwin
import IOKit.ps

func diskStatus() -> [String: Any] {
    let attrs = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())) ?? [:]
    let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
    let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    let trash = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.Trash"))?.filter { $0 != ".DS_Store" }.count
    return ["total": total, "free": free, "used": max(0, total-free), "trashCount": trash as Any? ?? NSNull(), "home": NSHomeDirectory()]
}
final class Monitor {
    var previousCPU: [UInt64] = [], previousNetwork: (UInt64, UInt64) = (0,0), lastTime = Date().timeIntervalSince1970
    func sample() -> [String: Any] {
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
        var power: [String:Any] = ["source":"Unknown", "percent": NSNull()]
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                if let details = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String:Any] {
                    let current = details[kIOPSCurrentCapacityKey] as? Double ?? 0, maximum = details[kIOPSMaxCapacityKey] as? Double ?? 0
                    power = ["source": details[kIOPSPowerSourceStateKey] as? String ?? "Unknown", "percent": maximum > 0 ? current/maximum*100 : 0, "charging": details[kIOPSIsChargingKey] as? Bool ?? false]
                }
            }
        }
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

struct InstalledApp {
    let path: String, name: String, bundleID: String, version: String
    func json() -> [String:Any] { ["path":path,"name":name,"bundleID":bundleID,"version":version] }
}
func installedApps() -> [InstalledApp] {
    var apps: [InstalledApp] = []
    for root in ["/Applications",NSHomeDirectory()+"/Applications"] {
        guard let files = FileManager.default.enumerator(at:URL(fileURLWithPath:root),includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { continue }
        while let url = files.nextObject() as? URL {
            if url.pathExtension == "app", let b = Bundle(url:url) {
                let displayName = (b.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                apps.append(InstalledApp(path:url.path, name:displayName.isEmpty ? url.deletingPathExtension().lastPathComponent : displayName, bundleID:b.bundleIdentifier ?? "", version:b.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—"))
                files.skipDescendants()
            }
        }
    }
    return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
func appRelated(_ app: InstalledApp) -> [[String:Any]] {
    let home = NSHomeDirectory(), fm = FileManager.default
    var paths: [(String,String)] = [(app.path,"Application")]
    guard !app.bundleID.isEmpty else {
        let result = Scanner(control:ScanControl()).scan(app.path)
        return [["path":app.path,"name":app.name,"size":result.nodes.first?.bytes ?? 0,"kind":"Application","shared":false,"skipped":result.skipped]]
    }
    for folder in ["Application Support","Caches","Preferences","Logs","Containers","Application Scripts","Saved Application State","HTTPStorages","WebKit","LaunchAgents"] {
        let root = home + "/Library/" + folder
        let names = (try? fm.contentsOfDirectory(atPath:root)) ?? []
        for name in names {
            // Exact bundle identifier ownership; never substring-match a vendor's whole folder.
            if name == app.bundleID || name == app.bundleID + ".plist" || name == app.bundleID + ".savedState" || name == app.name {
                paths.append((root+"/"+name,folder))
            }
        }
    }
    // Only groups declared in the code signature, and mark shared groups for explicit review.
    let signature = run("/usr/bin/codesign",["-d","--entitlements",":-",app.path],timeout:5)
    if let start = signature.range(of:"<?xml"), let data = String(signature[start.lowerBound...]).data(using:.utf8), let ent = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any], let groups = ent["com.apple.security.application-groups"] as? [String] {
        for group in groups {
            let p = home+"/Library/Group Containers/"+group
            if fm.fileExists(atPath:p) { paths.append((p,"Shared Group · review other apps")) }
        }
    }
    return paths.map { path, kind in
        let result = Scanner(control:ScanControl()).scan(path)
        return ["path":path,"name":(path as NSString).lastPathComponent,"size":result.nodes.first?.bytes ?? 0,"kind":kind,"shared":kind.hasPrefix("Shared"),"skipped":result.skipped]
    }
}
func orphanCandidates() -> [[String:Any]] {
    var installed = Set(installedApps().map(\.bundleID).filter { !$0.isEmpty })
    // One indexed lookup covers portable applications outside standard install folders.
    let indexedApps = run("/usr/bin/mdfind", ["-0", "kMDItemContentType == 'com.apple.application-bundle'"], timeout: 10)
    for path in indexedApps.split(separator: "\0") {
        if let id = Bundle(path: String(path))?.bundleIdentifier { installed.insert(id) }
    }
    var result: [[String:Any]] = []
    for kind in ["Caches","Preferences","Saved Application State","Application Support","Containers","HTTPStorages","WebKit","Logs"] {
        let root = NSHomeDirectory()+"/Library/"+kind
        for name in (try? FileManager.default.contentsOfDirectory(atPath:root)) ?? [] {
            var id = name
            for suffix in [".plist",".savedState"] where id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
            guard id.split(separator:".").count >= 3, !id.hasPrefix("com.apple."), !installed.contains(id), !installed.contains(where: { id.hasPrefix($0+".") || $0.hasPrefix(id+".") }) else { continue }
            let path = root+"/"+name, scan = Scanner(control:ScanControl()).scan(path)
            result.append(["path":path,"name":name,"size":scan.nodes.first?.bytes ?? 0,"kind":kind,"bundleID":id,"candidate":true])
            if result.count >= 300 { return result }
        }
    }
    return result.sorted { ($0["size"] as! Int64) > ($1["size"] as! Int64) }
}
