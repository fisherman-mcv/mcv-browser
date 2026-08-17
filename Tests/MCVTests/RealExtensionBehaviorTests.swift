import AppKit
import WebKit
import XCTest
@testable import MCV

final class RealExtensionBehaviorTests: XCTestCase {
    struct Result: Codable {
        let extensionName: String
        let version: String
        let status: String
        let backgroundAPI: Bool
        let contentAPI: Bool
        let storageRoundTrip: Bool
        let popupLoaded: Bool?
        let scriptErrors: [String]
        let apiFailures: [String: Int]
        let reason: String
    }

    @MainActor
    func testTwentyUnmodifiedChromeExtensionsInWKWebView() throws {
        guard ProcessInfo.processInfo.environment["MCV_REAL_EXTENSION_TESTS"] == "1" else {
            throw XCTSkip("Set MCV_REAL_EXTENSION_TESTS=1 to run downloaded Chrome Web Store CRXs")
        }
        _ = NSApplication.shared
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let packages = repository.appendingPathComponent("Benchmarks/real-extensions/packages")
        var names = try FileManager.default.contentsOfDirectory(at: packages, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "crx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let filter = ProcessInfo.processInfo.environment["MCV_EXTENSION_FILTER"], !filter.isEmpty {
            names = names.filter { $0.deletingPathExtension().lastPathComponent == filter }
        } else { XCTAssertEqual(names.count, 20) }
        var results: [Result] = []

        for package in names {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcv-real-\(UUID().uuidString)")
            MCVExtensionRuntime.shared.resetForIntegrationTests(root: root)
            let item = try MCVExtensionRuntime.shared.install(from: package)
            MCVExtensionRuntime.shared.approveInstall(id: item.id)

            let controller = BrowserWindowController()
            MCVExtensionRuntime.shared.host = controller
            controller.start(homepage: "https://example.com")
            controller.window.orderOut(nil)
            spin(seconds: 4)

            let manifest = MCVExtensionRuntime.shared.manifestForIntegrationTests(extensionID: item.id)!
            let background = evaluateBackground(id: item.id,
                script: "({api:typeof chrome==='object'&&chrome.runtime?.id!=null,errors:globalThis.__mcvErrors||[]})") as? [String: Any]
            let backgroundAPI = manifest.background == nil || (background?["api"] as? Bool == true)
            var errors = background?["errors"] as? [String] ?? []

            let content = evaluateContent(id: item.id, webView: controller.tabManager.current!.webView,
                script: "({api:typeof chrome==='object'&&chrome.runtime?.id!=null,errors:globalThis.__mcvErrors||[]})") as? [String: Any]
            let contentAPI = manifest.content_scripts?.isEmpty == false ? (content?["api"] as? Bool == true) : true
            errors.append(contentsOf: content?["errors"] as? [String] ?? [])

            let requiresStorage = manifest.requestedPermissions.contains("storage")
            var storage = "not-requested"
            if requiresStorage {
                _ = evaluateContent(id: item.id, webView: controller.tabManager.current!.webView,
                    script: "globalThis.__mcvStorageProbe='pending';chrome.storage.local.set({mcvRealProbe:'ok'}).then(()=>chrome.storage.local.get('mcvRealProbe')).then(x=>globalThis.__mcvStorageProbe=x.mcvRealProbe).catch(e=>globalThis.__mcvStorageProbe='error:'+e.message);true")
                spin(seconds: 0.5)
                storage = evaluateContent(id: item.id, webView: controller.tabManager.current!.webView,
                                          script: "globalThis.__mcvStorageProbe") as? String ?? "missing"
            }

            var popupLoaded: Bool? = nil
            if manifest.popupPath != nil {
                MCVExtensionRuntime.shared.showPopup(extensionID: item.id); spin(seconds: 1)
                let popup = NSApp.windows.compactMap { $0.contentView as? WKWebView }.last
                popupLoaded = popup.map { !$0.isLoading && (($0.stringByEvaluatingJavaScriptFromString("String(document.documentElement?.innerHTML.length||0)") as NSString).integerValue > 100) } ?? false
                popup?.window?.orderOut(nil)
            }

            let failures = MCVExtensionRuntime.shared.integrationDiagnostics(extensionID: item.id)
            let storageOK = !requiresStorage || storage == "ok"
            let fatalErrors = errors.filter { !$0.contains("ResizeObserver") && !$0.contains("favicon") }
            let status: String
            var reasons: [String] = []
            if !backgroundAPI || !contentAPI || !storageOK {
                status = "FAIL"
                if !backgroundAPI { reasons.append("background API did not initialize") }
                if !contentAPI { reasons.append("content-world API did not initialize") }
                if !storageOK { reasons.append("storage round-trip failed") }
            } else if !fatalErrors.isEmpty || !failures.isEmpty || popupLoaded == false {
                status = "PARTIAL"
                if !fatalErrors.isEmpty { reasons.append("script errors: \(fatalErrors.prefix(2).joined(separator: " | "))") }
                if !failures.isEmpty { reasons.append("unsupported/denied calls: \(failures.keys.sorted().joined(separator: ", "))") }
                if popupLoaded == false { reasons.append("popup did not load") }
            } else {
                status = "PASS"; reasons.append("background/content API and persistent storage executed without observed errors")
            }
            results.append(.init(extensionName: package.deletingPathExtension().lastPathComponent,
                                 version: item.manifest.version, status: status, backgroundAPI: backgroundAPI,
                                 contentAPI: contentAPI, storageRoundTrip: storageOK, popupLoaded: popupLoaded,
                                 scriptErrors: Array(fatalErrors.prefix(10)), apiFailures: failures,
                                 reason: reasons.joined(separator: "; ")))
            controller.window.orderOut(nil)
        }

        let output = repository.appendingPathComponent("Benchmarks/real-extensions/runtime-results.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        XCTAssertEqual(results.count, names.count)
    }

    @MainActor
    func testMV3LifecycleAndFullProcessPersistence() throws {
        guard ProcessInfo.processInfo.environment["MCV_REAL_EXTENSION_TESTS"] == "1" else {
            throw XCTSkip("Real extension integration test")
        }
        _ = NSApplication.shared
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcv-persistence-\(UUID().uuidString)")
        MCVExtensionRuntime.shared.resetForIntegrationTests(root: root)
        let item = try MCVExtensionRuntime.shared.install(from: repository.appendingPathComponent("Tests/Fixtures/MV3Lifecycle"))
        MCVExtensionRuntime.shared.approveInstall(id: item.id)
        let controller = BrowserWindowController(); MCVExtensionRuntime.shared.host = controller
        controller.start(homepage: "https://example.com"); controller.window.orderOut(nil); spin(seconds: 1)
        _ = evaluateBackground(id: item.id, script: "({api:typeof chrome==='object',fixture:globalThis.fixtureLoaded===true,errors:globalThis.__mcvErrors||[],html:document.documentElement.innerHTML.slice(0,200)})")
        controller.openNewTab(); spin(seconds: 0.4); controller.closeCurrentTab(); spin(seconds: 0.6)
        let before = readStorage(root: root, id: item.id)
        XCTAssertGreaterThanOrEqual(before["createdCount"] as? Int ?? 0, 1)
        XCTAssertGreaterThanOrEqual(before["removedCount"] as? Int ?? 0, 1)
        XCTAssertGreaterThanOrEqual(before["installedCount"] as? Int ?? 0, 1)

        controller.window.orderOut(nil)
        let executable = repository.appendingPathComponent(".build/debug/MCV")
        var counts: [Int] = []
        for _ in 0..<2 {
            let process = Process(); process.executableURL = executable
            var environment = ProcessInfo.processInfo.environment; environment["MCV_EXTENSION_ROOT"] = root.path
            process.environment = environment; try process.run(); spin(seconds: 1.5); process.terminate(); process.waitUntilExit()
            counts.append(readStorage(root: root, id: item.id)["startupCount"] as? Int ?? 0)
        }
        XCTAssertGreaterThan(counts[0], before["startupCount"] as? Int ?? 0)
        XCTAssertGreaterThan(counts[1], counts[0])
        let persisted = try JSONDecoder().decode([InstalledExtension].self, from: Data(contentsOf: root.appendingPathComponent("installed.json")))
        XCTAssertEqual(persisted.first?.grantedPermissions, item.manifest.requestedPermissions)
        XCTAssertTrue(persisted.first?.enabled == true)
    }

    @MainActor
    func testCriticalRealExtensionBehavior() throws {
        guard ProcessInfo.processInfo.environment["MCV_REAL_EXTENSION_TESTS"] == "1" else { throw XCTSkip("Real extension integration test") }
        _ = NSApplication.shared
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let packages = repository.appendingPathComponent("Benchmarks/real-extensions/packages")
        var report: [[String: Any]] = []

        // uBlock Origin Lite: compare actual subresource load/error outcomes
        // against an extension-free WKWebView on three different document origins.
        let probeOrigins = ["https://example.com/", "https://www.wikipedia.org/", "https://github.com/"]
        var baselineBlocked = 0, ubolBlocked = 0, controlLoaded = 0
        for origin in probeOrigins {
            let baseline = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600))
            let result = networkProbe(webView: baseline, origin: origin)
            baselineBlocked += result.adErrors; controlLoaded += result.controlLoaded ? 1 : 0
        }
        let ubol = try launch(package: packages.appendingPathComponent("ublock-origin-lite.crx"), repository: repository)
        spin(seconds: 5) // allow WKContentRuleList compilation before requests
        for origin in probeOrigins {
            let result = networkProbe(webView: ubol.controller.tabManager.current!.webView, origin: origin)
            ubolBlocked += result.adErrors; controlLoaded += result.controlLoaded ? 1 : 0
        }
        let ubolWorks = ubolBlocked > baselineBlocked
        report.append(["extension": "uBlock Origin Lite", "status": ubolWorks ? "PASS" : "FAIL",
                       "baselineAdErrors": baselineBlocked, "withExtensionAdErrors": ubolBlocked,
                       "reason": ubolWorks ? "DNR blocked additional advertising/tracker scripts on three origins" : "No measurable DNR blocking beyond baseline"])
        ubol.controller.window.orderOut(nil)

