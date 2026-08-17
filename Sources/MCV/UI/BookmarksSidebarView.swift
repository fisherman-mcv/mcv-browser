import AppKit

private final class BookmarkOutlineView: NSOutlineView {
    var onEnter: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onEnter?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class BookmarkNode: NSObject {
    let title: String
    let url: URL?
    let storageKey: String?
    var children: [BookmarkNode]

    init(title: String, url: URL? = nil, storageKey: String? = nil, children: [BookmarkNode] = []) {
        self.title = title
        self.url = url
        self.storageKey = storageKey
        self.children = children
    }
}

/// Native, keyboard-first bookmark tree. Bookmark keys containing `/` are
/// represented as folders, while old flat bookmark dictionaries remain valid.
final class BookmarksSidebarView: NSVisualEffectView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onOpen: ((URL) -> Void)?
    private let outline = BookmarkOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "No bookmarks yet\nPress ⌘D to add this page")
    private var roots: [BookmarkNode] = []
    private weak var contextNode: BookmarkNode?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.borderWidth = 0

        let title = NSTextField(labelWithString: "Bookmarks")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let addFolder = NSButton(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Folder")!, target: self, action: #selector(createFolder))
        addFolder.bezelStyle = .texturedRounded
        addFolder.isBordered = false
        addFolder.toolTip = "New Folder"
        addFolder.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        header.addSubview(addFolder)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            addFolder.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            addFolder.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 54),
        ])

        let column = NSTableColumn(identifier: .init("bookmark"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 30
        outline.indentationPerLevel = 14
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(openSelection)
        outline.onEnter = { [weak self] in self?.activateSelection() }
        outline.registerForDraggedTypes([.string])
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outline.menu = contextMenu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scroll)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .mcvConfigChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func configChanged() { reload() }

    func reload(focus: Bool = false) {
        roots = Self.makeTree()
        outline.reloadData()
        roots.filter { $0.url == nil }.forEach { outline.expandItem($0) }
        emptyLabel.isHidden = !roots.isEmpty
        if focus, !roots.isEmpty {
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            window?.makeFirstResponder(outline)
        }
    }

    private static func makeTree() -> [BookmarkNode] {
        let config = ConfigStore.shared.config
        let folderNames = Set(config.bookmarkFolders + config.bookmarks.keys.compactMap { key in
            guard let slash = key.firstIndex(of: "/") else { return nil }
            return String(key[..<slash])
        })
        var folders: [String: [BookmarkNode]] = Dictionary(uniqueKeysWithValues: folderNames.map { ($0, []) })
        var loose: [BookmarkNode] = []
        for (key, value) in config.bookmarks {
            let pieces = key.split(separator: "/", maxSplits: 1).map(String.init)
            let node = BookmarkNode(title: pieces.count == 2 ? pieces[1] : pieces[0], url: URL(string: value), storageKey: key)
            if pieces.count == 2 { folders[pieces[0], default: []].append(node) }
            else { loose.append(node) }
        }
        let folderNodes = folders.keys.sorted().map { name in
            BookmarkNode(title: name, children: folders[name, default: []].sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
        return folderNodes + loose.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func node(_ item: Any?) -> BookmarkNode? { item as? BookmarkNode }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { node(item)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { node(item)?.children[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(node(item)?.children.isEmpty ?? true) || node(item)?.url == nil }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = node(item) else { return nil }
        let id = NSUserInterfaceItemIdentifier("BookmarkCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let view = NSTableCellView()
            view.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            view.textField = text
            view.addSubview(text)
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4), text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            return view
        }()
        cell.textField?.stringValue = node.title
        cell.textField?.font = .systemFont(ofSize: 13, weight: node.url == nil ? .medium : .regular)
        cell.imageView?.image = NSImage(systemSymbolName: node.url == nil ? "folder.fill" : "bookmark.fill", accessibilityDescription: nil)
        cell.toolTip = node.url?.absoluteString
        return cell
    }

    @objc private func openSelection() { activateSelection() }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let node = node(outline.item(atRow: row)) else {
            contextNode = nil
            return
        }
        contextNode = node
        if node.url == nil {
            let ungroup = menu.addItem(withTitle: "Ungroup Folder (Keep Bookmarks)",
                                       action: #selector(ungroupContextFolder), keyEquivalent: "")
            ungroup.target = self
            menu.addItem(.separator())
            let delete = menu.addItem(withTitle: "Delete Folder…",
                                      action: #selector(deleteContextFolder), keyEquivalent: "")
            delete.target = self
        } else if node.storageKey != nil {
            let delete = menu.addItem(withTitle: "Delete Bookmark",
                                      action: #selector(deleteContextBookmark), keyEquivalent: "")
            delete.target = self
        }
    }

    @objc private func deleteContextBookmark() {
        guard let key = contextNode?.storageKey else { return }
        ConfigStore.shared.update { $0.bookmarks.removeValue(forKey: key) }
        contextNode = nil
    }

    @objc private func ungroupContextFolder() {
        guard let folder = contextNode, folder.url == nil else { return }
        let name = folder.title
        contextNode = nil
        ConfigStore.shared.update { $0.ungroupBookmarkFolder(named: name) }
    }

    @objc private func deleteContextFolder() {
        guard let folder = contextNode, folder.url == nil else { return }
        let name = folder.title
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = folder.children.isEmpty
            ? "The empty bookmark folder will be removed."
            : "This will also delete \(folder.children.count) bookmark\(folder.children.count == 1 ? "" : "s") inside it."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        contextNode = nil
        ConfigStore.shared.update { $0.deleteBookmarkFolder(named: name) }
    }

    private func activateSelection() {
        guard outline.selectedRow >= 0, let node = node(outline.item(atRow: outline.selectedRow)) else { return }
        if let url = node.url { onOpen?(url) }
        else { outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node) }
    }

    @objc private func createFolder() {
        let alert = NSAlert()
        alert.messageText = "New Bookmark Folder"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Folder name"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "–")
        guard !name.isEmpty else { return }
        ConfigStore.shared.update { if !$0.bookmarkFolders.contains(name) { $0.bookmarkFolders.append(name) } }
        reload(focus: true)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let key = node(item)?.storageKey else { return nil }
        return NSString(string: key)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let target = node(item), target.url == nil else { return [] }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = node(item), folder.url == nil,
              let oldKey = info.draggingPasteboard.string(forType: .string),
              let value = ConfigStore.shared.config.bookmarks[oldKey] else { return false }
        let leaf = oldKey.split(separator: "/", maxSplits: 1).last.map(String.init) ?? oldKey
        let newKey = "\(folder.title)/\(leaf)"
        ConfigStore.shared.update { config in
            config.bookmarks.removeValue(forKey: oldKey)
            config.bookmarks[newKey] = value
        }
        reload()
        return true
    }
}
