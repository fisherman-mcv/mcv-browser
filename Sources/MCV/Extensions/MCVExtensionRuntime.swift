import AppKit
import CryptoKit
import WebKit
import UserNotifications

private final class ExtensionPageWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?(); onClose = nil }
}

protocol MCVExtensionHost: AnyObject {
    func extensionTabs() -> [[String: Any]]
    func extensionCreateTab(url: URL?, active: Bool) -> Int
    func extensionUpdateTab(id: Int, url: URL?, active: Bool?) -> Bool
    func extensionRemoveTabs(ids: [Int])
    func extensionWebView(tabID: Int?) -> WKWebView?
    func extensionOpenPage(_ url: URL, title: String)
}

/// Native capability layer. Chrome/browser JS shims are deliberately thin:
/// authorization, state and browser mutations all happen here.
final class MCVExtensionRuntime: NSObject {
    static let shared = MCVExtensionRuntime()

    weak var host: MCVExtensionHost?
    var onChromeWebStoreInstall: ((String) -> Void)?
    private let loader = ExtensionPackageLoader()
    private let fm = FileManager.default
    private let queue = DispatchQueue(label: "mcv.extensions.state")
    private var installed: [InstalledExtension] = []
    private var manifests: [String: ExtensionManifest] = [:]
    private var backgroundViews: [String: WKWebView] = [:]
    private var pageWorldViews: Set<ObjectIdentifier> = []
    private var popupWindows: [NSWindowController] = []
    private var runtimePorts: [String: [(WKWebView, String)]] = [:]
    private var alarms: [String: Timer] = [:]
    private var rootOverride: URL?
    private var apiFailures: [String: [String: Int]] = [:]
    private var pendingInstallEvents: Set<String> = []
    private var pendingBackgroundEvents: [String: [(String, Any)]] = [:]
    private var backgroundIdleTimers: [String: Timer] = [:]

    private var baseURL: URL {
        rootOverride ?? ProcessInfo.processInfo.environment["MCV_EXTENSION_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".mcv/extensions", isDirectory: true)
    }
    private var indexURL: URL { baseURL.appendingPathComponent("installed.json") }

    private override init() { super.init() }

    func bootstrap() {
        try? fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let value = try? JSONDecoder().decode([InstalledExtension].self, from: data) {
            installed = value
        }
        for item in installed where item.enabled {
            if let manifest = try? loader.loadManifest(for: item) { manifests[item.id] = manifest }
        }
        startRequiredBackgroundContexts()
    }

    @discardableResult
    func install(from url: URL) throws -> InstalledExtension {
        var (item, manifest) = try loader.install(from: url, into: baseURL)
        item.enabled = false
        item.grantedPermissions = []
        installed.removeAll { $0.id == item.id }
        installed.append(item); manifests[item.id] = manifest; saveIndex()
        return item
    }

    func approveInstall(id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }), let manifest = manifests[id] else { return }
        installed[index].enabled = true
        installed[index].grantedPermissions = manifest.requestedPermissions
        saveIndex(); pendingInstallEvents.insert(id); startBackground(for: installed[index], manifest: manifest)
    }

    func allExtensions() -> [InstalledExtension] { installed }
    func commandNames(extensionID: String) -> [String] { manifests[extensionID]?.commands?.keys.sorted() ?? [] }
    func performanceCounters() -> (backgrounds: Int, alarms: Int, popups: Int) {
        (backgroundViews.count, alarms.count, popupWindows.count)
    }

