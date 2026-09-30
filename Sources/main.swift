import AppKit
import WebKit
import UniformTypeIdentifiers

// Receive the original mouse event in AppKit rather than trying to start a
// window drag from an asynchronous JavaScript message. HTML controls pass through.
final class WindowDragView: NSView {
    var headerHeight: CGFloat = 0
    var controls: [NSRect] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.y < headerHeight, local.x >= 90,
              window?.attachedSheet == nil,
              !controls.contains(where: { $0.contains(local) }) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    let windowDrag = WindowDragView()
    let work = DispatchQueue(label:"local.diskscope.work",qos:.userInitiated)
    let scanningQueue = DispatchQueue(label:"local.diskscope.scan",qos:.utility)
    var nodes: [DiskEntry] = []
    var control: ScanControl?
    var scanning = false
    var root = "", skipped = 0, limited = false
    let monitor = Monitor()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle:"About DiskScope", action:#selector(about), keyEquivalent:"")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit DiskScope",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu = appMenu; menu.addItem(item)
        let edit = NSMenuItem(title:"Edit",action:nil,keyEquivalent:""), editMenu = NSMenu(title:"Edit")
        for (title,action,key) in [("Undo","undo:","z"),("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] { editMenu.addItem(withTitle:title,action:Selector(action),keyEquivalent:key) }
        edit.submenu = editMenu; menu.addItem(edit)
        let view = NSMenuItem(title:"View",action:nil,keyEquivalent:""), viewMenu = NSMenu(title:"View")
        viewMenu.addItem(withTitle:"Search",action:#selector(focusSearch),keyEquivalent:"f")
        view.submenu = viewMenu; menu.addItem(view); NSApp.mainMenu = menu
        let config = WKWebViewConfiguration(); config.userContentController.add(self,name:"native")
        web = WKWebView(frame:.zero,configuration:config); web.navigationDelegate = self
        web.setValue(false,forKey:"drawsBackground")
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "DiskScope"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        let content = NSView(frame:NSRect(x:0,y:0,width:1400,height:900))
        web.frame = content.bounds; web.autoresizingMask = [.width,.height]
        windowDrag.frame = content.bounds; windowDrag.autoresizingMask = [.width,.height]
        content.addSubview(web); content.addSubview(windowDrag)
        window.minSize = NSSize(width:1050,height:700); window.contentView = content; window.center()
        window.appearance = NSAppearance(named:.darkAqua)
        if let url = Bundle.main.url(forResource:"index",withExtension:"html",subdirectory:"web") {
            web.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent())
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"DiskScope",.applicationVersion:"1.0.0",.credits:NSAttributedString(string:"Independent local disk analyzer. All features included.")]) }
    @objc func focusSearch() { web.evaluateJavaScript("document.querySelector('#search').focus()") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { control?.cancel() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }
    func send(_ id: String, result: Any? = nil, error: String? = nil) {
        var value: [String:Any] = ["id":id]
        if let error = error { value["error"] = error } else { value["result"] = result ?? NSNull() }
        emit("receive",value)
    }
    func emit(_ event: String, _ value: Any) {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]), let json = String(data:data,encoding:.utf8) else { return }
        DispatchQueue.main.async { self.web.evaluateJavaScript("window.\(event)(\(json))") }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String:Any], let id = body["id"] as? String, let action = body["action"] as? String else { return }
        let args = body["args"] as? [String:Any] ?? [:]
        switch action {
        case "dragRegions":
            windowDrag.headerHeight = min(100, max(0, args["height"] as? Double ?? 0))
            windowDrag.controls = (args["controls"] as? [[String:Double]] ?? []).map {
                NSRect(x:$0["x"] ?? 0,y:$0["y"] ?? 0,width:$0["width"] ?? 0,height:$0["height"] ?? 0)
            }
            send(id,result:["ok":true])
        case "choose":
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.beginSheetModal(for:window) { response in
                if response == .OK, let url = panel.url { self.startScan(url.path); self.send(id,result:["started":true]) } else { self.send(id,result:["started":false]) }
            }
        case "scan":
            let path = args["path"] as? String ?? NSHomeDirectory()
            startScan(path == "home" ? NSHomeDirectory() : path); send(id,result:["started":true])
        case "cancel": control?.cancel(); scanning = false; send(id,result:["cancelled":true])
        case "status":
            var state = control?.snapshot() ?? [:]; state["scanning"] = scanning
            send(id,result:state)
        case "reveal", "open":
            guard let path = args["path"] as? String, FileManager.default.fileExists(atPath:path) else { send(id,error:"The item no longer exists."); return }
            let url = URL(fileURLWithPath:path)
            if action == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { NSWorkspace.shared.open(url) }
            send(id,result:["ok":true])
        case "trash": reviewTrash(id,args)
        case "emptyTrash": emptyTrash(id)
        case "export": exportScan(id)
        case "permissions":
            NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!); send(id,result:["ok":true])
        case "copy":
            guard let path = args["path"] as? String else { send(id,error:"Missing path"); return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path,forType:.string)
            send(id,result:["ok":true])
        default:
            work.async {
                do { let result = try self.perform(action,args); self.send(id,result:result) }
                catch { self.send(id,error:error.localizedDescription) }
            }
        }
    }
    func startScan(_ path: String) {
        control?.cancel(); let current = ScanControl(); control = current; scanning = true
        let scanRoot = canonical(path)
        scanningQueue.async {
            let result = Scanner(control:current,full:scanRoot == "/").scan(scanRoot)
            if current.stopped() { return }
            self.work.async {
                if current.stopped() { return }
                self.nodes = result.nodes; self.root = scanRoot; self.skipped = result.skipped; self.limited = result.limited
                DispatchQueue.main.async {
                    if self.control !== current { return }
                    self.scanning = false; self.emit("scanFinished",["root":scanRoot,"count":result.nodes.count,"skipped":result.skipped,"limited":result.limited])
                }
            }
        }
    }
    func perform(_ action: String, _ args: [String:Any]) throws -> Any {
        switch action {
        case "disk": return diskStatus()
        case "monitor": return monitor.sample()
        case "browse":
            let id = args["node"] as? Int ?? 0
            guard nodes.indices.contains(id) else { return ["empty":true] }
            var ancestors: [[String:Any]] = []
            let byPath = Dictionary(uniqueKeysWithValues:nodes.indices.filter { nodes[$0].directory && (nodes[id].path == nodes[$0].path || nodes[id].path.hasPrefix(nodes[$0].path == "/" ? "/" : nodes[$0].path+"/")) }.map { (nodes[$0].path,$0) })
            for p in byPath.keys.sorted(by: { $0.count < $1.count }) { ancestors.append(nodes[byPath[p]!].json(byPath[p]!)) }
            func tree(_ n: Int, _ depth: Int, _ allowance: Int) -> [String:Any] {
                var json = nodes[n].json(n)
                if depth > 0 && allowance > 1 {
                    // Reserve siblings first, then divide detail by their storage share.
                    // A large first subtree must not consume every other top-level folder.
                    let children = Array(nodes[n].children.filter { nodes[$0].bytes > 0 }.prefix(min(80,allowance-1)))
                    let remaining = max(0,allowance-1-children.count)
                    let size = max(1,children.reduce(Int64(0)) { $0 + nodes[$1].bytes })
                    json["children"] = children.map { c in
                        let share = Int(Double(remaining) * Double(nodes[c].bytes) / Double(size))
                        return tree(c,depth-1,1+share)
                    }
                }
                return json
            }
            let offset = max(0,args["offset"] as? Int ?? 0)
            return ["node":nodes[id].json(id),"tree":tree(id,8,1400),"children":Array(nodes[id].children.dropFirst(offset).prefix(400)).map { nodes[$0].json($0) },"ancestors":ancestors,"totalChildren":nodes[id].children.count,"skipped":skipped,"limited":limited]
        case "search":
            let query = (args["query"] as? String ?? "").lowercased(), filters = args["filters"] as? [String] ?? [], type = args["type"] as? String ?? ""
            let scope = args["scope"] as? String ?? "scan"
            if scope != "scan" && !query.isEmpty {
                let safe = query.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"*",with:"\\*").replacingOccurrences(of:"?",with:"\\?")
                var argv = ["-0"]
                if scope == "home" { argv += ["-onlyin",NSHomeDirectory()] }
                argv.append("kMDItemFSName == \"*\(safe)*\"cd")
                let paths = run("/usr/bin/mdfind",argv,timeout:8).split(separator:"\0").prefix(500)
                let rows = paths.compactMap { path -> [String:Any]? in
                    let p = String(path); var st = stat(); guard lstat(p,&st) == 0 else { return nil }
                    let size = Int64(st.st_blocks)*512, cat = category(p), t = tags(p,size,cat)
                    if !filters.isEmpty && Set(filters).isDisjoint(with:t) { return nil }
                    if !type.isEmpty && cat != type { return nil }
                    return DiskEntry(path:p,name:(p as NSString).lastPathComponent,directory:(st.st_mode&S_IFMT)==S_IFDIR,symlink:(st.st_mode&S_IFMT)==S_IFLNK,bytes:size,logical:Int64(st.st_size),modified:Double(st.st_mtimespec.tv_sec),category:cat,tags:t).json(-1)
                }
                return ["rows":rows,"total":rows.count,"source":"Spotlight · up to 500 indexed matches; directory size is not recursive"]
            }
            let matches = nodes.indices.filter { n in
                let e = nodes[n]
                return (query.isEmpty || e.path.lowercased().contains(query)) && (filters.isEmpty || !Set(filters).isDisjoint(with:e.tags)) && (type.isEmpty || e.category == type) && (args["large"] as? Bool != true || !e.directory)
            }.sorted { nodes[$0].bytes > nodes[$1].bytes }
            return ["rows":Array(matches.prefix(500)).map { nodes[$0].json($0) },"total":matches.count,"source":"Current scan · allocated bytes"]
        case "apps": return installedApps().map { $0.json() }
        case "appDetails":
            guard let path = args["path"] as? String, let app = installedApps().first(where: { $0.path == path }) else { return [] as [[String:Any]] }
            return appRelated(app)
        case "orphans": return orphanCandidates()
        default: throw NSError(domain:"DiskScope",code:1,userInfo:[NSLocalizedDescriptionKey:"Unknown action: \(action)"])
        }
    }
    func reviewTrash(_ id: String, _ args: [String:Any]) {
        let paths = normalizeQueue(args["paths"] as? [String] ?? [])
        guard !paths.isEmpty, paths.allSatisfy(safeToTrash) else { send(id,error:"Protected paths cannot be removed. Select individual files or folders in your home, Applications or an external volume."); return }
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }
        if paths.contains(where: { running.contains($0) }) { send(id,error:"Quit the selected application before uninstalling it."); return }
        let alert = NSAlert(); alert.messageText = "Move \(paths.count) selected items to Trash?"
        alert.informativeText = "Review every path below. You can restore these items from Finder's Trash.\n\n" + paths.prefix(12).joined(separator:"\n") + (paths.count > 12 ? "\n… and \(paths.count-12) more items listed in your queue." : "")
        alert.alertStyle = .warning; alert.addButton(withTitle:"Move to Trash"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { response in
            guard response == .alertFirstButtonReturn else { self.send(id,result:["cancelled":true]); return }
            self.work.async {
                var moved: [String] = [], failures: [[String:String]] = []
                for p in paths {
                    // Revalidate after review, and never run a privileged delete.
                    guard safeToTrash(p) else { failures.append(["path":p,"error":"Protected path"]); continue }
                    do { try FileManager.default.trashItem(at:URL(fileURLWithPath:p),resultingItemURL:nil); moved.append(p) }
                    catch { failures.append(["path":p,"error":error.localizedDescription]) }
                }
                self.send(id,result:["moved":moved,"failures":failures])
            }
        }
    }
    func emptyTrash(_ id: String) {
        let alert = NSAlert(); alert.messageText = "Permanently empty this user's Trash?"
        alert.informativeText = "This cannot be undone. Type EMPTY to permanently erase the items in ~/.Trash. Trash on external volumes is not included."
        let input = NSTextField(frame:NSRect(x:0,y:0,width:300,height:24)); input.placeholderString = "EMPTY"; alert.accessoryView = input
        alert.alertStyle = .critical; alert.addButton(withTitle:"Permanently Empty"); alert.addButton(withTitle:"Cancel")
        alert.beginSheetModal(for:window) { response in
            guard response == .alertFirstButtonReturn && input.stringValue == "EMPTY" else { self.send(id,result:["cancelled":true]); return }
            self.work.async {
                let trash = NSHomeDirectory()+"/.Trash"; var errors:[String] = []
                var st = stat()
                guard lstat(trash,&st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
                      URL(fileURLWithPath:trash).resolvingSymlinksInPath().path == trash else {
                    self.send(id,error:"Trash is inaccessible or is not the standard Trash directory."); return
                }
                do { for name in try FileManager.default.contentsOfDirectory(atPath:trash) { do { try FileManager.default.removeItem(atPath:trash+"/"+name) } catch { errors.append(error.localizedDescription) } } }
                catch { errors.append(error.localizedDescription) }
                self.send(id,result:["errors":errors])
            }
        }
    }
    func exportScan(_ id: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "DiskScope-report.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        panel.beginSheetModal(for:window) { response in
            guard response == .OK, let url = panel.url else { self.send(id,result:["cancelled":true]); return }
            self.work.async {
                func field(_ value: String) -> String {
                    let safe = ["=","+","-","@"].contains(String(value.prefix(1))) ? "'"+value : value
                    return "\""+safe.replacingOccurrences(of:"\"",with:"\"\"")+"\""
                }
                do {
                    try Data("Path,Kind,Allocated bytes,Logical bytes,Category,Modified\n".utf8).write(to:url)
                    let file = try FileHandle(forWritingTo:url); defer { try? file.close() }; try file.seekToEnd()
                    let formatter = ISO8601DateFormatter()
                    for n in self.nodes { try file.write(contentsOf:Data(("\(field(n.path)),\(n.directory ? "Folder":"File"),\(n.bytes),\(n.logical),\(n.category),\(formatter.string(from:Date(timeIntervalSince1970:n.modified)))\n").utf8)) }
                    self.send(id,result:["path":url.path,"count":self.nodes.count])
                } catch { self.send(id,error:error.localizedDescription) }
            }
        }
    }
}

