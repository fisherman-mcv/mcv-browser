import AppKit
import WebKit
import CoreImage

/// Головне вікно: скляний chrome (вкладки + командний рядок) поверх
/// напівпрозорого фону, webview — «карткою» зі скругленими кутами.
final class BrowserWindowController: NSObject, BrowserControlling, NSTextFieldDelegate {
    let window: NSWindow
    let tabManager = TabManager()
    var engine: CommandEngine?

    private let tabBar = TabBarView()
    private let commandField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let webContainer = NSView()
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
    private var webTrailingToContent: NSLayoutConstraint!
    private var webTrailingToSidebar: NSLayoutConstraint!
    private var sidebarVisible = false

    private let sidebarChrome = SidebarChromeView()
    private var sidebarMode = ConfigStore.shared.config.sidebarMode
    private var webLeadingToContent: NSLayoutConstraint!
    private var webLeadingToSidebarChrome: NSLayoutConstraint!

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
    }

    func start(homepage: String, restored: [URL] = []) {
        if restored.isEmpty {
            let url = CommandEngine.url(from: homepage)
                ?? URL(string: homepage)
                ?? URL(string: "https://duckduckgo.com")!
            tabManager.newTab(url: url)
        } else {
            restored.forEach { tabManager.newTab(url: $0) }
            tabManager.select(at: 0)
        }
        window.alphaValue = ConfigStore.shared.config.windowOpacity
        window.makeKeyAndOrderFront(nil)
        applyChromeVisibility()
        updateStatus()
        focusCommand()
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window.contentView else { return }

        // Скляна основа всього вікна — Liquid Glass.
        let base = NSVisualEffectView()
        base.material = .sidebar
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

        commandField.placeholderString = "Введіть команду або URL…"
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
        webContainer.setContentHuggingPriority(.init(1), for: .vertical)

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

        sidebarChrome.onSelectTab = { [weak self] index in self?.tabManager.select(at: index) }
        sidebarChrome.onCloseTab = { [weak self] index in self?.tabManager.close(at: index) }
        sidebarChrome.onDuplicateTab = { [weak self] index in
            guard let self, self.tabManager.tabs.indices.contains(index) else { return }
            self.tabManager.newTab(url: self.tabManager.tabs[index].webView.url)
        }
        sidebarChrome.onTogglePin = { [weak self] index in
            guard let self else { return }
            self.tabManager.select(at: index)
            self.tabManager.togglePinCurrent()
        }
        sidebarChrome.onNewTab = { [weak self] in self?.openNewTab() }
        sidebarChrome.attachWindowControls(window)

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
        }
        tabManager.onDownloadMessage = { [weak self] message in
            self?.toast(message)
            if message.hasPrefix("⬇"), self?.sidebarVisible == false { self?.toggleDownloadsSidebar() }
        }
        tabBar.onSelect = { [weak self] index in self?.tabManager.select(at: index) }
        tabBar.onClose = { [weak self] index in self?.tabManager.close(at: index) }
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
        sidebarChrome.reload(tabManager.tabs.enumerated().map { index, tab in
            SidebarTabModel(
                favicon: tab.favicon, isActive: index == tabManager.currentIndex,
                isLoading: tab.webView.isLoading, isPinned: tab.isPinned,
                isPlayingAudio: tab.isPlayingAudio, hasUnread: tab.hasUnreadActivity
            )
        })
        if let current = tabManager.current {
            window.title = "MCV — \(current.displayTitle)"
        }
    }

    private func syncAddressField(force: Bool = false) {
        guard force || commandField.currentEditor() == nil else { return }
        commandField.stringValue = tabManager.current?.webView.url?.absoluteString ?? ""
        autocomplete?.hide()
    }

    private func attachCurrentWebView() {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let webView = tabManager.current?.webView else { return }
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 10
        webView.layer?.masksToBounds = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            // 12px — той самий відступ, що й у traffic lights від лівого краю
            // sidebar'а ((36-12)/2), для гармонійного ритму по горизонталі.
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor, constant: 12),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor, constant: -8),
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor, constant: -8),
        ])
        syncAddressField()
        updateStatus()
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
        palette.present()
    }

    // MARK: - BrowserControlling: базове

    var currentURL: URL? { tabManager.current?.webView.url }
    var currentTitle: String? { tabManager.current?.displayTitle }

    func navigate(to url: URL, newTab: Bool) {
        if newTab || tabManager.current == nil {
            tabManager.newTab(url: url)
        } else {
            tabManager.current?.load(url)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func reloadPage() { tabManager.current?.webView.reload() }
    func goBack() { tabManager.current?.webView.goBack() }
    func goForward() { tabManager.current?.webView.goForward() }

    func openNewTab() {
        tabManager.newTab(url: tabManager.homepageURL)
        focusCommand()
    }

    func closeCurrentTab() { tabManager.close(at: tabManager.currentIndex) }
    func selectTab(index: Int) { tabManager.select(at: index) }
    func nextTab() { tabManager.selectRelative(1) }
    func previousTab() { tabManager.selectRelative(-1) }

    func duplicateTab() {
        if let url = currentURL {
            tabManager.newTab(url: url)
        } else {
            openNewTab()
        }
    }

    func closeOtherTabs() {
        tabManager.closeOthers()
        toast("Інші вкладки закрито")
    }

    func reopenClosedTab() {
        if !tabManager.reopenLast() {
            toast("Немає закритих вкладок")
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
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        ConfigStore.shared.update { $0.theme = dark ? "dark" : "light" }
        Theme.update(dark: dark)
        toast(dark ? "Темна тема" : "Світла тема")
    }

    func toggleMinimalMode() {
        minimalMode.toggle()
        applyChromeVisibility()
        toast(minimalMode ? "Minimal mode — ⌘M щоб повернути" : "Повний інтерфейс")
    }

    /// Тоглить ультрамінімальний sidebar (лише фавіконки + traffic lights
    /// вертикально). Персистентно в конфізі, вимикається так само.
    func toggleSidebarMode() {
        sidebarMode.toggle()
        ConfigStore.shared.update { $0.sidebarMode = self.sidebarMode }
        applyChromeVisibility()
        toast(sidebarMode ? "Sidebar mode — ⌘E для команд" : "Класична панель")
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
        webLeadingToContent.isActive = hideSidebar
        webLeadingToSidebarChrome.isActive = !hideSidebar

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
                self?.toast("Reader: статтю не знайдено")
            }
        }
    }

    func showLocalPage(html: String) {
        if tabManager.current == nil { tabManager.newTab(url: nil) }
        tabManager.current?.webView.loadHTMLString(html, baseURL: nil)
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
        guard !text.isEmpty else { toast("find <текст>"); return }
        lastFindQuery = text
        let config = WKFindConfiguration()
        config.wraps = true
        config.caseSensitive = false
        webView.find(text, configuration: config) { [weak self] result in
            if !result.matchFound {
                self?.toast("«\(text)» не знайдено")
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
        toast(String(format: "Масштаб: %.0f%%", webView.pageZoom * 100))
    }

    func viewSource() {
        guard let webView = tabManager.current?.webView else { return }
        let pageURL = webView.url?.absoluteString ?? ""
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self, let html = result as? String else {
                self?.toast("Джерело недоступне")
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
                self.toast("PDF: помилка")
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
                self?.toast("Скріншот: помилка")
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
            toast("Немає сторінки")
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
        toast(ua == nil ? "UA: стандартний Safari" : "UA змінено — перезавантажте сторінку")
    }

    func showHistoryPage() {
        let entries = HistoryStore.shared.entries
        guard !entries.isEmpty else { toast("Історія порожня"); return }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd.MM HH:mm"
        let rows = entries.prefix(500).map { entry -> String in
            "<tr><td class=\"tagline\">\(dateFormatter.string(from: entry.visitedAt))</td>"
                + "<td><a href=\"\(entry.url)\">\(entry.title)</a></td>"
                + "<td class=\"tagline\">\(entry.url)</td></tr>"
        }.joined()
        showLocalPage(html: CommandEngine.localPage(
            title: "Історія",
            body: "<h1>Історія</h1><p class=\"tagline\">hist clear — очистити</p><table>\(rows)</table>"))
    }

    func clearHistory() {
        HistoryStore.shared.clear()
        toast("Історію переглядів очищено")
    }

    func clearBrowsingData() {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { [weak self] in
            self?.toast("Кукі, кеш і дані сайтів очищено")
        }
    }

    // MARK: - BrowserControlling: вкладки (розширене)

    func togglePinCurrentTab() {
        tabManager.togglePinCurrent()
        let pinned = tabManager.current?.isPinned == true
        toast(pinned ? "📌 Вкладку закріплено" : "Відкріплено")
    }

    func openPrivateTab() {
        tabManager.newTab(url: nil, ephemeral: true)
        toast("🕶 Приватна вкладка — без історії та кук")
        focusCommand()
    }

    func showLoadSpeed() {
        guard let duration = tabManager.current?.lastLoadDuration else {
            toast("Немає даних про завантаження")
            return
        }
        toast(String(format: "Завантажено за %.2f с", duration))
    }

    func toggleDownloadsSidebar() {
        sidebarVisible.toggle()
        downloadsSidebar.isHidden = !sidebarVisible
        webTrailingToContent.isActive = !sidebarVisible
        webTrailingToSidebar.isActive = sidebarVisible
    }

    // MARK: - BrowserControlling: вікно

    func setWindowOpacity(_ value: Double) {
        let clamped = min(1.0, max(0.3, value))
        window.alphaValue = clamped
        ConfigStore.shared.update { $0.windowOpacity = clamped }
        toast(String(format: "Прозорість вікна: %.0f%%", clamped * 100))
    }

    func toggleFullscreen() {
        window.toggleFullScreen(nil)
    }

    func toggleFloatOnTop() {
        let floating = window.level != .floating
        window.level = floating ? .floating : .normal
        toast(floating ? "Вікно поверх усіх — float щоб вимкнути" : "Звичайний рівень вікна")
    }

    func restoreLastSession() {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mcv/session.json")
        guard let data = try? Data(contentsOf: file),
              let urls = try? JSONDecoder().decode([String].self, from: data),
              !urls.isEmpty else {
            toast("Немає збереженої сесії")
            return
        }
        var restored = 0
        for raw in urls.prefix(20) {
            if let url = URL(string: raw) {
                tabManager.newTab(url: url)
                restored += 1
            }
        }
        toast("Відновлено вкладок: \(restored)")
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
