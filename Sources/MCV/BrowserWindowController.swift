import AppKit
import WebKit
import CoreImage
import Darwin.Mach

private final class FloatingVideoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Головне вікно: скляний chrome (вкладки + командний рядок) поверх
/// напівпрозорого фону, webview — «карткою» зі скругленими кутами.
final class BrowserWindowController: NSObject, BrowserControlling, NSTextFieldDelegate {
    let window: NSWindow
    let tabManager = TabManager()
    var engine: CommandEngine?
    var onSettingsRequest: (() -> Void)?

    private let tabBar = TabBarView()
    private let commandField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let webContainer = NSView()
    private let blankNewTabView = NSVisualEffectView()
    private let baseTint = NSView()
    private var showingNativeBlank = false
    private let commandRow = NSView()
    private let palette = CommandPaletteView()
    private let switcher = TabSwitcherView()
    private let toastGlass = CardSurface(cornerRadius: 12, shadow: true)
    private let toastLabel = NSTextField(labelWithString: "")

    private var minimalMode = false
    private var toastTimer: Timer?
    private var lastFindQuery = ""
    private var webTopToChrome: NSLayoutConstraint!
    private var webTopToContent: NSLayoutConstraint!
    private var autocomplete: AddressAutocomplete!
    private var capsule: CardSurface!
    private let downloadsSidebar = DownloadsSidebarView()
    private let bookmarksSidebar = BookmarksSidebarView()
    private var webTrailingToContent: NSLayoutConstraint!
    private var webTrailingToSidebar: NSLayoutConstraint!
    private var sidebarVisible = false
    private var bookmarksSidebarVisible = false

    private let sidebarChrome = SidebarChromeView()
    private var sidebarMode = ConfigStore.shared.config.sidebarMode
    private var webLeadingToContent: NSLayoutConstraint!
    private var webLeadingToSidebarChrome: NSLayoutConstraint!
    private var webLeadingToBookmarks: NSLayoutConstraint!
    private var bookmarksLeadingToContent: NSLayoutConstraint!
    private var bookmarksLeadingToSidebarChrome: NSLayoutConstraint!
    private var pageLeadingConstraint: NSLayoutConstraint?
    private var pageTrailingConstraint: NSLayoutConstraint?
    private var pageBottomConstraint: NSLayoutConstraint?
    private var pictureInPicturePanel: NSPanel?
    private weak var pictureInPictureTab: BrowserTab?
    private var pictureInPictureCloseObserver: NSObjectProtocol?
    private weak var pictureInPicturePendingTab: BrowserTab?
    private var pictureInPicturePlaceholder: NSImageView?
    private var popupWindows: [ObjectIdentifier: (tab: BrowserTab, controller: NSWindowController, opener: ObjectIdentifier, observer: NSObjectProtocol)] = [:]
    private var popupAttempts: [ObjectIdentifier: [Date]] = [:]

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        window.title = "MCV Browser"
        window.minSize = NSSize(width: 640, height: 400)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Розмір/позиція зберігаються між запусками (стандартний AppKit-механізм,
        // окремий запис у defaults на кожну назву); без збереженого кадру — центр.
        if !window.setFrameUsingName("MCVMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("MCVMainWindow")
        buildUI()
        wireTabManager()
        wireSecurity()
        NotificationCenter.default.addObserver(self, selector: #selector(applyInterfaceColors),
                                                name: .mcvThemeChanged, object: nil)
    }

    func start(homepage: String, restored: [URL] = [], pinned: [URL] = []) {
        pinned.forEach { tabManager.newTab(url: $0, pinned: true) }
        let pinnedSet = Set(pinned.map(\.absoluteString))
        let normalTabs = restored.filter { !pinnedSet.contains($0.absoluteString) }
        if pinned.isEmpty && normalTabs.isEmpty {
            tabManager.newTab(url: nil)
        } else {
            normalTabs.forEach { tabManager.newTab(url: $0) }
            tabManager.select(at: 0)
        }
        tabManager.restoreGroups()
        window.alphaValue = ConfigStore.shared.config.windowOpacity
        window.makeKeyAndOrderFront(nil)
        applyChromeVisibility()
        updateStatus()
        if tabManager.current?.logicalURL == nil { palette.present() }
        else { focusCommand() }
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window.contentView else { return }

        // Скляна основа всього вікна — Liquid Glass. .behindWindow напряму
        // сканує робочий стіл (звідси колір шпалер крізь блюр) — усе, що
        // сидить поверх (sidebar, downloads, tab bar у класичному режимі),
        // лише додає ще блюру НАД цим кольором, тож нейтралізувати треба
        // саме тут, в одному місці, а не в кожній дочірній панелі окремо.
        let base = NSVisualEffectView()
        base.material = .hudWindow
        base.blendingMode = .behindWindow
        base.state = .active
        base.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(base)
        NSLayoutConstraint.activate([
            base.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            base.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            base.topAnchor.constraint(equalTo: content.topAnchor),
            base.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        baseTint.wantsLayer = true
        baseTint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        baseTint.translatesAutoresizingMaskIntoConstraints = false
        base.addSubview(baseTint)
        NSLayoutConstraint.activate([
            baseTint.leadingAnchor.constraint(equalTo: base.leadingAnchor),
            baseTint.trailingAnchor.constraint(equalTo: base.trailingAnchor),
            baseTint.topAnchor.constraint(equalTo: base.topAnchor),
            baseTint.bottomAnchor.constraint(equalTo: base.bottomAnchor),
        ])

        // Статус-чіп (SAFE · JS ON) — праворуч у ряду вкладок, поруч із "+".
        statusLabel.font = Theme.Typo.small
        statusLabel.textColor = Theme.textSecondary
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        content.addSubview(statusLabel)

        // Командний рядок — 56px, скруглення 16, лого-бейдж, кругла кнопка виконання.
        let logo = LogoBadge()
        let execute = ExecuteButton()
        execute.target = self
        execute.action = #selector(commandSubmitted)

        commandField.placeholderString = "Enter a URL, search, or command…"
        commandField.font = Theme.Typo.command
        commandField.textColor = Theme.textPrimary
        commandField.isBezeled = false
        commandField.drawsBackground = false
        commandField.focusRingType = .none
        commandField.delegate = self
        commandField.target = self
        commandField.action = #selector(commandSubmitted)
        commandField.translatesAutoresizingMaskIntoConstraints = false

        let capsule = CardSurface(cornerRadius: Theme.Radius.commandBar, shadow: true)
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentHost.addSubview(logo)
        capsule.contentHost.addSubview(commandField)
        capsule.contentHost.addSubview(execute)
        NSLayoutConstraint.activate([
            capsule.heightAnchor.constraint(equalToConstant: 56),
            logo.leadingAnchor.constraint(equalTo: capsule.contentHost.leadingAnchor, constant: Theme.Spacing.xl),
            logo.centerYAnchor.constraint(equalTo: capsule.contentHost.centerYAnchor),
            execute.trailingAnchor.constraint(equalTo: capsule.contentHost.trailingAnchor, constant: -Theme.Spacing.lg),
            execute.centerYAnchor.constraint(equalTo: capsule.contentHost.centerYAnchor),
            commandField.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: Theme.Spacing.md),
            commandField.trailingAnchor.constraint(equalTo: execute.leadingAnchor, constant: -Theme.Spacing.md),
            commandField.centerYAnchor.constraint(equalTo: capsule.contentHost.centerYAnchor),
        ])

        // Явні constraints замість вертикального NSStackView — той не тягне
        // дітей по ширині за замовчуванням, через що toolbar стискався до
        // мінімального розміру й «спливав» у центр вікна.
        commandRow.translatesAutoresizingMaskIntoConstraints = false
        commandRow.addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: commandRow.leadingAnchor, constant: Theme.Spacing.xl),
            capsule.trailingAnchor.constraint(equalTo: commandRow.trailingAnchor, constant: -Theme.Spacing.xl),
            capsule.topAnchor.constraint(equalTo: commandRow.topAnchor, constant: Theme.Spacing.lg),
            capsule.bottomAnchor.constraint(equalTo: commandRow.bottomAnchor, constant: -Theme.Spacing.lg),
        ])

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.wantsLayer = true
        webContainer.layer?.backgroundColor = NSColor.clear.cgColor
        webContainer.setContentHuggingPriority(.init(1), for: .vertical)

