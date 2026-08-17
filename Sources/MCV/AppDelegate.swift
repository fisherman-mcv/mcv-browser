import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController!
    private let engine = CommandEngine()
    private var onboarding: OnboardingWindowController?
    private var chromeWebStoreDownloads: Set<String> = []
    private var resourceController: ResourcePressureController?
    private var settingsController: SettingsWindowController?
    private var pendingExternalURLs: [URL] = []
    private var browserStarted = false

    private var sessionFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mcv/session.json")
    }
    private var pinnedTabsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mcv/pinned-tabs.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Starts scheduled checks only in release bundles containing a real
        // HTTPS appcast and EdDSA public key. Placeholder developer builds stay dormant.
        Task { @MainActor in _ = UpdateController.shared }
        let config = ConfigStore.shared.config
        Theme.apply(mode: config.theme)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        windowController = BrowserWindowController()
        windowController.onSettingsRequest = { [weak self] in
            self?.showSettings(selectExtensions: false)
        }
        resourceController = ResourcePressureController(tabManager: windowController.tabManager)
        resourceController?.start()
        engine.browser = windowController
        windowController.engine = engine

        SecurityManager.shared.bootstrap()
        MCVExtensionRuntime.shared.host = windowController
        MCVExtensionRuntime.shared.onChromeWebStoreInstall = { [weak self] id in
            self?.installFromChromeWebStore(extensionID: id)
        }
        MCVExtensionRuntime.shared.bootstrap()

        buildMenu(shortcuts: config.shortcuts)

        let restored = config.restoreSession ? loadSessionURLs() : []
        let pinned = loadPinnedTabURLs()
        let launchBrowser: () -> Void = { [weak self] in
            guard let self else { return }
            self.windowController.start(homepage: ConfigStore.shared.config.homepage, restored: restored, pinned: pinned)
            self.browserStarted = true
            self.openPendingExternalURLs()
        }

        if config.hasCompletedOnboarding {
            launchBrowser()
        } else {
            let onboarding = OnboardingWindowController()
            onboarding.onFinish = launchBrowser
            self.onboarding = onboarding
            onboarding.present()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        let webURLs = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
        guard !webURLs.isEmpty else { return }
        pendingExternalURLs.append(contentsOf: webURLs)
        if browserStarted { openPendingExternalURLs() }
    }

    private func openPendingExternalURLs() {
        guard browserStarted, !pendingExternalURLs.isEmpty else { return }
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll(keepingCapacity: true)
        urls.forEach { windowController.navigate(to: $0, newTab: true) }
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController.reopenWindowWithBlankTab() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard ConfigStore.shared.config.restoreSession, let windowController else { return }
        saveSessionURLs(windowController.tabManager.sessionURLs)
    }

    @objc private func systemAppearanceChanged() {
        guard ConfigStore.shared.config.theme == "system" else { return }
        DispatchQueue.main.async { Theme.apply(mode: "system") }
    }

    private func loadSessionURLs() -> [URL] {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return raw.compactMap(URL.init(string:))
    }

    private func loadPinnedTabURLs() -> [URL] {
        guard let data = try? Data(contentsOf: pinnedTabsFileURL),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return raw.compactMap(URL.init(string:))
    }

    private func saveSessionURLs(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: sessionFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(urls) {
            try? data.write(to: sessionFileURL)
        }
    }

    // MARK: - Shortcuts

    /// Парсер шорткатів формату "cmd+e", "ctrl+shift+k".
    private struct Shortcut {
        let keyEquivalent: String
        let mask: NSEvent.ModifierFlags

        static func parse(_ raw: String) -> Shortcut? {
            var mask: NSEvent.ModifierFlags = []
            var key = ""
            for part in raw.lowercased().split(separator: "+").map(String.init) {
                switch part {
                case "cmd", "command", "meta":
                    mask.insert(.command)
                case "ctrl", "control":
                    mask.insert(.control)
                case "alt", "option", "opt":
                    mask.insert(.option)
                case "shift":
                    mask.insert(.shift)
                case "space":
                    key = " "
                default:
                    key = part
                }
            }
            guard !key.isEmpty else { return nil }
            return Shortcut(keyEquivalent: key, mask: mask)
        }
    }

    // MARK: - Menu

    private func buildMenu(shortcuts: [String: String]) {
        func item(_ title: String, _ action: Selector?, shortcutName: String? = nil,
                  fallbackKey: String = "", fallbackMask: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: fallbackKey)
            menuItem.keyEquivalentModifierMask = fallbackMask
            if let name = shortcutName, let raw = shortcuts[name], let sc = Shortcut.parse(raw) {
                menuItem.keyEquivalent = sc.keyEquivalent
                menuItem.keyEquivalentModifierMask = sc.mask
            }
            return menuItem
        }

        let mainMenu = NSMenu()

        // MCV
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MCV Browser",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(item("Check for Updates…", #selector(actCheckForUpdates), fallbackKey: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(actSettings), fallbackKey: ","))
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide MCV", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MCV", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("New Tab", #selector(actNewTab), shortcutName: "newTab", fallbackKey: "t"))
        fileMenu.addItem(item("New Private Tab", #selector(actPrivate), fallbackKey: "n", fallbackMask: [.command, .shift]))
        fileMenu.addItem(item("Duplicate Tab", #selector(actDup), fallbackKey: "d", fallbackMask: [.command, .option]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Close Tab", #selector(actCloseTab), shortcutName: "closeTab", fallbackKey: "w"))
        fileMenu.addItem(item("Close Other Tabs", #selector(actOnly), fallbackKey: "o", fallbackMask: [.command, .option]))
        fileMenu.addItem(item("Reopen Closed Tab", #selector(actReopen), fallbackKey: "t", fallbackMask: [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Save Page as PDF", #selector(actPDF), fallbackKey: "p", fallbackMask: [.command, .option]))
        fileMenu.addItem(item("Save Screenshot", #selector(actShot), fallbackKey: ""))
        fileMenu.addItem(item("Print…", #selector(actPrint), fallbackKey: "p", fallbackMask: [.command, .shift]))
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit — стандартні селектори, без них не працюють ⌘C/⌘V у полях вводу
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Find on Page…", #selector(actFind), fallbackKey: "f"))
        editMenu.addItem(item("Copy Address", #selector(actCopyURL), fallbackKey: "c", fallbackMask: [.command, .shift]))
        editMenu.addItem(item("Copy Title", #selector(actCopyTitle), fallbackKey: ""))
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Navigate
        let navMenu = NSMenu(title: "Navigate")
        navMenu.addItem(item("Back", #selector(actBack), fallbackKey: "["))
        navMenu.addItem(item("Forward", #selector(actForward), fallbackKey: "]"))
        navMenu.addItem(item("Home", #selector(actHome), fallbackKey: "h", fallbackMask: [.command, .shift]))
        navMenu.addItem(item("Reload", #selector(actReload), shortcutName: "reload", fallbackKey: "r"))
        navMenu.addItem(item("URL / Command Bar", #selector(actFocusAddress), shortcutName: "focusAddress", fallbackKey: "l"))
        navMenu.addItem(.separator())
        navMenu.addItem(item("Scroll to Top", #selector(actTop), fallbackKey: ""))
        navMenu.addItem(item("Scroll to Bottom", #selector(actBottom), fallbackKey: ""))
        navMenu.addItem(.separator())
        let reader = item("Reader Mode", #selector(actReader), fallbackKey: "r")
        reader.keyEquivalentModifierMask = [.command, .shift]
        navMenu.addItem(reader)
        navMenu.addItem(item("View Source", #selector(actSource), fallbackKey: "u", fallbackMask: [.command, .option]))
        navMenu.addItem(item("Show History", #selector(actHistory), fallbackKey: "y", fallbackMask: [.command, .shift]))
        navMenu.addItem(.separator())
        navMenu.addItem(item("Add Bookmark", #selector(actBookmark), fallbackKey: "d"))
        let navItem = NSMenuItem()
        navItem.submenu = navMenu
        mainMenu.addItem(navItem)

        // View
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Minimal Mode", #selector(actMinimal), shortcutName: "minimalMode", fallbackKey: "m", fallbackMask: [.command, .shift]))
        viewMenu.addItem(item("Sidebar Mode", #selector(actSidebarMode), fallbackKey: "s", fallbackMask: [.command, .shift]))
        viewMenu.addItem(item("Full Screen", #selector(actFullscreen), fallbackKey: "f", fallbackMask: [.command, .control]))
        viewMenu.addItem(item("Float on Top", #selector(actFloat), fallbackKey: "f", fallbackMask: [.command, .option]))
        viewMenu.addItem(.separator())
        let theme = item("Toggle Dark/Light", #selector(actToggleTheme), fallbackKey: "d")
        theme.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(theme)
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Zoom In", #selector(actZoomIn), fallbackKey: "="))
        viewMenu.addItem(item("Zoom Out", #selector(actZoomOut), fallbackKey: "-"))
        viewMenu.addItem(item("Actual Size", #selector(actZoomReset), fallbackKey: "0"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Increase Opacity", #selector(actOpacityUp), fallbackKey: "]", fallbackMask: [.command, .option]))
        viewMenu.addItem(item("Decrease Opacity", #selector(actOpacityDown), fallbackKey: "[", fallbackMask: [.command, .option]))
        let viewItem = NSMenuItem()
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Tabs
        let tabsMenu = NSMenu(title: "Tabs")
        tabsMenu.addItem(item("Tab Switcher", #selector(actSwitcher), shortcutName: "tabSwitcher", fallbackKey: "p"))
        tabsMenu.addItem(item("Next Tab", #selector(actNextTab), fallbackKey: "]", fallbackMask: [.command, .shift]))
        tabsMenu.addItem(item("Previous Tab", #selector(actPrevTab), fallbackKey: "[", fallbackMask: [.command, .shift]))
        tabsMenu.addItem(.separator())
        tabsMenu.addItem(item("Pin/Unpin Tab", #selector(actPin), shortcutName: "pinTab", fallbackKey: "p"))
        tabsMenu.addItem(item("Page Load Speed", #selector(actSpeed), fallbackKey: ""))
        tabsMenu.addItem(.separator())
        for n in 1...9 {
            let tabItem = NSMenuItem(title: n == 9 ? "Last Tab" : "Tab \(n)",
                                     action: #selector(actSelectTab(_:)), keyEquivalent: "\(n)")
            tabItem.tag = n
            tabsMenu.addItem(tabItem)
        }
        let tabsItem = NSMenuItem()
        tabsItem.submenu = tabsMenu
        mainMenu.addItem(tabsItem)

        // Window — стандартний macOS-набір (Minimize/Zoom/Bring All to Front), сюди ж
        // AppKit сам дописує список вікон та ⌘` перемикання, коли `NSApp.windowsMenu`
        // вказує на це меню (те саме, що й у звичайних macOS-застосунків).
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        // Security
        let secMenu = NSMenu(title: "Security")
        secMenu.addItem(item("Classic Mode", #selector(actModeClassic), fallbackKey: ""))
        secMenu.addItem(item("Safe Mode", #selector(actModeSafe), fallbackKey: ""))
        secMenu.addItem(item("Secure Mode", #selector(actModeSecure), fallbackKey: ""))
        secMenu.addItem(.separator())
        secMenu.addItem(item("Toggle JavaScript", #selector(actToggleJS), fallbackKey: "j", fallbackMask: [.command, .option]))
        secMenu.addItem(item("Clear Browsing Data…", #selector(actClear), fallbackKey: ""))
        secMenu.addItem(item("Clear History…", #selector(actClearHistory), fallbackKey: ""))
        let secItem = NSMenuItem()
        secItem.submenu = secMenu
        mainMenu.addItem(secItem)

        // Tools
        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.addItem(item("URL / Command Bar", #selector(actPalette), shortcutName: "commandPalette", fallbackKey: "e"))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(item("Bookmarks", #selector(actBookmarksList), fallbackKey: "b", fallbackMask: [.command, .option]))
        toolsMenu.addItem(item("Bookmarks Sidebar", #selector(actBookmarksSidebar), fallbackKey: "d", fallbackMask: [.control]))
        toolsMenu.addItem(item("QR Code for Page", #selector(actQR), fallbackKey: ""))
        toolsMenu.addItem(item("Downloads", #selector(actDownloads), fallbackKey: "j"))
        toolsMenu.addItem(item("Restore Last Session", #selector(actRestore), fallbackKey: ""))
        toolsMenu.addItem(.separator())
        let intelligenceMenu = NSMenu(title: "Web Intelligence")
        for (title, command) in [
            ("Semantic Page Model", "page"), ("Personal Web API", "api"),
            ("App Reader", "ui"), ("Research All Tabs", "research"),
            ("Memory Graph", "memory"), ("Intent-aware Tabs", "tabs"),
            ("Toggle Attention Firewall", "focus"), ("Forensic Page Check", "scam"),
            ("Select Element for AI DevTools", "inspect"), ("AI DevTools", "debug"),
            ("Runtime Status", "status")
        ] {
            let action = NSMenuItem(title: title, action: #selector(actAICommand(_:)), keyEquivalent: "")
            action.representedObject = command
            intelligenceMenu.addItem(action)
        }
        let intelligenceItem = NSMenuItem(title: "Web Intelligence", action: nil, keyEquivalent: "")
        intelligenceItem.submenu = intelligenceMenu
        toolsMenu.addItem(intelligenceItem)
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(item("Install Chrome Extension…", #selector(actInstallExtension), fallbackKey: ""))
        toolsMenu.addItem(item("Manage Extensions", #selector(actManageExtensions), fallbackKey: ""))
        let uninstallMenu = NSMenu(title: "Uninstall Extension")
        let installedExtensions = MCVExtensionRuntime.shared.allExtensions()
        if installedExtensions.isEmpty {
            let empty = NSMenuItem(title: "No installed extensions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            uninstallMenu.addItem(empty)
        } else {
            for ext in installedExtensions.sorted(by: { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }) {
                let remove = NSMenuItem(title: ext.manifest.name, action: #selector(actUninstallExtension(_:)), keyEquivalent: "")
                remove.representedObject = ext.id
                uninstallMenu.addItem(remove)
            }
        }
        let uninstallItem = NSMenuItem(title: "Uninstall Extension", action: nil, keyEquivalent: "")
        uninstallItem.submenu = uninstallMenu
        toolsMenu.addItem(uninstallItem)
        let extensionMenu = NSMenu(title: "Extension Actions")
        for (index, ext) in MCVExtensionRuntime.shared.allExtensions().enumerated() where ext.enabled {
            let popup = NSMenuItem(title: ext.manifest.name, action: #selector(actExtensionPopup(_:)), keyEquivalent: "")
            popup.representedObject = ext.id; popup.tag = index; extensionMenu.addItem(popup)
            for command in MCVExtensionRuntime.shared.commandNames(extensionID: ext.id) {
                let commandItem = NSMenuItem(title: "\(ext.manifest.name): \(command)", action: #selector(actExtensionCommand(_:)), keyEquivalent: "")
                commandItem.representedObject = ["id": ext.id, "command": command]
                extensionMenu.addItem(commandItem)
            }
        }
        let extensionItem = NSMenuItem(title: "Extension Actions", action: nil, keyEquivalent: "")
        extensionItem.submenu = extensionMenu; toolsMenu.addItem(extensionItem)
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(item("Help", #selector(actHelp), fallbackKey: ""))
        let toolsItem = NSMenuItem()
        toolsItem.submenu = toolsMenu
        mainMenu.addItem(toolsItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu actions

    @objc private func actNewTab() { windowController.openNewTab() }
    @objc private func actCheckForUpdates() {
        Task { @MainActor in UpdateController.shared.checkForUpdates() }
    }
    @objc private func actDup() { windowController.duplicateTab() }
    @objc private func actPrivate() { windowController.openPrivateTab() }
    @objc private func actPin() { windowController.togglePinCurrentTab() }
    @objc private func actSpeed() { windowController.showLoadSpeed() }
    @objc private func actCloseTab() {
        // ⌘W follows the active macOS window. Only the main browser window
        // interprets it as Close Tab; Settings/popups close themselves.
        if let keyWindow = NSApp.keyWindow, keyWindow !== windowController.window {
            keyWindow.performClose(nil)
        } else {
            windowController.closeCurrentTab()
        }
    }
    @objc private func actOnly() { windowController.closeOtherTabs() }
    @objc private func actReopen() { windowController.reopenClosedTab() }
    @objc private func actBack() { windowController.goBack() }
    @objc private func actForward() { windowController.goForward() }
    @objc private func actHome() { engine.execute("home") }
    @objc private func actReload() { windowController.reloadPage() }
    @objc private func actReader() { windowController.activateReader() }
    @objc private func actSource() { windowController.viewSource() }
    @objc private func actHistory() { windowController.showHistoryPage() }
    @objc private func actTop() { windowController.scrollToTop() }
    @objc private func actBottom() { windowController.scrollToBottom() }
    @objc private func actMinimal() { windowController.toggleMinimalMode() }
    @objc private func actSidebarMode() { windowController.toggleSidebarMode() }
    @objc private func actFullscreen() { windowController.toggleFullscreen() }
    @objc private func actFloat() { windowController.toggleFloatOnTop() }
    @objc private func actPalette() { windowController.showCommandPalette() }
    @objc private func actSwitcher() { windowController.showTabSwitcher() }
    @objc private func actNextTab() { windowController.nextTab() }
    @objc private func actPrevTab() { windowController.previousTab() }
    @objc private func actFocusAddress() { windowController.showCommandPalette() }
    @objc private func actFind() { windowController.focusCommand(prefill: "find ") }
    @objc private func actCopyURL() { engine.execute("copyurl") }
    @objc private func actCopyTitle() { engine.execute("copytitle") }
    @objc private func actBookmark() { engine.execute("bm add") }
    @objc private func actBookmarksList() { engine.execute("bm") }
    @objc private func actBookmarksSidebar() { windowController.toggleBookmarksSidebar() }
    @objc private func actQR() { windowController.showQRCode() }
    @objc private func actDownloads() { windowController.toggleDownloadsSidebar() }
    @objc private func actPrint() { windowController.printPage() }
    @objc private func actPDF() { windowController.exportPDF() }
    @objc private func actShot() { windowController.snapshotPage() }
    @objc private func actRestore() { windowController.restoreLastSession() }
    @objc private func actClear() { windowController.clearBrowsingData() }
    @objc private func actClearHistory() { windowController.clearHistory() }
    @objc private func actHelp() { engine.execute("help") }
    @objc private func actAICommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        windowController.runAI(command)
    }
    @objc private func actExtensionPopup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        MCVExtensionRuntime.shared.showPopup(extensionID: id)
    }
    @objc private func actExtensionCommand(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String: String], let id = value["id"], let command = value["command"] else { return }
        MCVExtensionRuntime.shared.dispatchCommand(command, extensionID: id)
    }
    @objc private func actUninstallExtension(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let ext = MCVExtensionRuntime.shared.allExtensions().first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall \(ext.manifest.name)?"
        alert.informativeText = "The extension and its local settings will be permanently removed from MCV."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        MCVExtensionRuntime.shared.uninstall(id: id)
        buildMenu(shortcuts: ConfigStore.shared.config.shortcuts)
        windowController.toast("Extension removed — reopen affected tabs")
    }
    @objc private func actInstallExtension() {
        let panel = NSOpenPanel()
        panel.title = "Install Chrome-compatible Extension"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .init(filenameExtension: "crx")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let item = try MCVExtensionRuntime.shared.install(from: url)
            confirmExtensionInstall(item)
        } catch { windowController.toast("Extension install failed: \(error.localizedDescription)") }
    }

    private func installFromChromeWebStore(extensionID: String) {
        guard !chromeWebStoreDownloads.contains(extensionID),
              let url = MCVExtensionRuntime.shared.chromeWebStoreDownloadURL(extensionID: extensionID) else { return }
        chromeWebStoreDownloads.insert(extensionID)
        windowController.toast("Downloading extension from Chrome Web Store…")
        URLSession.shared.downloadTask(with: url) { [weak self] downloadedURL, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.chromeWebStoreDownloads.remove(extensionID)
                guard error == nil, let downloadedURL,
                      (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) != false else {
                    self.windowController.toast("Chrome Web Store download failed: \(error?.localizedDescription ?? "invalid response")")
                    return
                }
                let packageURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mcv-webstore-\(UUID().uuidString).crx")
                do {
                    try FileManager.default.moveItem(at: downloadedURL, to: packageURL)
                    defer { try? FileManager.default.removeItem(at: packageURL) }
                    let item = try MCVExtensionRuntime.shared.install(from: packageURL)
                    self.confirmExtensionInstall(item)
                } catch {
                    self.windowController.toast("Extension install failed: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    private func confirmExtensionInstall(_ item: InstalledExtension) {
        let permissions = item.manifest.requestedPermissions.sorted()
        let hostPermissions = permissions.filter(isHostPermission)
        let apiPermissions = permissions.filter { !isHostPermission($0) }
        let confirmation = NSAlert()
        confirmation.messageText = "Install \(item.manifest.name)?"
        var summary = "API permissions:\n" + (apiPermissions.isEmpty ? "None" : apiPermissions.joined(separator: ", "))
        if !hostPermissions.isEmpty {
            summary += "\n\nWebsite access: \(hostPermissions.count == 1 ? "1 pattern" : "\(hostPermissions.count) patterns")"
        }
        confirmation.informativeText = summary
        confirmation.alertStyle = .warning
        confirmation.addButton(withTitle: "Install")
        confirmation.addButton(withTitle: "Cancel")
        if !hostPermissions.isEmpty { confirmation.addButton(withTitle: "Domains (\(hostPermissions.count)) ›") }
        let response = confirmation.runModal()
        if response == .alertThirdButtonReturn {
            showHostPermissionDetails(hostPermissions, extensionName: item.manifest.name)
            confirmExtensionInstall(item)
            return
        }
        guard response == .alertFirstButtonReturn else {
            MCVExtensionRuntime.shared.uninstall(id: item.id)
            return
        }
        MCVExtensionRuntime.shared.approveInstall(id: item.id)
        windowController.toast("Extension installed: \(item.manifest.name) — open a new tab to activate")
        buildMenu(shortcuts: ConfigStore.shared.config.shortcuts)
    }

    private func isHostPermission(_ permission: String) -> Bool {
        permission == "<all_urls>" || permission.contains("://") || permission.hasPrefix("*.")
    }

    private func showHostPermissionDetails(_ permissions: [String], extensionName: String) {
        let details = NSAlert()
        details.messageText = "Website access — \(extensionName)"
        details.informativeText = "The extension requested access to these URL patterns:"
        details.addButton(withTitle: "Close")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = permissions.joined(separator: "\n")
        text.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = text
        details.accessoryView = scroll
        details.runModal()
    }
    @objc private func actManageExtensions() { showSettings(selectExtensions: true) }
    @objc private func actSettings() { showSettings(selectExtensions: false) }

    private func showSettings(selectExtensions: Bool) {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                browser: windowController,
                onInstallExtension: { [weak self] in self?.actInstallExtension() },
                onExtensionsChanged: { [weak self] in
                    guard let self else { return }
                    self.buildMenu(shortcuts: ConfigStore.shared.config.shortcuts)
                }
            )
        }
        settingsController?.show()
        if selectExtensions { settingsController?.selectExtensions() }
    }

    @objc private func actZoomIn() { windowController.setZoom(.increase) }
    @objc private func actZoomOut() { windowController.setZoom(.decrease) }
    @objc private func actZoomReset() { windowController.setZoom(.reset) }
    @objc private func actOpacityUp() { engine.execute("opacity \(currentOpacityPct(+10))") }
    @objc private func actOpacityDown() { engine.execute("opacity \(currentOpacityPct(-10))") }

    @objc private func actModeClassic() { SecurityManager.shared.setMode(.classic) }
    @objc private func actModeSafe() { SecurityManager.shared.setMode(.safe) }
    @objc private func actModeSecure() { SecurityManager.shared.setMode(.secure) }
    @objc private func actToggleJS() {
        SecurityManager.shared.setJavaScript(!SecurityManager.shared.javascriptEnabled)
    }

    @objc private func actToggleTheme() {
        windowController.applyTheme(dark: ConfigStore.shared.config.theme != "dark")
    }

    @objc private func actSelectTab(_ sender: NSMenuItem) {
        windowController.selectTabShortcut(number: sender.tag)
    }

    private func currentOpacityPct(_ delta: Int) -> Int {
        let current = Int(ConfigStore.shared.config.windowOpacity * 100)
        return min(100, max(30, current + delta))
    }
}
