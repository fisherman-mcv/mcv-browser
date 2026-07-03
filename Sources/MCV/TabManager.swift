import AppKit
import WebKit

/// Одна вкладка = один WKWebView + KVO за title/url/isLoading + завантаження файлів.
final class BrowserTab: NSObject {
    static let defaultUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    /// Кастомний UA, встановлений командою `ua`. Діє на нові вкладки.
    static var userAgentOverride: String?

    let webView: WKWebView
    let isPrivate: Bool
    var isPinned = false
    var hasUnreadActivity = false
    private(set) var isPlayingAudio = false
    private(set) var favicon: NSImage?
    private(set) var lastLoadDuration: TimeInterval?

    var onUpdate: (() -> Void)?
    var onRequestNewTab: ((URL) -> Void)?
    var onDownloadEvent: ((String) -> Void)?
    /// Сторінка в неактивній вкладці завершила навігацію — кандидат на "●".
    var onBackgroundActivity: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var activeDownloads: [WKDownload] = []
    private var downloadIDs: [ObjectIdentifier: UUID] = [:]
    private var progressObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var navigationStart: Date?
    private static let scriptHandlerName = "mcvAudio"

    var displayTitle: String {
        let base: String
        if let title = webView.title, !title.isEmpty { base = title }
        else if let host = webView.url?.host { base = host }
        else { base = "Нова вкладка" }
        return isPinned ? "📌 \(base)" : base
    }

