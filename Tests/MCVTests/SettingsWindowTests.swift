import XCTest
@testable import MCV

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testSettingsBuildsAllNativePanesWithoutConstraintException() {
        let browser = BrowserWindowController()
        let settings = SettingsWindowController(browser: browser, onInstallExtension: {}, onExtensionsChanged: {})
        defer { settings.close(); browser.window.close() }
        let tabs = settings.window?.contentViewController as? NSTabViewController
        XCTAssertEqual(tabs?.tabViewItems.count, 3)
        XCTAssertEqual(tabs?.tabViewItems.map(\.label), ["General", "Privacy", "Extensions"])
        settings.show()
        XCTAssertTrue(settings.window?.isVisible == true)
        settings.selectExtensions()
        XCTAssertEqual(tabs?.selectedTabViewItemIndex, 2)
    }
}
