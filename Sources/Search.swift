import Foundation
import Darwin

struct SpotlightEnumerationReport {
    var limited = false
    var warnings: [String] = []
    var reasons: [String] = []
}
typealias SpotlightCandidateSource = (_ consume: (String) -> Bool) -> SpotlightEnumerationReport

func spotlightExpression(query: String, large: Bool) -> String? {
    guard !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
    let safe = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
    if large && query.isEmpty { return "kMDItemFSSize > 0" }
    return "kMDItemFSName == \"*\(safe)*\"cd"
}

func spotlightEntry(_ path: String) -> DiskEntry? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    let size = Int64(st.st_blocks) * 512, cat = category(path)
    return DiskEntry(path: path, name: (path as NSString).lastPathComponent,
        directory: (st.st_mode & S_IFMT) == S_IFDIR, symlink: (st.st_mode & S_IFMT) == S_IFLNK,
        bytes: size, logical: Int64(st.st_size), modified: Double(st.st_mtimespec.tv_sec),
        category: cat, tags: tags(path, size, cat))
}

private func spotlightRanksBefore(_ a: DiskEntry, _ b: DiskEntry) -> Bool {
    a.bytes == b.bytes ? a.path < b.path : a.bytes > b.bytes
}

// The least useful retained result is the root, keeping memory proportional to
// the requested display limit rather than the number of indexed matches.
private struct SpotlightTopRows {
    var heap: [DiskEntry] = []
    let limit: Int
    mutating func offer(_ entry: DiskEntry) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(entry)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                if !spotlightRanksBefore(heap[parent], heap[child]) { break }
                heap.swapAt(parent, child); child = parent
            }
        } else if spotlightRanksBefore(entry, heap[0]) {
            heap[0] = entry
            var parent = 0
            while parent * 2 + 1 < heap.count {
                var child = parent * 2 + 1
                if child + 1 < heap.count && spotlightRanksBefore(heap[child], heap[child + 1]) { child += 1 }
                if !spotlightRanksBefore(heap[parent], heap[child]) { break }
                heap.swapAt(parent, child); parent = child
            }
        }
    }
}

func searchSpotlightCandidates(query: String, filters: [String], type: String, large: Bool,
    limit: Int = 500, candidateLimit: Int = 100_000, timeLimit: TimeInterval = 8,
    source: SpotlightCandidateSource, entryForPath: @escaping (String) -> DiskEntry? = spotlightEntry,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> [String:Any] {
    let start = now(), cap = max(0, min(100_000, candidateLimit))
    let budget = max(0, min(8, timeLimit)), resultLimit = max(0, min(5_000, limit))
    let selectedTags = Set(filters)
    var top = SpotlightTopRows(limit: resultLimit)
    var examined = 0, skipped = 0, total = 0
    var reasons: [String] = []
    let report = source { path in
        if examined >= cap { reasons.append("candidateLimit"); return false }
        if now() - start >= budget { reasons.append("timeLimit"); return false }
        examined += 1
        guard let entry = entryForPath(path) else { skipped += 1; return true }
        if large && entry.directory { return true }
        if !query.isEmpty && entry.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return true }
        if !selectedTags.isEmpty && selectedTags.isDisjoint(with: entry.tags) { return true }
        if !type.isEmpty && entry.category != type { return true }
        total += 1
        top.offer(entry)
        return true
    }
    reasons += report.reasons
    if skipped > 0 { reasons.append("unreadablePaths") }
    let incomplete = report.limited || !reasons.isEmpty
    let rows = top.heap.sorted(by: spotlightRanksBefore).map { $0.json(-1) }
    let truncated = incomplete || total > rows.count
    if total > rows.count { reasons.append("resultLimit") }
    var warnings = report.warnings
    if skipped > 0 { warnings.append("Some indexed paths no longer exist or could not be read.") }
    if incomplete { warnings.append("Partial results: total counts filtered matches among the candidates examined.") }
    var sourceLabel = "Spotlight · indexed locations only · allocated bytes; directory size is not recursive"
    if incomplete { sourceLabel += " · partial results (\(examined) candidates examined)" }
    return ["rows": rows, "total": total, "examined": examined, "skipped": skipped,
        "limited": truncated, "truncated": truncated, "incomplete": incomplete, "totalIsExact": !incomplete,
        "candidateLimit": cap, "resultLimit": resultLimit, "reasons": Array(Set(reasons)).sorted(),
        "warnings": warnings, "elapsed": max(0, now() - start), "source": sourceLabel]
}

