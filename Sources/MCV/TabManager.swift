import AppKit
import WebKit

private struct PageDownloadContext {
    let link: URL?
    let image: URL?
}

private final class MCVWebView: WKWebView {
    var pageDownloadContext: PageDownloadContext?
    var onDownloadURL: ((URL) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let context = pageDownloadContext, context.link != nil || context.image != nil else { return menu }
        menu.addItem(.separator())
        if context.link != nil {
            let item = NSMenuItem(title: "Download", action: #selector(downloadLink), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        if context.image != nil {
            let item = NSMenuItem(title: "Download Image", action: #selector(downloadImage), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        return menu
    }

    @objc private func downloadLink() { if let url = pageDownloadContext?.link { onDownloadURL?(url) } }
    @objc private func downloadImage() { if let url = pageDownloadContext?.image { onDownloadURL?(url) } }
}

/// Одна вкладка = один WKWebView + KVO за title/url/isLoading + завантаження файлів.
final class BrowserTab: NSObject {
    let id = UUID()
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
    private(set) var lastNavigationError: String?
    private(set) var lastHTTPStatus: Int?
    private(set) var lastRequestedURL: URL?
    private(set) var isMediaSuspended = false
    private(set) var isHibernated = false
    private(set) var lastActiveAt = Date()
    private var hibernatedURL: URL?
    private var hibernatedTitle: String?

    var logicalURL: URL? { isHibernated ? hibernatedURL : (webView.url ?? lastRequestedURL) }

    var onUpdate: (() -> Void)?
    var onRequestNewTab: ((URL) -> Void)?
    var onRequestPopup: ((BrowserTab, WKWebViewConfiguration, WKNavigationAction, WKWindowFeatures) -> WKWebView?)?
    var onRequestClose: ((BrowserTab) -> Void)?
    var onDownloadEvent: ((String) -> Void)?
    var onPictureInPictureRequest: ((BrowserTab) -> Void)?
    var onPictureInPictureStop: ((BrowserTab) -> Void)?
    /// Сторінка в неактивній вкладці завершила навігацію — кандидат на "●".
    var onBackgroundActivity: (() -> Void)?
    var onPageReady: ((BrowserTab) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var activeDownloads: [WKDownload] = []
    private var downloadIDs: [ObjectIdentifier: UUID] = [:]
    private var progressObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var navigationStart: Date?
    private let ownsScriptHandlers: Bool
    private static let scriptHandlerName = "mcvAudio"
    private static let pictureInPictureHandlerName = "mcvPictureInPicture"
    private static let contextMenuHandlerName = "mcvContextMenu"

    var displayTitle: String {
        let base: String
        if isHibernated, let title = hibernatedTitle, !title.isEmpty { base = title }
        else if let title = webView.title, !title.isEmpty { base = title }
        else if let host = webView.url?.host { base = host }
        else { base = "New Tab" }
        return isPinned ? "📌 \(base)" : base
    }

    init(configuration: WKWebViewConfiguration, isPrivate: Bool = false, installUserContentHandlers: Bool = true) {
        ownsScriptHandlers = installUserContentHandlers
        if installUserContentHandlers {
            let audioScript = WKUserScript(source: Self.audioDetectionJS,
                                            injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            configuration.userContentController.addUserScript(audioScript)
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.pictureInPictureJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false))
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.contextMenuJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false))
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.diagnosticsJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }

        webView = MCVWebView(frame: .zero, configuration: configuration)
        self.isPrivate = isPrivate
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.customUserAgent = Self.userAgentOverride ?? Self.defaultUA
        if installUserContentHandlers {
            webView.configuration.userContentController.add(self, name: Self.scriptHandlerName)
            webView.configuration.userContentController.add(self, name: Self.pictureInPictureHandlerName)
            webView.configuration.userContentController.add(self, name: Self.contextMenuHandlerName)
            (webView as? MCVWebView)?.onDownloadURL = { [weak self] url in self?.startDownload(url) }
        }
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.onUpdate?() },
            webView.observe(\.url) { [weak self] _, _ in self?.onUpdate?() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.onUpdate?() },
        ]
    }

    func load(_ url: URL) {
        isHibernated = false
        hibernatedURL = nil
        hibernatedTitle = nil
        lastRequestedURL = url
        webView.load(URLRequest(url: url))
    }

    func markActive() { lastActiveAt = Date() }

    /// Releases the page DOM, decoded images, JS heap and compositing layers
    /// without closing the logical tab. Pinned/audio/private tabs are filtered
    /// by TabManager before this is called.
    @discardableResult
    func hibernate() -> Bool {
        guard !isHibernated, !isPlayingAudio,
              let url = webView.url ?? lastRequestedURL,
              url.scheme == "http" || url.scheme == "https" else { return false }
        hibernatedURL = url
        hibernatedTitle = webView.title
        isHibernated = true
        webView.stopLoading()
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        webView.loadHTMLString("<!doctype html><meta charset=utf-8><title>Sleeping tab</title>", baseURL: nil)
        return true
    }

    func wakeIfNeeded() {
        markActive()
        guard isHibernated, let url = hibernatedURL else { return }
        load(url)
    }

    func setBackgroundMediaSuspended(_ suspended: Bool) {
        guard suspended != isMediaSuspended else { return }
        isMediaSuspended = suspended
        webView.setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
    }

    /// Розриває утримувальний цикл webView.configuration → userContentController → self,
    /// інакше вкладка ніколи не звільниться з пам'яті після закриття.
    func teardown() {
        if ownsScriptHandlers {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.scriptHandlerName)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.pictureInPictureHandlerName)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.contextMenuHandlerName)
        }
        onPictureInPictureStop?(self)
        MCVExtensionRuntime.shared.teardown(webView.configuration)
    }

    /// Обирає найбільшу задекларовану іконку (apple-touch-icon майже завжди
    /// значно якісніший за 16×16 favicon.ico), а не перший-ліпший тег.
    private static let faviconPickerJS = """
    (() => {
      const links = Array.from(document.querySelectorAll(
        "link[rel~='icon'], link[rel='apple-touch-icon'], link[rel='apple-touch-icon-precomposed']"
      ));
      function size(l) {
        const attr = l.getAttribute('sizes');
        if (!attr) return l.rel.includes('apple-touch-icon') ? 180 : 32;
        const m = attr.match(/(\\d+)x(\\d+)/i);
        return m ? parseInt(m[1], 10) : 32;
      }
      let best = null, bestSize = 0;
      for (const l of links) {
        const s = size(l);
        if (s > bestSize) { bestSize = s; best = l; }
      }
      return best ? best.href : (location.origin + '/favicon.ico');
    })();
    """

    private func fetchFavicon() {
        webView.evaluateJavaScript(Self.faviconPickerJS) { [weak self] result, _ in
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
          .some(el => !el.paused && !el.ended);
      }
      function report() {
        try { window.webkit.messageHandlers.mcvAudio.postMessage(isAnyPlaying()); } catch (e) {}
      }
      ['play', 'playing', 'pause', 'ended', 'volumechange'].forEach(evt => document.addEventListener(evt, report, true));
      report();
    })();
    """

    private static let diagnosticsJS = #"""
    (() => {
      if (globalThis.__mcvDiagnostics) return;
      const log = globalThis.__mcvDiagnostics = [];
      const add = (type,message,source='page') => {
        message=String(message||'').replace(/\s+/g,' ').slice(0,500);
        source=String(source||'page').slice(0,300);
        if(message && !log.some(x=>x.type===type&&x.message===message&&x.source===source)) {
          log.push({type,message,source}); if(log.length>100)log.shift();
        }
      };
      addEventListener('error', e => {
        const target=e.target;
        if(target && target!==globalThis) add('resource_error',target.src||target.href||target.tagName,'network');
        else add('javascript_error',e.message,e.filename||'script');
      }, true);
      addEventListener('unhandledrejection', e => add('unhandled_rejection',e.reason?.message||e.reason,'promise'));
      const original=console.error;
      console.error=(...args)=>{add('console_error',args.map(String).join(' '),'console');return original.apply(console,args)};
    })();
    """#

    /// Lightweight MCV mini-player. It deliberately avoids MutationObserver and
    /// continuous layout scans: JS-heavy sites such as YouTube mutate thousands of
    /// nodes per minute. One control tracks one primary video using media events.
    private static let pictureInPictureJS = #"""
    (() => {
      if (globalThis.__mcvPiPInstalled) return;
      globalThis.__mcvPiPInstalled = true;
      let video = null, framePending = false;
      const host = document.createElement('span');
      host.className = 'mcv-native-pip-control';
      const root = host.attachShadow({mode:'closed'});
      const button = document.createElement('button');
      button.type = 'button'; button.textContent = '▣';
      button.title = 'MCV Mini Player'; button.setAttribute('aria-label', 'MCV Mini Player');
      const style = document.createElement('style');
      style.textContent = `button{all:initial;box-sizing:border-box;width:34px;height:34px;border-radius:7px;
        display:grid;place-items:center;background:rgba(15,15,18,.86);color:white;font:600 18px -apple-system;
        box-shadow:0 2px 8px rgba(0,0,0,.35);cursor:pointer;opacity:.88}button:hover{opacity:1}`;
      root.append(style, button);
      host.style.cssText = 'position:fixed;z-index:2147483647;width:34px;height:34px;pointer-events:auto;display:none';
      document.documentElement.appendChild(host);

      function choose() {
        const candidates = Array.from(document.querySelectorAll('video')).filter(v => {
          const r = v.getBoundingClientRect(); return r.width >= 200 && r.height >= 112;
        });
        candidates.sort((a, b) => Number(a.paused) - Number(b.paused) ||
          b.getBoundingClientRect().width * b.getBoundingClientRect().height -
          a.getBoundingClientRect().width * a.getBoundingClientRect().height);
        video = candidates[0] || null;
        scheduleLayout();
      }
      button.addEventListener('click', event => {
        event.preventDefault(); event.stopPropagation();
        try { window.webkit.messageHandlers.mcvPictureInPicture.postMessage({}); } catch (_) {}
      }, true);
      function layout() {
        framePending = false;
        if (!video?.isConnected) { video = null; host.style.display = 'none'; return; }
        const r = video.getBoundingClientRect();
        const visible = r.width >= 200 && r.height >= 112 && r.bottom > 0 && r.top < innerHeight;
        host.style.display = visible ? 'block' : 'none';
        if (!visible) return;
        host.style.left = `${Math.max(8, Math.min(innerWidth - 42, r.right - 43))}px`;
        host.style.top = `${Math.max(8, Math.min(innerHeight - 42, r.top + 9))}px`;
      }
      function scheduleLayout() {
        if (!framePending) { framePending = true; requestAnimationFrame(layout); }
      }
      document.addEventListener('play', event => { if (event.target instanceof HTMLVideoElement) { video = event.target; scheduleLayout(); } }, true);
      document.addEventListener('loadedmetadata', event => { if (event.target instanceof HTMLVideoElement) choose(); }, true);
      addEventListener('scroll', scheduleLayout, true); addEventListener('resize', scheduleLayout);
      choose();
    })();
    """#

    private static let contextMenuJS = #"""
    (() => {
      document.addEventListener('contextmenu', event => {
        const path = event.composedPath?.() || [event.target];
        const image = path.find(node => node instanceof HTMLImageElement);
        const link = path.find(node => node instanceof HTMLAnchorElement && node.href);
        let imageURL = image ? (image.currentSrc || image.src || '') : '';
        if (!imageURL && event.target instanceof Element) {
          const bg = getComputedStyle(event.target).backgroundImage;
          const match = bg && bg.match(/^url\(["']?(.*?)["']?\)$/);
          imageURL = match ? match[1] : '';
        }
        try { window.webkit.messageHandlers.mcvContextMenu.postMessage({
          link: link?.href || '', image: imageURL
        }); } catch (_) {}
      }, true);
    })();
    """#

    private func startDownload(_ url: URL) {
        guard ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else {
            onDownloadEvent?("✕ This resource cannot be downloaded")
            return
        }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { return }
            download.delegate = self
            self.activeDownloads.append(download)
        }
    }
}

extension BrowserTab: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == Self.contextMenuHandlerName {
            let body = message.body as? [String: Any]
            let link = (body?["link"] as? String).flatMap(URL.init(string:))
            let image = (body?["image"] as? String).flatMap(URL.init(string:))
            (webView as? MCVWebView)?.pageDownloadContext = .init(link: link, image: image)
            return
        }
        if message.name == Self.pictureInPictureHandlerName {
            onPictureInPictureRequest?(self)
            return
        }
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
        if let url = navigationAction.request.url,
           navigationAction.targetFrame?.isMainFrame != false {
            lastRequestedURL = url
        }
        preferences.allowsContentJavaScript = SecurityManager.shared.effectiveJS
        decisionHandler(.allow, preferences)
    }

    // Все, що WebKit не може показати (архіви, бінарники…) — у завантаження.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse { lastHTTPStatus = response.statusCode }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        activeDownloads.append(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStart = Date()
        lastNavigationError = nil
        lastHTTPStatus = nil
        if isHibernated { return }
        MCVExtensionRuntime.shared.navigationEvent("onBeforeNavigate", tab: self)
    }

    // Час завантаження (команда `speed`) + глобальна історія (не для приватних вкладок).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isHibernated { return }
        if let start = navigationStart {
            lastLoadDuration = Date().timeIntervalSince(start)
        }
        fetchFavicon()
        MCVExtensionRuntime.shared.navigationEvent("onCompleted", tab: self)
        onBackgroundActivity?()
        guard !isPrivate, let url = webView.url?.absoluteString, !url.isEmpty else { return }
        let title = webView.title?.isEmpty == false ? webView.title! : url
        HistoryStore.shared.record(title: title, url: url)
        onPageReady?(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastNavigationError = error.localizedDescription
        MCVExtensionRuntime.shared.navigationEvent("onErrorOccurred", tab: self, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        lastNavigationError = error.localizedDescription
        MCVExtensionRuntime.shared.navigationEvent("onErrorOccurred", tab: self, error: error)
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
        onDownloadEvent?("✓ Download completed → Downloads")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.removeAll { $0 === download }
        if let id = downloadIDs[ObjectIdentifier(download)] { DownloadsCenter.shared.markFailed(id: id) }
        progressObservers[ObjectIdentifier(download)] = nil
        onDownloadEvent?("✕ Download failed")
    }
}

extension BrowserTab: WKUIDelegate {
    // target="_blank" і window.open → нова вкладка MCV.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let hasPopupSize = windowFeatures.width != nil || windowFeatures.height != nil
        if hasPopupSize { return onRequestPopup?(self, configuration, navigationAction, windowFeatures) }
        if let url = navigationAction.request.url {
            onRequestNewTab?(url)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) { onRequestClose?(self) }
}

final class TabManager {
    struct TabGroup {
        let id: UUID
        var title: String
        var colorIndex: Int
        var isCollapsed: Bool
        var tabIDs: [UUID]
    }

    private(set) var tabs: [BrowserTab] = []
    private(set) var tabGroups: [TabGroup] = []
    private(set) var currentIndex: Int = -1
    private var closedURLs: [URL] = []
    private let pinnedFileURL: URL
    private let groupsFileURL: URL
    private var pinnedPersistenceWorkItem: DispatchWorkItem?
    private var lastPinnedData: Data?

    init(pinnedFileURL: URL? = nil, groupsFileURL: URL? = nil) {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcv-tests-\(UUID().uuidString)", isDirectory: true)
        self.pinnedFileURL = pinnedFileURL ?? (isTesting
            ? testRoot.appendingPathComponent("pinned-tabs.json")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mcv/pinned-tabs.json"))
        self.groupsFileURL = groupsFileURL ?? (isTesting
            ? testRoot.appendingPathComponent("tab-groups.json")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mcv/tab-groups.json"))
    }

    /// Вкладки додано/закрито/перемкнуто.
    var onLayoutChange: (() -> Void)?
    /// Оновились title/url/isLoading поточних вкладок.
    var onContentChange: (() -> Void)?
    /// Події завантажень файлів (для тостів).
    var onDownloadMessage: ((String) -> Void)?
    var onPictureInPictureRequest: ((BrowserTab) -> Void)?
    var onPictureInPictureStop: ((BrowserTab) -> Void)?
    var onPopupRequest: ((BrowserTab, WKWebViewConfiguration, WKNavigationAction, WKWindowFeatures) -> WKWebView?)?
    var onPopupCloseRequest: ((BrowserTab) -> Void)?
    var onPageReady: ((BrowserTab) -> Void)?

    var current: BrowserTab? {
        tabs.indices.contains(currentIndex) ? tabs[currentIndex] : nil
    }

    var hibernatedCount: Int { tabs.lazy.filter(\.isHibernated).count }

    var homepageURL: URL? {
        let home = ConfigStore.shared.config.homepage
        return CommandEngine.url(from: home) ?? URL(string: home)
    }

    var sessionURLs: [String] {
        tabs.filter { !$0.isPinned }.compactMap { $0.logicalURL?.absoluteString }.filter { !$0.hasPrefix("about:") }
    }

    var pinnedURLs: [String] {
        tabs.filter(\.isPinned).compactMap { $0.logicalURL?.absoluteString }.filter { !$0.hasPrefix("about:") }
    }

    @discardableResult
    func newTab(url: URL?, ephemeral: Bool = false, pinned: Bool = false) -> BrowserTab {
        let configuration = ephemeral
            ? SecurityManager.shared.makeEphemeralConfiguration()
            : SecurityManager.shared.makeWebViewConfiguration()
        MCVExtensionRuntime.shared.configure(configuration)
        let tab = BrowserTab(configuration: configuration, isPrivate: ephemeral)
        tab.isPinned = pinned
        tab.onUpdate = { [weak self, weak tab] in
            self?.onContentChange?()
            if tab?.isPinned == true { self?.schedulePinnedPersistence() }
        }
        tab.onRequestNewTab = { [weak self] url in self?.newTab(url: url) }
        tab.onRequestPopup = { [weak self] opener, configuration, action, features in
            self?.onPopupRequest?(opener, configuration, action, features)
        }
        tab.onRequestClose = { [weak self] tab in self?.onPopupCloseRequest?(tab) }
        tab.onDownloadEvent = { [weak self] message in self?.onDownloadMessage?(message) }
        tab.onPictureInPictureRequest = { [weak self] tab in self?.onPictureInPictureRequest?(tab) }
        tab.onPictureInPictureStop = { [weak self] tab in self?.onPictureInPictureStop?(tab) }
        tab.onBackgroundActivity = { [weak self, weak tab] in
            guard let self, let tab, tab !== self.current else { return }
            tab.hasUnreadActivity = true
            self.onContentChange?()
        }
        tab.onPageReady = { [weak self] tab in self?.onPageReady?(tab) }
        if pinned {
            let insertion = tabs.firstIndex { !$0.isPinned } ?? tabs.endIndex
            tabs.insert(tab, at: insertion)
            currentIndex = insertion
        } else {
            tabs.append(tab)
            currentIndex = tabs.count - 1
        }
        tab.markActive()
        tab.setBackgroundMediaSuspended(false)
        if let url { tab.load(url) }
        onLayoutChange?()
        MCVExtensionRuntime.shared.tabEvent("onCreated", payload: ["id": currentIndex, "index": currentIndex, "active": true, "url": url?.absoluteString ?? ""])
        MCVExtensionRuntime.shared.tabEvent("onActivated", payload: ["tabId": currentIndex, "windowId": 1])
        return tab
    }

    func togglePinCurrent() {
        guard let tab = current else { return }
        tab.isPinned.toggle()
        tabs.removeAll { $0 === tab }
        let insertion = tabs.firstIndex { !$0.isPinned } ?? tabs.endIndex
        tabs.insert(tab, at: insertion)
        currentIndex = insertion
        persistPinnedTabs()
        onLayoutChange?()
    }

    /// Reorders only inside the tab's own pinned/unpinned section. This keeps
    /// the invariant that all pinned tabs form one leading contiguous block.
    @discardableResult
    func moveTab(from source: Int, to destination: Int) -> Bool {
        guard tabs.indices.contains(source), tabs.indices.contains(destination), source != destination,
              tabs[source].isPinned == tabs[destination].isPinned else { return false }
        let selected = current
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        currentIndex = selected.flatMap { selectedTab in tabs.firstIndex { $0 === selectedTab } } ?? 0
        if tab.isPinned { persistPinnedTabs() }
        onLayoutChange?()
        MCVExtensionRuntime.shared.tabEvent("onMoved", payload: [source, ["windowId": 1, "fromIndex": source, "toIndex": destination]])
        return true
    }

    func group(containing tabID: UUID) -> TabGroup? { tabGroups.first { $0.tabIDs.contains(tabID) } }

    @discardableResult
    func createGroup(from source: Int, with target: Int) -> UUID? {
        guard tabs.indices.contains(source), tabs.indices.contains(target), source != target,
              tabs[source].isPinned == tabs[target].isPinned else { return nil }
        let sourceTab = tabs[source], targetTab = tabs[target]
        if let existing = tabGroups.firstIndex(where: { $0.tabIDs.contains(targetTab.id) }) {
            guard !tabGroups[existing].tabIDs.contains(sourceTab.id) else { return tabGroups[existing].id }
            let existingID = tabGroups[existing].id
            tabGroups.indices.forEach { index in tabGroups[index].tabIDs.removeAll { $0 == sourceTab.id } }
            compactGroups()
            guard let updated = tabGroups.firstIndex(where: { $0.id == existingID }) else { return nil }
            tabGroups[updated].tabIDs.append(sourceTab.id)
            makeGroupContiguous(existingID)
            persistGroups()
            onLayoutChange?()
            return existingID
        }
        tabGroups.indices.forEach { index in
            tabGroups[index].tabIDs.removeAll { $0 == sourceTab.id || $0 == targetTab.id }
        }
        compactGroups()
        let id = UUID()
        tabGroups.append(TabGroup(id: id, title: "Group \(tabGroups.count + 1)", colorIndex: -1,
                                  isCollapsed: false, tabIDs: [targetTab.id, sourceTab.id]))
        makeGroupContiguous(id)
        persistGroups()
        onLayoutChange?()
        return id
    }

    func toggleGroup(_ id: UUID) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        tabGroups[index].isCollapsed.toggle()
        persistGroups()
        onLayoutChange?()
    }

    func setGroupColor(_ id: UUID, colorIndex: Int) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        tabGroups[index].colorIndex = max(-1, min(5, colorIndex))
        persistGroups()
        onLayoutChange?()
    }

    func ungroup(_ id: UUID) {
        guard tabGroups.contains(where: { $0.id == id }) else { return }
        tabGroups.removeAll { $0.id == id }
        persistGroups()
        onLayoutChange?()
    }

    func closeGroup(_ id: UUID) {
        guard let group = tabGroups.first(where: { $0.id == id }) else { return }
        let indexes = tabs.indices.filter { group.tabIDs.contains(tabs[$0].id) }.reversed()
        tabGroups.removeAll { $0.id == id }
        for index in indexes { _ = close(at: index, forcePinned: true) }
        persistGroups()
        onLayoutChange?()
    }

    @discardableResult
    func hibernateGroup(_ id: UUID) -> Int {
        guard let group = tabGroups.first(where: { $0.id == id }) else { return 0 }
        var count = 0
        for tab in tabs where group.tabIDs.contains(tab.id) && !tab.isPrivate && !tab.isPlayingAudio {
            if tab.hibernate() { count += 1 }
        }
        if let index = tabGroups.firstIndex(where: { $0.id == id }) { tabGroups[index].isCollapsed = true }
        persistGroups()
        onLayoutChange?()
        return count
    }

    func bookmarkGroup(_ id: UUID) -> Int {
        guard let group = tabGroups.first(where: { $0.id == id }) else { return 0 }
        let members = tabs.filter { group.tabIDs.contains($0.id) }
        ConfigStore.shared.update { config in
            if !config.bookmarkFolders.contains(group.title) { config.bookmarkFolders.append(group.title) }
            for tab in members {
                guard let url = tab.logicalURL?.absoluteString else { continue }
                let title = tab.displayTitle.replacingOccurrences(of: "/", with: "–")
                config.bookmarks["\(group.title)/\(title)"] = url
            }
        }
        return members.count
    }

    private func makeGroupContiguous(_ id: UUID) {
        guard let group = tabGroups.first(where: { $0.id == id }) else { return }
        let selected = current
        let members = group.tabIDs.compactMap { id in tabs.first { $0.id == id } }
        guard let first = tabs.firstIndex(where: { group.tabIDs.contains($0.id) }) else { return }
        tabs.removeAll { group.tabIDs.contains($0.id) }
        tabs.insert(contentsOf: members, at: min(first, tabs.count))
        currentIndex = selected.flatMap { selectedTab in tabs.firstIndex { $0 === selectedTab } } ?? 0
    }

    private func compactGroups() { tabGroups.removeAll { $0.tabIDs.count < 2 } }

    private struct StoredGroup: Codable {
        let title: String
        let colorIndex: Int
        let isCollapsed: Bool
        let urls: [String]
    }

    func restoreGroups() {
        guard let data = try? Data(contentsOf: groupsFileURL),
              let stored = try? JSONDecoder().decode([StoredGroup].self, from: data) else { return }
        tabGroups.removeAll()
        var claimed = Set<UUID>()
        for saved in stored {
            var members: [BrowserTab] = []
            for url in saved.urls {
                if let tab = tabs.first(where: { !claimed.contains($0.id) && $0.logicalURL?.absoluteString == url }) {
                    members.append(tab); claimed.insert(tab.id)
                }
            }
            guard members.count >= 2, Set(members.map(\.isPinned)).count == 1 else { continue }
            let id = UUID()
            tabGroups.append(TabGroup(id: id, title: saved.title, colorIndex: saved.colorIndex,
                                      isCollapsed: saved.isCollapsed, tabIDs: members.map(\.id)))
            makeGroupContiguous(id)
        }
        onLayoutChange?()
    }

    private func persistGroups() {
        let stored = tabGroups.compactMap { group -> StoredGroup? in
            let urls = group.tabIDs.compactMap { id in tabs.first { $0.id == id }?.logicalURL?.absoluteString }
            guard urls.count >= 2 else { return nil }
            return StoredGroup(title: group.title, colorIndex: group.colorIndex,
                               isCollapsed: group.isCollapsed, urls: urls)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let url = groupsFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func select(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        if index == currentIndex {
            tabs[index].wakeIfNeeded()
            tabs[index].hasUnreadActivity = false
            onLayoutChange?()
            return
        }
        currentIndex = index
        tabs[index].wakeIfNeeded()
        tabs[index].setBackgroundMediaSuspended(false)
        tabs[index].hasUnreadActivity = false
        onLayoutChange?()
        MCVExtensionRuntime.shared.tabEvent("onActivated", payload: ["tabId": index, "windowId": 1])
        hibernateBackgroundTabs(olderThan: 15 * 60)
    }

    func selectRelative(_ delta: Int) {
        guard tabs.count > 1 else { return }
        let index = ((currentIndex + delta) % tabs.count + tabs.count) % tabs.count
        select(at: index)
    }

    /// Browser shortcut semantics: ⌘9 always means the last tab. Any numeric
    /// shortcut beyond the current tab count also resolves to the last tab.
    func selectShortcut(_ number: Int) {
        guard !tabs.isEmpty, (1...9).contains(number) else { return }
        let target = number == 9 ? tabs.count - 1 : min(number - 1, tabs.count - 1)
        select(at: target)
    }

    /// Starts a fresh logical browser window while keeping globally pinned
    /// pages. Used after the last window was closed but the macOS app remains.
    func resetForNewWindow() {
        let pinned = tabs.filter(\.isPinned).compactMap(\.logicalURL)
        tabs.forEach { $0.teardown() }
        tabs.removeAll()
        tabGroups.removeAll()
        currentIndex = -1
        pinned.forEach { newTab(url: $0, pinned: true) }
        newTab(url: nil)
        restoreGroups()
    }

    @discardableResult
    func close(at index: Int, forcePinned: Bool = false) -> Bool {
        guard tabs.indices.contains(index), forcePinned || !tabs[index].isPinned else { return false }
        MCVExtensionRuntime.shared.tabEvent("onRemoved", payload: [index, ["windowId": 1, "isWindowClosing": false]])
        rememberClosed(tabs[index])
        tabs[index].teardown()
        let removedID = tabs[index].id
        tabs.remove(at: index)
        tabGroups.indices.forEach { group in tabGroups[group].tabIDs.removeAll { $0 == removedID } }
        compactGroups()
        persistGroups()
        persistPinnedTabs()
        if tabs.isEmpty {
            currentIndex = -1
            newTab(url: nil) // native empty tab; no about:blank navigation
            return true
        }
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            currentIndex = min(index, tabs.count - 1)
        }
        onLayoutChange?()
        return true
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
        guard let url = tab.logicalURL else { return }
        closedURLs.append(url)
        if closedURLs.count > 25 { closedURLs.removeFirst() }
    }

    private func persistPinnedTabs() {
        pinnedPersistenceWorkItem?.cancel()
        pinnedPersistenceWorkItem = nil
        guard let data = try? JSONEncoder().encode(pinnedURLs), data != lastPinnedData else { return }
        lastPinnedData = data
        let fileURL = pinnedFileURL
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func schedulePinnedPersistence() {
        pinnedPersistenceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistPinnedTabs() }
        pinnedPersistenceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Event-driven, never polled. The normal path only sleeps genuinely cold
    /// tabs; pressure paths may become increasingly aggressive.
    @discardableResult
    func hibernateBackgroundTabs(olderThan age: TimeInterval, includePinned: Bool = false) -> Int {
        let cutoff = Date().addingTimeInterval(-age)
        var count = 0
        for tab in tabs where tab !== current {
            guard !tab.isPrivate, !tab.isPlayingAudio, !tab.isHibernated,
                  (includePinned || !tab.isPinned), tab.lastActiveAt <= cutoff else { continue }
            if tab.hibernate() { count += 1 }
        }
        return count
    }
}
