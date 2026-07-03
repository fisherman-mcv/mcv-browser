import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController!
    private let engine = CommandEngine()
    private let mini = MiniMCVController()
    private var onboarding: OnboardingWindowController?

    private var sessionFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mcv/session.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ConfigStore.shared.config
        NSApp.appearance = NSAppearance(named: config.theme == "light" ? .aqua : .darkAqua)

        windowController = BrowserWindowController()
        engine.browser = windowController
        windowController.engine = engine

        SecurityManager.shared.bootstrap()

        buildMenu(shortcuts: config.shortcuts)
        registerMiniHotKey(config.shortcuts["miniMCV"] ?? "alt+space")

        mini.onSubmit = { [weak self] text in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.engine.execute(text, preferNewTab: true)
            self.windowController.window.makeKeyAndOrderFront(nil)
        }

        let restored = config.restoreSession ? loadSessionURLs() : []
        let launchBrowser: () -> Void = { [weak self] in
            self?.windowController.start(homepage: ConfigStore.shared.config.homepage, restored: restored)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        guard ConfigStore.shared.config.restoreSession, let windowController else { return }
        saveSessionURLs(windowController.tabManager.sessionURLs)
    }

    private func loadSessionURLs() -> [URL] {
        guard let data = try? Data(contentsOf: sessionFileURL),
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

    /// Парсер шорткатів формату "cmd+e", "alt+space", "ctrl+shift+k".
    private struct Shortcut {
        let keyEquivalent: String
        let mask: NSEvent.ModifierFlags
        let carbonKey: UInt32?
        let carbonMods: UInt32

        static let carbonCodes: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            " ": 49,
        ]

        static func parse(_ raw: String) -> Shortcut? {
            var mask: NSEvent.ModifierFlags = []
            var carbonMods: UInt32 = 0
            var key = ""
            for part in raw.lowercased().split(separator: "+").map(String.init) {
                switch part {
                case "cmd", "command", "meta":
                    mask.insert(.command); carbonMods |= UInt32(cmdKey)
                case "ctrl", "control":
                    mask.insert(.control); carbonMods |= UInt32(controlKey)
                case "alt", "option", "opt":
                    mask.insert(.option); carbonMods |= UInt32(optionKey)
                case "shift":
                    mask.insert(.shift); carbonMods |= UInt32(shiftKey)
                case "space":
                    key = " "
                default:
                    key = part
                }
            }
            guard !key.isEmpty else { return nil }
            return Shortcut(keyEquivalent: key, mask: mask,
                            carbonKey: carbonCodes[key], carbonMods: carbonMods)
        }
    }

    private func registerMiniHotKey(_ raw: String) {
        guard let shortcut = Shortcut.parse(raw), let keyCode = shortcut.carbonKey else { return }
        GlobalHotKey.shared.onPressed = { [weak self] in self?.mini.toggle() }
        GlobalHotKey.shared.register(keyCode: keyCode, carbonModifiers: shortcut.carbonMods)
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
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(actSettings), fallbackKey: ","))
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
        navMenu.addItem(item("Focus Address", #selector(actFocusAddress), shortcutName: "focusAddress", fallbackKey: "l"))
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
        viewMenu.addItem(item("Minimal Mode", #selector(actMinimal), shortcutName: "minimalMode", fallbackKey: "m"))
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
        tabsMenu.addItem(item("Pin/Unpin Tab", #selector(actPin), fallbackKey: ""))
        tabsMenu.addItem(item("Page Load Speed", #selector(actSpeed), fallbackKey: ""))
        tabsMenu.addItem(.separator())
        for n in 1...9 {
            let tabItem = NSMenuItem(title: "Tab \(n)", action: #selector(actSelectTab(_:)), keyEquivalent: "\(n)")
            tabItem.tag = n - 1
            tabsMenu.addItem(tabItem)
        }
        let tabsItem = NSMenuItem()
        tabsItem.submenu = tabsMenu
        mainMenu.addItem(tabsItem)

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
        toolsMenu.addItem(item("Command Palette", #selector(actPalette), shortcutName: "commandPalette", fallbackKey: "e"))
        toolsMenu.addItem(item("Mini MCV", #selector(actMini), fallbackKey: ""))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(item("Bookmarks", #selector(actBookmarksList), fallbackKey: "b", fallbackMask: [.command, .option]))
        toolsMenu.addItem(item("QR Code for Page", #selector(actQR), fallbackKey: ""))
        toolsMenu.addItem(item("Downloads", #selector(actDownloads), fallbackKey: "j"))
        toolsMenu.addItem(item("Restore Last Session", #selector(actRestore), fallbackKey: ""))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(item("Help", #selector(actHelp), fallbackKey: ""))
        let toolsItem = NSMenuItem()
        toolsItem.submenu = toolsMenu
        mainMenu.addItem(toolsItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu actions

    @objc private func actNewTab() { windowController.openNewTab() }
    @objc private func actDup() { windowController.duplicateTab() }
    @objc private func actPrivate() { windowController.openPrivateTab() }
    @objc private func actPin() { windowController.togglePinCurrentTab() }
    @objc private func actSpeed() { windowController.showLoadSpeed() }
    @objc private func actCloseTab() { windowController.closeCurrentTab() }
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
    @objc private func actMini() { mini.toggle() }
    @objc private func actFocusAddress() { windowController.focusCommand() }
    @objc private func actFind() { windowController.focusCommand(prefill: "find ") }
    @objc private func actCopyURL() { engine.execute("copyurl") }
    @objc private func actCopyTitle() { engine.execute("copytitle") }
    @objc private func actBookmark() { engine.execute("bm add") }
    @objc private func actBookmarksList() { engine.execute("bm") }
    @objc private func actQR() { windowController.showQRCode() }
    @objc private func actDownloads() { windowController.toggleDownloadsSidebar() }
    @objc private func actPrint() { windowController.printPage() }
    @objc private func actPDF() { windowController.exportPDF() }
    @objc private func actShot() { windowController.snapshotPage() }
    @objc private func actRestore() { windowController.restoreLastSession() }
    @objc private func actClear() { windowController.clearBrowsingData() }
    @objc private func actClearHistory() { windowController.clearHistory() }
    @objc private func actHelp() { engine.execute("help") }
    @objc private func actSettings() { engine.execute("open file://" + FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".mcv/config.json").path) }

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
        windowController.selectTab(index: sender.tag)
    }

    private func currentOpacityPct(_ delta: Int) -> Int {
        let current = Int(ConfigStore.shared.config.windowOpacity * 100)
        return min(100, max(30, current + delta))
    }
}