        // Dark Reader: verify its production DOM/style markers, not merely API availability.
        let dark = try launch(package: packages.appendingPathComponent("dark-reader.crx"), repository: repository)
        var darkened = 0
        for raw in ["https://example.com", "https://en.wikipedia.org/wiki/WebKit", "https://github.com/WebKit/WebKit"] {
            dark.controller.tabManager.current!.load(URL(string: raw)!); spin(seconds: 5)
            let marker = evaluatePage(dark.controller.tabManager.current!.webView,
                "Boolean(document.querySelector('style.darkreader,meta[name=darkreader],#__darkreader__fallback'))") as? Bool ?? false
            if marker { darkened += 1 }
        }
        report.append(["extension": "Dark Reader", "status": darkened >= 2 ? "PASS" : (darkened > 0 ? "PARTIAL" : "FAIL"),
                       "pagesChanged": darkened, "pagesTested": 3,
                       "reason": "Dark Reader production style markers detected on \(darkened)/3 pages"])
        dark.controller.window.orderOut(nil)

        // Bitwarden: real popup + content scripts on a dynamically created login form.
        let bitwarden = try launch(package: packages.appendingPathComponent("bitwarden.crx"), repository: repository)
        let page = bitwarden.controller.tabManager.current!.webView
        _ = evaluatePage(page, "document.body.innerHTML='<form><input id=email autocomplete=username><input id=password type=password autocomplete=current-password><button>Login</button></form>';true")
        spin(seconds: 2)
        let contentHealthy = (evaluateContent(id: bitwarden.id, webView: page,
            script: "({api:typeof chrome==='object',errors:globalThis.__mcvErrors||[]})") as? [String: Any])?["api"] as? Bool ?? false
        MCVExtensionRuntime.shared.showPopup(extensionID: bitwarden.id); spin(seconds: 2)
        let popup = NSApp.windows.compactMap { $0.contentView as? WKWebView }.last
        let popupState = popup.flatMap { evaluatePage($0, "({ready:document.readyState,root:Boolean(document.querySelector('app-root')),scripts:document.scripts.length,errors:globalThis.__mcvErrors||[]})") as? [String: Any] } ?? [:]
        let popupOK = popupState["ready"] as? String == "complete" && popupState["root"] as? Bool == true
        let bwFailures = MCVExtensionRuntime.shared.integrationDiagnostics(extensionID: bitwarden.id)
        report.append(["extension": "Bitwarden", "status": contentHealthy && popupOK ? "PARTIAL" : "FAIL",
                       "popupLoaded": popupOK, "contentInjection": contentHealthy,
                       "reason": contentHealthy && popupOK ? "Popup, storage bridge and login-page content scripts load; vault unlock/autofill cannot complete because nativeMessaging/offscreen/auth flows are incomplete" : "Popup or content injection failed",
                       "apiFailures": bwFailures, "popupState": popupState])
        popup?.window?.orderOut(nil); bitwarden.controller.window.orderOut(nil)

        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: repository.appendingPathComponent("Benchmarks/real-extensions/critical-results.json"), options: .atomic)
        XCTAssertTrue(ubolWorks)
        XCTAssertGreaterThanOrEqual(darkened, 2)
        XCTAssertTrue(contentHealthy && popupOK)
    }

    @MainActor private func spin(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func readStorage(root: URL, id: String) -> [String: Any] {
        let url = root.appendingPathComponent(id).appendingPathComponent(".mcv-storage-local.json")
        guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    @MainActor private func launch(package: URL, repository: URL) throws -> (controller: BrowserWindowController, id: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcv-critical-\(UUID().uuidString)")
        MCVExtensionRuntime.shared.resetForIntegrationTests(root: root)
        let item = try MCVExtensionRuntime.shared.install(from: package); MCVExtensionRuntime.shared.approveInstall(id: item.id)
        let controller = BrowserWindowController(); MCVExtensionRuntime.shared.host = controller
        controller.start(homepage: "https://example.com"); controller.window.orderOut(nil); spin(seconds: 4)
        return (controller, item.id)
    }

    @MainActor private func networkProbe(webView: WKWebView, origin: String) -> (adErrors: Int, controlLoaded: Bool) {
        let html = """
        <script>window.probe={ads:0,control:false,done:0};function ad(ok){if(!ok)probe.ads++;if(++probe.done===4)probe.complete=true}</script>
        <script src="https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js" onload="ad(true)" onerror="ad(false)"></script>
        <script src="https://www.google-analytics.com/analytics.js" onload="ad(true)" onerror="ad(false)"></script>
        <script src="https://connect.facebook.net/en_US/fbevents.js" onload="ad(true)" onerror="ad(false)"></script>
        <script src="https://cdnjs.cloudflare.com/ajax/libs/dayjs/1.11.10/dayjs.min.js" onload="probe.control=true;ad(true)" onerror="ad(false)"></script>
        """
        webView.loadHTMLString(html, baseURL: URL(string: origin)); spin(seconds: 7)
        let value = evaluatePage(webView, "window.probe") as? [String: Any] ?? [:]
        return ((value["ads"] as? NSNumber)?.intValue ?? 0, value["control"] as? Bool ?? false)
    }

    @MainActor private func evaluatePage(_ webView: WKWebView, _ script: String) -> Any? {
        var value: Any?; let semaphore = DispatchSemaphore(value: 0)
        webView.evaluateJavaScript(script) { result, _ in value = result; semaphore.signal() }
        wait(semaphore); return value
    }

    @MainActor private func evaluateBackground(id: String, script: String) -> Any? {
        var value: Any?; let semaphore = DispatchSemaphore(value: 0)
        MCVExtensionRuntime.shared.evaluateBackground(extensionID: id, script: script) { result, error in
            if let error { print("BACKGROUND EVAL ERROR [\(id)]: \(error)") }; value = result; semaphore.signal()
        }
        wait(semaphore); return value
    }

    @MainActor private func evaluateContent(id: String, webView: WKWebView, script: String) -> Any? {
        var value: Any?; let semaphore = DispatchSemaphore(value: 0)
        MCVExtensionRuntime.shared.evaluateContent(extensionID: id, webView: webView, script: script) { result, error in
            if let error { print("CONTENT EVAL ERROR [\(id)]: \(error)") }; value = result; semaphore.signal()
        }
        wait(semaphore); return value
    }

    @MainActor private func wait(_ semaphore: DispatchSemaphore) {
        let end = Date().addingTimeInterval(5)
        while semaphore.wait(timeout: .now()) != .success && Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

private extension WKWebView {
    func stringByEvaluatingJavaScriptFromString(_ script: String) -> String {
        var result = ""; let semaphore = DispatchSemaphore(value: 0)
        evaluateJavaScript(script) { value, _ in result = value as? String ?? ""; semaphore.signal() }
        let end = Date().addingTimeInterval(3)
        while semaphore.wait(timeout: .now()) != .success && Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return result
    }
}
