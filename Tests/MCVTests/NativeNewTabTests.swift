import XCTest
@testable import MCV

@MainActor
final class NativeNewTabTests: XCTestCase {
    func testNewTabHasNoNavigationAndWebViewIsNotAttached() {
        let manager = TabManager()
        let tab = manager.newTab(url: nil)
        defer { tab.teardown() }
        XCTAssertNil(tab.logicalURL)
        XCTAssertNil(tab.webView.url)
        XCTAssertNil(tab.webView.superview)
    }

    func testBlankTabCanTransitionToWebContent() {
        let manager = TabManager()
        let tab = manager.newTab(url: nil)
        defer { tab.teardown() }
        tab.load(URL(string: "data:text/html,<title>Loaded</title>")!)
        XCTAssertEqual(tab.logicalURL?.scheme, "data")
    }
}
