import AppKit

struct CommandDescriptor {
    let name: String
    let usage: String
    let help: String
}

enum ZoomAction {
    case increase, decrease, reset
    case set(Double)
}

/// Все, що вміє браузер з точки зору команд. UI реалізує цей протокол,
/// тож ядро команд не знає нічого про AppKit-вікна і портується як є.
protocol BrowserControlling: AnyObject {
    var currentURL: URL? { get }
    var currentTitle: String? { get }

    func navigate(to url: URL, newTab: Bool)
    func reloadPage()
    func goBack()
    func goForward()
    func openNewTab()
    func closeCurrentTab()
    func selectTab(index: Int)
    func nextTab()
    func previousTab()
    func duplicateTab()
    func closeOtherTabs()
    func reopenClosedTab()
    func showTabSwitcher()
    func applyTheme(dark: Bool)
    func applyTheme(mode: String)
    func toggleMinimalMode()
    func activateReader()
    func showLocalPage(html: String)
    func toast(_ message: String)

    func findInPage(_ query: String)
    func setZoom(_ action: ZoomAction)
    func viewSource()
    func printPage()
    func exportPDF()
    func snapshotPage()
    func scrollToTop()
    func scrollToBottom()
    func showQRCode()
    func setUserAgent(_ ua: String?)
    func showHistoryPage()
    func clearBrowsingData()
    func setWindowOpacity(_ value: Double)
    func toggleFullscreen()
    func toggleFloatOnTop()
    func restoreLastSession()

    func togglePinCurrentTab()
    func openPrivateTab()
    func showLoadSpeed()
    func showPerformanceStats()
    func clearHistory()
    func toggleDownloadsSidebar()
    func toggleBookmarksSidebar()
    func toggleSidebarMode()
    func runAI(_ command: String)
}

final class CommandEngine {
    weak var browser: BrowserControlling?

    // MARK: - Пошуковики (команда → базовий URL)

    static let searchEngines: [String: (base: String, help: String)] = [
        "g": ("https://www.google.com/search?q=", "Search Google"),
        "ddg": ("https://duckduckgo.com/?q=", "Search DuckDuckGo"),
        "yt": ("https://www.youtube.com/results?search_query=", "Search YouTube"),
        "wiki": ("https://en.wikipedia.org/w/index.php?search=", "Search Wikipedia"),
        "gh": ("https://github.com/search?q=", "Search GitHub"),
        "so": ("https://stackoverflow.com/search?q=", "Search Stack Overflow"),
        "npm": ("https://www.npmjs.com/search?q=", "Search npm"),
        "mdn": ("https://developer.mozilla.org/en-US/search?q=", "Search MDN"),
        "img": ("https://www.google.com/search?tbm=isch&q=", "Search images"),
        "maps": ("https://www.google.com/maps/search/", "Google Maps"),
    ]

