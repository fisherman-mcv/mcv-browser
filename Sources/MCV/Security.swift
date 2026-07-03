import WebKit

enum SecurityMode: String, CaseIterable {
    case classic, safe, secure

    var label: String {
        switch self {
        case .classic: return "CLASSIC"
        case .safe: return "SAFE"
        case .secure: return "SECURE"
        }
    }
}

/// Режими безпеки + вбудований блокувальник трекерів/реклами на WKContentRuleList —
/// той самий механізм декларативних правил, що й у контент-блокерів Safari,
/// працює в мережевому шарі WebKit без витрат на JS.
final class SecurityManager {
    static let shared = SecurityManager()

    private(set) var mode: SecurityMode
    private(set) var javascriptEnabled: Bool
    private(set) var adblockRules: WKContentRuleList?

    /// Викликається при зміні режиму/JS та після компіляції правил.
    var onChange: (() -> Void)?

    private static let trackerDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "adservice.google.com",
        "adnxs.com", "adsrvr.org", "criteo.com", "criteo.net",
        "taboola.com", "outbrain.com", "scorecardresearch.com", "quantserve.com",
        "moatads.com", "adsafeprotected.com", "connect.facebook.net",
        "hotjar.com", "mouseflow.com", "mc.yandex.ru", "an.yandex.ru",
        "mixpanel.com", "amplitude.com", "segment.io", "branch.io", "appsflyer.com",
    ]

    private init() {
        mode = SecurityMode(rawValue: ConfigStore.shared.config.mode) ?? .safe
        javascriptEnabled = ConfigStore.shared.config.javascript
    }

    /// JS реально доступний: у Secure він примусово вимкнений.
    var effectiveJS: Bool { mode == .secure ? false : javascriptEnabled }

    func bootstrap() {
        compileRules()
    }

    func setMode(_ newMode: SecurityMode) {
        mode = newMode
        ConfigStore.shared.update { $0.mode = newMode.rawValue }
        onChange?()
    }

    func setJavaScript(_ enabled: Bool) {
        javascriptEnabled = enabled
        ConfigStore.shared.update { $0.javascript = enabled }
        onChange?()
    }

    func makeWebViewConfiguration() -> WKWebViewConfiguration {
        makeConfiguration(forceEphemeral: mode == .secure)
    }

    /// Приватна вкладка (`private`/`incognito`) — ephemeral незалежно від
    /// глобального режиму безпеки, для разового приватного перегляду.
    func makeEphemeralConfiguration() -> WKWebViewConfiguration {
        makeConfiguration(forceEphemeral: true)
    }

    private func makeConfiguration(forceEphemeral: Bool) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        if forceEphemeral {
            cfg.websiteDataStore = .nonPersistent() // повна ізоляція: без кук і кешу на диску
        }
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = effectiveJS
        cfg.defaultWebpagePreferences = prefs
        cfg.preferences.isFraudulentWebsiteWarningEnabled = mode != .classic
        apply(to: cfg.userContentController)
        return cfg
    }

    func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if mode != .classic, let rules = adblockRules {
            controller.add(rules)
        }
    }

    private func compileRules() {
        var rules: [[String: Any]] = Self.trackerDomains.map { domain in
            [
                "trigger": ["url-filter": domain.replacingOccurrences(of: ".", with: "\\.")],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": ".adsbygoogle, ins.adsbygoogle, [id^='google_ads_'], .ad-banner, .sponsored-content",
            ],
        ])

        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "mcv-shield",
            encodedContentRuleList: json
        ) { [weak self] list, error in
            DispatchQueue.main.async {
                guard let self, let list else {
                    if let error { NSLog("MCV: adblock compile failed: \(error.localizedDescription)") }
                    return
                }
                self.adblockRules = list
                self.onChange?()
            }
        }
    }
}
