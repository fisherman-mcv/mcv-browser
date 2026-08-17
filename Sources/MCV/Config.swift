import Foundation

extension Notification.Name {
    static let mcvConfigChanged = Notification.Name("MCVConfigChanged")
}

/// Конфігурація MCV. Зберігається у ~/.mcv/config.json.
struct MCVConfig: Codable {
    var theme: String
    var mode: String
    var javascript: Bool
    var homepage: String
    var searchEngine: String
    var translateTarget: String
    var windowOpacity: Double
    var restoreSession: Bool
    var sidebarMode: Bool
    var hasCompletedOnboarding: Bool
    var semanticMemory: Bool
    var aliases: [String: String]
    var bookmarks: [String: String]
    var bookmarkFolders: [String]
    var shortcuts: [String: String]

    enum CodingKeys: String, CodingKey {
        case theme, mode, javascript, homepage, searchEngine, translateTarget,
             windowOpacity, restoreSession, sidebarMode, hasCompletedOnboarding, semanticMemory,
             aliases, bookmarks, bookmarkFolders, shortcuts
    }

    static let standard = MCVConfig(
        theme: "dark",
        mode: "safe",
        javascript: true,
        homepage: "https://duckduckgo.com",
        searchEngine: "ddg",
        translateTarget: "uk",
        windowOpacity: 1.0,
        restoreSession: true,
        sidebarMode: false,
        hasCompletedOnboarding: false,
        semanticMemory: true,
        aliases: [
            "hn": "open news.ycombinator.com",
        ],
        bookmarks: [:],
        bookmarkFolders: [],
        shortcuts: [
            "commandPalette": "cmd+e",
            "tabSwitcher": "cmd+shift+p",
            "minimalMode": "cmd+shift+m",
            "newTab": "cmd+t",
            "closeTab": "cmd+w",
            "reload": "cmd+r",
            "focusAddress": "cmd+l",
            "pinTab": "cmd+p",
        ]
    )
}

extension MCVConfig {
    // Ручний decode: юзер може тримати в конфігу лише частину ключів —
    // відсутні поля добираються зі стандартних, а не валять весь файл.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MCVConfig.standard
        theme = (try? c.decode(String.self, forKey: .theme)) ?? d.theme
        mode = (try? c.decode(String.self, forKey: .mode)) ?? d.mode
        javascript = (try? c.decode(Bool.self, forKey: .javascript)) ?? d.javascript
        homepage = (try? c.decode(String.self, forKey: .homepage)) ?? d.homepage
        searchEngine = (try? c.decode(String.self, forKey: .searchEngine)) ?? d.searchEngine
        translateTarget = (try? c.decode(String.self, forKey: .translateTarget)) ?? d.translateTarget
        windowOpacity = (try? c.decode(Double.self, forKey: .windowOpacity)) ?? d.windowOpacity
        restoreSession = (try? c.decode(Bool.self, forKey: .restoreSession)) ?? d.restoreSession
        sidebarMode = (try? c.decode(Bool.self, forKey: .sidebarMode)) ?? d.sidebarMode
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        semanticMemory = (try? c.decode(Bool.self, forKey: .semanticMemory)) ?? d.semanticMemory
        aliases = (try? c.decode([String: String].self, forKey: .aliases)) ?? d.aliases
        bookmarks = (try? c.decode([String: String].self, forKey: .bookmarks)) ?? d.bookmarks
        bookmarkFolders = (try? c.decode([String].self, forKey: .bookmarkFolders)) ?? d.bookmarkFolders
        var merged = d.shortcuts
        if let user = try? c.decode([String: String].self, forKey: .shortcuts) {
            for (k, v) in user { merged[k] = v }
        }
        // Migrate the short-lived binding where ⌘D pinned a tab and ⌘P opened
        // the switcher. ⌘D is the conventional bookmark action again.
        if merged["pinTab"] == "cmd+d", merged["tabSwitcher"] == "cmd+p" {
            merged["pinTab"] = "cmd+p"
            merged["tabSwitcher"] = "cmd+shift+p"
        }
        shortcuts = merged
    }
}

final class ConfigStore {
    static let shared = ConfigStore()

    private(set) var config: MCVConfig

    private let dirURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mcv", isDirectory: true)
    private var fileURL: URL { dirURL.appendingPathComponent("config.json") }

    private init() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mcv/config.json")
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode(MCVConfig.self, from: data) {
            config = parsed
        } else {
            config = .standard
        }
        save() // гарантує наявність файлу після першого запуску
    }

    func update(_ mutate: (inout MCVConfig) -> Void) {
        mutate(&config)
        save()
        NotificationCenter.default.post(name: .mcvConfigChanged, object: self)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: fileURL)
        }
    }
}