    init(configuration: WKWebViewConfiguration, isPrivate: Bool = false) {
        let audioScript = WKUserScript(source: Self.audioDetectionJS,
                                        injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        configuration.userContentController.addUserScript(audioScript)

        webView = WKWebView(frame: .zero, configuration: configuration)
        self.isPrivate = isPrivate
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.customUserAgent = Self.userAgentOverride ?? Self.defaultUA
        webView.configuration.userContentController.add(self, name: Self.scriptHandlerName)
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.onUpdate?() },
            webView.observe(\.url) { [weak self] _, _ in self?.onUpdate?() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.onUpdate?() },
        ]
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Розриває утримувальний цикл webView.configuration → userContentController → self,
    /// інакше вкладка ніколи не звільниться з пам'яті після закриття.
    func teardown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.scriptHandlerName)
    }

    private func fetchFavicon() {
        let js = """
        (() => {
          const l = document.querySelector("link[rel~='icon']");
          return l ? l.href : (location.origin + '/favicon.ico');
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let href = result as? String, let url = URL(string: href) else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    self.favicon = image
                    self.onUpdate?()
                }
            }.resume()
        }
    }

    private static let audioDetectionJS = """
    (function () {
      function isAnyPlaying() {
        return Array.from(document.querySelectorAll('audio,video'))
          .some(el => !el.paused && !el.ended && el.currentTime > 0);
      }
      function report() {
        try { window.webkit.messageHandlers.mcvAudio.postMessage(isAnyPlaying()); } catch (e) {}
      }
      ['play', 'pause', 'ended', 'volumechange'].forEach(evt => document.addEventListener(evt, report, true));
      setInterval(report, 2000);
    })();
    """
}

extension BrowserTab: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.scriptHandlerName, let playing = message.body as? Bool else { return }
        guard playing != isPlayingAudio else { return }
        isPlayingAudio = playing
        onUpdate?()
    }
}

extension BrowserTab: WKNavigationDelegate {
    // Політика JS вирішується на кожну навігацію: команда `js on/off`
    // діє на існуючі вкладки одразу після перезавантаження.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = SecurityManager.shared.effectiveJS
        decisionHandler(.allow, preferences)
    }

    // Все, що WebKit не може показати (архіви, бінарники…) — у завантаження.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        activeDownloads.append(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStart = Date()
    }

    // Час завантаження (команда `speed`) + глобальна історія (не для приватних вкладок).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let start = navigationStart {
            lastLoadDuration = Date().timeIntervalSince(start)
        }
        fetchFavicon()
        onBackgroundActivity?()
        guard !isPrivate, let url = webView.url?.absoluteString, !url.isEmpty else { return }
        let title = webView.title?.isEmpty == false ? webView.title! : url
        HistoryStore.shared.record(title: title, url: url)
    }
}

extension BrowserTab: WKDownloadDelegate {
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var destination = downloads.appendingPathComponent(suggestedFilename)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = downloads.appendingPathComponent("\(counter)-\(suggestedFilename)")
            counter += 1
        }
        onDownloadEvent?("⬇ \(suggestedFilename)")

        let id = DownloadsCenter.shared.add(filename: suggestedFilename, destination: destination)
        downloadIDs[ObjectIdentifier(download)] = id
        progressObservers[ObjectIdentifier(download)] = download.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            DispatchQueue.main.async { DownloadsCenter.shared.updateProgress(id: id, fraction: progress.fractionCompleted) }
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        activeDownloads.removeAll { $0 === download }
        if let id = downloadIDs[ObjectIdentifier(download)] { DownloadsCenter.shared.markFinished(id: id) }
        progressObservers[ObjectIdentifier(download)] = nil
        onDownloadEvent?("✓ Завантаження завершено → Downloads")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.removeAll { $0 === download }
        if let id = downloadIDs[ObjectIdentifier(download)] { DownloadsCenter.shared.markFailed(id: id) }
        progressObservers[ObjectIdentifier(download)] = nil
        onDownloadEvent?("✕ Завантаження не вдалося")
    }
}

extension BrowserTab: WKUIDelegate {
    // target="_blank" і window.open → нова вкладка MCV.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            onRequestNewTab?(url)
        }
        return nil
    }
}

final class TabManager {
    private(set) var tabs: [BrowserTab] = []
    private(set) var currentIndex: Int = -1
    private var closedURLs: [URL] = []

    /// Вкладки додано/закрито/перемкнуто.
    var onLayoutChange: (() -> Void)?
    /// Оновились title/url/isLoading поточних вкладок.
    var onContentChange: (() -> Void)?
    /// Події завантажень файлів (для тостів).
    var onDownloadMessage: ((String) -> Void)?

    var current: BrowserTab? {
        tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil
    }

    var homepageURL: URL? {
        let home = ConfigStore.shared.config.homepage
        return CommandEngine.url(from: home) ?? URL(string: home)
    }

    var sessionURLs: [String] {
        tabs.compactMap { $0.webView.url?.absoluteString }.filter { !$0.hasPrefix("about:") }
    }

    @discardableResult
    func newTab(url: URL?, ephemeral: Bool = false) -> BrowserTab {
        let configuration = ephemeral
            ? SecurityManager.shared.makeEphemeralConfiguration()
            : SecurityManager.shared.makeWebViewConfiguration()
        let tab = BrowserTab(configuration: configuration, isPrivate: ephemeral)
        tab.onUpdate = { [weak self] in self?.onContentChange?() }
        tab.onRequestNewTab = { [weak self] url in self?.newTab(url: url) }
        tab.onDownloadEvent = { [weak self] message in self?.onDownloadMessage?(message) }
        tab.onBackgroundActivity = { [weak self, weak tab] in
            guard let self, let tab, tab !== self.current else { return }
            tab.hasUnreadActivity = true
            self.onContentChange?()
        }
        tabs.append(tab)
        currentIndex = tabs.count - 1
        onLayoutChange?()
        if let url { tab.load(url) }
        return tab
    }

    func togglePinCurrent() {
        guard let tab = current else { return }
        tab.isPinned.toggle()
        onLayoutChange?()
    }

    func select(at index: Int) {
        guard tabs.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        tabs[index].hasUnreadActivity = false
        onLayoutChange?()
    }

    func selectRelative(_ delta: Int) {
        guard tabs.count > 1 else { return }
        let index = ((currentIndex + delta) % tabs.count + tabs.count) % tabs.count
        select(at: index)
    }

    func close(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        rememberClosed(tabs[index])
        tabs[index].teardown()
        tabs.remove(at: index)
        if tabs.isEmpty {
            currentIndex = -1
            newTab(url: homepageURL) // браузер ніколи не лишається без вкладки
            return
        }
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            currentIndex = min(index, tabs.count - 1)
        }
        onLayoutChange?()
    }

    /// Закриває всі вкладки, крім поточної та закріплених (📌).
    func closeOthers() {
        guard let keep = current, tabs.count > 1 else { return }
        for tab in tabs where tab !== keep && !tab.isPinned {
            rememberClosed(tab)
            tab.teardown()
        }
        tabs = tabs.filter { $0 === keep || $0.isPinned }
        currentIndex = tabs.firstIndex { $0 === keep } ?? 0
        onLayoutChange?()
    }

    @discardableResult
    func reopenLast() -> Bool {
        guard let url = closedURLs.popLast() else { return false }
        newTab(url: url)
        return true
    }

    private func rememberClosed(_ tab: BrowserTab) {
        guard let url = tab.webView.url else { return }
        closedURLs.append(url)
        if closedURLs.count > 25 { closedURLs.removeFirst() }
    }
}
