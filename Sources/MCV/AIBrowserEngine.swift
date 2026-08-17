import Foundation
import WebKit

/// Gemma may classify and select IDs, but every user-visible fact is copied
/// from the deterministic WebKit fact catalog.
final class AIBrowserEngine {
    static let shared = AIBrowserEngine()
    private let endpoint = URL(string: "http://127.0.0.1:11434/api/generate")!
    private let model = "gemma3:1b"
    private let memory = BrowserMemoryStore()
    private init() {}

    /// Event-driven indexing: runs after a real navigation completes, never on
    /// a timer, and never invokes Gemma. Only deterministic page evidence is
    /// stored in the local memory graph.
    func remember(_ tab: BrowserTab) {
        guard !tab.isPrivate, ConfigStore.shared.config.semanticMemory else { return }
        extract(from: tab.webView, requestedURL: tab.lastRequestedURL ?? tab.webView.url) { [weak self] snapshot in
            guard let snapshot, !snapshot.isExplicitError else { return }
            self?.memory.remember(snapshot)
        }
    }

    func run(_ raw: String, current: BrowserTab?, tabs: [BrowserTab],
             show: @escaping (String) -> Void, toast: @escaping (String) -> Void) {
        let pieces = raw.split(separator: " ", maxSplits: 1).map(String.init)
        let action = pieces.first?.lowercased() ?? "help"
        let argument = pieces.count > 1 ? pieces[1] : ""
        switch action {
        case "status": checkStatus(show: show)
        case "inspect": toggleElementInspector(current?.webView, toast: toast)
        case "page", "api", "ui", "scam", "debug", "ask":
            if action == "debug", let error = current?.lastNavigationError {
                show(Self.report(title: "Page Diagnostics",
                    text: "Navigation failed\n\n\(error)\n\nHTTP status: \(current?.lastHTTPStatus.map(String.init) ?? "unavailable")\n\nThis is an observed WebKit/network error; no model inference was used.",
                    source: current?.logicalURL?.absoluteString ?? "WebKit"))
                return
            }
            guard let webView = current?.webView else { toast("No active page"); return }
            toast("Building verified semantic catalog…")
            extract(from: webView, requestedURL: current?.lastRequestedURL ?? webView.url) { [weak self] snapshot in
                guard let self, let snapshot else { toast("Could not read the page"); return }
                self.memory.remember(snapshot)
                let catalog = FactCatalog(snapshot: snapshot)
                self.select(action: action, query: argument, catalog: catalog) { selection in
                    DispatchQueue.main.async {
                        show(Self.semanticReport(action: action, catalog: catalog, selection: selection))
                    }
                }
            }
        case "research": research(tabs: tabs, question: argument, show: show, toast: toast)
        case "memory": show(Self.memoryReport(memory.search(argument), query: argument))
        case "tabs": groupTabs(tabs, show: show)
        case "focus": toggleAttentionFirewall(current?.webView, toast: toast)
        case "help", "": show(Self.helpPage())
        default: run("ask \(raw)", current: current, tabs: tabs, show: show, toast: toast)
        }
    }

