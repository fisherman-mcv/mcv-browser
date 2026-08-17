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
        "2mdn.net", "admob.com", "pagead2.googlesyndication.com",
        "adnxs.com", "adsrvr.org", "criteo.com", "criteo.net", "casalemedia.com",
        "taboola.com", "outbrain.com", "scorecardresearch.com", "quantserve.com",
        "moatads.com", "adsafeprotected.com", "connect.facebook.net",
        "hotjar.com", "mouseflow.com", "mc.yandex.ru", "an.yandex.ru",
        "mixpanel.com", "amplitude.com", "segment.io", "branch.io", "appsflyer.com",
        "advertising.com", "adform.net", "adroll.com", "bidswitch.net", "bluekai.com",
        "contextweb.com", "demdex.net", "everesttech.net", "lijit.com", "mathtag.com",
        "openx.net", "pubmatic.com", "rubiconproject.com", "smartadserver.com", "yieldmo.com",
        "zedo.com", "serving-sys.com", "amazon-adsystem.com", "media.net", "rlcdn.com",
        "sharethrough.com", "triplelift.com", "yieldlab.net", "360yield.com", "gumgum.com",
        "indexww.com", "smaato.net", "teads.tv", "undertone.com", "revcontent.com",
        "mgid.com", "adcolony.com", "unityads.unity3d.com", "applovin.com", "vungle.com",
        "chartbeat.com", "chartbeat.net", "newrelic.com", "nr-data.net", "fullstory.com",
        "clarity.ms", "heapanalytics.com", "kissmetrics.io", "optimizely.com", "crazyegg.com",
        "bugsnag.com", "sentry-cdn.com", "logrocket.io", "luckyorange.com", "inspectlet.com",
        "facebook.com/tr", "analytics.twitter.com", "ads-twitter.com", "snap.licdn.com",
        "bat.bing.com", "pixel.wp.com", "stats.wp.com", "tiktok.com/i18n/pixel",
        "pinterest.com/ct", "redditstatic.com/ads", "cloudfront.net/ads/",
    ]

    private static let advertisingURLPatterns = [
        #"/pagead/"#, #"/adsbygoogle"#, #"/gampad/ads"#, #"/googleads/"#,
        #"/prebid[^/]*\.js"#, #"/advert/"#, #"/adverts/"#, #"/advertising/"#, #"/adserver/"#,
        #"/adservice/"#, #"/adserve/"#, #"/videoads/"#,
        #"/vast"#, #"[?&]adunit="#, #"[?&]ad_slot="#, #"[?&]adslot="#,
        #"[?&]adTagUrl="#, #"/tracking-pixel"#, #"/tracking_pixel"#, #"/tracking/pixel"#,
    ]

    private static let cosmeticSelectors = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^='google_ads_']", "[id^='div-gpt-ad']",
        "[data-ad-slot]", "[data-ad-client]", "[data-ad-unit]", "[aria-label='Advertisement']",
        ".ad-banner", ".ad-container", ".ad-wrapper", ".advertisement", ".advertising",
        ".sponsored-content", ".sponsored-post", "aside[id*='advert']",
    ]

    private init() {
        mode = SecurityMode(rawValue: ConfigStore.shared.config.mode) ?? .safe
        javascriptEnabled = ConfigStore.shared.config.javascript
    }

    /// JS реально доступний: у Secure він примусово вимкнений.
    var effectiveJS: Bool { mode == .secure ? false : javascriptEnabled }

    func bootstrap() {
        // WebKit's network process owns HTTP/2, HTTP/3/QUIC, Brotli and its
        // memory/disk resource cache. A bounded shared URL cache also avoids
        // duplicate native requests made by browser services.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1_024 * 1_024,
                                   diskCapacity: 512 * 1_024 * 1_024)
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
        cfg.suppressesIncrementalRendering = false
        cfg.allowsAirPlayForMediaPlayback = true
        // Enables the standard HTML Fullscreen API used by YouTube's player.
        // WebKit presents the selected <video> element in native macOS fullscreen.
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.preferences.isFraudulentWebsiteWarningEnabled = mode != .classic
        apply(to: cfg.userContentController)
        cfg.userContentController.addUserScript(WKUserScript(
            source: Self.myDoodleJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        return cfg
    }

    /// Tiny, event-driven Google homepage easter egg. The observer disconnects
    /// immediately after the logo appears, so it has no steady-state CPU cost.
    static let myDoodleJS = #"""
    (() => {
      const host = location.hostname.toLowerCase();
      if (host !== 'google.com' && host !== 'www.google.com') return;
      if (location.pathname !== '/' && location.pathname !== '/webhp') return;
      const install = () => {
        if (document.getElementById('mcv-mydoodle')) return true;
        const logo = document.querySelector('img.lnXdpd, #hplogo, img[alt="Google"]');
        if (!logo) return false;
        const doodle = document.createElement('div');
        doodle.id = 'mcv-mydoodle';
        doodle.setAttribute('role', 'img');
        doodle.setAttribute('aria-label', 'MC Browser');
        doodle.textContent = 'MC Browser';
        doodle.style.cssText = [
          'width:272px','height:92px','display:flex','align-items:center','justify-content:center',
          'font:700 42px -apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif',
          'letter-spacing:-2.5px','color:transparent',
          'background:linear-gradient(105deg,#4285f4 0 24%,#ea4335 24% 45%,#fbbc05 45% 62%,#34a853 62% 80%,#8b5cf6 80%)',
          '-webkit-background-clip:text','background-clip:text',
          'filter:drop-shadow(0 2px 8px rgba(66,133,244,.18))','user-select:none'
        ].join(';');
        logo.replaceWith(doodle);
        return true;
      };
      if (install()) return;
      const observer = new MutationObserver(() => { if (install()) observer.disconnect(); });
      observer.observe(document.documentElement, {childList:true, subtree:true});
      addEventListener('pagehide', () => observer.disconnect(), {once:true});
    })();
    """#

    func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if mode != .classic, let rules = adblockRules {
            controller.add(rules)
        }
    }

    static func nativeRuleJSON() -> String? {
        var rules: [[String: Any]] = trackerDomains.map { domain in
            [
                "trigger": [
                    "url-filter": domain.replacingOccurrences(of: ".", with: "\\."),
                    "load-type": ["third-party"],
                    "resource-type": ["image", "style-sheet", "script", "font", "media", "raw"],
                ],
                "action": ["type": "block"],
            ]
        }
        rules.append(contentsOf: advertisingURLPatterns.map { pattern in
            [
                "trigger": [
                    "url-filter": pattern,
                    "load-type": ["third-party"],
                    "resource-type": ["image", "style-sheet", "script", "media", "raw"],
                ],
                "action": ["type": "block"],
            ]
        })
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": cosmeticSelectors.joined(separator: ", "),
            ],
        ])

        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private func compileRules() {
        guard let json = Self.nativeRuleJSON() else { return }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "mcv-native-shield-v2",
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
