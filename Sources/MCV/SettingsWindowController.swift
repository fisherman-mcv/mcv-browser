import AppKit

final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(browser: BrowserWindowController, onInstallExtension: @escaping () -> Void,
         onExtensionsChanged: @escaping () -> Void) {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "MCV Settings"
        window.center()
        super.init(window: window)

        tabs.tabStyle = .toolbar
        tabs.addChild(GeneralSettingsViewController(browser: browser))
        tabs.addChild(PrivacySettingsViewController())
        tabs.addChild(ExtensionsSettingsViewController(onInstall: onInstallExtension,
                                                        onChanged: onExtensionsChanged))
        let symbols = ["gearshape", "hand.raised", "puzzlepiece.extension"]
        for (item, symbol) in zip(tabs.tabViewItems, symbols) {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        window.contentViewController = tabs
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show() {
        (tabs.children.first { $0 is ExtensionsSettingsViewController } as? ExtensionsSettingsViewController)?.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func selectExtensions() { tabs.selectedTabViewItemIndex = 2 }
}

private class SettingsPaneViewController: NSViewController {
    let stack = NSStackView()

    override func loadView() {
        view = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = .init(top: 28, left: 30, bottom: 28, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
    }

    func heading(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(label)
    }

    func formRow(_ title: String, _ control: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60).isActive = true
    }
}

private final class GeneralSettingsViewController: SettingsPaneViewController {
    private weak var browser: BrowserWindowController?
    private let search = NSPopUpButton()
    private let homepage = NSTextField()
    private let theme = NSSegmentedControl(labels: ["System", "Dark", "Light"], trackingMode: .selectOne,
                                            target: nil, action: nil)
    private let opacity = NSSlider(value: 1, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    private let restore = NSButton(checkboxWithTitle: "Restore tabs after restart", target: nil, action: nil)
    private let sidebar = NSButton(checkboxWithTitle: "Use favicon sidebar", target: nil, action: nil)
    private let defaultBrowser = NSButton(title: "Make Default", target: nil, action: nil)

    init(browser: BrowserWindowController) {
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        heading("General")
        let names = ["g": "Google", "ddg": "DuckDuckGo", "yt": "YouTube", "wiki": "Wikipedia",
                     "gh": "GitHub", "so": "Stack Overflow", "npm": "npm", "mdn": "MDN"]
        for id in ["g", "ddg", "yt", "wiki", "gh", "so", "npm", "mdn"] {
            search.addItem(withTitle: names[id] ?? id)
            search.lastItem?.representedObject = id
        }
        let config = ConfigStore.shared.config
        search.selectItem(where: { ($0.representedObject as? String) == config.searchEngine })
        search.target = self; search.action = #selector(searchChanged)
        formRow("Default search engine", search)

        defaultBrowser.target = self
        defaultBrowser.action = #selector(makeDefaultBrowser)
        updateDefaultBrowserButton()
        formRow("Default browser", defaultBrowser)

        homepage.stringValue = config.homepage
        homepage.placeholderString = "https://example.com"
        homepage.target = self; homepage.action = #selector(homepageChanged)
        formRow("Home command page", homepage)

        theme.selectedSegment = config.theme == "dark" ? 1 : (config.theme == "light" ? 2 : 0)
        theme.target = self; theme.action = #selector(themeChanged)
        formRow("Appearance", theme)

        opacity.doubleValue = config.windowOpacity
        opacity.isContinuous = true
        opacity.target = self; opacity.action = #selector(opacityChanged)
        formRow("Window opacity", opacity)

        restore.state = config.restoreSession ? .on : .off
        restore.target = self; restore.action = #selector(restoreChanged)
        stack.addArrangedSubview(restore)
        sidebar.state = config.sidebarMode ? .on : .off
        sidebar.target = self; sidebar.action = #selector(sidebarChanged)
        stack.addArrangedSubview(sidebar)
    }

    @objc private func searchChanged() {
        guard let id = search.selectedItem?.representedObject as? String else { return }
        ConfigStore.shared.update { $0.searchEngine = id }
    }
    @objc private func homepageChanged() { ConfigStore.shared.update { $0.homepage = homepage.stringValue } }
    @objc private func themeChanged() {
        browser?.applyTheme(mode: ["system", "dark", "light"][theme.selectedSegment])
    }
    @objc private func opacityChanged() { browser?.setWindowOpacity(opacity.doubleValue) }
    @objc private func restoreChanged() { ConfigStore.shared.update { $0.restoreSession = restore.state == .on } }
    @objc private func sidebarChanged() { browser?.setSidebarMode(sidebar.state == .on) }
    @objc private func makeDefaultBrowser() {
        defaultBrowser.isEnabled = false
        defaultBrowser.title = "Requesting…"
        DefaultBrowserManager.makeDefault { [weak self] error in
            guard let self else { return }
            self.updateDefaultBrowserButton()
            if let error { self.browser?.toast("Could not set default browser · \(error.localizedDescription)") }
            else { self.browser?.toast("MCV is now the default browser") }
        }
    }

    private func updateDefaultBrowserButton() {
        let isDefault = DefaultBrowserManager.isDefault
        defaultBrowser.title = isDefault ? "MCV is Default" : "Make Default"
        defaultBrowser.isEnabled = !isDefault
    }
}

private final class PrivacySettingsViewController: SettingsPaneViewController {
    private let mode = NSPopUpButton()
    private let javascript = NSButton(checkboxWithTitle: "Allow JavaScript", target: nil, action: nil)
    private let semanticMemory = NSButton(checkboxWithTitle: "Build local Semantic Memory Graph", target: nil, action: nil)

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        title = "Privacy"
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        heading("Privacy & Security")
        for item in SecurityMode.allCases {
            mode.addItem(withTitle: item.label.capitalized)
            mode.lastItem?.representedObject = item.rawValue
        }
        mode.selectItem(where: { ($0.representedObject as? String) == SecurityManager.shared.mode.rawValue })
        mode.target = self; mode.action = #selector(modeChanged)
        formRow("Protection mode", mode)
        javascript.state = SecurityManager.shared.javascriptEnabled ? .on : .off
        javascript.target = self; javascript.action = #selector(jsChanged)
        stack.addArrangedSubview(javascript)
        semanticMemory.state = ConfigStore.shared.config.semanticMemory ? .on : .off
        semanticMemory.target = self; semanticMemory.action = #selector(memoryChanged)
        stack.addArrangedSubview(semanticMemory)
        let note = NSTextField(wrappingLabelWithString: "Changes apply to new navigations. Secure mode always disables page JavaScript. Private tabs use an isolated, non-persistent WebKit data store.")
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 0
        note.widthAnchor.constraint(equalToConstant: 610).isActive = true
        stack.addArrangedSubview(note)
    }

    @objc private func modeChanged() {
        guard let raw = mode.selectedItem?.representedObject as? String,
              let value = SecurityMode(rawValue: raw) else { return }
        SecurityManager.shared.setMode(value)
    }
    @objc private func jsChanged() { SecurityManager.shared.setJavaScript(javascript.state == .on) }
    @objc private func memoryChanged() { ConfigStore.shared.update { $0.semanticMemory = semanticMemory.state == .on } }
}

private final class ExtensionsSettingsViewController: SettingsPaneViewController {
    private let rows = NSStackView()
    private let onInstall: () -> Void
    private let onChanged: () -> Void

    init(onInstall: @escaping () -> Void, onChanged: @escaping () -> Void) {
        self.onInstall = onInstall; self.onChanged = onChanged
        super.init(nibName: nil, bundle: nil)
        title = "Extensions"
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let header = NSStackView()
        header.orientation = .horizontal
        let title = NSTextField(labelWithString: "Extensions")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let install = NSButton(title: "Install…", target: self, action: #selector(installTapped))
        header.addArrangedSubview(title); header.addArrangedSubview(NSView()); header.addArrangedSubview(install)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60).isActive = true
        rows.orientation = .vertical; rows.alignment = .width; rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = rows
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -60).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 410).isActive = true
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let extensions = MCVExtensionRuntime.shared.allExtensions().sorted {
            $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
        }
        if extensions.isEmpty {
            let empty = NSTextField(labelWithString: "No extensions installed")
            empty.textColor = .secondaryLabelColor; rows.addArrangedSubview(empty); return
        }
        for item in extensions {
            let row = ExtensionSettingsRow(item: item)
            row.onToggle = { [weak self] enabled in
                MCVExtensionRuntime.shared.setEnabled(enabled, id: item.id); self?.onChanged()
            }
            row.onOptions = { MCVExtensionRuntime.shared.showOptions(extensionID: item.id) }
            row.onPopup = { MCVExtensionRuntime.shared.showPopup(extensionID: item.id) }
            row.onRemove = { [weak self] in
                let alert = NSAlert(); alert.messageText = "Remove \(item.manifest.name)?"
                alert.informativeText = "The extension and its local files will be deleted."
                alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                MCVExtensionRuntime.shared.uninstall(id: item.id); self?.onChanged(); self?.reload()
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    @objc private func installTapped() { onInstall(); reload(); onChanged() }
}

private final class ExtensionSettingsRow: NSView {
    var onToggle: ((Bool) -> Void)?; var onPopup: (() -> Void)?; var onOptions: (() -> Void)?; var onRemove: (() -> Void)?
    private let enabled = NSSwitch()

    init(item: InstalledExtension) {
        super.init(frame: .zero); wantsLayer = true; layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.65).cgColor
        let name = NSTextField(labelWithString: item.manifest.name)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        let details = NSTextField(labelWithString: "v\(item.manifest.version) · MV\(item.manifest.manifestVersion) · \(item.grantedPermissions.count) permissions")
        details.textColor = .secondaryLabelColor; details.font = .systemFont(ofSize: 11)
        let labels = NSStackView(views: [name, details]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 2
        enabled.state = item.enabled ? .on : .off; enabled.target = self; enabled.action = #selector(toggle)
        let popup = NSButton(title: "Popup", target: self, action: #selector(openPopup))
        let options = NSButton(title: "Options", target: self, action: #selector(openOptions))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeTapped)); remove.hasDestructiveAction = true
        let row = NSStackView(views: [labels, NSView(), popup, options, remove, enabled])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), row.topAnchor.constraint(equalTo: topAnchor, constant: 10), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)])
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    @objc private func toggle() { onToggle?(enabled.state == .on) }
    @objc private func openPopup() { onPopup?() }
    @objc private func openOptions() { onOptions?() }
    @objc private func removeTapped() { onRemove?() }
}

private extension NSPopUpButton {
    func selectItem(where predicate: (NSMenuItem) -> Bool) {
        if let item = itemArray.first(where: predicate) { select(item) }
    }
}