// Read NUL-delimited paths in small chunks. The old run() helper collects a
// subprocess's entire output, which is unsuitable for an unbounded index query.
private func enumerateSpotlight(expression: String, scope: String, consume: (String) -> Bool) -> SpotlightEnumerationReport {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    process.arguments = ["-0"] + (scope == "home" ? ["-onlyin", NSHomeDirectory()] : []) + [expression]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() }
    catch { return SpotlightEnumerationReport(limited: true, warnings: ["Spotlight could not start: \(error.localizedDescription)"], reasons: ["sourceError"]) }
    try? pipe.fileHandleForWriting.close()
    defer { try? pipe.fileHandleForReading.close() }

    var report = SpotlightEnumerationReport()
    let fd = pipe.fileHandleForReading.fileDescriptor
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    var buffer = [UInt8](repeating: 0, count: 32_768), pathBytes: [UInt8] = []
    var received = 0, ended = false, consumerStopped = false, oversizedPath = false
    if fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0 {
        report = SpotlightEnumerationReport(limited: true, warnings: ["Spotlight output could not be read safely."], reasons: ["sourceError"])
    } else {
        readLoop: while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                report.limited = true; report.reasons.append("sourceError"); break
            }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { ended = true; break }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                report.limited = true; report.reasons.append("sourceError"); break
            }
            received += count
            if received > 64 * 1024 * 1024 {
                report.limited = true; report.reasons.append("outputLimit"); break
            }
            for byte in buffer.prefix(count) {
                if byte == 0 {
                    if oversizedPath || String(bytes: pathBytes, encoding: .utf8) == nil {
                        report.limited = true
                        report.reasons.append("invalidPath")
                    } else if !pathBytes.isEmpty, let path = String(bytes: pathBytes, encoding: .utf8), !consume(path) {
                        consumerStopped = true; break readLoop
                    }
                    pathBytes.removeAll(keepingCapacity: true); oversizedPath = false
                } else if pathBytes.count < 16_384 {
                    pathBytes.append(byte)
                } else {
                    oversizedPath = true
                }
            }
        }
        if !ended && !consumerStopped && !report.limited {
            report.limited = true; report.reasons.append("timeLimit")
        }
    }
    // Closing the read end and terminating the bounded query prevents a writer
    // blocked on a full pipe from surviving a cap or deadline.
    try? pipe.fileHandleForReading.close()
    if process.isRunning {
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(1_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    if ended && process.terminationStatus != 0 {
        report.limited = true; report.reasons.append("sourceError")
        report.warnings.append("Spotlight failed (status \(process.terminationStatus)); its index may be unavailable.")
    }
    if report.limited && report.warnings.isEmpty {
        report.warnings.append("Spotlight enumeration was incomplete (\(Array(Set(report.reasons)).sorted().joined(separator: ", "))).")
    }
    return report
}

func spotlightSearch(query: String, scope: String, filters: [String], type: String, large: Bool, limit: Int = 500) -> [String:Any] {
    guard let expression = spotlightExpression(query: query, large: large) else {
        return searchSpotlightCandidates(query: query, filters: filters, type: type, large: large, limit: limit,
            source: { _ in SpotlightEnumerationReport(limited: true,
                warnings: ["Search text contains unsupported control characters."], reasons: ["invalidQuery"]) })
    }
    return searchSpotlightCandidates(query: query, filters: filters, type: type, large: large, limit: limit,
        source: { consume in enumerateSpotlight(expression: expression, scope: scope, consume: consume) })
}
