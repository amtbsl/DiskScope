import Foundation
import Darwin

struct DiskEntry {
    var path: String
    var name: String
    var directory: Bool
    var symlink: Bool
    var bytes: Int64
    var logical: Int64
    var modified: Double
    var children: [Int] = []
    var count: Int = 1
    var category: String
    var tags: [String]
    func json(_ id: Int) -> [String: Any] {
        ["id": id, "path": path, "name": name, "directory": directory, "symlink": symlink,
         "size": bytes, "logical": logical, "modified": modified, "count": count,
         "category": category, "tags": tags, "childCount": children.count]
    }
}

func category(_ path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    if ["mp4","mov","mkv","avi","webm","m4v","mp3","wav","flac","aac"].contains(ext) { return "Video" }
    if ["png","jpg","jpeg","gif","webp","heic","svg","tiff","psd","raw"].contains(ext) { return "Image" }
    if ["pdf","doc","docx","txt","md","ppt","pptx","xls","xlsx","csv","epub"].contains(ext) { return "Doc" }
    if ["zip","tar","gz","rar","7z","dmg","iso","xz","bz2","pkg"].contains(ext) { return "Archive" }
    if ["js","ts","jsx","tsx","py","swift","c","cpp","h","rs","go","java","json","html","css","sh","ipynb","pt","onnx"].contains(ext) { return "Dev" }
    return "Other"
}
func tags(_ path: String, _ size: Int64, _ cat: String) -> [String] {
    let p = path.lowercased(), parts = p.split(separator: "/").map(String.init)
    var result: [String] = []
    if parts.contains("node_modules") || parts.contains(".npm") || parts.contains(".pnpm-store") { result.append("Node.js") }
    if p.contains("/developer/xcode/") || p.contains("/developer/coresimulator/") || p.hasSuffix(".xcarchive") { result.append("Xcode") }
    if parts.contains(".build") || parts.contains("__pycache__") || parts.contains("target") || parts.contains("dist") || parts.contains("build") { result.append("Build Artifacts") }
    if p.contains("/.gradle/") || p.contains("/android/") || p.contains("/.android/") { result.append("Android") }
    if p.contains("docker") { result.append("Docker") }
    if cat == "Video" { result.append("Videos") }
    if p.hasSuffix(".dmg") || p.hasSuffix(".iso") { result.append("Disk Images") }
    if cat == "Archive" { result.append("Archives") }
    if p.contains("/mobilesync/backup") { result.append("iOS Backups") }
    if [".pvm",".vmdk",".qcow2",".vdi",".vmwarevm",".utm"].contains(where: { p.contains($0) }) { result.append("Virtual Machines") }
    if ["Image","Video"].contains(cat) && size > 100_000_000 { result.append("Large Media") }
    if parts.contains("caches") || parts.contains("logs") || p.hasSuffix(".log") || parts.contains(".cache") { result.append("Logs & Caches") }
    if p.contains("/.ollama/models") || p.contains("/huggingface/") || p.contains("/lm studio/models") || p.hasSuffix(".gguf") || p.hasSuffix(".safetensors") { result.append("AI Models") }
    return result
}