#if DEBUG
    func resetForIntegrationTests(root: URL) {
        backgroundViews.values.forEach { $0.stopLoading() }
        alarms.values.forEach { $0.invalidate() }
        backgroundIdleTimers.values.forEach { $0.invalidate() }
        backgroundViews = [:]; pageWorldViews = []; alarms = [:]; backgroundIdleTimers = [:]
        installed = []; manifests = [:]; apiFailures = [:]; pendingInstallEvents = []; pendingBackgroundEvents = [:]
        rootOverride = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func evaluateBackground(extensionID: String, script: String,
                            completion: @escaping (Any?, Error?) -> Void) {
        guard let view = backgroundViews[extensionID] else {
            completion(nil, ExtensionAPIError.invalidArguments); return
        }
        view.evaluateJavaScript(script, completionHandler: completion)
    }

    func evaluateContent(extensionID: String, webView: WKWebView, script: String,
                         completion: @escaping (Any?, Error?) -> Void) {
        webView.evaluateJavaScript(script, in: nil, in: .world(name: "mcv.extension.\(extensionID)")) { result in
            switch result { case .success(let value): completion(value, nil); case .failure(let error): completion(nil, error) }
        }
    }

    func integrationDiagnostics(extensionID: String) -> [String: Int] { apiFailures[extensionID] ?? [:] }
    func manifestForIntegrationTests(extensionID: String) -> ExtensionManifest? { manifests[extensionID] }
    func bridgeSourceForIntegrationTests(extensionID: String) -> String? {
        manifests[extensionID].map { bridgeJavaScript(extensionID: extensionID, manifest: $0) }
    }
#endif

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = enabled; saveIndex()
        if enabled, let manifest = try? loader.loadManifest(for: installed[index]) {
            manifests[id] = manifest; startBackground(for: installed[index], manifest: manifest)
        } else { manifests[id] = nil; unloadBackground(id) }
    }

    func uninstall(id: String) {
        guard let item = installed.first(where: { $0.id == id }) else { return }
        try? fm.removeItem(at: item.rootURL); installed.removeAll { $0.id == id }
        manifests[id] = nil; unloadBackground(id); saveIndex()
    }

    /// Called before WKWebView construction. Every extension gets its own
    /// WKContentWorld, so page JS and other extensions cannot access its globals.
    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(self, forURLScheme: "mcv-extension")
        configuration.userContentController.add(self, name: "mcvChromeWebStore")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.chromeWebStoreButtonScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        for item in installed where item.enabled {
            guard let manifest = manifests[item.id] else { continue }
            let world = WKContentWorld.world(name: "mcv.extension.\(item.id)")
            configuration.userContentController.add(self, contentWorld: world, name: handlerName(item.id))
            configuration.userContentController.addUserScript(WKUserScript(
                source: bridgeJavaScript(extensionID: item.id, manifest: manifest),
                injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
            addContentScripts(item: item, manifest: manifest, configuration: configuration, world: world)
            applyNetworkRules(item: item, manifest: manifest, configuration: configuration)
        }
    }

    func teardown(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.removeScriptMessageHandler(forName: "mcvChromeWebStore")
        for item in installed where item.enabled {
            configuration.userContentController.removeScriptMessageHandler(forName: handlerName(item.id),
                contentWorld: .world(name: "mcv.extension.\(item.id)"))
        }
    }

    func showPopup(extensionID: String) { showExtensionPage(extensionID: extensionID, path: manifests[extensionID]?.popupPath) }
    func showOptions(extensionID: String) { showExtensionPage(extensionID: extensionID, path: manifests[extensionID]?.optionsPath) }
    func dispatchCommand(_ command: String, extensionID: String) { broadcast("commands.onCommand", payload: command, extensionID: extensionID) }

    func chromeWebStoreExtensionID(from url: URL) -> String? {
        guard ["chromewebstore.google.com", "chrome.google.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url.pathComponents.reversed().first { component in
            component.count == 32 && component.allSatisfy { ("a"..."p").contains(String($0)) }
        }
    }

    func chromeWebStoreDownloadURL(extensionID: String) -> URL? {
        guard extensionID.count == 32,
              extensionID.allSatisfy({ ("a"..."p").contains(String($0)) }) else { return nil }
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        components?.queryItems = [
            .init(name: "response", value: "redirect"),
            .init(name: "prodversion", value: "131.0.0.0"),
            .init(name: "acceptformat", value: "crx2,crx3"),
            .init(name: "x", value: "id=\(extensionID)&uc")
        ]
        return components?.url
    }

    private static let chromeWebStoreButtonScript = #"""
    (() => {
      const validHost = location.hostname === 'chromewebstore.google.com' || location.hostname === 'chrome.google.com';
      if (!validHost || globalThis.__mcvStoreButtonLoaded) return;
      globalThis.__mcvStoreButtonLoaded = true;
      const extensionID = () => location.pathname.split('/').findLast(x => /^[a-p]{32}$/.test(x));
      const render = () => {
        const id = extensionID();
        let button = document.getElementById('mcv-cws-install');
        if (!id) { button?.remove(); return; }
        if (button) { button.dataset.extensionId = id; return; }
        button = document.createElement('button');
        button.id = 'mcv-cws-install';
        button.dataset.extensionId = id;
        button.textContent = 'Add to MCV';
        button.title = 'Download this extension from Chrome Web Store and install it in MCV';
        Object.assign(button.style, {
          position:'fixed', right:'22px', bottom:'22px', zIndex:'2147483647',
          border:'0', borderRadius:'999px', padding:'12px 19px', cursor:'pointer',
          color:'#fff', background:'#1769e0', font:'600 14px -apple-system, BlinkMacSystemFont, sans-serif',
          boxShadow:'0 5px 20px rgba(0,0,0,.28)'
        });
        button.addEventListener('click', () => {
          button.disabled = true; button.textContent = 'Downloading…';
          window.webkit.messageHandlers.mcvChromeWebStore.postMessage({extensionId:button.dataset.extensionId});
          setTimeout(() => { button.disabled = false; button.textContent = 'Add to MCV'; }, 15000);
        });
        document.documentElement.appendChild(button);
      };
      render();
      new MutationObserver(render).observe(document.documentElement, {childList:true, subtree:true});
      addEventListener('popstate', render); addEventListener('hashchange', render);
    })();
    """#

    func navigationEvent(_ name: String, tab: BrowserTab, error: Error? = nil) {
        guard let url = tab.logicalURL,
              let tabID = host?.extensionTabs().first(where: { ($0["url"] as? String) == url.absoluteString })?["id"] as? Int else { return }
        let payload: [String: Any] = ["tabId": tabID, "frameId": 0, "url": url.absoluteString,
                                      "timeStamp": Date().timeIntervalSince1970 * 1000,
                                      "error": error?.localizedDescription ?? ""]
        for item in installed where item.enabled {
            if granted(item.id).contains("webNavigation") { broadcast("webNavigation.\(name)", payload: payload, extensionID: item.id) }
            if granted(item.id).contains("webRequest") { broadcast("webRequest.\(webRequestEvent(name))", payload: payload, extensionID: item.id) }
        }
    }

    func tabEvent(_ name: String, payload: Any) {
        for item in installed where item.enabled && granted(item.id).contains("tabs") {
            broadcast("tabs.\(name)", payload: payload, extensionID: item.id)
        }
    }

    private func addContentScripts(item: InstalledExtension, manifest: ExtensionManifest,
                                   configuration: WKWebViewConfiguration, world: WKContentWorld) {
        for declaration in manifest.content_scripts ?? [] {
            let guardJS = matchGuard(matches: declaration.matches, excludes: declaration.exclude_matches ?? [])
            for cssPath in declaration.css ?? [] {
                guard let css = safeRead(cssPath, root: item.rootURL) else { continue }
                let source = "if (\(guardJS)) { const s=document.createElement('style');s.textContent=\(jsString(css));(document.head||document.documentElement).appendChild(s); }"
                configuration.userContentController.addUserScript(WKUserScript(source: source,
                    injectionTime: .atDocumentStart, forMainFrameOnly: !(declaration.all_frames ?? false), in: world))
            }
            for jsPath in declaration.js ?? [] {
                guard let script = safeRead(jsPath, root: item.rootURL) else { continue }
                let source = "if (\(guardJS)) { try { \(script)\n } catch(e) { console.error('[MCV Extension]', e); } }"
                let time: WKUserScriptInjectionTime = declaration.run_at == "document_start" ? .atDocumentStart : .atDocumentEnd
                let scriptWorld: WKContentWorld = declaration.world?.uppercased() == "MAIN" ? .page : world
                configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: time,
                    forMainFrameOnly: !(declaration.all_frames ?? false), in: scriptWorld))
            }
        }
    }

    /// WebKit content rule lists provide genuine request blocking without a
    /// proxy. Chromium-only header mutation, auth interception and synchronous
    /// blocking listeners intentionally remain unavailable.
    private func applyNetworkRules(item: InstalledExtension, manifest: ExtensionManifest,
                                   configuration: WKWebViewConfiguration) {
        var chromeRules: [[String: Any]] = []
        for resource in manifest.declarative_net_request?.rule_resources ?? [] where resource.enabled {
            let url = item.rootURL.appendingPathComponent(resource.path).standardizedFileURL
            guard url.path.hasPrefix(item.rootURL.standardizedFileURL.path + "/"),
                  let data = try? Data(contentsOf: url),
                  let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            chromeRules.append(contentsOf: rules)
        }
        chromeRules.append(contentsOf: dynamicRules(item.id) as? [[String: Any]] ?? [])
        let webKitRules: [[String: Any]] = chromeRules.compactMap { rule in
            guard let action = rule["action"] as? [String: Any], action["type"] as? String == "block" else { return nil }
            let condition = rule["condition"] as? [String: Any] ?? [:]
            let filter: String
            if let regex = condition["regexFilter"] as? String {
                // WKContentRuleList supports a deliberately small regex subset;
                // one invalid expression rejects the complete compiled list.
                let unsupportedTokens = ["(?", "|", "\\1", "[", "{", "\\d", "\\w", "\\s", "("]
                guard !unsupportedTokens.contains(where: regex.contains) else { return nil }
                filter = regex
            } else { filter = (condition["urlFilter"] as? String).map(Self.chromeFilterToRegex) ?? ".*" }
            var trigger: [String: Any] = ["url-filter": filter]
            if let domains = condition["requestDomains"] as? [String] { trigger["if-domain"] = domains }
            if let excluded = condition["excludedRequestDomains"] as? [String] { trigger["unless-domain"] = excluded }
            if let types = condition["resourceTypes"] as? [String] {
                let mapped = Set(types.compactMap(Self.webKitResourceType))
                if !mapped.isEmpty { trigger["resource-type"] = Array(mapped) }
            }
            return ["trigger": trigger, "action": ["type": "block"]]
        }
        guard !webKitRules.isEmpty else { return }
        for (index, _) in stride(from: 0, to: webKitRules.count, by: 500).enumerated() {
            let end = min(index * 500 + 500, webKitRules.count)
            let start = index * 500
            compileRuleChunk(Array(webKitRules[start..<end]), identifier: "mcv.\(item.id).\(index)",
                             extensionID: item.id, controller: configuration.userContentController)
        }
    }

    private func compileRuleChunk(_ rules: [[String: Any]], identifier: String, extensionID: String,
                                  controller: WKUserContentController) {
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return }
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let cacheIdentifier = identifier + "." + digest
        guard let store = WKContentRuleListStore.default() else { return }
        store.lookUpContentRuleList(forIdentifier: cacheIdentifier) { cached, _ in
            if let cached {
                controller.add(cached)
                return
            }
            store.compileContentRuleList(forIdentifier: cacheIdentifier, encodedContentRuleList: json) { list, error in
            if let list { controller.add(list); return }
            guard error != nil else { return }
            if rules.count == 1 {
                self.apiFailures[extensionID, default: [:]]["DNR.skippedUnsupportedRule", default: 0] += 1
                return
            }
            let middle = rules.count / 2
            self.compileRuleChunk(Array(rules[..<middle]), identifier: identifier + ".a", extensionID: extensionID, controller: controller)
            self.compileRuleChunk(Array(rules[middle...]), identifier: identifier + ".b", extensionID: extensionID, controller: controller)
            }
        }
    }

    private static func chromeFilterToRegex(_ filter: String) -> String {
        var value = NSRegularExpression.escapedPattern(for: filter)
        value = value.replacingOccurrences(of: "\\*", with: ".*")
        value = value.replacingOccurrences(of: "\\|\\|", with: "^[a-z]+://([^/]+\\.)?")
        value = value.replacingOccurrences(of: "\\^", with: "[^A-Za-z0-9_.%-]")
        return value
    }

    private static func webKitResourceType(_ chrome: String) -> String? {
        switch chrome {
        case "main_frame", "sub_frame": return "document"
        case "stylesheet": return "style-sheet"
        case "xmlhttprequest", "ping", "other": return "raw"
        case "image", "script", "font", "media", "popup": return chrome
        default: return nil
        }
    }

    private func webRequestEvent(_ navigationName: String) -> String {
        switch navigationName { case "onBeforeNavigate": return "onBeforeRequest"; case "onCompleted": return "onCompleted"; case "onErrorOccurred": return "onErrorOccurred"; default: return "onBeforeSendHeaders" }
    }

    private func bridgeJavaScript(extensionID: String, manifest: ExtensionManifest) -> String {
        let rawManifest = installed.first(where: { $0.id == extensionID }).flatMap {
            try? Data(contentsOf: $0.rootURL.appendingPathComponent("manifest.json"))
        }.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? ["name": manifest.name, "version": manifest.version,
                                                                       "manifest_version": manifest.manifest_version]
        let manifestObject = jsonObject(rawManifest)
        return """
        (() => {
          const EXT = \(jsString(extensionID)); let seq = 0; const pending = new Map(); const listeners = new Map();
          globalThis.__mcvErrors=[];
          if(!globalThis.registration)globalThis.registration={addEventListener(){},removeEventListener(){}};
          addEventListener('error',e=>globalThis.__mcvErrors.push(String((e.message||e.error||e)+'\\n'+(e.error?.stack||''))),true);
          addEventListener('unhandledrejection',e=>globalThis.__mcvErrors.push(String((e.reason?.message||e.reason||e)+'\\n'+(e.reason?.stack||''))),true);
          globalThis.__mcvResolve = (id, ok, value) => { const p=pending.get(id); if(!p)return; pending.delete(id); ok?p.resolve(value):p.reject(new Error(value?.message||String(value))); };
          globalThis.__mcvEvent = (name, payload) => { for(const fn of (listeners.get(name)||[])) { try { if(name==='runtime.onMessage'&&Array.isArray(payload))fn(payload[0],payload[1]||{},()=>{});else Array.isArray(payload)?fn(...payload):fn(payload); } catch(e){} } };
          const rawCall = (method,args=[]) => new Promise((resolve,reject) => { const id=EXT+':' + (++seq); pending.set(id,{resolve,reject});
            webkit.messageHandlers.\(handlerName(extensionID)).postMessage({id,method,args}); });
          const call = (method,args=[]) => { const callback=typeof args[args.length-1]==='function'?args.pop():null; const promise=rawCall(method,args);
            if(callback){promise.then(v=>callback(v)).catch(e=>{chrome.runtime.lastError={message:e.message};callback();chrome.runtime.lastError=null});return;} return promise; };
          const event = name => ({addListener(fn){const a=listeners.get(name)||[];a.push(fn);listeners.set(name,a)},removeListener(fn){const a=listeners.get(name)||[];listeners.set(name,a.filter(x=>x!==fn))},hasListener(fn){return (listeners.get(name)||[]).includes(fn)}});
          const area = name => ({get:(...a)=>call('storage.get',[name,...a]),set:(...a)=>call('storage.set',[name,...a]),remove:(...a)=>call('storage.remove',[name,...a]),clear:(...a)=>call('storage.clear',[name,...a]),onChanged:event('storage.'+name+'.onChanged')});
          const chrome = {
            runtime:{id:EXT,lastError:null,getManifest:()=>(\(manifestObject)),getURL:p=>'mcv-extension://'+EXT+'/'+String(p||'').replace(/^[/]/,''),sendMessage:(...a)=>call('runtime.sendMessage',a),connect:()=>({postMessage:m=>call('runtime.sendMessage',[m]),disconnect(){},onMessage:event('runtime.onMessage'),onDisconnect:event('runtime.onDisconnect')}),getPlatformInfo:(...a)=>call('runtime.getPlatformInfo',a),setUninstallURL:(...a)=>call('runtime.setUninstallURL',a),reload:()=>call('runtime.reload'),onMessage:event('runtime.onMessage'),onMessageExternal:event('runtime.onMessageExternal'),onInstalled:event('runtime.onInstalled'),onStartup:event('runtime.onStartup'),onConnect:event('runtime.onConnect'),onConnectExternal:event('runtime.onConnectExternal'),onUpdateAvailable:event('runtime.onUpdateAvailable'),openOptionsPage:()=>call('runtime.openOptionsPage')},
            storage:{local:area('local'),sync:area('sync'),session:area('session'),managed:area('managed'),onChanged:event('storage.onChanged')},
            tabs:{TAB_ID_NONE:-1,query:(...a)=>call('tabs.query',a),get:(...a)=>call('tabs.get',a),getCurrent:(...a)=>call('tabs.getCurrent',a),create:(...a)=>call('tabs.create',a),update:(...a)=>call('tabs.update',a),reload:(...a)=>call('tabs.reload',a),remove:(...a)=>call('tabs.remove',a),sendMessage:(...a)=>call('tabs.sendMessage',a),executeScript:(...a)=>call('tabs.executeScript',a),insertCSS:(...a)=>call('tabs.insertCSS',a),onCreated:event('tabs.onCreated'),onUpdated:event('tabs.onUpdated'),onRemoved:event('tabs.onRemoved'),onActivated:event('tabs.onActivated'),onReplaced:event('tabs.onReplaced'),onAttached:event('tabs.onAttached'),onDetached:event('tabs.onDetached')},
            windows:{WINDOW_ID_NONE:-1,getAll:(...a)=>call('windows.getAll',a),getCurrent:(...a)=>call('windows.getCurrent',a),create:(...a)=>call('windows.create',a),update:(...a)=>call('windows.update',a),remove:(...a)=>call('windows.remove',a),onCreated:event('windows.onCreated'),onRemoved:event('windows.onRemoved'),onFocusChanged:event('windows.onFocusChanged')},
            scripting:{ExecutionWorld:{ISOLATED:'ISOLATED',MAIN:'MAIN'},executeScript:(...a)=>call('scripting.executeScript',a),insertCSS:(...a)=>call('scripting.insertCSS',a),removeCSS:(...a)=>call('scripting.removeCSS',a),registerContentScripts:(...a)=>call('userScripts.register',a),updateContentScripts:(...a)=>call('userScripts.update',a),unregisterContentScripts:(...a)=>call('userScripts.unregister',a),getRegisteredContentScripts:(...a)=>call('userScripts.getScripts',a)},
            bookmarks:{getTree:()=>call('bookmarks.getTree'),search:q=>call('bookmarks.search',[q]),create:q=>call('bookmarks.create',[q]),remove:i=>call('bookmarks.remove',[i])},
            history:{search:q=>call('history.search',[q]),deleteAll:()=>call('history.deleteAll')},
            downloads:{search:q=>call('downloads.search',[q]),download:q=>call('downloads.download',[q])},
            notifications:{create:(...a)=>call('notifications.create',a),clear:(...a)=>call('notifications.clear',a),onClicked:event('notifications.onClicked'),onClosed:event('notifications.onClosed'),onButtonClicked:event('notifications.onButtonClicked')},
            permissions:{contains:(...a)=>call('permissions.contains',a),request:(...a)=>call('permissions.request',a),remove:(...a)=>call('permissions.remove',a),getAll:(...a)=>call('permissions.getAll',a),onAdded:event('permissions.onAdded'),onRemoved:event('permissions.onRemoved')},
            contextMenus:{create:p=>call('contextMenus.create',[p]),update:(...a)=>call('contextMenus.update',a),remove:i=>call('contextMenus.remove',[i]),removeAll:()=>call('contextMenus.removeAll'),onClicked:event('contextMenus.onClicked')},
            webNavigation:{onBeforeNavigate:event('webNavigation.onBeforeNavigate'),onCommitted:event('webNavigation.onCommitted'),onCompleted:event('webNavigation.onCompleted'),onErrorOccurred:event('webNavigation.onErrorOccurred'),onHistoryStateUpdated:event('webNavigation.onHistoryStateUpdated'),onReferenceFragmentUpdated:event('webNavigation.onReferenceFragmentUpdated'),onDOMContentLoaded:event('webNavigation.onDOMContentLoaded')},
            webRequest:{OnBeforeSendHeadersOptions:{EXTRA_HEADERS:'extraHeaders'},onBeforeRequest:event('webRequest.onBeforeRequest'),onBeforeSendHeaders:event('webRequest.onBeforeSendHeaders'),onSendHeaders:event('webRequest.onSendHeaders'),onHeadersReceived:event('webRequest.onHeadersReceived'),onBeforeRedirect:event('webRequest.onBeforeRedirect'),onAuthRequired:event('webRequest.onAuthRequired'),onCompleted:event('webRequest.onCompleted'),onErrorOccurred:event('webRequest.onErrorOccurred')},
            declarativeNetRequest:{RuleConditionKeys:{EXCLUDED_TOP_DOMAINS:'excludedTopDomains'},updateDynamicRules:(...a)=>call('declarativeNetRequest.updateDynamicRules',a),getDynamicRules:(...a)=>call('declarativeNetRequest.getDynamicRules',a),updateSessionRules:(...a)=>call('declarativeNetRequest.updateSessionRules',a),getSessionRules:(...a)=>call('declarativeNetRequest.getSessionRules',a),updateEnabledRulesets:(...a)=>call('declarativeNetRequest.updateEnabledRulesets',a),getEnabledRulesets:(...a)=>call('declarativeNetRequest.getEnabledRulesets',a)},
            commands:{getAll:()=>call('commands.getAll'),onCommand:event('commands.onCommand')},
            alarms:{create:(...a)=>call('alarms.create',a),get:(...a)=>call('alarms.get',a),getAll:(...a)=>call('alarms.getAll',a),clear:(...a)=>call('alarms.clear',a),clearAll:(...a)=>call('alarms.clearAll',a),onAlarm:event('alarms.onAlarm')},
            cookies:{get:(...a)=>call('cookies.get',a),getAll:(...a)=>call('cookies.getAll',a),set:(...a)=>call('cookies.set',a),remove:(...a)=>call('cookies.remove',a),onChanged:event('cookies.onChanged')},
            idle:{queryState:(...a)=>call('idle.queryState',a),setDetectionInterval:(...a)=>call('idle.setDetectionInterval',a),onStateChanged:event('idle.onStateChanged')},
            action:{setIcon:(...a)=>call('action.noop',a),setTitle:(...a)=>call('action.noop',a),setBadgeText:(...a)=>call('action.noop',a),setBadgeBackgroundColor:(...a)=>call('action.noop',a),enable:(...a)=>call('action.noop',a),disable:(...a)=>call('action.noop',a),openPopup:(...a)=>call('action.openPopup',a),onClicked:event('action.onClicked')},
            browserAction:{setIcon:(...a)=>call('action.noop',a),setTitle:(...a)=>call('action.noop',a),setBadgeText:(...a)=>call('action.noop',a),onClicked:event('action.onClicked')},
            offscreen:{createDocument:(...a)=>call('offscreen.createDocument',a),closeDocument:(...a)=>call('offscreen.closeDocument',a),hasDocument:(...a)=>call('offscreen.hasDocument',a)},
            userScripts:{register:(...a)=>call('userScripts.register',a),update:(...a)=>call('userScripts.update',a),unregister:(...a)=>call('userScripts.unregister',a),getScripts:(...a)=>call('userScripts.getScripts',a)},
            sessions:{getRecentlyClosed:(...a)=>call('sessions.getRecentlyClosed',a),restore:(...a)=>call('sessions.restore',a)},
            sidePanel:{setOptions:(...a)=>call('sidePanel.setOptions',a),open:(...a)=>call('sidePanel.open',a)},
            management:{getSelf:(...a)=>call('management.getSelf',a),getAll:(...a)=>call('management.getAll',a)},
            privacy:{network:{webRTCIPHandlingPolicy:{get:(...a)=>call('privacy.get',a),set:(...a)=>call('privacy.set',a)}},websites:{}},
            omnibox:{setDefaultSuggestion(){},onInputStarted:event('omnibox.onInputStarted'),onInputChanged:event('omnibox.onInputChanged'),onInputEntered:event('omnibox.onInputEntered'),onInputCancelled:event('omnibox.onInputCancelled')},
            i18n:{getMessage:k=>k,getUILanguage:()=>navigator.language,getAcceptLanguages:(...a)=>{const cb=typeof a[a.length-1]==='function'?a.pop():null,p=Promise.resolve(navigator.languages||[navigator.language]);if(cb){p.then(cb);return}return p}},extension:{getURL:p=>'mcv-extension://'+EXT+'/'+p,getBackgroundPage:()=>null}
          };
          globalThis.chrome=chrome; globalThis.browser=chrome;
          setTimeout(()=>globalThis.__mcvEvent('runtime.onStartup',[]),250);
        })();
        """
    }

    private func dispatch(_ body: [String: Any], webView: WKWebView) {
        guard let extensionID = body["extensionId"] as? String,
              let requestID = body["id"] as? String, let method = body["method"] as? String,
              installed.first(where: { $0.id == extensionID && $0.enabled }) != nil else { return }
        let args = body["args"] as? [Any] ?? []
        do { resolve(requestID, value: try perform(method, args: args, extensionID: extensionID), in: webView, extensionID: extensionID) }
        catch {
            apiFailures[extensionID, default: [:]][method, default: 0] += 1
            reject(requestID, error: error, in: webView, extensionID: extensionID)
        }
    }

    private func perform(_ method: String, args: [Any], extensionID: String) throws -> Any {
        try requirePermission(for: method, extensionID: extensionID)
        switch method {
        case "storage.get": return storageGet(extensionID, area: string(args, 0), keys: args.count > 1 ? args[1] : nil)
        case "storage.set": storageSet(extensionID, area: string(args, 0), value: dictionary(args, 1)); return NSNull()
        case "storage.remove": storageRemove(extensionID, area: string(args, 0), keys: args.count > 1 ? args[1] : nil); return NSNull()
        case "storage.clear": storageWrite([:], extensionID: extensionID, area: string(args, 0)); return NSNull()
        case "runtime.sendMessage", "tabs.sendMessage":
            let message = args.first ?? NSNull()
            let active = host?.extensionTabs().first { ($0["active"] as? Bool) == true } ?? [:]
            broadcast("runtime.onMessage", payload: [message, ["tab": active, "url": active["url"] ?? "", "id": extensionID]], extensionID: extensionID); return NSNull()
        case "runtime.getPlatformInfo": return ["os": "mac", "arch": "arm", "nacl_arch": "arm"]
        case "runtime.setUninstallURL", "runtime.reload": return NSNull()
        case "runtime.openOptionsPage": DispatchQueue.main.async { self.showOptions(extensionID: extensionID) }; return NSNull()
        case "tabs.query": return host?.extensionTabs() ?? []
        case "tabs.get", "tabs.getCurrent":
            let tabs = host?.extensionTabs() ?? []; let id = int(args, 0)
            if let tab = tabs.first(where: { ($0["id"] as? Int) == id }) ?? tabs.first(where: { ($0["active"] as? Bool) == true }) { return tab }
            return NSNull()
        case "tabs.create":
            let p = dictionary(args, 0); let url = (p["url"] as? String).flatMap(URL.init(string:)); return host?.extensionCreateTab(url: url, active: p["active"] as? Bool ?? true) ?? -1
        case "tabs.update":
            let id: Int; let p: [String: Any]
            if args.first is NSNumber { id = int(args, 0); p = dictionary(args, 1) } else { id = -1; p = dictionary(args, 0) }
            let url = (p["url"] as? String).flatMap(URL.init(string:)); return host?.extensionUpdateTab(id: id, url: url, active: p["active"] as? Bool) ?? false
        case "tabs.remove": host?.extensionRemoveTabs(ids: intArray(args.first)); return NSNull()
        case "tabs.reload": host?.extensionWebView(tabID: int(args, 0))?.reload(); return NSNull()
        case "tabs.executeScript": return try executeScript(["target": ["tabId": int(args, 0)], "code": dictionary(args, 1)["code"] as Any], extensionID: extensionID)
        case "tabs.insertCSS": return try insertCSS(["target": ["tabId": int(args, 0)], "css": dictionary(args, 1)["code"] as Any], extensionID: extensionID)
        case "windows.getAll", "windows.getCurrent": return [["id": 1, "focused": NSApp.isActive, "tabs": host?.extensionTabs() ?? []]]
        case "windows.create": let p = dictionary(args, 0); _ = host?.extensionCreateTab(url: (p["url"] as? String).flatMap(URL.init(string:)), active: true); return ["id": 1]
        case "windows.update": if let focused = dictionary(args, 1)["focused"] as? Bool, focused { DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) } }; return ["id": 1]
        case "windows.remove": DispatchQueue.main.async { NSApp.keyWindow?.performClose(nil) }; return NSNull()
        case "scripting.executeScript": return try executeScript(dictionary(args, 0), extensionID: extensionID)
        case "scripting.insertCSS": return try insertCSS(dictionary(args, 0), extensionID: extensionID)
        case "scripting.removeCSS": return NSNull()
        case "bookmarks.getTree":
            let children = ConfigStore.shared.config.bookmarks.sorted { $0.key < $1.key }.map { ["id": $0.key, "title": $0.key, "url": $0.value] }
            return [["id": "0", "title": "MCV Bookmarks", "children": children]]
        case "bookmarks.search":
            let query = (dictionary(args, 0)["query"] as? String ?? string(args, 0)).lowercased()
            return ConfigStore.shared.config.bookmarks.filter { query.isEmpty || $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query) }.map { ["id": $0.key, "title": $0.key, "url": $0.value] }
        case "bookmarks.create":
            let p = dictionary(args, 0); guard let url = p["url"] as? String else { throw ExtensionAPIError.invalidArguments }
            let title = p["title"] as? String ?? url; ConfigStore.shared.update { $0.bookmarks[title] = url }; return ["id": title, "title": title, "url": url]
        case "bookmarks.remove": ConfigStore.shared.update { $0.bookmarks.removeValue(forKey: string(args, 0)) }; return NSNull()
        case "history.search": return HistoryStore.shared.entries.map { ["id": $0.url, "url": $0.url, "title": $0.title, "lastVisitTime": $0.visitedAt.timeIntervalSince1970 * 1000] }
        case "history.deleteAll": HistoryStore.shared.clear(); return NSNull()
        case "downloads.search": return DownloadsCenter.shared.items.map { ["id": $0.id.uuidString, "filename": $0.destination.path, "url": $0.destination.absoluteString, "state": $0.state == .completed ? "complete" : "in_progress"] }
        case "downloads.download":
            guard let raw = dictionary(args, 0)["url"] as? String, let url = URL(string: raw) else { return -1 }
            URLSession.shared.downloadTask(with: url) { temporary, response, _ in if let temporary { let name = response?.suggestedFilename ?? url.lastPathComponent; let dst = self.fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(name); try? self.fm.moveItem(at: temporary, to: dst) } }.resume(); return 1
        case "notifications.create": notify(dictionary(args, args.count > 1 ? 1 : 0)); return string(args, 0).isEmpty ? UUID().uuidString : string(args, 0)
        case "permissions.contains": return permissionSet(dictionary(args, 0)).isSubset(of: granted(extensionID))
        case "permissions.getAll": return ["permissions": Array(granted(extensionID).filter { !$0.contains("://") && $0 != "<all_urls>" }), "origins": Array(granted(extensionID).filter { $0.contains("://") || $0 == "<all_urls>" })]
        case "permissions.request": return requestPermissions(permissionSet(dictionary(args, 0)), extensionID: extensionID)
        case "permissions.remove": return removePermissions(permissionSet(dictionary(args, 0)), extensionID: extensionID)
        case "commands.getAll": return manifests[extensionID]?.commands?.map { ["name": $0.key, "description": $0.value.description ?? "", "shortcut": $0.value.suggested_key?.mac ?? $0.value.suggested_key?.default ?? ""] } ?? []
        case "action.noop", "idle.setDetectionInterval", "privacy.set": return NSNull()
        case "action.openPopup": DispatchQueue.main.async { self.showPopup(extensionID: extensionID) }; return NSNull()
        case "idle.queryState": return "active"
        case "management.getSelf": return ["id": extensionID, "name": manifests[extensionID]?.name ?? "", "enabled": true, "version": manifests[extensionID]?.version ?? ""]
        case "management.getAll": return installed.map { ["id": $0.id, "name": $0.manifest.name, "enabled": $0.enabled, "version": $0.manifest.version] }
        case "sessions.getRecentlyClosed": return []
        case "privacy.get": return ["value": "default", "levelOfControl": "controllable_by_this_extension"]
        case "offscreen.hasDocument": return false
        case "offscreen.createDocument", "offscreen.closeDocument", "sidePanel.setOptions", "sidePanel.open": return NSNull()
        case "userScripts.register", "userScripts.update", "userScripts.unregister": return NSNull()
        case "userScripts.getScripts": return []
        case "cookies.get", "cookies.getAll", "cookies.set", "cookies.remove": throw ExtensionAPIError.unsupported(method)
        case "alarms.create": createAlarm(args, extensionID: extensionID); return NSNull()
        case "alarms.clear": return clearAlarm(name: string(args, 0), extensionID: extensionID)
        case "alarms.clearAll": return clearAllAlarms(extensionID: extensionID)
        case "alarms.get": return alarmDescription(name: string(args, 0), extensionID: extensionID)
        case "alarms.getAll": return alarms.keys.filter { $0.hasPrefix(extensionID + ":") }.map { ["name": String($0.dropFirst(extensionID.count + 1))] }
        case "declarativeNetRequest.getDynamicRules": return dynamicRules(extensionID)
        case "declarativeNetRequest.updateDynamicRules": updateDynamicRules(dictionary(args, 0), extensionID: extensionID); return NSNull()
        case "declarativeNetRequest.getSessionRules": return sessionRules(extensionID)
        case "declarativeNetRequest.updateSessionRules": updateSessionRules(dictionary(args, 0), extensionID: extensionID); return NSNull()
        case "declarativeNetRequest.getEnabledRulesets": return manifests[extensionID]?.declarative_net_request?.rule_resources.filter(\.enabled).map(\.id) ?? []
        case "declarativeNetRequest.updateEnabledRulesets": return NSNull()
        case "contextMenus.create": return ExtensionContextMenuStore.shared.create(extensionID: extensionID, properties: dictionary(args, 0))
        case "contextMenus.update": ExtensionContextMenuStore.shared.update(extensionID: extensionID, id: args.first ?? "", properties: dictionary(args, 1)); return NSNull()
        case "contextMenus.remove": ExtensionContextMenuStore.shared.remove(extensionID: extensionID, id: args.first ?? ""); return NSNull()
        case "contextMenus.removeAll": ExtensionContextMenuStore.shared.removeAll(extensionID: extensionID); return NSNull()
        default: throw ExtensionAPIError.unsupported(method)
        }
    }

    private func executeScript(_ details: [String: Any], extensionID: String) throws -> [[String: Any]] {
        let target = details["target"] as? [String: Any] ?? [:]
        guard let webView = host?.extensionWebView(tabID: target["tabId"] as? Int) else { throw ExtensionAPIError.invalidArguments }
        var code = details["code"] as? String
        if code == nil, let files = details["files"] as? [String] { code = files.compactMap { safeRead($0, root: installed.first { $0.id == extensionID }!.rootURL) }.joined(separator: "\n") }
        guard let code else { throw ExtensionAPIError.invalidArguments }
        DispatchQueue.main.async { webView.evaluateJavaScript(code) }
        return [["frameId": 0, "result": NSNull()]]
    }

    private func insertCSS(_ details: [String: Any], extensionID: String) throws -> Any {
        let target = details["target"] as? [String: Any] ?? [:]
        guard let webView = host?.extensionWebView(tabID: target["tabId"] as? Int) else { throw ExtensionAPIError.invalidArguments }
        var css = details["css"] as? String
        if css == nil, let files = details["files"] as? [String] { css = files.compactMap { safeRead($0, root: installed.first { $0.id == extensionID }!.rootURL) }.joined(separator: "\n") }
        guard let css else { throw ExtensionAPIError.invalidArguments }
        DispatchQueue.main.async { webView.evaluateJavaScript("document.head.appendChild(Object.assign(document.createElement('style'),{textContent:\(self.jsString(css))}))") }
        return NSNull()
    }

    private func requirePermission(for method: String, extensionID: String) throws {
        if method == "management.getSelf" { return }
        let namespace = method.split(separator: ".").first.map(String.init) ?? "runtime"
        let implicit: Set<String> = ["runtime", "i18n", "permissions", "action", "browserAction", "tabs", "windows", "commands"]
        if implicit.contains(namespace) { return }
        let aliases: Set<String>
        if namespace == "scripting" { aliases = ["scripting", "activeTab"] }
        else if namespace == "userScripts" { aliases = ["userScripts", "scripting"] }
        else if namespace == "declarativeNetRequest" { aliases = ["declarativeNetRequest", "declarativeNetRequestWithHostAccess"] }
        else { aliases = [namespace] }
        guard !granted(extensionID).isDisjoint(with: aliases) else { throw ExtensionAPIError.permissionDenied(namespace) }
    }

    private func granted(_ id: String) -> Set<String> { installed.first { $0.id == id }?.grantedPermissions ?? [] }
    private func permissionSet(_ p: [String: Any]) -> Set<String> { Set((p["permissions"] as? [String] ?? []) + (p["origins"] as? [String] ?? [])) }
    private func requestPermissions(_ p: Set<String>, extensionID: String) -> Bool {
        guard p.isSubset(of: manifests[extensionID]?.requestedPermissions ?? []) else { return false }
        guard let i = installed.firstIndex(where: { $0.id == extensionID }) else { return false }
        installed[i].grantedPermissions.formUnion(p); saveIndex(); broadcast("permissions.onAdded", payload: ["permissions": Array(p)], extensionID: extensionID); return true
    }
    private func removePermissions(_ p: Set<String>, extensionID: String) -> Bool {
        guard let i = installed.firstIndex(where: { $0.id == extensionID }) else { return false }
        installed[i].grantedPermissions.subtract(p); saveIndex(); broadcast("permissions.onRemoved", payload: ["permissions": Array(p)], extensionID: extensionID); return true
    }

    private func storageURL(_ id: String, _ area: String) -> URL { baseURL.appendingPathComponent(id).appendingPathComponent(".mcv-storage-\(area).json") }
    private func storageRead(_ id: String, area: String) -> [String: Any] { guard let d = try? Data(contentsOf: storageURL(id, area)), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }; return o }
    private func storageWrite(_ value: [String: Any], extensionID: String, area: String) { if let d = try? JSONSerialization.data(withJSONObject: value) { try? d.write(to: storageURL(extensionID, area), options: .atomic) } }
    private func storageGet(_ id: String, area: String, keys: Any?) -> [String: Any] { let all = storageRead(id, area: area); if keys == nil || keys is NSNull { return all }; if let key = keys as? String { return all[key].map { [key: $0] } ?? [:] }; if let list = keys as? [String] { return all.filter { list.contains($0.key) } }; if let defaults = keys as? [String: Any] { return defaults.merging(all) { _, current in current } }; return [:] }
    private func storageSet(_ id: String, area: String, value: [String: Any]) {
        var all = storageRead(id, area: area)
        var changes: [String: Any] = [:]
        for (key, newValue) in value { changes[key] = ["oldValue": all[key] ?? NSNull(), "newValue": newValue] }
        all.merge(value) { _, new in new }; storageWrite(all, extensionID: id, area: area)
        broadcast("storage.onChanged", payload: [changes, area], extensionID: id)
        broadcast("storage.\(area).onChanged", payload: changes, extensionID: id)
    }
    private func storageRemove(_ id: String, area: String, keys: Any?) { var all = storageRead(id, area: area); let list = keys as? [String] ?? (keys as? String).map { [$0] } ?? []; list.forEach { all[$0] = nil }; storageWrite(all, extensionID: id, area: area) }

    private func startRequiredBackgroundContexts() {
        for item in installed where item.enabled {
            guard let manifest = manifests[item.id], let background = manifest.background else { continue }
            let needsStartup: Bool
            if let worker = background.service_worker {
                needsStartup = safeRead(worker, root: item.rootURL)?.contains("onStartup") == true
            } else {
                needsStartup = true // MV2 background pages are persistent by contract.
            }
            if needsStartup {
                pendingBackgroundEvents[item.id, default: []].append(("runtime.onStartup", NSNull()))
                startBackground(for: item, manifest: manifest)
            }
        }
    }
    private func startBackground(for item: InstalledExtension, manifest: ExtensionManifest) {
        guard backgroundViews[item.id] == nil, let background = manifest.background else { return }
        let config = WKWebViewConfiguration(); config.setURLSchemeHandler(self, forURLScheme: "mcv-extension"); let world = WKContentWorld.page
        config.userContentController.add(self, contentWorld: world, name: handlerName(item.id))
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 1, height: 1), configuration: config)
        view.navigationDelegate = self
        backgroundViews[item.id] = view; pageWorldViews.insert(ObjectIdentifier(view))
        let bootstrap = "<script>\(bridgeJavaScript(extensionID: item.id, manifest: manifest).replacingOccurrences(of: "</script>", with: "<\\/script>"))</script>"
        let extensionBase = URL(string: "mcv-extension://\(item.id)/")
        if let page = background.page, let html = safeRead(page, root: item.rootURL) {
            view.loadHTMLString(bootstrap + html, baseURL: extensionBase)
        }
        else if let worker = background.service_worker, background.type == "module" {
            let source = "mcv-extension://\(item.id)/\(worker.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
            view.loadHTMLString(bootstrap + "<script type=module src=\"\(source)\"></script>", baseURL: extensionBase)
        } else {
            let scripts = (background.scripts ?? []) + (background.service_worker.map { [$0] } ?? [])
            let tags = scripts.map { "<script src=\"mcv-extension://\(item.id)/\($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\"></script>" }.joined()
            view.loadHTMLString(bootstrap + tags, baseURL: extensionBase)
        }
    }

    private func touchBackground(_ id: String) {
        guard manifests[id]?.background?.service_worker != nil else { return }
        backgroundIdleTimers[id]?.invalidate()
        backgroundIdleTimers[id] = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.unloadBackground(id)
        }
    }

    private func unloadBackground(_ id: String) {
        backgroundIdleTimers.removeValue(forKey: id)?.invalidate()
        guard let view = backgroundViews.removeValue(forKey: id) else { return }
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: handlerName(id), contentWorld: .page)
        pageWorldViews.remove(ObjectIdentifier(view))
    }

    private func showExtensionPage(extensionID: String, path: String?) {
        guard let path, let item = installed.first(where: { $0.id == extensionID }) else { return }
        let config = WKWebViewConfiguration(); config.setURLSchemeHandler(self, forURLScheme: "mcv-extension"); let world = WKContentWorld.page
        config.userContentController.add(self, contentWorld: world, name: handlerName(extensionID))
        let web = WKWebView(frame: .zero, configuration: config); pageWorldViews.insert(ObjectIdentifier(web))
        guard let manifest = manifests[extensionID], let html = safeRead(path, root: item.rootURL) else { return }
        let bootstrap = "<script>\(bridgeJavaScript(extensionID: extensionID, manifest: manifest).replacingOccurrences(of: "</script>", with: "<\\/script>"))</script>"
        web.loadHTMLString(bootstrap + html, baseURL: URL(string: "mcv-extension://\(extensionID)/\((path as NSString).deletingLastPathComponent)/"))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 420, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false); window.title = item.manifest.name; window.contentView = web; window.center()
        let controller = ExtensionPageWindowController(window: window)
        window.delegate = controller
        controller.onClose = { [weak self, weak controller, weak web] in
            guard let self else { return }
            if let controller { self.popupWindows.removeAll { $0 === controller } }
            if let web {
                web.stopLoading()
                web.configuration.userContentController.removeScriptMessageHandler(
                    forName: self.handlerName(extensionID), contentWorld: .page)
                self.pageWorldViews.remove(ObjectIdentifier(web))
            }
        }
        popupWindows.append(controller)
        controller.showWindow(nil)
    }

    private func broadcast(_ event: String, payload: Any, extensionID: String) {
        let js = "globalThis.__mcvEvent?.(\(jsString(event)),\(jsonObject(payload)))"
        let world = WKContentWorld.world(name: "mcv.extension.\(extensionID)")
        DispatchQueue.main.async {
            if let background = self.backgroundViews[extensionID] {
                background.evaluateJavaScript(js, in: nil, in: .page)
                self.touchBackground(extensionID)
            } else if let item = self.installed.first(where: { $0.id == extensionID && $0.enabled }),
                      let manifest = self.manifests[extensionID], manifest.background != nil {
                self.pendingBackgroundEvents[extensionID, default: []].append((event, payload))
                self.startBackground(for: item, manifest: manifest)
            }
            for tab in self.host?.extensionTabs() ?? [] {
                if let id = tab["id"] as? Int { self.host?.extensionWebView(tabID: id)?.evaluateJavaScript(js, in: nil, in: world) }
            }
        }
    }

    private func resolve(_ id: String, value: Any, in view: WKWebView, extensionID: String) { callback(id, ok: true, value: value, view: view, extensionID: extensionID) }
    private func reject(_ id: String, error: Error, in view: WKWebView, extensionID: String) { callback(id, ok: false, value: ["message": error.localizedDescription], view: view, extensionID: extensionID) }
    private func callback(_ id: String, ok: Bool, value: Any, view: WKWebView, extensionID: String) {
        let js = "globalThis.__mcvResolve?.(\(jsString(id)),\(ok),\(jsonObject(value)))"
        let contentWorld: WKContentWorld = pageWorldViews.contains(ObjectIdentifier(view)) ? .page : .world(name: "mcv.extension.\(extensionID)")
        DispatchQueue.main.async { view.evaluateJavaScript(js, in: nil, in: contentWorld) }
    }
    private func saveIndex() { if let d = try? JSONEncoder().encode(installed) { try? d.write(to: indexURL, options: .atomic) } }
    private func handlerName(_ id: String) -> String { "mcvExtension_\(id)" }
    private func safeRead(_ relative: String, root: URL) -> String? { let u = root.appendingPathComponent(relative).standardizedFileURL; guard u.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }; return try? String(contentsOf: u, encoding: .utf8) }
    private func matchGuard(matches: [String], excludes: [String]) -> String { let m = jsonObject(matches), e = jsonObject(excludes); return "(()=>{const cv=(p)=>{if(p==='<all_urls>')return ['http:','https:','file:','ftp:'].includes(location.protocol);const x=p.indexOf('://');if(x<0)return false;const s=p.slice(0,x),r=p.slice(x+3),i=r.indexOf('/'),h=r.slice(0,i),q=r.slice(i).replace(/[.+?^${}()|[\\]\\\\]/g,'\\\\$&').replace(/\\*/g,'.*');return(s==='*'||s===location.protocol.slice(0,-1))&&(h==='*'||(h.startsWith('*.')?(location.hostname===h.slice(2)||location.hostname.endsWith('.'+h.slice(2))):location.hostname===h))&&new RegExp('^'+q+'$').test(location.pathname)};return \(m).some(cv)&&!\(e).some(cv)})()" }
    private func jsString(_ value: String) -> String { let d = try! JSONSerialization.data(withJSONObject: [value]); return String(data: d, encoding: .utf8)!.dropFirst().dropLast().description }
    private func jsonObject(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) {
            return String(data: data, encoding: .utf8) ?? "null"
        }
        guard JSONSerialization.isValidJSONObject([value]), let data = try? JSONSerialization.data(withJSONObject: [value]),
              let wrapped = String(data: data, encoding: .utf8), wrapped.count >= 2 else { return "null" }
        return String(wrapped.dropFirst().dropLast())
    }
    private func string(_ a: [Any], _ i: Int) -> String { a.indices.contains(i) ? (a[i] as? String ?? "") : "" }
    private func int(_ a: [Any], _ i: Int) -> Int { a.indices.contains(i) ? (a[i] as? NSNumber)?.intValue ?? -1 : -1 }
    private func dictionary(_ a: [Any], _ i: Int) -> [String: Any] { a.indices.contains(i) ? (a[i] as? [String: Any] ?? [:]) : [:] }
    private func intArray(_ value: Any?) -> [Int] { if let n = value as? NSNumber { return [n.intValue] }; return (value as? [NSNumber] ?? []).map(\.intValue) }
    private func notify(_ p: [String: Any]) { let c = UNMutableNotificationContent(); c.title = p["title"] as? String ?? "MCV Extension"; c.body = p["message"] as? String ?? ""; UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _,_ in }; UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: c, trigger: nil)) }
    private func createAlarm(_ args: [Any], extensionID: String) {
        let name = (args.first as? String) ?? ""
        let info = dictionary(args, args.first is String ? 1 : 0)
        let delayMinutes = (info["delayInMinutes"] as? NSNumber)?.doubleValue
        let scheduledAt = (info["when"] as? NSNumber)?.doubleValue
        let delay: TimeInterval
        if let delayMinutes { delay = delayMinutes * 60 }
        else if let scheduledAt { delay = max(0, scheduledAt / 1000 - Date().timeIntervalSince1970) }
        else { delay = 60 }
        let period = (info["periodInMinutes"] as? NSNumber)?.doubleValue
        let key = extensionID + ":" + name
        DispatchQueue.main.async {
            self.alarms[key]?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: max(0.01, delay), repeats: period != nil) { [weak self] _ in
                self?.broadcast("alarms.onAlarm", payload: ["name": name, "scheduledTime": Date().timeIntervalSince1970 * 1000], extensionID: extensionID)
                if period == nil { self?.alarms[key] = nil }
            }
            self.alarms[key] = timer
        }
    }
    private func clearAlarm(name: String, extensionID: String) -> Bool { let key = extensionID + ":" + name; guard let timer = alarms.removeValue(forKey: key) else { return false }; timer.invalidate(); return true }
    private func clearAllAlarms(extensionID: String) -> Bool { let keys = alarms.keys.filter { $0.hasPrefix(extensionID + ":") }; keys.forEach { alarms.removeValue(forKey: $0)?.invalidate() }; return !keys.isEmpty }
    private func alarmDescription(name: String, extensionID: String) -> Any { alarms[extensionID + ":" + name] == nil ? NSNull() : ["name": name] }
    private func dynamicRules(_ id: String) -> [Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: baseURL.appendingPathComponent(id).appendingPathComponent(".mcv-dnr.json")))) as? [Any] ?? [] }
    private func updateDynamicRules(_ p: [String: Any], extensionID: String) { var rules = dynamicRules(extensionID) as? [[String: Any]] ?? []; let remove = Set((p["removeRuleIds"] as? [NSNumber] ?? []).map(\.intValue)); rules.removeAll { remove.contains(($0["id"] as? NSNumber)?.intValue ?? -1) }; rules.append(contentsOf: p["addRules"] as? [[String: Any]] ?? []); if let d = try? JSONSerialization.data(withJSONObject: rules) { try? d.write(to: baseURL.appendingPathComponent(extensionID).appendingPathComponent(".mcv-dnr.json")) } }
    private func sessionRules(_ id: String) -> [[String: Any]] { storageRead(id, area: "dnr-session")["rules"] as? [[String: Any]] ?? [] }
    private func updateSessionRules(_ p: [String: Any], extensionID: String) { var rules = sessionRules(extensionID); let remove = Set((p["removeRuleIds"] as? [NSNumber] ?? []).map(\.intValue)); rules.removeAll { remove.contains(($0["id"] as? NSNumber)?.intValue ?? -1) }; rules.append(contentsOf: p["addRules"] as? [[String: Any]] ?? []); storageWrite(["rules": rules], extensionID: extensionID, area: "dnr-session") }
}

extension MCVExtensionRuntime: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "mcvChromeWebStore",
           let body = message.body as? [String: Any],
           let id = body["extensionId"] as? String,
           chromeWebStoreDownloadURL(extensionID: id) != nil {
            onChromeWebStoreInstall?(id)
            return
        }
        guard message.name.hasPrefix("mcvExtension_"), var body = message.body as? [String: Any], let webView = message.webView else { return }
        let extensionID = String(message.name.dropFirst("mcvExtension_".count))
        body["extensionId"] = extensionID
        if backgroundViews[extensionID] === webView { touchBackground(extensionID) }
        dispatch(body, webView: webView)
    }
}

extension MCVExtensionRuntime: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = backgroundViews.first(where: { $0.value === webView })?.key else { return }
        var events = pendingBackgroundEvents.removeValue(forKey: id) ?? []
        if pendingInstallEvents.remove(id) != nil {
            events.append(("runtime.onInstalled", ["reason": "install"]))
        }
        for (event, payload) in events {
            let js = "globalThis.__mcvEvent?.(\(jsString(event)),\(jsonObject(payload)))"
            webView.evaluateJavaScript(js, in: nil, in: .page)
        }
        touchBackground(id)
    }
}

extension MCVExtensionRuntime: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let id = url.host,
              let item = installed.first(where: { $0.id == id && $0.enabled }) else {
            urlSchemeTask.didFailWithError(ExtensionAPIError.permissionDenied("extension resource")); return
        }
        let relative = url.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let internalRequest = pageWorldViews.contains(ObjectIdentifier(webView))
            || urlSchemeTask.request.mainDocumentURL?.host == id || urlSchemeTask.request.mainDocumentURL == url
        if !internalRequest, !isWebAccessible(relative, manifest: manifests[id]) {
            urlSchemeTask.didFailWithError(ExtensionAPIError.permissionDenied("web_accessible_resources")); return
        }
        let resource = item.rootURL.appendingPathComponent(relative).standardizedFileURL
        guard resource.path.hasPrefix(item.rootURL.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: resource) else {
            urlSchemeTask.didFailWithError(ExtensionAPIError.invalidArguments); return
        }
        let mime = ["html":"text/html", "js":"text/javascript", "css":"text/css", "json":"application/json",
                    "png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "svg":"image/svg+xml"] [resource.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil)
        urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func isWebAccessible(_ path: String, manifest: ExtensionManifest?) -> Bool {
        guard let value = manifest?.web_accessible_resources else { return false }
        let patterns: [String]
        switch value {
        case .array(let values):
            patterns = values.flatMap { entry -> [String] in
                if case .string(let pattern) = entry { return [pattern] }
                if case .object(let object) = entry, case .array(let resources)? = object["resources"] {
                    return resources.compactMap { if case .string(let pattern) = $0 { return pattern }; return nil }
                }
                return []
            }
        default: patterns = []
        }
        return patterns.contains { pattern in
            let regex = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
            return path.range(of: regex, options: .regularExpression) != nil
        }
    }
}

enum ExtensionAPIError: LocalizedError {
    case permissionDenied(String), unsupported(String), invalidArguments
    var errorDescription: String? { switch self { case .permissionDenied(let p): return "Permission denied: \(p)"; case .unsupported(let m): return "Unsupported API: \(m)"; case .invalidArguments: return "Invalid arguments" } }
}

final class ExtensionContextMenuStore {
    static let shared = ExtensionContextMenuStore(); private var items: [String: [[String: Any]]] = [:]
    func create(extensionID: String, properties: [String: Any]) -> Any { let id = properties["id"] ?? UUID().uuidString; var p = properties; p["id"] = id; items[extensionID, default: []].append(p); return id }
    func update(extensionID: String, id: Any, properties: [String: Any]) { guard let i = items[extensionID]?.firstIndex(where: { String(describing: $0["id"] ?? "") == String(describing: id) }) else { return }; items[extensionID]?[i].merge(properties) { _, new in new } }
    func remove(extensionID: String, id: Any) { items[extensionID]?.removeAll { String(describing: $0["id"] ?? "") == String(describing: id) } }
    func removeAll(extensionID: String) { items[extensionID] = [] }
    func entries(extensionID: String) -> [[String: Any]] { items[extensionID] ?? [] }
}