    // JS-heavy pages often expose metadata before hydrated visible content.
    private func extract(from webView: WKWebView, requestedURL: URL?, attempt: Int = 0,
                         best: PageSnapshot? = nil, completion: @escaping (PageSnapshot?) -> Void) {
        webView.evaluateJavaScript(Self.semanticSnapshotJS) { [weak self, weak webView] value, _ in
            guard let self, let webView else { completion(best); return }
            let candidate: PageSnapshot? = {
                guard let dictionary = value as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return nil }
                return try? JSONDecoder().decode(PageSnapshot.self, from: data)
            }()
            let richest = [best, candidate].compactMap { $0 }.max { $0.richness < $1.richness }
            if richest?.isExplicitError == true { completion(richest); return }
            guard richest?.isWeak ?? true else { completion(richest); return }
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.extract(from: webView, requestedURL: requestedURL, attempt: attempt + 1,
                                 best: richest, completion: completion)
                }
                return
            }
            guard let requestedURL, ["http","https"].contains(requestedURL.scheme?.lowercased() ?? "") else {
                completion(richest); return
            }
            HTMLMetadataFallback.fetch(requestedURL) { fallback in
                let candidates = [richest, fallback].compactMap { $0 }
                completion(candidates.max { $0.richness < $1.richness })
            }
        }
    }

    private func select(action: String, query: String, catalog: FactCatalog,
                        completion: @escaping (VerifiedSelection) -> Void) {
        guard catalog.hasSufficientEvidence else {
            completion(.insufficient("deterministic_insufficient_evidence")); return
        }
        let allowed = Self.allowedLabels[action] ?? Self.allowedLabels["ask"]!
        let task = query.isEmpty ? Self.defaultTask[action] ?? "select relevant facts" : query
        let prompt = """
        Classify and select existing fact IDs. Never write facts or values.
        Task: \(Self.promptSafe(task, limit: 240))
        Evidence passed the deterministic sufficiency gate. Return status=ok and select supporting IDs.
        FACTS:
        \(catalog.prompt)
        """
        generateJSON(prompt, allowedLabels: allowed) { result in
            switch result {
            case .success(let data):
                let verified = SelectionVerifier.verify(data: data, catalog: catalog,
                                                        allowedLabels: Set(allowed))
                completion(verified.status == .ok ? verified
                    : .deterministic(catalog: catalog, label: allowed[0], reason: verified.reason))
            case .failure:
                completion(.deterministic(catalog: catalog, label: allowed[0],
                                          reason: "model_unavailable_or_invalid_json"))
            }
        }
    }

    private func generateJSON(_ prompt: String, allowedLabels: [String],
                              completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "stream": false,
            "format": Self.selectionSchema(allowedLabels: allowedLabels),
            "options": ["temperature": 0.0, "num_ctx": 4096, "num_predict": 150, "num_thread": 4]
        ])
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { completion(.failure(AIError.unavailable(error.localizedDescription))); return }
            guard let data,
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = envelope["response"] as? String,
                  let json = response.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: json)) != nil else {
                completion(.failure(AIError.invalidResponse)); return
            }
            completion(.success(json))
        }.resume()
    }

    private func research(tabs: [BrowserTab], question: String,
                          show: @escaping (String) -> Void, toast: @escaping (String) -> Void) {
        let live = Array(tabs.prefix(20))
        guard !live.isEmpty else { toast("No tabs"); return }
        toast("Collecting verified facts from \(live.count) tabs…")
        let group = DispatchGroup(), lock = NSLock()
        var pages: [(Int, PageSnapshot)] = []
        for (index, tab) in live.enumerated() {
            group.enter()
            extract(from: tab.webView, requestedURL: tab.lastRequestedURL ?? tab.webView.url) { snapshot in
                if let snapshot { lock.lock(); pages.append((index + 1, snapshot)); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, !pages.isEmpty else { toast("Could not read the tabs"); return }
            pages.sort { $0.0 < $1.0 }
            let catalog = FactCatalog(pages: pages)
            self.select(action: "research", query: question, catalog: catalog) { selection in
                DispatchQueue.main.async {
                    show(Self.semanticReport(action: "research", catalog: catalog, selection: selection))
                }
            }
        }
    }

    /// Useful without Ollama and unable to invent a grouping fact.
    private func groupTabs(_ tabs: [BrowserTab], show: @escaping (String) -> Void) {
        let groups = Dictionary(grouping: tabs.enumerated()) { _, tab in
            IntentClassifier.classify(url: tab.logicalURL, title: tab.displayTitle)
        }
        let rows = groups.sorted { $0.key < $1.key }.map { host, entries in
            let items = entries.map { "<li>[\($0.offset + 1)] \(Self.escape($0.element.displayTitle))</li>" }.joined()
            return "<h2>\(Self.escape(host))</h2><ul>\(items)</ul>"
        }.joined()
        show(CommandEngine.localPage(title: "Intent-aware tabs",
            body: "<h1>Intent-aware tabs</h1><p class=\"tagline\">Local intent classification · no generated facts</p>\(rows)"))
    }

    private func checkStatus(show: @escaping (String) -> Void) {
        let tiny = FactCatalog(facts: [Fact(id: "f1", kind: .title,
                                           value: "READY", source: "self-test", page: 1)])
        select(action: "ask", query: "select READY", catalog: tiny) { selection in
            DispatchQueue.main.async {
                let ok = selection.status == .ok && selection.factIDs.contains("f1")
                show(Self.report(title: "Local AI",
                    text: ok ? "✓ Ollama + ID verifier ready\n\nModel: gemma3:1b"
                             : "⚠ Model reachable, but ID-only self-test failed safely",
                    source: "local"))
            }
        }
    }

    private func toggleAttentionFirewall(_ webView: WKWebView?, toast: @escaping (String) -> Void) {
        guard let webView else { toast("No active page"); return }
        webView.evaluateJavaScript(Self.attentionFirewallJS) { value, _ in
            toast((value as? Bool) == true ? "Attention firewall enabled" : "Attention firewall disabled")
        }
    }

    private func toggleElementInspector(_ webView: WKWebView?, toast: @escaping (String) -> Void) {
        guard let webView else { toast("No active page"); return }
        webView.evaluateJavaScript(Self.elementInspectorJS) { value, _ in
            toast((value as? Bool) == true ? "Click an element to capture it for AI DevTools" : "Element inspector disabled")
        }
    }

    private static let allowedLabels: [String: [String]] = [
        "page": ["identity", "summary", "details", "actions"],
        "api": ["identity", "attributes", "actions", "relations"],
        "ui": ["primary", "details", "actions", "secondary"],
        "scam": ["risk_signal", "trust_signal", "unknown"],
        "debug": ["observed_issue", "control", "structure", "unknown"],
        "ask": ["answer", "context", "unknown"],
        "research": ["finding", "comparison", "contradiction", "unknown"]
    ]
    private static let defaultTask: [String: String] = [
        "page":"classify the page and select its essential facts",
        "api":"select identity, attributes and actions",
        "ui":"select facts for a minimal task-focused interface",
        "scam":"select only observable risk or trust signals",
        "debug":"select observable DOM, structure and control issues",
        "ask":"select the most important facts",
        "research":"select findings, comparisons and contradictions"
    ]

    private static func semanticReport(action: String, catalog: FactCatalog,
                                       selection: VerifiedSelection) -> String {
        let heading = title(for: action)
        guard selection.status == .ok else {
            return CommandEngine.localPage(title: heading,
                body: "<h1>\(escape(heading))</h1><p><code>null</code> · insufficient_evidence</p><p class=\"tagline\">\(escape(selection.reason)) · validator rejected unsupported output</p>")
        }
        if action == "api" {
            var fields: [String: [[String: Any]]] = [:]
            for section in selection.sections {
                fields[section.label] = section.factIDs.compactMap { id in
                    guard let fact = catalog.byID[id] else { return nil }
                    return ["factId": fact.id, "kind": fact.kind.rawValue,
                            "value": fact.value, "source": fact.source, "page": fact.page]
                }
            }
            let api: [String: Any] = ["status": "ok", "type": selection.pageType ?? "other",
                                      "source": catalog.source, "fields": fields]
            let data = try? JSONSerialization.data(withJSONObject: api, options: [.prettyPrinted, .sortedKeys])
            let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return CommandEngine.localPage(title: heading,
                body: "<h1>\(escape(heading))</h1><p class=\"tagline\">Typed, evidence-backed JSON · every value carries a verified factId</p><pre style=\"white-space:pre-wrap\">\(escape(json))</pre>")
        }
        var body = "<h1>\(escape(heading))</h1><p class=\"tagline\">Gemma 3 1B selects IDs only · \(escape(catalog.source)) · type: \(escape(selection.pageType ?? "other"))</p>"
        for section in selection.sections {
            body += "<h2>\(escape(section.label))</h2><table>"
            for id in section.factIDs {
                guard let fact = catalog.byID[id] else { continue }
                body += "<tr><td><code>\(fact.id)</code></td><td>\(escape(fact.kind.rawValue))</td><td>\(escape(fact.value))</td><td class=\"tagline\">\(escape(fact.source))</td></tr>"
            }
            body += "</table>"
        }
        body += "<p class=\"tagline\">Schema valid · all IDs verified · confidence \(String(format: "%.2f", selection.confidence))</p>"
        return CommandEngine.localPage(title: heading, body: body)
    }

    private static func title(for action: String) -> String {
        ["page":"Semantic Page Model", "api":"Personal Web API", "ui":"Interface Compiler",
         "scam":"Forensic Page Check", "debug":"AI DevTools", "ask":"Verified Answer",
         "research":"Verified Research"][action] ?? "MCV AI"
    }
    private static func report(title: String, text: String, source: String) -> String {
        CommandEngine.localPage(title: title,
            body: "<h1>\(escape(title))</h1><p class=\"tagline\">\(escape(source))</p><pre style=\"white-space:pre-wrap\">\(escape(text))</pre>")
    }
    private static func memoryReport(_ items: [MemoryItem], query: String) -> String {
        let rows = items.map { "<tr><td>\(escape($0.project ?? "Web"))</td><td><a href=\"\(escape($0.url))\">\(escape($0.title))</a></td><td>\(escape(($0.concepts ?? []).joined(separator: ", ")))</td><td>\(escape($0.summary))</td></tr>" }.joined()
        return CommandEngine.localPage(title: "Browser Memory",
            body: "<h1>Browser Memory Graph</h1><p class=\"tagline\">Local projects + concepts · \(escape(query.isEmpty ? "recent" : query))</p><table><tr><th>Project</th><th>Page</th><th>Concepts</th><th>Evidence</th></tr>\(rows)</table>")
    }
    private static func helpPage() -> String {
        let commands = [("ai page","verified semantic model"),("ai ui","fact-grounded interface compiler"),("ai api","ID-backed Personal Web API"),("ai research [question]","verified facts across tabs"),("ai memory [query]","local memory"),("ai tabs","intent grouping"),("ai focus","attention firewall"),("ai scam","observable risk signals"),("ai inspect","select a DOM element"),("ai debug","observable page/layout issues"),("ai ask <question>","verified fact selection"),("ai status","ID-only self-test")]
        let rows = commands.map { "<tr><td><code>\($0.0)</code></td><td>\($0.1)</td></tr>" }.joined()
        return CommandEngine.localPage(title: "MCV AI",
            body: "<h1>MCV Semantic Engine</h1><p class=\"tagline\">WebKit facts → IDs → Gemma selection → schema + evidence verification</p><table>\(rows)</table>")
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func promptSafe(_ value: String, limit: Int) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ").prefix(limit))
    }
    private static func selectionSchema(allowedLabels: [String]) -> [String: Any] {
        ["type":"object", "additionalProperties":false,
         "required":["status","pageType","sections","confidence"],
         "properties":[
            "status":["type":"string","enum":["ok","insufficient_evidence"]],
            "pageType":["type":["string","null"],"enum":["article","product","video","repository","thread","documentation","dashboard","form","other",NSNull()]],
            "sections":["type":"array","maxItems":4,"items":[
                "type":"object","additionalProperties":false,"required":["label","factIds"],
                "properties":["label":["type":"string","enum":allowedLabels],
                              "factIds":["type":"array","minItems":1,"maxItems":12,
                                         "items":["type":"string","pattern":"^f[1-9][0-9]*$"]]]]],
            "confidence":["type":"number","minimum":0,"maximum":1]
         ]]
    }

    private static let semanticSnapshotJS = #"""
    (() => {
      const clean=s=>(s||'').replace(/\s+/g,' ').trim(), visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'};
      const roots=[document]; document.querySelectorAll('*').forEach(e=>{if(e.shadowRoot)roots.push(e.shadowRoot)});document.querySelectorAll('iframe').forEach(f=>{try{if(f.contentDocument)roots.push(f.contentDocument)}catch(_){}});
      const all=q=>roots.flatMap(r=>Array.from(r.querySelectorAll(q))), pick=(q,n,m)=>all(q).filter(visible).slice(0,n).map(m);
      const metas={}; document.querySelectorAll('meta[name],meta[property]').forEach(e=>{const k=e.name||e.getAttribute('property'),v=clean(e.content);if(k&&v&&Object.keys(metas).length<40)metas[k]=v});
      const text=roots.map(r=>r.body?.innerText||r.host?.innerText||'').join('\n');
      const bootstrap=[];[['ytInitialPlayerResponse',window.ytInitialPlayerResponse],['ytInitialData',window.ytInitialData],['__NEXT_DATA__',window.__NEXT_DATA__],['__APOLLO_STATE__',window.__APOLLO_STATE__],['inspectedElement',window.__mcvInspectedElement]].forEach(([name,value])=>{if(value){try{bootstrap.push(JSON.stringify({[name]:value}).slice(0,12000))}catch(_){}}});
      const layoutDiagnostics=all('*').filter(visible).filter(e=>e.scrollWidth>e.clientWidth+2).slice(0,20).map(e=>{const s=getComputedStyle(e);return {type:'layout_overflow',message:`${e.tagName.toLowerCase()} scrollWidth=${e.scrollWidth} clientWidth=${e.clientWidth} display=${s.display} width=${s.width} margin=${s.margin}`,source:e.id?`#${e.id}`:String(e.className||e.tagName).slice(0,120)}});
      return {url:location.href,title:document.title||metas['og:title']||'',description:metas.description||metas['og:description']||'',language:document.documentElement.lang||'',readyState:document.readyState,text:clean(text).slice(0,30000),metas,
        headings:pick('h1,h2,h3,[role=heading]',80,e=>({level:e.tagName,text:clean(e.innerText||e.getAttribute('aria-label'))})),
        links:pick('a[href]',100,e=>({text:clean(e.innerText||e.getAttribute('aria-label')||e.title),url:e.href})),
        controls:pick('button,input,select,textarea,[role=button],[role=menuitem],[role=tab]',100,e=>({type:e.getAttribute('type')||e.getAttribute('role')||e.tagName.toLowerCase(),label:clean(e.innerText||e.getAttribute('aria-label')||e.getAttribute('placeholder')||e.name),value:clean(e.value),disabled:!!e.disabled})),
        media:pick('video,audio,img',50,e=>({type:e.tagName.toLowerCase(),title:clean(e.getAttribute('aria-label')||e.alt||e.title),src:e.currentSrc||e.src||''})),
        tables:pick('tr',60,e=>clean(e.innerText)).filter(Boolean),forms:pick('form',20,e=>clean(e.innerText).slice(0,800)),
        structuredData:Array.from(document.querySelectorAll('script[type="application/ld+json"],script[type="application/json"],script#__NEXT_DATA__')).slice(0,10).map(e=>clean(e.textContent).slice(0,12000)).concat(bootstrap),
        diagnostics:(globalThis.__mcvDiagnostics||[]).slice(-60).concat(layoutDiagnostics)};
    })()
    """#
    private static let attentionFirewallJS = #"""
    (()=>{const id='mcv-attention-firewall',old=document.getElementById(id);if(old){old.remove();document.querySelectorAll('[data-mcv-hidden]').forEach(e=>{e.style.removeProperty('display');e.removeAttribute('data-mcv-hidden')});return false}const style=document.createElement('style');style.id=id;style.textContent='[data-mcv-hidden]{display:none!important}';document.documentElement.appendChild(style);const noise=/(shorts|trending|recommended|suggested|autoplay|sponsored|promoted|newsletter|notification|cookie|advert)/i;document.querySelectorAll('aside,nav,section,div').forEach(e=>{const s=[e.id,e.className,e.getAttribute('aria-label'),e.getAttribute('data-testid')].filter(x=>typeof x==='string').join(' ');if(noise.test(s)&&!e.closest('main,article'))e.setAttribute('data-mcv-hidden','')});document.querySelectorAll('video,audio').forEach(e=>{e.autoplay=false;e.pause?.()});return true})()
    """#
    private static let elementInspectorJS = #"""
    (()=>{if(globalThis.__mcvInspectorActive){globalThis.__mcvInspectorCleanup?.();return false}globalThis.__mcvInspectorActive=true;let last,old='';const move=e=>{if(last)last.style.outline=old;last=e.target;old=last.style.outline;last.style.outline='2px solid #66d9ef'};const click=e=>{e.preventDefault();e.stopPropagation();const el=e.target,s=getComputedStyle(el),r=el.getBoundingClientRect();const path=[];let n=el;while(n&&n.nodeType===1&&path.length<8){let p=n.tagName.toLowerCase();if(n.id){p+='#'+n.id;path.unshift(p);break}const cls=Array.from(n.classList||[]).slice(0,2);if(cls.length)p+='.'+cls.join('.');path.unshift(p);n=n.parentElement}globalThis.__mcvInspectedElement={path:path.join(' > '),tag:el.tagName.toLowerCase(),text:(el.innerText||el.getAttribute('aria-label')||'').trim().slice(0,500),rect:{x:r.x,y:r.y,width:r.width,height:r.height},styles:{display:s.display,position:s.position,width:s.width,height:s.height,margin:s.margin,padding:s.padding,overflow:s.overflow,flex:s.flex,grid:s.grid,zIndex:s.zIndex}};cleanup()};const cleanup=()=>{if(last)last.style.outline=old;removeEventListener('mousemove',move,true);removeEventListener('click',click,true);delete globalThis.__mcvInspectorActive;delete globalThis.__mcvInspectorCleanup};globalThis.__mcvInspectorCleanup=cleanup;addEventListener('mousemove',move,true);addEventListener('click',click,true);return true})()
    """#
}

/// Same-origin network fallback for a WebKit navigation that collapsed to an
/// empty document. It reads public initial HTML only; it does not solve a
/// challenge, replay cookies, or disguise an error page.
private enum HTMLMetadataFallback {
    static func fetch(_ url: URL, completion: @escaping (PageSnapshot?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(BrowserTab.defaultUA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, data.count <= 8_000_000,
                  let html = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let snapshot = parse(html: html, url: http.url ?? url)
            DispatchQueue.main.async { completion(snapshot) }
        }.resume()
    }

    private static func parse(html: String, url: URL) -> PageSnapshot {
        var metas: [String:String] = [:]
        for tag in matches(#"(?is)<meta\b[^>]*>"#, html).prefix(80) {
            let name = attribute("name", in: tag) ?? attribute("property", in: tag)
            let content = attribute("content", in: tag)
            if let name, let content, !name.isEmpty, !content.isEmpty { metas[name] = decode(content) }
        }
        let title = decode(first(#"(?is)<title[^>]*>(.*?)</title>"#, html) ?? metas["og:title"] ?? "")
        let description = metas["description"] ?? metas["og:description"] ?? ""
        var withoutNoise = replacing(#"(?is)<script\b.*?</script>|<style\b.*?</style>|<!--.*?-->"#, in: html, with: " ")
        withoutNoise = replacing(#"(?s)<[^>]+>"#, in: withoutNoise, with: " ")
        let text = String(decode(withoutNoise).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(30_000))
        let structured = matches(#"(?is)<script[^>]+(?:application/ld\+json|application/json|__NEXT_DATA__)[^>]*>(.*?)</script>"#, html)
            .prefix(10).map { String(decode($0).prefix(12_000)) }
        return PageSnapshot(url: url.absoluteString, title: title, description: description,
            language: attribute("lang", in: first(#"(?is)<html\b[^>]*>"#, html) ?? "") ?? "",
            readyState: "network-fallback", text: text, metas: metas, headings: [], links: [],
            controls: [], media: [], tables: [], forms: [], structuredData: structured, diagnostics: [])
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        first("(?is)\\b" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']*)["']"#, tag)
    }
    private static func first(_ pattern: String, _ value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let index = match.numberOfRanges > 1 ? 1 : 0
        guard let range = Range(match.range(at: index), in: value) else { return nil }
        return String(value[range])
    }
    private static func matches(_ pattern: String, _ value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            let index = match.numberOfRanges > 1 ? 1 : 0
            return Range(match.range(at: index), in: value).map { String(value[$0]) }
        }
    }
    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        (try? NSRegularExpression(pattern: pattern))?.stringByReplacingMatches(in: value,
            range: NSRange(value.startIndex..., in: value), withTemplate: replacement) ?? value
    }
    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

private enum AIError: LocalizedError {
    case unavailable(String), invalidResponse
    var errorDescription: String? {
        switch self { case .unavailable(let detail): return "Ollama unavailable: \(detail)"
        case .invalidResponse: return "Invalid JSON" }
    }
}

private struct PageSnapshot: Codable {
    struct Heading: Codable { let level: String; let text: String }
    struct Link: Codable { let text: String; let url: String }
    struct Control: Codable { let type: String; let label: String; let value: String; let disabled: Bool }
    struct Media: Codable { let type: String; let title: String; let src: String }
    struct Diagnostic: Codable { let type: String; let message: String; let source: String }
    let url: String, title: String, description: String, language: String, readyState: String, text: String
    let metas: [String:String], headings: [Heading], links: [Link], controls: [Control], media: [Media]
    let tables: [String], forms: [String], structuredData: [String], diagnostics: [Diagnostic]
    var richness: Int { title.count + description.count + text.count + headings.count*20 + controls.count*20 + structuredData.joined().count + diagnostics.count*20 }
    var isWeak: Bool { richness < 350 }
    var isExplicitError: Bool {
        let signal = (title + " " + description + " " + String(text.prefix(500))).lowercased()
        return ["page not found", "access denied", "verify you are human", "captcha", "robot check"]
            .contains { signal.contains($0) }
    }
}

private enum FactKind: String, Codable { case url, title, description, metadata, heading, text, link, control, media, table, form, structured, diagnostic, security }
private struct Fact: Codable, Hashable { let id: String; let kind: FactKind; let value: String; let source: String; let page: Int }

private struct FactCatalog {
    let facts: [Fact], source: String
    var byID: [String:Fact] { Dictionary(uniqueKeysWithValues: facts.map { ($0.id,$0) }) }
    var hasSufficientEvidence: Bool {
        if facts.contains(where: { $0.kind == .title && $0.value.lowercased().contains("page not found") }) {
            return false
        }
        let useful = facts.filter { $0.kind != .url && $0.value.lowercased() != "page not found" }
        return useful.count >= 3
    }
    var deterministicPageType: String {
        let haystack = facts.prefix(30).map(\.value).joined(separator:" ").lowercased()
        if haystack.contains("github.com/login") || haystack.contains("password") { return "form" }
        if haystack.contains("wikipedia.org") { return "article" }
        if haystack.contains("amazon.") && haystack.contains("/dp/") { return "product" }
        if haystack.contains("youtube.com/watch") { return "video" }
        if haystack.contains("github.com/") { return "repository" }
        if haystack.contains("reddit.com/") { return "thread" }
        if haystack.contains("developer.mozilla.org") { return "documentation" }
        if haystack.contains("dashboard") { return "dashboard" }
        return "other"
    }
    var prompt: String { facts.prefix(70).map { "\($0.id)|\($0.kind.rawValue)|\(Self.compact($0.value, 120))" }.joined(separator: "\n") }
    init(snapshot: PageSnapshot) { self.init(pages: [(1,snapshot)]) }
    init(facts: [Fact]) { self.facts=facts; source="self-test" }
    init(pages: [(Int,PageSnapshot)]) {
        var values: [(FactKind,String,String,Int)] = []
        for (page,snapshot) in pages {
            func add(_ kind: FactKind,_ value: String,_ source: String) {
                let compact = Self.compact(value,500); if !compact.isEmpty { values.append((kind,compact,source,page)) }
            }
            add(.url,snapshot.url,"page.url"); add(.title,snapshot.title,"document.title"); add(.description,snapshot.description,"meta.description")
            for (key,value) in snapshot.metas.sorted(by: {$0.key<$1.key}) { add(.metadata,"\(key): \(value)","meta.\(key)") }
            snapshot.headings.forEach { add(.heading,$0.text,$0.level.lowercased()) }
            snapshot.controls.forEach { add(.control,"\($0.type): \($0.label)\($0.value.isEmpty ? "" : " = \($0.value)")","control") }
            snapshot.tables.forEach { add(.table,$0,"table") }; snapshot.forms.forEach { add(.form,$0,"form") }
            snapshot.media.forEach { add(.media,"\($0.type): \($0.title) \($0.src)","media") }
            snapshot.links.prefix(50).forEach { add(.link,"\($0.text) -> \($0.url)","link") }
            snapshot.structuredData.forEach { raw in
                if let data=raw.data(using:.utf8), let object=try? JSONSerialization.jsonObject(with:data) {
                    Self.flatten(object,prefix:"jsonld",depth:0).forEach { add(.structured,$0,"structuredData") }
                }
            }
            snapshot.diagnostics.forEach { add(.diagnostic,"\($0.type): \($0.message)",$0.source) }
            if URL(string:snapshot.url)?.scheme?.lowercased() == "http" { add(.security,"Transport is unencrypted HTTP","url.scheme") }
            let lower=snapshot.text.lowercased()
            if snapshot.controls.contains(where:{$0.type.lowercased()=="password"}) { add(.security,"Page requests a password","input[type=password]") }
            if ["cryptocurrency only","wire transfer only","gift card","act now","limited time"].contains(where:lower.contains) { add(.security,"Page contains urgency or irreversible-payment language","visibleText") }
            let policySignals=["refund","return policy","privacy policy","terms"] .filter(lower.contains)
            if !policySignals.isEmpty { add(.security,"Published policies: \(policySignals.joined(separator:", "))","visibleText") }
            Self.sentences(snapshot.text).prefix(80).forEach { add(.text,$0,"visibleText") }
        }
        var seen=Set<String>(), output:[Fact]=[]
        for (kind,value,origin,page) in values {
            guard seen.insert(value.lowercased()).inserted else { continue }
            output.append(Fact(id:"f\(output.count+1)",kind:kind,value:value,source:origin,page:page))
            if output.count >= 220 { break }
        }
        facts=output; source=pages.count == 1 ? pages[0].1.url : "\(pages.count) tabs"
    }
    private static func compact(_ value:String,_ limit:Int)->String { String(value.replacingOccurrences(of:"\n",with:" ").split(whereSeparator:{$0.isWhitespace}).joined(separator:" ").prefix(limit)) }
    private static func sentences(_ value:String)->[String] { value.components(separatedBy:CharacterSet(charactersIn:".!?\n")).map{compact($0,360)}.filter{$0.count>=18} }
    private static func flatten(_ value:Any,prefix:String,depth:Int)->[String] {
        guard depth<3 else{return[]}
        if let dict=value as? [String:Any] { return dict.sorted{$0.key<$1.key}.flatMap{flatten($0.value,prefix:"\(prefix).\($0.key)",depth:depth+1)} }
        if let array=value as? [Any] { return array.prefix(8).flatMap{flatten($0,prefix:prefix,depth:depth+1)} }
        if let string=value as? String { return ["\(prefix): \(compact(string,300))"] }
        if let number=value as? NSNumber { return ["\(prefix): \(number)"] }
        return []
    }
}

private struct ModelSelection: Decodable {
    struct Section: Decodable { let label:String; let factIds:[String] }
    let status:String, pageType:String?, sections:[Section], confidence:Double
}
private struct VerifiedSelection {
    enum Status { case ok, insufficient }
    struct Section { let label:String; let factIDs:[String] }
    let status:Status, pageType:String?, sections:[Section], confidence:Double, reason:String
    var factIDs:[String] { sections.flatMap{$0.factIDs} }
    static func insufficient(_ reason:String)->Self { .init(status:.insufficient,pageType:nil,sections:[],confidence:0,reason:reason) }
    static func deterministic(catalog:FactCatalog,label:String,reason:String)->Self {
        let selected = catalog.facts.filter { $0.kind != .url }.prefix(8).map(\.id)
        guard !selected.isEmpty else { return .insufficient("deterministic_insufficient_evidence") }
        return .init(status:.ok,pageType:catalog.deterministicPageType,
                     sections:[.init(label:label,factIDs:selected)],confidence:0.7,
                     reason:"deterministic_fallback_after_\(reason)")
    }
}
private enum SelectionVerifier {
    static let pageTypes:Set<String>=["article","product","video","repository","thread","documentation","dashboard","form","other"]
    static func verify(data:Data,catalog:FactCatalog,allowedLabels:Set<String>)->VerifiedSelection {
        guard let selection=try? JSONDecoder().decode(ModelSelection.self,from:data),
              ["ok","insufficient_evidence"].contains(selection.status),
              (0...1).contains(selection.confidence) else { return .insufficient("schema_invalid") }
        if selection.status == "insufficient_evidence" { return .insufficient("model_reported_insufficient_evidence") }
        guard let type=selection.pageType,pageTypes.contains(type),!selection.sections.isEmpty else { return .insufficient("schema_invalid") }
        let ids=Set(catalog.facts.map{$0.id}); var verified:[VerifiedSelection.Section]=[]
        for section in selection.sections {
            guard allowedLabels.contains(section.label),!section.factIds.isEmpty,
                  section.factIds.allSatisfy(ids.contains) else { return .insufficient("unknown_label_or_fact_id") }
            verified.append(.init(label:section.label,factIDs:Array(section.factIds.prefix(20))))
        }
        return .init(status:.ok,pageType:type,sections:verified,confidence:selection.confidence,reason:"verified")
    }
}

private struct MemoryItem:Codable { let url:String,title:String,summary:String,searchable:String,visitedAt:Date; let concepts:[String]?; let project:String? }
private final class BrowserMemoryStore {
    private var items:[MemoryItem]=[]
    private let file=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mcv/ai-memory.json")
    init(){if let data=try? Data(contentsOf:file),let saved=try? JSONDecoder().decode([MemoryItem].self,from:data){items=saved}}
    func remember(_ page:PageSnapshot){let concepts=Self.concepts(page.title+" "+page.description+" "+String(page.text.prefix(4000)));let item=MemoryItem(url:page.url,title:page.title,summary:String(page.text.prefix(360)),searchable:(page.title+" "+page.description+" "+page.text+" "+concepts.joined(separator:" ")).lowercased(),visitedAt:Date(),concepts:concepts,project:IntentClassifier.classify(url:URL(string:page.url),title:page.title));items.removeAll{$0.url==page.url};items.insert(item,at:0);items=Array(items.prefix(1000));try? FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);if let data=try? JSONEncoder().encode(items){try? data.write(to:file,options:.atomic)}}
    func search(_ query:String)->[MemoryItem]{let terms=query.lowercased().split(separator:" ").map(String.init);if terms.isEmpty{return Array(items.prefix(50))};return items.map{item in(item,terms.reduce(0){score,term in score+(item.searchable.contains(term) ? 1:0)})}.filter{$0.1>0}.sorted{$0.1>$1.1}.prefix(50).map(\.0)}
    private static func concepts(_ text:String)->[String]{let stop:Set<String>=["about","after","also","and","are","but","for","from","have","into","that","the","this","with","your","https","www"];let words=text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 && !stop.contains($0) };let counts=Dictionary(words.map{($0,1)},uniquingKeysWith:+);return counts.sorted{$0.value == $1.value ? $0.key<$1.key : $0.value>$1.value}.prefix(8).map(\.key)}
}

private enum IntentClassifier {
    static func classify(url:URL?,title:String)->String {
        let value=((url?.host ?? "")+" "+(url?.path ?? "")+" "+title).lowercased()
        let rules:[(String,[String])]=[("MC Browser",["webkit","swift","github","developer","mdn","stackoverflow","browser"]),("Research",["wikipedia","paper","docs","documentation","research"]),("Shopping",["amazon","shop","product","price","store"]),("Entertainment",["youtube","netflix","twitch","reddit","shorts"]),("Music",["soundcloud","spotify","music"]),("Communication",["chatgpt","mail","slack","discord"]),("Finance",["bank","trading","market","finance"])]
        return rules.first(where:{rule in rule.1.contains{value.contains($0)}})?.0 ?? "Temporary"
    }
}