final class ScanControl: @unchecked Sendable {
    let lock = NSLock()
    var cancelled = false
    var count = 0
    var skipped = 0
    var current = ""
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func stopped() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func progress(_ path: String, _ n: Int, _ errors: Int) { lock.lock(); current = path; count = n; skipped = errors; lock.unlock() }
    func snapshot() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return ["count":count,"skipped":skipped,"current":current,"cancelled":cancelled] }
}
struct ScanResult { var nodes: [DiskEntry]; var skipped: Int; var limited: Bool }
final class Scanner {
    var nodes: [DiskEntry] = []
    var hardlinks = Set<String>()
    var skipped = 0
    var limited = false
    let control: ScanControl
    let limit: Int
    let full: Bool
    init(control: ScanControl, limit: Int = 2_000_000, full: Bool = false) { self.control = control; self.limit = limit; self.full = full }
    func scan(_ path: String) -> ScanResult {
        _ = visit(path, depth: 0)
        control.progress(path, nodes.count, skipped)
        return ScanResult(nodes: nodes, skipped: skipped, limited: limited)
    }
    @discardableResult func visit(_ path: String, depth: Int) -> Int? {
        if control.stopped() { return nil }
        if nodes.count >= limit || depth > 256 { limited = true; return nil }
        var st = stat()
        guard lstat(path, &st) == 0 else { skipped += 1; return nil }
        let directory = (st.st_mode & S_IFMT) == S_IFDIR
        let link = (st.st_mode & S_IFMT) == S_IFLNK
        var bytes = Int64(st.st_blocks) * 512
        if st.st_nlink > 1 && !directory {
            let key = "\(st.st_dev):\(st.st_ino)"
            if hardlinks.contains(key) { bytes = 0 } else { hardlinks.insert(key) }
        }
        let id = nodes.count, cat = category(path)
        nodes.append(DiskEntry(path: path, name: path == "/" ? "Macintosh HD" : (path as NSString).lastPathComponent, directory: directory, symlink: link, bytes: bytes, logical: Int64(st.st_size), modified: Double(st.st_mtimespec.tv_sec), category: cat, tags: tags(path, bytes, cat)))
        if nodes.count % 1024 == 0 { control.progress(path, nodes.count, skipped) }
        if directory {
            guard let dir = opendir(path) else { skipped += 1; return id }
            defer { closedir(dir) }
            while let item = readdir(dir) {
                let name = withUnsafePointer(to: &item.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                let childPath = path == "/" ? "/" + name : path + "/" + name
                // Firmlinks already expose the Data volume under /. Do not count it a second time.
                if full && ["/System/Volumes","/dev","/Volumes","/Network","/cores"].contains(childPath) { continue }
                if let child = visit(childPath, depth: depth + 1) {
                    nodes[id].children.append(child)
                    nodes[id].bytes += nodes[child].bytes
                    nodes[id].logical += nodes[child].logical
                    nodes[id].count += nodes[child].count
                }
                if control.stopped() || limited { break }
            }
            let sortedChildren = nodes[id].children.sorted { nodes[$0].bytes > nodes[$1].bytes }
            nodes[id].children = sortedChildren
        }
        return id
    }
}

func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
func safeToTrash(_ path: String) -> Bool {
    let p = canonical(path), home = NSHomeDirectory()
    let protected = ["/", "/Applications", "/Users", "/Library", "/Volumes", "/System", "/bin", "/sbin", "/usr", "/private", "/opt", home, home + "/Library", home + "/.Trash", home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Pictures", home + "/Music", home + "/Movies"]
    if protected.contains(p) { return false }
    // Resolve the parent as well: a symlinked directory must not bypass protected paths.
    let parent = URL(fileURLWithPath: p).deletingLastPathComponent().resolvingSymlinksInPath().path
    let resolved = parent + "/" + URL(fileURLWithPath:p).lastPathComponent
    for candidate in [p, resolved] {
        if ["/System/","/bin/","/sbin/","/usr/","/private/","/dev/"].contains(where: { candidate.hasPrefix($0) }) { return false }
        if candidate == Bundle.main.bundlePath || candidate.hasPrefix(home + "/.Trash/") { return false }
    }
    return p.hasPrefix(home + "/") || p.hasPrefix("/Applications/") || p.hasPrefix("/Volumes/")
}
func normalizeQueue(_ paths: [String]) -> [String] {
    let sorted = Array(Set(paths.map(canonical))).sorted { $0.count < $1.count }
    var result: [String] = []
    for p in sorted where !result.contains(where: { p.hasPrefix($0 + "/") }) { result.append(p) }
    return result
}

func run(_ executable: String, _ arguments: [String], timeout: Double = 10) -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit(); stop.cancel()
    return String(data: output, encoding: .utf8) ?? ""
}
