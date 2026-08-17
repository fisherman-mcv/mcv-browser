import XCTest
import WebKit
@testable import MCV

@MainActor
final class ContextDownloadTests: XCTestCase {
    func testLinkAndImageDownloadActionsAppearForDOMHit() async throws {
        let tab = BrowserTab(configuration: WKWebViewConfiguration())
        defer { tab.teardown() }
        tab.webView.loadHTMLString("<a id='a' href='https://example.com/file.zip'><img id='i' src='https://example.com/image.png'></a>",
                                   baseURL: URL(string: "https://example.com/"))
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await tab.webView.evaluateJavaScript("document.getElementById('i').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,composed:true}))")
        try await Task.sleep(nanoseconds: 50_000_000)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        let titles = tab.webView.menu(for: event)?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("Download"))
        XCTAssertTrue(titles.contains("Download Image"))
    }
}
