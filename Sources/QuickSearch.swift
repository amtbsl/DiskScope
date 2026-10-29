import AppKit
import Carbon

private final class QuickResultTable: NSTableView {
    var activate: (() -> Void)?
    var dismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { activate?() }
        else if event.keyCode == 53 { dismiss?() }
        else { super.keyDown(with: event) }
    }
}

final class QuickSearchController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var appearance: NSAppearance? = NSAppearance(named: .darkAqua) { didSet { panel?.appearance = appearance } }
    private var panel: NSPanel?
    private let input = NSSearchField()
    private let table = QuickResultTable()
    private let status = NSTextField(labelWithString: "")
    private let requests = SearchRequestGate()
    private let queue = DispatchQueue(label: "local.diskscope.quicksearch", qos: .userInitiated)
    private var debounce: DispatchWorkItem?
    private var rows: [[String: Any]] = []
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private(set) var shortcutAvailable = false

    func registerShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x44534350, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<QuickSearchController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { controller.toggle() }
            return noErr
        }, 1, &spec, context, &eventHandler)
        guard installed == noErr else { return }
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x44534350, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        shortcutAvailable = result == noErr
    }
    func unregisterShortcut() {
        debounce?.cancel(); requests.invalidate()
        if let key = hotKey { UnregisterEventHotKey(key); hotKey = nil }
        if let handler = eventHandler { RemoveEventHandler(handler); eventHandler = nil }
    }
    func toggle() { panel?.isVisible == true ? hide() : show() }
    func show() {
        if panel == nil { makePanel() }
        NSApp.activate(ignoringOtherApps: true)
        panel?.center(); panel?.makeKeyAndOrderFront(nil); panel?.makeFirstResponder(input)
        input.selectText(nil)
        if input.stringValue.isEmpty { status.stringValue = shortcutAvailable ? "Type a name · ⌘⇧Space to toggle · Return to open · Esc to close" : "Type a name · Global shortcut unavailable; use View → Quick Search" }
        else { controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input)) }
    }
    func hide() { debounce?.cancel(); requests.invalidate(); panel?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { debounce?.cancel(); requests.invalidate() }

    private func makePanel() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 470), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DiskScope Quick Search"; window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.minSize = NSSize(width: 570, height: 330); window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        let content = NSView(); window.contentView = content
        input.placeholderString = "Search files and apps…"; input.font = .systemFont(ofSize: 22)
        // Search-field actions can fire for every keystroke. Opening is handled
        // only by the explicit Return delegate command, table action or button.
        input.delegate = self; input.target = nil; input.action = nil
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.title = "Name"; name.width = 250
        let path = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path")); path.title = "Location"; path.width = 460
        table.addTableColumn(name); table.addTableColumn(path)
        table.delegate = self; table.dataSource = self; table.rowHeight = 31
        table.target = self; table.doubleAction = #selector(openSelected)
        table.activate = { [weak self] in self?.openSelected() }; table.dismiss = { [weak self] in self?.hide() }
        scroll.documentView = table
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let open = NSButton(title: "Open", target: self, action: #selector(openSelected))
        let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealSelected))
        for view in [input, scroll, status, open, reveal] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18), input.heightAnchor.constraint(equalToConstant: 42),
            scroll.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 14), scroll.leadingAnchor.constraint(equalTo: input.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: input.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: open.topAnchor, constant: -12),
            open.trailingAnchor.constraint(equalTo: input.trailingAnchor), open.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            reveal.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -10), reveal.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: input.leadingAnchor), status.trailingAnchor.constraint(lessThanOrEqualTo: reveal.leadingAnchor, constant: -10), status.centerYAnchor.constraint(equalTo: open.centerYAnchor)
        ])
        panel = window
    }
    func controlTextDidChange(_ notification: Notification) {
        debounce?.cancel()
        let query = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), generation = requests.next()
        rows = []; table.reloadData()
        guard !query.isEmpty else {
            rows = []; table.reloadData(); status.stringValue = "Type a file or application name. Search stays on this Mac."
            return
        }
        status.stringValue = "Searching files and apps…"
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                guard self.requests.isCurrent(generation) else { return }
                let apps: [[String: Any]] = installedApps().filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(15).map {
                    ["path": $0.path, "name": $0.name, "kind": "Application"]
                }
                DispatchQueue.main.async {
                    guard self.requests.isCurrent(generation), self.panel?.isVisible == true else { return }
                    self.requests.publishResults(for: generation)
                    self.rows = apps; self.table.reloadData()
                    if !apps.isEmpty { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                    self.status.stringValue = apps.isEmpty ? "Searching indexed files…" : "\(apps.count) apps · Searching indexed files…"
                }
                let found = spotlightSearch(query: query, scope: "mac", filters: [], type: "", large: false, limit: 50)
                guard self.requests.isCurrent(generation) else { return }
                var seen = Set<String>()
                let matches = (apps + (found["rows"] as? [[String: Any]] ?? [])).filter { row in
                    guard let path = row["path"] as? String else { return false }
                    return seen.insert(path).inserted
                }
                DispatchQueue.main.async {
                    guard self.requests.isCurrent(generation), self.panel?.isVisible == true else { return }
                    self.requests.publishResults(for: generation)
                    let selectedPath = self.rows.indices.contains(self.table.selectedRow) ? self.rows[self.table.selectedRow]["path"] as? String : nil
                    self.rows = matches; self.table.reloadData()
                    if !matches.isEmpty {
                        let selection = matches.firstIndex { ($0["path"] as? String) == selectedPath } ?? 0
                        self.table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
                    }
                    let partial = found["limited"] as? Bool == true || found["incomplete"] as? Bool == true
                    self.status.stringValue = matches.isEmpty ? (partial ? "Search incomplete or unavailable. Refine the query or retry; no results shown." : "No matches in indexed, accessible locations.") : "\(matches.count) results · Return to open\(partial ? " · Partial index results; refine search" : "")"
                }
            }
        }
        debounce = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) { hide(); return true }
        if command == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if command == #selector(NSResponder.moveDown(_:)) || command == #selector(NSResponder.moveUp(_:)) {
            guard !rows.isEmpty else { return true }
            let delta = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(rows.count - 1, max(0, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
            return true
        }
        return false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let key = column?.identifier.rawValue == "name" ? "name" : "path"
        let text = NSTextField(labelWithString: rows[row][key] as? String ?? "")
        text.lineBreakMode = key == "path" ? .byTruncatingMiddle : .byTruncatingTail
        text.textColor = key == "path" ? .secondaryLabelColor : .labelColor
        text.toolTip = rows[row]["path"] as? String
        return text
    }
    private func selectedURL() -> URL? {
        guard requests.canActivateResults(), rows.indices.contains(table.selectedRow), let path = rows[table.selectedRow]["path"] as? String,
              FileManager.default.fileExists(atPath: path) else { NSSound.beep(); return nil }
        return URL(fileURLWithPath: path)
    }
    @objc private func openSelected() { guard let url = selectedURL() else { return }; NSWorkspace.shared.open(url); hide() }
    @objc private func revealSelected() { guard let url = selectedURL() else { return }; NSWorkspace.shared.activateFileViewerSelecting([url]); hide() }
}