    static let descriptors: [CommandDescriptor] = [
        .init(name: "open", usage: "open <url>", help: "Open a page"),
        .init(name: "reload", usage: "reload", help: "Reload the page"),
        .init(name: "back", usage: "back", help: "Go back"),
        .init(name: "forward", usage: "forward", help: "Go forward"),
        .init(name: "home", usage: "home", help: "Open the home page"),
        .init(name: "new", usage: "new [url]", help: "Open a new tab"),
        .init(name: "close", usage: "close", help: "Close the current tab"),
        .init(name: "only", usage: "only", help: "Close all other tabs"),
        .init(name: "reopen", usage: "reopen", help: "Reopen the last closed tab (⇧⌘T)"),
        .init(name: "dup", usage: "dup", help: "Duplicate the current tab"),
        .init(name: "pin", usage: "pin", help: "Pin or unpin the current tab"),
        .init(name: "private", usage: "private [url]", help: "Open a private tab without persistent history or cookies"),
        .init(name: "tabs", usage: "tabs", help: "Show the tab switcher (⌘P)"),
        .init(name: "tab", usage: "tab <n>", help: "Switch to tab n (⌘1–9)"),
        .init(name: "next", usage: "next", help: "Switch to the next tab (⇧⌘])"),
        .init(name: "prev", usage: "prev", help: "Switch to the previous tab (⇧⌘[)"),
    ] + searchEngines
        .sorted { $0.key < $1.key }
        .map { .init(name: $0.key, usage: "\($0.key) <query>", help: $0.value.help) }
    + [
        .init(name: "find", usage: "find <text>", help: "Find on page (⌘F; repeat for next match)"),
        .init(name: "zoom", usage: "zoom in|out|reset|<50-300>", help: "Change page zoom"),
        .init(name: "reader", usage: "reader", help: "Open Reader Mode (⇧⌘R)"),
        .init(name: "src", usage: "src", help: "Show the page HTML source"),
        .init(name: "hist", usage: "hist [clear]", help: "Show global browsing history"),
        .init(name: "speed", usage: "speed", help: "Show the current page load time"),
        .init(name: "perf", usage: "perf", help: "Show live MCV performance counters"),
        .init(name: "print", usage: "print", help: "Print the page"),
        .init(name: "pdf", usage: "pdf", help: "Save the page as a PDF in Downloads"),
        .init(name: "shot", usage: "shot", help: "Save a page screenshot in Downloads"),
        .init(name: "qr", usage: "qr", help: "Create a QR code for the current address"),
        .init(name: "downloads", usage: "downloads", help: "Toggle the Downloads sidebar"),
        .init(name: "top", usage: "top", help: "Scroll to the top"),
        .init(name: "bottom", usage: "bottom", help: "Scroll to the bottom"),
        .init(name: "copyurl", usage: "copyurl", help: "Copy the current address"),
        .init(name: "copytitle", usage: "copytitle", help: "Copy the page title"),
        .init(name: "bm", usage: "bm [add|rm|name]", help: "Bookmarks: bm add to add; bm to list"),
        .init(name: "calc", usage: "calc <expression>", help: "Calculator"),
        .init(name: "tran", usage: "tran <text>", help: "Translate text"),
        .init(name: "uuid", usage: "uuid", help: "Generate a UUID"),
        .init(name: "rand", usage: "rand [n]", help: "Generate a random number from 1 to n"),
        .init(name: "pass", usage: "pass [length]", help: "Generate a secure password"),
        .init(name: "b64", usage: "b64 <text>", help: "Encode Base64"),
        .init(name: "b64d", usage: "b64d <text>", help: "Decode Base64"),
        .init(name: "hex", usage: "hex <number|0x…>", help: "Convert decimal and hexadecimal"),
        .init(name: "bin", usage: "bin <number|0b…>", help: "Convert decimal and binary"),
        .init(name: "len", usage: "len <text>", help: "Count characters and words"),
        .init(name: "lorem", usage: "lorem [n]", help: "Generate n words of Lorem ipsum"),
        .init(name: "color", usage: "color <#hex>", help: "Preview a color"),
        .init(name: "date", usage: "date", help: "Show the current date and time"),
        .init(name: "ip", usage: "ip", help: "Show your public IP address"),
        .init(name: "dark", usage: "dark", help: "Use the dark theme"),
        .init(name: "light", usage: "light", help: "Use the light theme"),
        .init(name: "system", usage: "system", help: "Follow the macOS appearance"),
        .init(name: "opacity", usage: "opacity <30-100>", help: "Change window opacity"),
        .init(name: "minimal", usage: "minimal", help: "Toggle Minimal Mode (⇧⌘M)"),
        .init(name: "sidebar", usage: "sidebar on|off", help: "Toggle the favicon-only sidebar"),
        .init(name: "fullscreen", usage: "fullscreen", help: "Toggle full screen"),
        .init(name: "float", usage: "float", help: "Toggle always-on-top mode"),
        .init(name: "mode", usage: "mode classic|safe|secure", help: "Change the security mode"),
        .init(name: "js", usage: "js on|off", help: "Enable or disable JavaScript"),
        .init(name: "ua", usage: "ua <string>|reset", help: "Change the User-Agent"),
        .init(name: "clear", usage: "clear", help: "Clear cookies, cache, and website data"),
        .init(name: "restore", usage: "restore", help: "Restore the previous session"),
        .init(name: "ai", usage: "ai <page|ui|api|research|memory|tabs|focus|scam|debug|ask|status>", help: "Local semantic browser powered by Gemma 3 1B"),
        .init(name: "alias", usage: "alias <key> <command>", help: "Create a command alias"),
        .init(name: "unalias", usage: "unalias <key>", help: "Remove a command alias"),
        .init(name: "help", usage: "help", help: "Show help"),
        .init(name: "quit", usage: "quit", help: "Quit MCV"),
    ]