if CommandLine.arguments.count > 3 && CommandLine.arguments[1] == "--service-json" {
    let delegate = AppDelegate()
    let scan = Scanner(control:ScanControl()).scan(canonical(CommandLine.arguments[3]))
    delegate.nodes = scan.nodes; delegate.root = canonical(CommandLine.arguments[3]); delegate.skipped = scan.skipped
    let arguments = CommandLine.arguments.count > 4 ? (try? JSONSerialization.jsonObject(with:Data(CommandLine.arguments[4].utf8))) as? [String:Any] ?? [:] : [:]
    do {
        let output = try delegate.perform(CommandLine.arguments[2],arguments)
        let data = try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]); FileHandle.standardOutput.write(data)
    } catch { fputs(error.localizedDescription,stderr); exit(1) }
} else if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--scan-json" {
    let result = Scanner(control:ScanControl()).scan(canonical(CommandLine.arguments[2]))
    let out: [String:Any] = ["nodes":result.nodes.enumerated().map { $0.element.json($0.offset) },"skipped":result.skipped,"limited":result.limited]
    let data = try! JSONSerialization.data(withJSONObject:out,options:[.sortedKeys]); FileHandle.standardOutput.write(data)
} else if CommandLine.arguments.contains("--trash-test") {
    // Only this newly created UUID-named test file is touched. Restore it immediately.
    let url = URL(fileURLWithPath:NSHomeDirectory()+"/Downloads/DiskScope-validation-"+UUID().uuidString+".txt")
    let contents = Data("DiskScope reversible trash integration test".utf8)
    do {
        try contents.write(to:url,options:.withoutOverwriting)
        precondition(safeToTrash(url.path))
        var trashed: NSURL?
        try FileManager.default.trashItem(at:url,resultingItemURL:&trashed)
        guard let destination = trashed as URL? else { fatalError("Trash did not return the resulting URL") }
        precondition(!FileManager.default.fileExists(atPath:url.path))
        let inTrash = try Data(contentsOf:destination)
        precondition(inTrash == contents)
        try FileManager.default.moveItem(at:destination,to:url)
        let restored = try Data(contentsOf:url)
        precondition(restored == contents)
        try FileManager.default.removeItem(at:url)
        print("PASS: native Trash move, resulting item verification, restoration, test fixture cleanup")
    } catch { fputs(error.localizedDescription,stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    precondition(!safeToTrash("/")); precondition(!safeToTrash(NSHomeDirectory())); precondition(!safeToTrash("/System/Library/test"))
    precondition(!safeToTrash(NSHomeDirectory()+"/.Trash/file")); precondition(safeToTrash(NSHomeDirectory()+"/Downloads/test.bin"))
    precondition(normalizeQueue(["/tmp/a/b","/tmp/a","/tmp/a"]) == ["/tmp/a"])
    precondition(category("test.mp4") == "Video"); precondition(tags("/a/node_modules/pkg/test.js",100,"Dev").contains("Node.js"))
    let m = Monitor(); _ = m.sample(); let stats = m.sample(); precondition((stats["totalMemory"] as! UInt64) > 0)
    print("PASS: protected paths, queue normalization, categories, filters, real monitor sampling")
} else {
    let app = NSApplication.shared, delegate = AppDelegate(); app.delegate = delegate; app.run()
}