        blankNewTabView.material = .underWindowBackground
        blankNewTabView.blendingMode = .withinWindow
        blankNewTabView.state = .active
        blankNewTabView.alphaValue = 0.16

        content.addSubview(tabBar)
        content.addSubview(commandRow)
        content.addSubview(webContainer)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),

            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.Spacing.lg),
            statusLabel.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),

            commandRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            commandRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            commandRow.topAnchor.constraint(equalTo: tabBar.bottomAnchor),

            webContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // Два взаємовиключні constraints для верху webContainer: у звичайному
        // режимі — під toolbar'ом, у minimal/sidebar — впритул до краю вікна.
        webTopToChrome = webContainer.topAnchor.constraint(equalTo: commandRow.bottomAnchor)
        webTopToContent = webContainer.topAnchor.constraint(equalTo: content.topAnchor)
        webTopToChrome.isActive = true

        // Ліва скляна панель (48–56px, тільки фавіконки) — альтернативний
        // ультрамінімальний chrome, перемикається командою `sidebar on|off`.
        sidebarChrome.translatesAutoresizingMaskIntoConstraints = false
        sidebarChrome.isHidden = true
        content.addSubview(sidebarChrome)
        NSLayoutConstraint.activate([
            sidebarChrome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebarChrome.topAnchor.constraint(equalTo: content.topAnchor),
            sidebarChrome.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        webLeadingToContent = webContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        webLeadingToSidebarChrome = webContainer.leadingAnchor.constraint(equalTo: sidebarChrome.trailingAnchor)
        webLeadingToContent.isActive = true

        sidebarChrome.onSelectTab = { [weak self] index in
            self?.tabManager.select(at: index)
            DispatchQueue.main.async { self?.focusWeb() }
        }
        sidebarChrome.onCloseTab = { [weak self] index in self?.tabManager.close(at: index, forcePinned: true) }
        sidebarChrome.onDuplicateTab = { [weak self] index in
            guard let self, self.tabManager.tabs.indices.contains(index) else { return }
            self.tabManager.newTab(url: self.tabManager.tabs[index].logicalURL)
        }
        sidebarChrome.onTogglePin = { [weak self] index in
            guard let self else { return }
            self.tabManager.select(at: index)
            self.tabManager.togglePinCurrent()
        }
        sidebarChrome.onMoveTab = { [weak self] source, destination in
            self?.tabManager.moveTab(from: source, to: destination)
        }
        sidebarChrome.onGroupTabs = { [weak self] source, target in
            guard let self else { return }
            if self.tabManager.createGroup(from: source, with: target) == nil {
                self.toast("Pinned and regular tabs cannot share a group")
            }
        }
        sidebarChrome.onToggleGroup = { [weak self] id in self?.tabManager.toggleGroup(id) }
        sidebarChrome.onCloseGroup = { [weak self] id in self?.tabManager.closeGroup(id) }
        sidebarChrome.onHibernateGroup = { [weak self] id in
            guard let self else { return }
            self.toast("Group hibernated · \(self.tabManager.hibernateGroup(id)) tabs released")
        }
        sidebarChrome.onBookmarkGroup = { [weak self] id in
            guard let self else { return }
            self.toast("Bookmarked \(self.tabManager.bookmarkGroup(id)) tabs")
        }
        sidebarChrome.onColorGroup = { [weak self] id, color in self?.tabManager.setGroupColor(id, colorIndex: color) }
        sidebarChrome.onUngroup = { [weak self] id in self?.tabManager.ungroup(id) }
        sidebarChrome.onSpotlight = { [weak self] in self?.showCommandPalette() }
        sidebarChrome.onNewTab = { [weak self] in self?.openNewTab() }
        sidebarChrome.onSettings = { [weak self] in self?.onSettingsRequest?() }
        sidebarChrome.attachWindowControls(window)

        bookmarksSidebar.translatesAutoresizingMaskIntoConstraints = false
        bookmarksSidebar.isHidden = true
        content.addSubview(bookmarksSidebar)
        NSLayoutConstraint.activate([
            bookmarksSidebar.topAnchor.constraint(equalTo: content.topAnchor),
            bookmarksSidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bookmarksSidebar.widthAnchor.constraint(equalToConstant: 286),
        ])
        bookmarksLeadingToContent = bookmarksSidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        bookmarksLeadingToSidebarChrome = bookmarksSidebar.leadingAnchor.constraint(equalTo: sidebarChrome.trailingAnchor)
        bookmarksLeadingToContent.isActive = true
        webLeadingToBookmarks = webContainer.leadingAnchor.constraint(equalTo: bookmarksSidebar.trailingAnchor)
        bookmarksSidebar.onOpen = { [weak self] url in
            self?.navigate(to: url, newTab: true)
            self?.focusWeb()
        }

        // Бічна панель завантажень (320px) — за замовчуванням прихована;
        // webContainer звужується під неї, коли панель відкрита.
        downloadsSidebar.translatesAutoresizingMaskIntoConstraints = false
        downloadsSidebar.isHidden = true
        content.addSubview(downloadsSidebar)
        NSLayoutConstraint.activate([
            downloadsSidebar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            downloadsSidebar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            downloadsSidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            downloadsSidebar.widthAnchor.constraint(equalToConstant: 320),
        ])
        webTrailingToContent = webContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        webTrailingToSidebar = webContainer.trailingAnchor.constraint(equalTo: downloadsSidebar.leadingAnchor)
        webTrailingToContent.isActive = true

        // Автодоповнення адресного рядка: локальна історія/закладки одразу,
        // підказки Google/DuckDuckGo — з дебаунсом.
        autocomplete = AddressAutocomplete(
            field: commandField, anchor: capsule, container: content,
            onExecuteSearch: { [weak self] engineKey, query in
                self?.engine?.execute("\(engineKey) \(query)")
                self?.focusWeb()
            }
        )
        autocomplete.onAccept = { [weak self] text in
            self?.commandField.stringValue = text
            self?.commandField.currentEditor()?.moveToEndOfLine(nil)
        }
        autocomplete.onExecuteURL = { [weak self] url in
            self?.navigate(to: url, newTab: false)
            self?.focusWeb()
        }
        self.capsule = capsule
        applyInterfaceColors()

        // Оверлеї
        for overlay in [palette, switcher] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.isHidden = true
            content.addSubview(overlay)
        }
        NSLayoutConstraint.activate([
            palette.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            palette.topAnchor.constraint(equalTo: content.topAnchor, constant: 110),
            palette.widthAnchor.constraint(equalToConstant: 640),
            switcher.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            switcher.topAnchor.constraint(equalTo: content.topAnchor, constant: 110),
            switcher.widthAnchor.constraint(equalToConstant: 560),
        ])

        palette.onSubmit = { [weak self] text in self?.engine?.execute(text) }
        palette.onDismiss = { [weak self] in self?.focusWeb() }
        palette.onBack = { [weak self] in self?.tabManager.current?.webView.goBack() }
        palette.onForward = { [weak self] in self?.tabManager.current?.webView.goForward() }
        palette.onReload = { [weak self] in
            guard let webView = self?.tabManager.current?.webView else { return }
            if webView.isLoading { webView.stopLoading() } else { webView.reload() }
            self?.refreshPaletteNavigation()
        }
        switcher.provider = { [weak self] in
            guard let self else { return (titles: [], current: 0) }
            return (
                titles: self.tabManager.tabs.map { $0.displayTitle },
                current: self.tabManager.currentIndex
            )
        }
        switcher.onSelect = { [weak self] index in
            self?.switcher.dismiss()
            self?.tabManager.select(at: index)
            self?.focusWeb()
        }
        switcher.onCloseTab = { [weak self] index in
            self?.tabManager.close(at: index)
            self?.switcher.refreshIfVisible()
        }

        // Тост
        toastGlass.alphaValue = 0
        toastGlass.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.font = Theme.Typo.body
        toastLabel.textColor = Theme.textPrimary
        toastLabel.lineBreakMode = .byTruncatingMiddle
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastGlass.contentHost.addSubview(toastLabel)
        content.addSubview(toastGlass)
        NSLayoutConstraint.activate([
            toastLabel.leadingAnchor.constraint(equalTo: toastGlass.contentHost.leadingAnchor, constant: 16),
            toastLabel.trailingAnchor.constraint(equalTo: toastGlass.contentHost.trailingAnchor, constant: -16),
            toastLabel.topAnchor.constraint(equalTo: toastGlass.contentHost.topAnchor, constant: 9),
            toastLabel.bottomAnchor.constraint(equalTo: toastGlass.contentHost.bottomAnchor, constant: -9),
            toastGlass.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toastGlass.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
            toastGlass.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -80),
        ])
    }

    private func wireTabManager() {
        tabManager.onLayoutChange = { [weak self] in
            self?.refreshTabsUI()
            self?.attachCurrentWebView()
        }
        tabManager.onContentChange = { [weak self] in
            self?.refreshTabsUI()
            self?.syncAddressField()
            self?.refreshPaletteNavigation()
        }
        tabManager.onDownloadMessage = { [weak self] message in
            self?.toast(message)
            if message.hasPrefix("⬇"), self?.sidebarVisible == false { self?.toggleDownloadsSidebar() }
        }
        tabManager.onPictureInPictureRequest = { [weak self] tab in self?.togglePictureInPicture(for: tab) }
        tabManager.onPictureInPictureStop = { [weak self] tab in
            self?.stopPictureInPicture(for: tab)
            self?.closePopups(openedBy: tab)
        }
        tabManager.onPopupRequest = { [weak self] opener, configuration, action, features in
            self?.openSmartPopup(opener: opener, configuration: configuration, action: action, features: features)
        }
        tabManager.onPopupCloseRequest = { [weak self] tab in self?.closePopup(tab) }
        tabManager.onPageReady = { tab in AIBrowserEngine.shared.remember(tab) }
        tabBar.onSelect = { [weak self] index in
            self?.tabManager.select(at: index)
            DispatchQueue.main.async { self?.focusWeb() }
        }
        tabBar.onClose = { [weak self] index in self?.tabManager.close(at: index) }
        tabBar.onMove = { [weak self] source, destination in self?.tabManager.moveTab(from: source, to: destination) }
        tabBar.onGroup = { [weak self] source, target in
            guard let self else { return }
            if self.tabManager.createGroup(from: source, with: target) == nil {
                self.toast("Pinned and regular tabs cannot share a group")
            }
        }
        tabBar.onNew = { [weak self] in self?.openNewTab() }
    }

    private func wireSecurity() {
        SecurityManager.shared.onChange = { [weak self] in
            guard let self else { return }
            // Живе застосування блокувальника до вже відкритих вкладок
            for tab in self.tabManager.tabs {
                SecurityManager.shared.apply(to: tab.webView.configuration.userContentController)
            }
            self.updateStatus()
        }
    }

    // MARK: - State sync

    private func refreshTabsUI() {
        tabBar.reload(
            items: tabManager.tabs.map { ($0.displayTitle, $0.webView.isLoading) },
            current: tabManager.currentIndex
        )
        var sidebarModels: [SidebarTabModel] = []
        var emittedGroups = Set<UUID>()
        let groupColors = ["#66D9EF", "#A78BFA", "#FB7185", "#FBBF24", "#34D399", "#60A5FA"].map { NSColor(hex: $0) }
        for (index, tab) in tabManager.tabs.enumerated() {
            if let group = tabManager.group(containing: tab.id) {
                guard !emittedGroups.contains(group.id) else { continue }
                emittedGroups.insert(group.id)
                let members = tabManager.tabs.enumerated().filter { group.tabIDs.contains($0.element.id) }
                let activeMember = members.first { $0.offset == tabManager.currentIndex }?.element ?? members.first?.element
                sidebarModels.append(SidebarTabModel(
                    tabIndex: members.first?.offset ?? index, favicon: activeMember?.favicon,
                    isActive: members.contains { $0.offset == tabManager.currentIndex }, isLoading: false,
                    isPinned: tab.isPinned, isPlayingAudio: members.contains { $0.element.isPlayingAudio },
                    hasUnread: members.contains { $0.element.hasUnreadActivity }, groupID: group.id,
                    groupTitle: group.title, groupCount: members.count,
                    groupColor: group.colorIndex >= 0 ? groupColors[group.colorIndex % groupColors.count] : nil,
                    isGroup: true))
                if !group.isCollapsed {
                    for member in members {
                        let child = member.element
                        sidebarModels.append(SidebarTabModel(
                            tabIndex: member.offset, favicon: child.favicon,
                            isActive: member.offset == tabManager.currentIndex, isLoading: child.webView.isLoading,
                            isPinned: child.isPinned, isPlayingAudio: child.isPlayingAudio,
                            hasUnread: child.hasUnreadActivity, groupID: group.id))
                    }
                }
            } else {
                sidebarModels.append(SidebarTabModel(
                    tabIndex: index, favicon: tab.favicon, isActive: index == tabManager.currentIndex,
                    isLoading: tab.webView.isLoading, isPinned: tab.isPinned,
                    isPlayingAudio: tab.isPlayingAudio, hasUnread: tab.hasUnreadActivity))
            }
        }
        sidebarChrome.reload(sidebarModels)
        if let current = tabManager.current {
            window.title = "MCV — \(current.displayTitle)"
        }
    }

    private func syncAddressField(force: Bool = false) {
        guard force || commandField.currentEditor() == nil else { return }
        commandField.stringValue = tabManager.current?.webView.url?.absoluteString ?? ""
        autocomplete?.hide()
    }

    private func refreshPaletteNavigation() {
        guard let webView = tabManager.current?.webView else {
            palette.updateNavigation(canGoBack: false, canGoForward: false, isLoading: false)
            return
        }
        palette.updateNavigation(canGoBack: webView.canGoBack,
                                 canGoForward: webView.canGoForward,
                                 isLoading: webView.isLoading)
    }

    private func attachCurrentWebView() {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let current = tabManager.current else { return }
        guard current.logicalURL != nil else {
            // The desktop-colored .behindWindow material lives below baseTint.
            // Lowering only that tint makes the native tab genuinely
            // translucent instead of merely painting another dark shade.
            showingNativeBlank = true
            updateBaseTint()
            blankNewTabView.translatesAutoresizingMaskIntoConstraints = false
            webContainer.addSubview(blankNewTabView)
            NSLayoutConstraint.activate([
                blankNewTabView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                blankNewTabView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                blankNewTabView.topAnchor.constraint(equalTo: webContainer.topAnchor),
                blankNewTabView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            ])
            return
        }
        showingNativeBlank = false
        updateBaseTint()
        if current === pictureInPictureTab { stopPictureInPicture(for: current, reattach: false) }
        let webView = current.webView
        webView.wantsLayer = true
        webView.layer?.masksToBounds = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)
        let leading = webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor)
        let trailing = webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor)
        let bottom = webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        pageLeadingConstraint = leading
        pageTrailingConstraint = trailing
        pageBottomConstraint = bottom
        NSLayoutConstraint.activate([
            leading,
            trailing,
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            bottom,
        ])
        applyPageSurfaceStyle()
        syncAddressField()
        updateStatus()
    }

    func togglePictureInPicture(for tab: BrowserTab) {
        if pictureInPictureTab === tab { stopPictureInPicture(for: tab); return }
        guard pictureInPicturePendingTab == nil else { return }
        if let existing = pictureInPictureTab { stopPictureInPicture(for: existing, reattach: false) }

        pictureInPicturePendingTab = tab
        let snapshot = WKSnapshotConfiguration()
        snapshot.afterScreenUpdates = false
        tab.webView.takeSnapshot(with: snapshot) { [weak self, weak tab] image, _ in
            DispatchQueue.main.async {
                guard let self, let tab, self.pictureInPicturePendingTab === tab else { return }
                self.pictureInPicturePendingTab = nil
                self.openPictureInPicturePanel(for: tab, pageSnapshot: image)
            }
        }
    }

    private func openPictureInPicturePanel(for tab: BrowserTab, pageSnapshot: NSImage?) {
        if tabManager.current === tab, let pageSnapshot {
            let placeholder = NSImageView(image: pageSnapshot)
            placeholder.imageScaling = .scaleAxesIndependently
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            webContainer.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                placeholder.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                placeholder.topAnchor.constraint(equalTo: webContainer.topAnchor),
                placeholder.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            ])
            pictureInPicturePlaceholder = placeholder
        }

        let panel = FloatingVideoPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 248),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 280, height: 158)
        panel.maxSize = NSSize(width: 998, height: 528)
        panel.isMovableByWindowBackground = true
        panel.center()

        let webView = tab.webView
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(webView)
        if let content = panel.contentView {
            content.wantsLayer = true
            content.layer?.cornerRadius = 16
            content.layer?.cornerCurve = .continuous
            content.layer?.masksToBounds = true
            content.layer?.borderWidth = 1
            content.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            webView.wantsLayer = true
            webView.layer?.cornerRadius = 16
            webView.layer?.cornerCurve = .continuous
            webView.layer?.masksToBounds = true
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                webView.topAnchor.constraint(equalTo: content.topAnchor),
                webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        webView.evaluateJavaScript(Self.enterPictureInPicturePageJS)
        pictureInPictureTab = tab
        pictureInPicturePanel = panel
        pictureInPictureCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            self.stopPictureInPicture(for: tab)
        }
        panel.orderFrontRegardless()
    }

    private func stopPictureInPicture(for tab: BrowserTab, reattach: Bool = true) {
        guard pictureInPictureTab === tab else { return }
        if let observer = pictureInPictureCloseObserver { NotificationCenter.default.removeObserver(observer) }
        pictureInPictureCloseObserver = nil
        tab.webView.evaluateJavaScript(Self.exitPictureInPicturePageJS)
        tab.webView.removeFromSuperview()
        pictureInPicturePlaceholder?.removeFromSuperview()
        pictureInPicturePlaceholder = nil
        pictureInPicturePanel?.orderOut(nil)
        pictureInPicturePanel = nil
        pictureInPictureTab = nil
        if reattach, tabManager.current === tab { attachCurrentWebView() }
    }

    private static let enterPictureInPicturePageJS = #"""
    (() => {
      const videos = Array.from(document.querySelectorAll('video'));
      videos.sort((a,b) => Number(a.paused)-Number(b.paused) || b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight);
      const video = videos[0]; if (!video) return;
      const surface = video.closest('#movie_player, .html5-video-player, .video-js, [data-player], [class*="video-player"]') || video.parentElement || video;
      globalThis.__mcvNativePiP = {video, surface, surfaceStyle:surface.getAttribute('style'),
        videoStyle:video.getAttribute('style'), controls:video.controls};
      const set = (el,k,v) => el.style.setProperty(k,v,'important');
      set(surface,'position','fixed');set(surface,'inset','0');set(surface,'width','100vw');set(surface,'height','100vh');
      set(surface,'max-width','none');set(surface,'max-height','none');set(surface,'z-index','2147483647');
      set(surface,'background','#000');set(surface,'margin','0');set(surface,'transform','none');
      set(video,'width','100%');set(video,'height','100%');set(video,'max-width','none');set(video,'max-height','none');
      set(video,'object-fit','contain');set(video,'background','#000');
      if (surface === video || surface === video.parentElement) video.controls=true;
      document.documentElement.style.setProperty('background','#000','important');
      return true;
    })()
    """#

    private static let exitPictureInPicturePageJS = #"""
    (() => { const s=globalThis.__mcvNativePiP; if(!s?.video)return;
      if(s.surfaceStyle==null)s.surface.removeAttribute('style');else s.surface.setAttribute('style',s.surfaceStyle);
      if(s.videoStyle==null)s.video.removeAttribute('style');else s.video.setAttribute('style',s.videoStyle);
      s.video.controls=s.controls;document.documentElement.style.removeProperty('background');
      delete globalThis.__mcvNativePiP; })()
    """#

    private func openSmartPopup(opener: BrowserTab, configuration: WKWebViewConfiguration,
                                action: WKNavigationAction, features: WKWindowFeatures) -> WKWebView? {
        if let scheme = action.request.url?.scheme?.lowercased(), !["http", "https", "about"].contains(scheme) {
            toast("Popup blocked: unsafe URL scheme")
            return nil
        }
        let openerID = ObjectIdentifier(opener)
        let cutoff = Date().addingTimeInterval(-30)
        var attempts = (popupAttempts[openerID] ?? []).filter { $0 > cutoff }
        guard attempts.count < 4 else { toast("Popup blocked: too many windows"); return nil }
        attempts.append(Date()); popupAttempts[openerID] = attempts

        configuration.preferences.isElementFullscreenEnabled = true
        SecurityManager.shared.apply(to: configuration.userContentController)
        let popupTab = BrowserTab(configuration: configuration, installUserContentHandlers: false)
        let width = min(1000, max(320, features.width?.doubleValue ?? 520))
        let height = min(800, max(240, features.height?.doubleValue ?? 640))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = action.request.url?.host ?? "MCV Popup"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 240)
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.maxSize = NSSize(width: min(1000, screen.width), height: min(800, screen.height))
        panel.center()
        popupTab.webView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(popupTab.webView)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                popupTab.webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                popupTab.webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                popupTab.webView.topAnchor.constraint(equalTo: content.topAnchor),
                popupTab.webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        popupTab.onUpdate = { [weak panel, weak popupTab] in panel?.title = popupTab?.displayTitle ?? "MCV Popup" }
        popupTab.onRequestClose = { [weak self] tab in self?.closePopup(tab) }
        popupTab.onRequestNewTab = { [weak self] url in self?.tabManager.newTab(url: url) }
        popupTab.onRequestPopup = { [weak self] nestedOpener, nestedConfiguration, nestedAction, nestedFeatures in
            self?.openSmartPopup(opener: nestedOpener, configuration: nestedConfiguration, action: nestedAction, features: nestedFeatures)
        }
        let controller = NSWindowController(window: panel)
        let key = ObjectIdentifier(popupTab)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: panel, queue: .main) { [weak self, weak popupTab] _ in
            if let popupTab { self?.closePopup(popupTab) }
        }
        popupWindows[key] = (popupTab, controller, openerID, observer)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        return popupTab.webView
    }

    private func closePopup(_ tab: BrowserTab) {
        let key = ObjectIdentifier(tab)
        guard let popup = popupWindows.removeValue(forKey: key) else { return }
        NotificationCenter.default.removeObserver(popup.observer)
        if let popupWindow = popup.controller.window {
            window.removeChildWindow(popupWindow)
            popupWindow.orderOut(nil)
        }
        popup.tab.teardown()
    }

    private func closePopups(openedBy opener: BrowserTab) {
        let openerID = ObjectIdentifier(opener)
        let tabs = popupWindows.values.filter { $0.opener == openerID }.map(\.tab)
        tabs.forEach(closePopup)
        popupAttempts[openerID] = nil
    }

    /// Sidebar mode is true edge-to-edge content. The inset rounded "card"
    /// remains exclusive to the classic chrome.
    private func applyPageSurfaceStyle() {
        let framed = !sidebarMode && !minimalMode
        pageLeadingConstraint?.constant = framed ? 12 : 0
        pageTrailingConstraint?.constant = framed ? -8 : 0
        pageBottomConstraint?.constant = framed ? -8 : 0
        tabManager.current?.webView.layer?.cornerRadius = framed ? 10 : 0
    }

    private func updateStatus() {
        let security = SecurityManager.shared
        statusLabel.stringValue = "\(security.mode.label) · JS \(security.effectiveJS ? "ON" : "OFF")"
    }

    // MARK: - Focus helpers

    func focusCommand(prefill: String? = nil) {
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(commandField)
        if let prefill {
            commandField.stringValue = prefill
            commandField.currentEditor()?.moveToEndOfDocument(nil)
        } else {
            commandField.currentEditor()?.selectAll(nil)
        }
    }

    private func focusWeb() {
        if let webView = tabManager.current?.webView {
            window.makeKey()
            _ = window.makeFirstResponder(webView)
        }
    }

    @objc private func commandSubmitted() {
        let text = commandField.stringValue
        autocomplete.hide()
        guard !text.isEmpty else { return }
        engine?.execute(text)
        focusWeb()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === commandField else { return }
        autocomplete.textDidChange()
    }

    // Рамка капсули стає акцентною при фокусі (0.15s з макета).
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === commandField else { return }
        capsule.setFocused(true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === commandField else { return }
        capsule.setFocused(false)
    }

    // Стрілки/Tab/Enter — спершу автодоповненню; Esc без активних підказок
    // повертає URL сторінки і віддає фокус сторінці.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === commandField else { return false }
        if autocomplete.handle(selector) { return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            syncAddressField(force: true)
            focusWeb()
            return true
        }
        return false
    }

    // MARK: - Overlays (тоглюються повторним натисканням)

    func showCommandPalette() {
        if !palette.isHidden {
            palette.dismiss()
            return
        }
        switcher.dismiss()
        refreshPaletteNavigation()
        palette.present(prefill: tabManager.current?.logicalURL?.absoluteString ?? "")
    }

    // MARK: - BrowserControlling: базове

    var currentURL: URL? { tabManager.current?.webView.url }
    var currentTitle: String? { tabManager.current?.displayTitle }

    func navigate(to url: URL, newTab: Bool) {
        if newTab || tabManager.current == nil {
            tabManager.newTab(url: url)
        } else {
            tabManager.current?.load(url)
            attachCurrentWebView()
        }
        window.makeKeyAndOrderFront(nil)
    }

    func reloadPage() { tabManager.current?.webView.reload() }
    func goBack() { tabManager.current?.webView.goBack() }
    func goForward() { tabManager.current?.webView.goForward() }

    func openNewTab() {
        if !window.isVisible {
            reopenWindowWithBlankTab()
            return
        }
        tabManager.newTab(url: nil)
        switcher.dismiss()
        palette.present()
    }

    func reopenWindowWithBlankTab() {
        tabManager.resetForNewWindow()
        window.makeKeyAndOrderFront(nil)
        applyChromeVisibility()
        switcher.dismiss()
        palette.present()
    }

    func closeCurrentTab() {
        if tabManager.tabs.count == 1 {
            if tabManager.current?.isPinned == true {
                toast("Pinned tabs are protected — right-click to close or unpin first")
            } else {
                window.performClose(nil)
            }
            return
        }
        guard tabManager.close(at: tabManager.currentIndex) else {
            if tabManager.current?.isPinned == true {
                toast("Pinned tabs are protected — right-click to close or unpin first")
            }
            return
        }
        if tabManager.current?.logicalURL == nil {
            switcher.dismiss()
            palette.present()
        }
    }
    func selectTab(index: Int) { tabManager.select(at: index); focusWeb() }
    func selectTabShortcut(number: Int) { tabManager.selectShortcut(number); focusWeb() }
    func nextTab() { tabManager.selectRelative(1); focusWeb() }
    func previousTab() { tabManager.selectRelative(-1); focusWeb() }

    func duplicateTab() {
        if let url = currentURL {
            tabManager.newTab(url: url)
        } else {
            openNewTab()
        }
    }

    func closeOtherTabs() {
        tabManager.closeOthers()
        toast("Other tabs closed")
    }

    func reopenClosedTab() {
        if !tabManager.reopenLast() {
            toast("No recently closed tabs")
        }
    }

    func showTabSwitcher() {
        if !switcher.isHidden {
            switcher.dismiss()
            focusWeb()
            return
        }
        palette.dismiss()
        switcher.present()
    }

    func applyTheme(dark: Bool) {
        applyTheme(mode: dark ? "dark" : "light")
    }

    func applyTheme(mode: String) {
        let normalized = ["dark", "light", "system"].contains(mode) ? mode : "system"
        ConfigStore.shared.update { $0.theme = normalized }
        Theme.apply(mode: normalized)
        toast(normalized == "system" ? "System theme · follows macOS" : "\(normalized.capitalized) theme")
    }

    @objc private func applyInterfaceColors() {
        commandField.textColor = Theme.textPrimary
        statusLabel.textColor = Theme.textSecondary
        toastLabel.textColor = Theme.textPrimary
        updateBaseTint()
    }

    private func updateBaseTint() {
        let color: NSColor
        if Theme.isDark {
            color = NSColor.black.withAlphaComponent(showingNativeBlank ? 0.30 : 0.85)
        } else {
            color = NSColor.white.withAlphaComponent(showingNativeBlank ? 0.20 : 0.68)
        }
        baseTint.layer?.backgroundColor = color.cgColor
    }

    func toggleMinimalMode() {
        minimalMode.toggle()
        applyChromeVisibility()
        toast(minimalMode ? "Minimal mode — press ⇧⌘M to exit" : "Full interface")
    }

    /// Тоглить ультрамінімальний sidebar (лише фавіконки + traffic lights
    /// вертикально). Персистентно в конфізі, вимикається так само.
    func toggleSidebarMode() {
        sidebarMode.toggle()
        ConfigStore.shared.update { $0.sidebarMode = self.sidebarMode }
        applyChromeVisibility()
        toast(sidebarMode ? "Sidebar mode — press ⌘E for the command bar" : "Classic toolbar")
    }

    func setSidebarMode(_ enabled: Bool) {
        guard sidebarMode != enabled else { return }
        toggleSidebarMode()
    }

    /// Єдина точка правди для видимості верхнього chrome / лівого sidebar:
    /// minimal ховає все, sidebar замінює верхню панель на ліву колонку.
    private func applyChromeVisibility() {
        let hideTopChrome = minimalMode || sidebarMode
        tabBar.isHidden = hideTopChrome
        commandRow.isHidden = hideTopChrome
        statusLabel.isHidden = hideTopChrome
        webTopToChrome.isActive = !hideTopChrome
        webTopToContent.isActive = hideTopChrome

        let hideSidebar = !sidebarMode || minimalMode
        sidebarChrome.isHidden = hideSidebar
        bookmarksSidebar.isHidden = !bookmarksSidebarVisible
        let bookmarksFollowTabSidebar = bookmarksSidebarVisible && !hideSidebar
        bookmarksLeadingToContent.isActive = !bookmarksFollowTabSidebar
        bookmarksLeadingToSidebarChrome.isActive = bookmarksFollowTabSidebar
        webLeadingToContent.isActive = hideSidebar && !bookmarksSidebarVisible
        webLeadingToSidebarChrome.isActive = !hideSidebar && !bookmarksSidebarVisible
        webLeadingToBookmarks.isActive = bookmarksSidebarVisible
        applyPageSurfaceStyle()

        // Реальні traffic lights показуються лише в класичному режимі (без
        // sidebar і без minimal) — у sidebar-режимі їх заміняють власні
        // вертикальні, а в minimal ховається геть усе chrome, включно з ними.
        let showRealTrafficLights = !sidebarMode && !minimalMode
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = !showRealTrafficLights
        }
    }

    func activateReader() {
        tabManager.current?.webView.evaluateJavaScript(Reader.js) { [weak self] result, _ in
            if let status = result as? String, status == "no-content" {
                self?.toast("Reader: no article found")
            }
        }
    }

    func showLocalPage(html: String) {
        // Internal tools must never replace the user's page—especially a
        // pinned tab. `about:blank` gives the native tab a logical URL while
        // keeping it out of session restore, then the local HTML replaces it.
        let tab = tabManager.newTab(url: URL(string: "about:blank"))
        tab.webView.loadHTMLString(html, baseURL: nil)
    }

    func toast(_ message: String) {
        toastLabel.stringValue = message
        toastTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toastGlass.animator().alphaValue = 1
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self?.toastGlass.animator().alphaValue = 0
            }
        }
    }

    // MARK: - BrowserControlling: сторінка

    func findInPage(_ query: String) {
        guard let webView = tabManager.current?.webView else { return }
        let text = query.isEmpty ? lastFindQuery : query
        guard !text.isEmpty else { toast("find <text>"); return }
        lastFindQuery = text
        let config = WKFindConfiguration()
        config.wraps = true
        config.caseSensitive = false
        webView.find(text, configuration: config) { [weak self] result in
            if !result.matchFound {
                self?.toast("“\(text)” was not found")
            }
        }
    }

    func setZoom(_ action: ZoomAction) {
        guard let webView = tabManager.current?.webView else { return }
        switch action {
        case .increase: webView.pageZoom = min(3.0, webView.pageZoom + 0.1)
        case .decrease: webView.pageZoom = max(0.3, webView.pageZoom - 0.1)
        case .reset: webView.pageZoom = 1.0
        case .set(let value): webView.pageZoom = min(5.0, max(0.25, value))
        }
        toast(String(format: "Zoom: %.0f%%", webView.pageZoom * 100))
    }

    func viewSource() {
        guard let webView = tabManager.current?.webView else { return }
        let pageURL = webView.url?.absoluteString ?? ""
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self, let html = result as? String else {
                self?.toast("Page source is unavailable")
                return
            }
            let escaped = html
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
            let body = """
            <h1>view-source</h1><p class="tagline">\(pageURL)</p>
            <pre style="white-space:pre-wrap;word-break:break-all;font-size:12px">\(escaped)</pre>
            """
            self.tabManager.newTab(url: nil)
            self.tabManager.current?.webView.loadHTMLString(
                CommandEngine.localPage(title: "source", body: body), baseURL: nil)
        }
    }

    func printPage() {
        guard let webView = tabManager.current?.webView else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func exportPDF() {
        guard let webView = tabManager.current?.webView else { return }
        let name = "MCV-\(sanitizedFileName(currentTitle ?? "page")).pdf"
        webView.createPDF { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                try? data.write(to: self.downloadsFile(name))
                self.toast("PDF → Downloads/\(name)")
            case .failure:
                self.toast("PDF export failed")
            }
        }
    }

    func snapshotPage() {
        guard let webView = tabManager.current?.webView else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                self?.toast("Screenshot failed")
                return
            }
            let name = "MCV-shot-\(Int(Date().timeIntervalSince1970)).png"
            try? png.write(to: self.downloadsFile(name))
            self.toast("PNG → Downloads/\(name)")
        }
    }

    func scrollToTop() { runJS("window.scrollTo({top:0,behavior:'smooth'})") }
    func scrollToBottom() { runJS("window.scrollTo({top:document.body.scrollHeight,behavior:'smooth'})") }

    func showQRCode() {
        guard let urlString = currentURL?.absoluteString else {
            toast("No active page")
            return
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
        filter.setValue(Data(urlString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let body = """
        <div style="text-align:center;margin-top:6vh">
          <img src="data:image/png;base64,\(png.base64EncodedString())"
               style="width:320px;image-rendering:pixelated;border-radius:16px;background:#fff;padding:18px">
          <p class="tagline" style="word-break:break-all;max-width:480px;margin:20px auto">\(urlString)</p>
        </div>
        """
        tabManager.newTab(url: nil)
        tabManager.current?.webView.loadHTMLString(
            CommandEngine.localPage(title: "QR", body: body), baseURL: nil)
    }

    func setUserAgent(_ ua: String?) {
        BrowserTab.userAgentOverride = ua
        for tab in tabManager.tabs {
            tab.webView.customUserAgent = ua ?? BrowserTab.defaultUA
        }
        toast(ua == nil ? "UA: Safari default" : "UA changed — reload the page")
    }

    func showHistoryPage() {
        let entries = HistoryStore.shared.entries
        guard !entries.isEmpty else { toast("History is empty"); return }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd.MM HH:mm"
        let rows = entries.prefix(500).map { entry -> String in
            "<tr><td class=\"tagline\">\(dateFormatter.string(from: entry.visitedAt))</td>"
                + "<td><a href=\"\(entry.url)\">\(entry.title)</a></td>"
                + "<td class=\"tagline\">\(entry.url)</td></tr>"
        }.joined()
        showLocalPage(html: CommandEngine.localPage(
            title: "History",
            body: "<h1>History</h1><p class=\"tagline\">hist clear — clear history</p><table>\(rows)</table>"))
    }

    func clearHistory() {
        HistoryStore.shared.clear()
        toast("Browsing history cleared")
    }

    func clearBrowsingData() {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { [weak self] in
            self?.toast("Cookies, cache, and website data cleared")
        }
    }

    // MARK: - BrowserControlling: вкладки (розширене)

    func togglePinCurrentTab() {
        tabManager.togglePinCurrent()
        let pinned = tabManager.current?.isPinned == true
        toast(pinned ? "📌 Tab pinned" : "Tab unpinned")
    }

    func openPrivateTab() {
        tabManager.newTab(url: nil, ephemeral: true)
        toast("🕶 Private tab — no history or persistent cookies")
        focusCommand()
    }

    func showLoadSpeed() {
        guard let duration = tabManager.current?.lastLoadDuration else {
            toast("No load timing available")
            return
        }
        toast(String(format: "Loaded in %.2f s", duration))
    }

    func showPerformanceStats() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let memory = result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
        let ext = MCVExtensionRuntime.shared.performanceCounters()
        toast(String(format: "PERF · %.0f MB · %d tabs (%d sleeping) · %d extension workers · %d alarms · %d popups",
                     memory, tabManager.tabs.count, tabManager.hibernatedCount,
                     ext.backgrounds, ext.alarms, ext.popups))
    }

    func toggleDownloadsSidebar() {
        sidebarVisible.toggle()
        downloadsSidebar.isHidden = !sidebarVisible
        webTrailingToContent.isActive = !sidebarVisible
        webTrailingToSidebar.isActive = sidebarVisible
    }

    func toggleBookmarksSidebar() {
        bookmarksSidebarVisible.toggle()
        if bookmarksSidebarVisible { bookmarksSidebar.reload(focus: true) }
        applyChromeVisibility()
    }

    // MARK: - BrowserControlling: вікно

    func setWindowOpacity(_ value: Double) {
        let clamped = min(1.0, max(0.3, value))
        window.alphaValue = clamped
        ConfigStore.shared.update { $0.windowOpacity = clamped }
        toast(String(format: "Window opacity: %.0f%%", clamped * 100))
    }

    func toggleFullscreen() {
        window.toggleFullScreen(nil)
    }

    func toggleFloatOnTop() {
        let floating = window.level != .floating
        window.level = floating ? .floating : .normal
        toast(floating ? "Always on top — run float to disable" : "Normal window level")
    }

    func restoreLastSession() {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mcv/session.json")
        guard let data = try? Data(contentsOf: file),
              let urls = try? JSONDecoder().decode([String].self, from: data),
              !urls.isEmpty else {
            toast("No saved session")
            return
        }
        var restored = 0
        for raw in urls.prefix(20) {
            if let url = URL(string: raw) {
                tabManager.newTab(url: url)
                restored += 1
            }
        }
        toast("Restored tabs: \(restored)")
    }

    func runAI(_ command: String) {
        let lower = command.lowercased()
        let scopedTabs: [BrowserTab]
        if lower.hasPrefix("research"), !lower.hasPrefix("research all"),
           let current = tabManager.current, let group = tabManager.group(containing: current.id) {
            scopedTabs = tabManager.tabs.filter { group.tabIDs.contains($0.id) }
        } else {
            scopedTabs = tabManager.tabs
        }
        AIBrowserEngine.shared.run(command, current: tabManager.current, tabs: scopedTabs,
            show: { [weak self] html in
                self?.showLocalPage(html: html)
            },
            toast: { [weak self] message in self?.toast(message) })
    }

    // MARK: - Private

    private func runJS(_ script: String) {
        tabManager.current?.webView.evaluateJavaScript(script) { _, _ in }
    }

    private func downloadsFile(_ name: String) -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
    }

    private func sanitizedFileName(_ raw: String) -> String {
        let cleaned = raw.map { ch -> Character in
            "/\\:?%*|\"<>".contains(ch) ? "-" : ch
        }
        return String(String(cleaned).prefix(40))
    }
}

// MARK: - Native extension host

extension BrowserWindowController: MCVExtensionHost {
    func extensionTabs() -> [[String: Any]] {
        tabManager.tabs.enumerated().map { index, tab in
            ["id": index, "index": index, "windowId": 1,
             "active": index == tabManager.currentIndex, "highlighted": index == tabManager.currentIndex,
             "pinned": tab.isPinned, "incognito": tab.isPrivate,
             "title": tab.displayTitle, "url": tab.logicalURL?.absoluteString ?? "",
             "status": tab.webView.isLoading ? "loading" : "complete"]
        }
    }

    func extensionCreateTab(url: URL?, active: Bool) -> Int {
        let previous = tabManager.currentIndex
        _ = tabManager.newTab(url: url ?? tabManager.homepageURL)
        let created = tabManager.currentIndex
        if !active, previous >= 0 { tabManager.select(at: previous) }
        return created
    }

    func extensionUpdateTab(id: Int, url: URL?, active: Bool?) -> Bool {
        let target = id < 0 ? tabManager.currentIndex : id
        guard tabManager.tabs.indices.contains(target) else { return false }
        if let url {
            tabManager.tabs[target].load(url)
            if target == tabManager.currentIndex { attachCurrentWebView() }
        }
        if active == true { tabManager.select(at: target) }
        return true
    }

    func extensionRemoveTabs(ids: [Int]) {
        for id in ids.sorted(by: >) where tabManager.tabs.indices.contains(id) { tabManager.close(at: id) }
    }

    func extensionWebView(tabID: Int?) -> WKWebView? {
        guard let tabID else { return tabManager.current?.webView }
        guard tabManager.tabs.indices.contains(tabID) else { return nil }
        tabManager.tabs[tabID].wakeIfNeeded()
        return tabManager.tabs[tabID].webView
    }

    func extensionOpenPage(_ url: URL, title: String) { navigate(to: url, newTab: true) }
}