    // MARK: - Виконання

    /// preferNewTab — навігація йде в нову вкладку замість поточної.
    func execute(_ raw: String, preferNewTab: Bool = false) {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        // Розгортання alias'ів (до 5 рівнів, щоб не зациклитись)
        var hops = 0
        while hops < 5 {
            let head = String(input.split(separator: " ", maxSplits: 1)[0])
            guard let expansion = ConfigStore.shared.config.aliases[head] else { break }
            let rest = input.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
            input = rest.isEmpty ? expansion : "\(expansion) \(rest)"
            hops += 1
        }

        let parts = input.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0].lowercased()
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        if let engine = Self.searchEngines[cmd] {
            search(engine.base, arg, preferNewTab)
            return
        }

        switch cmd {
        // --- Навігація й вкладки ---
        case "open":
            if let url = Self.url(from: arg) {
                browser?.navigate(to: url, newTab: preferNewTab)
            } else {
                browser?.toast("open: invalid URL")
            }
        case "reload": browser?.reloadPage()
        case "back": browser?.goBack()
        case "forward": browser?.goForward()
        case "home":
            let home = ConfigStore.shared.config.homepage
            if let url = Self.url(from: home) ?? URL(string: home) {
                browser?.navigate(to: url, newTab: false)
            }
        case "new":
            if arg.isEmpty {
                browser?.openNewTab()
            } else if let url = Self.url(from: arg) {
                browser?.navigate(to: url, newTab: true)
            }
        case "close": browser?.closeCurrentTab()
        case "only": browser?.closeOtherTabs()
        case "reopen": browser?.reopenClosedTab()
        case "dup": browser?.duplicateTab()
        case "pin": browser?.togglePinCurrentTab()
        case "private":
            browser?.openPrivateTab()
            if let url = Self.url(from: arg) { browser?.navigate(to: url, newTab: false) }
        case "tabs": browser?.showTabSwitcher()
        case "tab":
            if let n = Int(arg), n >= 1 { browser?.selectTab(index: n - 1) }
            else { browser?.toast("tab <number>") }
        case "next": browser?.nextTab()
        case "prev": browser?.previousTab()

        // --- Сторінка ---
        case "find": browser?.findInPage(arg)
        case "zoom": handleZoom(arg)
        case "reader": browser?.activateReader()
        case "src": browser?.viewSource()
        case "hist":
            if arg.lowercased() == "clear" {
                browser?.clearHistory()
            } else {
                browser?.showHistoryPage()
            }
        case "speed": browser?.showLoadSpeed()
        case "perf": browser?.showPerformanceStats()
        case "print": browser?.printPage()
        case "pdf": browser?.exportPDF()
        case "shot": browser?.snapshotPage()
        case "qr": browser?.showQRCode()
        case "downloads": browser?.toggleDownloadsSidebar()
        case "top": browser?.scrollToTop()
        case "bottom": browser?.scrollToBottom()
        case "copyurl", "cu":
            if let url = browser?.currentURL?.absoluteString { copyToast(url) }
            else { browser?.toast("No active page") }
        case "copytitle", "ct":
            if let title = browser?.currentTitle { copyToast(title) }
            else { browser?.toast("No active page") }

        // --- Закладки ---
        case "bm": handleBookmarks(arg)

        // --- Утиліти ---
        case "calc":
            if let value = Calculator.evaluate(arg) {
                copyToast(Self.format(value), prefix: "= ")
            } else {
                browser?.toast("calc: invalid expression")
            }
        case "tran":
            guard !arg.isEmpty else { browser?.toast("tran <text>"); return }
            switch Translator.translate(arg, target: ConfigStore.shared.config.translateTarget) {
            case .text(let translated): browser?.toast("→ \(translated)")
            case .url(let url): browser?.navigate(to: url, newTab: true)
            }
        case "uuid": copyToast(UUID().uuidString)
        case "rand":
            let upper = max(2, Int(arg) ?? 100)
            copyToast("\(Int.random(in: 1...upper))", prefix: "1–\(upper): ")
        case "pass":
            let length = min(64, max(6, Int(arg) ?? 20))
            copyToast(Self.generatePassword(length: length))
        case "b64":
            guard !arg.isEmpty else { browser?.toast("b64 <text>"); return }
            copyToast(Data(arg.utf8).base64EncodedString())
        case "b64d":
            if let data = Data(base64Encoded: arg), let text = String(data: data, encoding: .utf8) {
                copyToast(text)
            } else {
                browser?.toast("b64d: invalid Base64")
            }
        case "hex":
            if arg.lowercased().hasPrefix("0x"), let v = Int(arg.dropFirst(2), radix: 16) {
                copyToast("\(v)")
            } else if let v = Int(arg) {
                copyToast("0x" + String(v, radix: 16))
            } else {
                browser?.toast("hex <number|0x…>")
            }
        case "bin":
            if arg.lowercased().hasPrefix("0b"), let v = Int(arg.dropFirst(2), radix: 2) {
                copyToast("\(v)")
            } else if let v = Int(arg) {
                copyToast("0b" + String(v, radix: 2))
            } else {
                browser?.toast("bin <number|0b…>")
            }
        case "len":
            guard !arg.isEmpty else { browser?.toast("len <text>"); return }
            let words = arg.split(whereSeparator: { $0.isWhitespace }).count
            browser?.toast("Characters: \(arg.count) · words: \(words)")
        case "lorem":
            let count = min(500, max(1, Int(arg) ?? 30))
            copyToast(Self.lorem(count), prefix: "")
        case "color":
            handleColor(arg)
        case "date":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "EEEE, d MMMM yyyy · HH:mm:ss"
            browser?.toast(formatter.string(from: Date()))
        case "ip":
            fetchIP()

        // --- Вигляд ---
        case "dark": browser?.applyTheme(dark: true)
        case "light": browser?.applyTheme(dark: false)
        case "system": browser?.applyTheme(mode: "system")
        case "opacity":
            if let pct = Int(arg), (30...100).contains(pct) {
                browser?.setWindowOpacity(Double(pct) / 100)
            } else {
                browser?.toast("opacity 30–100")
            }
        case "minimal": browser?.toggleMinimalMode()
        case "sidebar":
            switch arg.lowercased() {
            case "on": if ConfigStore.shared.config.sidebarMode == false { browser?.toggleSidebarMode() }
            case "off": if ConfigStore.shared.config.sidebarMode == true { browser?.toggleSidebarMode() }
            default: browser?.toggleSidebarMode()
            }
        case "fullscreen", "fs": browser?.toggleFullscreen()
        case "float": browser?.toggleFloatOnTop()

        // --- Безпека ---
        case "mode":
            if let m = SecurityMode(rawValue: arg.lowercased()) {
                SecurityManager.shared.setMode(m)
                let extra = m == .secure ? " — new tabs are fully isolated" : ""
                browser?.toast("Mode: \(m.label)\(extra)")
            } else {
                browser?.toast("mode classic|safe|secure")
            }
        case "js":
            switch arg.lowercased() {
            case "on":
                SecurityManager.shared.setJavaScript(true)
                browser?.toast("JavaScript enabled — reload the page")
            case "off":
                SecurityManager.shared.setJavaScript(false)
                browser?.toast("JavaScript disabled — reload the page")
            default:
                browser?.toast("js on|off")
            }
        case "ua":
            if arg.isEmpty { browser?.toast("ua <string> or ua reset") }
            else if arg.lowercased() == "reset" { browser?.setUserAgent(nil) }
            else { browser?.setUserAgent(arg) }
        case "clear": browser?.clearBrowsingData()

        // --- Сесія / система ---
        case "restore": browser?.restoreLastSession()
        case "ai": browser?.runAI(arg)
        case "alias":
            let sub = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if sub.isEmpty {
                let list = ConfigStore.shared.config.aliases
                    .map { "\($0.key) → \($0.value)" }.sorted().joined(separator: "   ")
                browser?.toast(list.isEmpty ? "No aliases" : list)
            } else if sub.count == 1 {
                let existing = ConfigStore.shared.config.aliases[sub[0]]
                browser?.toast(existing.map { "\(sub[0]) → \($0)" } ?? "Alias “\(sub[0])” was not found")
            } else {
                ConfigStore.shared.update { $0.aliases[sub[0]] = sub[1] }
                browser?.toast("alias: \(sub[0]) → \(sub[1])")
            }
        case "unalias":
            ConfigStore.shared.update { $0.aliases.removeValue(forKey: arg) }
            browser?.toast("unalias: \(arg)")
        case "help": browser?.showLocalPage(html: Self.helpHTML())
        case "quit": NSApp.terminate(nil)

        default:
            // Не команда → URL або пошук пошуковиком за замовчуванням
            if let url = Self.url(from: input) {
                browser?.navigate(to: url, newTab: preferNewTab)
            } else {
                let base = Self.searchEngines[ConfigStore.shared.config.searchEngine]?.base
                    ?? Self.searchEngines["ddg"]!.base
                search(base, input, preferNewTab)
            }
        }
    }

    // MARK: - Обробники

    private func handleZoom(_ arg: String) {
        switch arg.lowercased() {
        case "in": browser?.setZoom(.increase)
        case "out": browser?.setZoom(.decrease)
        case "reset", "": browser?.setZoom(.reset)
        default:
            let cleaned = arg.replacingOccurrences(of: "%", with: "")
            if let pct = Int(cleaned), (25...500).contains(pct) {
                browser?.setZoom(.set(Double(pct) / 100))
            } else {
                browser?.toast("zoom in|out|reset|<25-500>")
            }
        }
    }

    private func handleBookmarks(_ arg: String) {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let bookmarks = ConfigStore.shared.config.bookmarks

        if parts.isEmpty {
            if bookmarks.isEmpty {
                browser?.toast("No bookmarks — use bm add [name]")
            } else {
                browser?.showLocalPage(html: Self.bookmarksHTML(bookmarks))
            }
            return
        }

        switch parts[0] {
        case "add":
            guard let url = browser?.currentURL?.absoluteString else {
                browser?.toast("No page to bookmark")
                return
            }
            let name = parts.count > 1 ? parts[1] : (browser?.currentTitle ?? url)
            ConfigStore.shared.update { $0.bookmarks[name] = url }
            browser?.toast("★ \(name)")
        case "rm":
            guard parts.count > 1 else { browser?.toast("bm rm <name>"); return }
            ConfigStore.shared.update { $0.bookmarks.removeValue(forKey: parts[1]) }
            browser?.toast("Bookmark removed: \(parts[1])")
        default:
            let exact = bookmarks[arg]
            let byPrefix = bookmarks.first { $0.key.lowercased().hasPrefix(arg.lowercased()) }?.value
            if let target = exact ?? byPrefix, let url = URL(string: target) {
                browser?.navigate(to: url, newTab: false)
            } else {
                browser?.toast("Bookmark not found: \(arg)")
            }
        }
    }

    private func handleColor(_ arg: String) {
        var hex = arg.hasPrefix("#") ? String(arg.dropFirst()) : arg
        guard (3...8).contains(hex.count), hex.allSatisfy({ $0.isHexDigit }) else {
            browser?.toast("color <#hex>, for example: color #ff6600")
            return
        }
        hex = "#" + hex
        let body = """
        <div style="min-height:70vh;display:flex;align-items:center;justify-content:center;
                    background:\(hex);border-radius:16px;margin-top:24px">
          <span style="font:600 32px ui-monospace,monospace;background:rgba(0,0,0,.55);
                       color:#fff;padding:12px 28px;border-radius:12px">\(hex)</span>
        </div>
        """
        browser?.showLocalPage(html: Self.localPage(title: hex, body: body))
    }

    private func fetchIP() {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                if let data, let ip = String(data: data, encoding: .utf8), !ip.isEmpty {
                    self?.copyToast(ip, prefix: "IP: ")
                } else {
                    self?.browser?.toast("IP: network error")
                }
            }
        }.resume()
    }

    private func search(_ base: String, _ query: String, _ newTab: Bool) {
        guard !query.isEmpty else { browser?.toast("Empty query"); return }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let url = URL(string: base + encoded) {
            browser?.navigate(to: url, newTab: newTab)
        }
    }

    private func copyToast(_ value: String, prefix: String = "") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        let display = value.count > 80 ? String(value.prefix(80)) + "…" : value
        browser?.toast("\(prefix)\(display)  (copied)")
    }

    // MARK: - Хелпери

    static func url(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if t.contains("://") { return URL(string: t) }
        if t.hasPrefix("localhost") || t.hasPrefix("127.") { return URL(string: "http://" + t) }
        if t.contains(".") { return URL(string: "https://" + t) }
        return nil
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%g", value)
    }

    static func lorem(_ count: Int) -> String {
        let base = """
        lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor \
        incididunt ut labore et dolore magna aliqua enim ad minim veniam quis nostrud \
        exercitation ullamco laboris nisi aliquip ex ea commodo consequat
        """.split(separator: " ").map(String.init)
        return (0..<count).map { base[$0 % base.count] }.joined(separator: " ")
    }

    static func generatePassword(length: Int) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*-_=+")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// Спільна обгортка для локальних сторінок (довідка, закладки, історія, QR…).
    static func localPage(title: String, body: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(title)</title><style>
        :root{color-scheme:light dark;background:#F8F9FA;color:#1A1A1A}
        @media (prefers-color-scheme:dark){:root{background:#0A0A0A;color:#EAEAEA}}
        body{max-width:760px;margin:48px auto;padding:0 24px;
             font:14px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;background:inherit;color:inherit}
        h1{font-size:24px;font-weight:600;line-height:1.3} h2{font-size:18px;font-weight:600;margin-top:32px}
        table{border-collapse:collapse;width:100%}
        td{padding:8px 12px;border-bottom:1px solid rgba(136,136,136,.25);vertical-align:top}
        a{color:#6C5CE7;text-decoration:none} a:hover{text-decoration:underline}
        code{font:13px ui-monospace,SFMono-Regular,monospace;background:rgba(108,92,231,.12);
             padding:2px 6px;border-radius:4px;white-space:nowrap}
        .tagline{color:#888888;font-size:12px}
        </style></head><body>\(body)</body></html>
        """
    }

    static func bookmarksHTML(_ bookmarks: [String: String]) -> String {
        let rows = bookmarks.sorted { $0.key < $1.key }.map { name, url in
            "<tr><td>★</td><td><a href=\"\(url)\">\(name)</a></td><td class=\"tagline\">\(url)</td></tr>"
        }.joined()
        let body = """
        <h1>Bookmarks</h1>
        <p class="tagline">bm add [name] — add · bm rm &lt;name&gt; — remove · bm &lt;name&gt; — open</p>
        <table>\(rows)</table>
        """
        return localPage(title: "MCV — Bookmarks", body: body)
    }

    static func helpHTML() -> String {
        let commandRows = descriptors
            .map { "<tr><td><code>\($0.usage)</code></td><td>\($0.help)</td></tr>" }
            .joined()
        let shortcutRows = ConfigStore.shared.config.shortcuts
            .sorted { $0.key < $1.key }
            .map { "<tr><td><code>\($0.value)</code></td><td>\($0.key)</td></tr>" }
            .joined()
        let body = """
        <h1>MCV Browser</h1>
        <p class="tagline">Fewer clicks. More done.</p>
        <h2>Commands</h2><table>\(commandRows)</table>
        <h2>Shortcuts</h2><table>\(shortcutRows)</table>
        <p class="tagline">Config: <code>~/.mcv/config.json</code> · F Corp</p>
        """
        return localPage(title: "MCV — Help", body: body)
    }
}
