import XCTest
@testable import MCV

final class ExtensionRuntimeTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testManifestV2AndV3Decode() throws {
        let mv2 = try decode(#"{"manifest_version":2,"name":"V2","version":"1","permissions":["tabs"],"background":{"scripts":["bg.js"]},"browser_action":{"default_popup":"popup.html"}}"#)
        XCTAssertEqual(mv2.manifest_version, 2); XCTAssertEqual(mv2.background?.scripts, ["bg.js"]); XCTAssertEqual(mv2.popupPath, "popup.html")
        let mv3 = try decode(#"{"manifest_version":3,"name":"V3","version":"1","permissions":["storage","scripting"],"host_permissions":["https://*.example.com/*"],"background":{"service_worker":"worker.js"},"action":{"default_popup":"popup.html"}}"#)
        XCTAssertEqual(mv3.manifest_version, 3); XCTAssertTrue(mv3.requestedPermissions.contains("scripting")); XCTAssertNotNil(mv3.background?.service_worker)
    }

    func testChromeMatchPatterns() {
        XCTAssertTrue(ExtensionMatchPattern.matches("https://*.example.com/*", url: URL(string: "https://a.example.com/path")!))
        XCTAssertTrue(ExtensionMatchPattern.matches("*://example.com/foo*", url: URL(string: "http://example.com/foobar")!))
        XCTAssertFalse(ExtensionMatchPattern.matches("https://example.com/private/*", url: URL(string: "https://example.com/public/x")!))
        XCTAssertTrue(ExtensionMatchPattern.matches("<all_urls>", url: URL(string: "file:///tmp/test.html")!))
    }

    func testChromeWebStoreInstallURL() throws {
        let id = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        let page = URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(id)?hl=en")!
        XCTAssertEqual(MCVExtensionRuntime.shared.chromeWebStoreExtensionID(from: page), id)
        let download = try XCTUnwrap(MCVExtensionRuntime.shared.chromeWebStoreDownloadURL(extensionID: id))
        XCTAssertEqual(download.host, "clients2.google.com")
        XCTAssertTrue(download.absoluteString.contains(id))
        XCTAssertNil(MCVExtensionRuntime.shared.chromeWebStoreExtensionID(from: URL(string: "https://example.com/detail/\(id)")!))
        XCTAssertNil(MCVExtensionRuntime.shared.chromeWebStoreDownloadURL(extensionID: "invalid"))
    }

    func testUnpackedExtensionInstallation() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = temporary.appendingPathComponent("source"), library = temporary.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Fixture","version":"1.0","permissions":["storage"],"content_scripts":[{"matches":["<all_urls>"],"js":["content.js"]}]}"#.data(using: .utf8)!.write(to: source.appendingPathComponent("manifest.json"))
        try "globalThis.fixtureLoaded=true".write(to: source.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let (installed, manifest) = try ExtensionPackageLoader().install(from: source, into: library)
        XCTAssertEqual(manifest.name, "Fixture"); XCTAssertTrue(FileManager.default.fileExists(atPath: installed.rootURL.appendingPathComponent("content.js").path))
    }

    func testZipAndCRX3Installation() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = temporary.appendingPathComponent("source"), zip = temporary.appendingPathComponent("fixture.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Packed Fixture","version":"1"}"#.data(using: .utf8)!.write(to: source.appendingPathComponent("manifest.json"))
        try run("/usr/bin/zip", ["-q", "-r", zip.path, "."], directory: source)
        let zipInstall = temporary.appendingPathComponent("zip-install")
        XCTAssertEqual(try ExtensionPackageLoader().install(from: zip, into: zipInstall).1.name, "Packed Fixture")

        let payload = try Data(contentsOf: zip); var crx = Data("Cr24".utf8)
        crx.append(contentsOf: [3, 0, 0, 0, 0, 0, 0, 0]) // version 3, empty protobuf header
        crx.append(payload)
        let crxURL = temporary.appendingPathComponent("fixture.crx"); try crx.write(to: crxURL)
        XCTAssertEqual(try ExtensionPackageLoader().install(from: crxURL, into: temporary.appendingPathComponent("crx-install")).1.manifest_version, 3)
        try? FileManager.default.removeItem(at: temporary)
    }

    func testPopularExtensionCompatibilityProfiles() throws {
        // Representative public feature profiles used by these extensions.
        let profiles: [(String, String, CompatibilityLevel)] = [
            ("uBlock Origin", #"{"manifest_version":2,"name":"uBlock Origin","version":"1","permissions":["storage","tabs","webRequest","webRequestBlocking","<all_urls>"],"background":{"scripts":["background.js"]}}"#, .partial),
            ("Dark Reader", #"{"manifest_version":3,"name":"Dark Reader","version":"1","permissions":["storage","scripting","contextMenus"],"host_permissions":["<all_urls>"],"background":{"service_worker":"background.js"},"content_scripts":[{"matches":["<all_urls>"],"js":["inject.js"]}]}"#, .partial),
            ("Bitwarden", #"{"manifest_version":3,"name":"Bitwarden","version":"1","permissions":["storage","tabs","contextMenus","notifications"],"background":{"service_worker":"background.js"}}"#, .partial),
            ("React Developer Tools", #"{"manifest_version":3,"name":"React Developer Tools","version":"1","permissions":["devtools"],"devtools_page":"devtools.html"}"#, .unsupported)
        ]
        for (name, json, expected) in profiles {
            let report = ExtensionCompatibility.analyze(try decode(json))
            XCTAssertEqual(report.overall, expected, name)
        }
    }

    private func decode(_ json: String) throws -> ExtensionManifest { try decoder.decode(ExtensionManifest.self, from: Data(json.utf8)) }
    private func run(_ executable: String, _ arguments: [String], directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.currentDirectoryURL = directory
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
}
