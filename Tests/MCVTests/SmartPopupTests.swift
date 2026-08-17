import AppKit
import WebKit
import XCTest
@testable import MCV

final class SmartPopupTests: XCTestCase {
    @MainActor
    func testSizedWindowOpenUsesNativeChildPanelAndWindowClose() {
        _ = NSApplication.shared
        let controller = BrowserWindowController()
        controller.start(homepage: "about:blank")
        controller.window.orderOut(nil)
        let source = controller.tabManager.current!.webView
        source.evaluateJavaScript("window.open('about:blank','oauth','width=480,height=560');true")
        spin(0.5)
        XCTAssertEqual(controller.window.childWindows?.count, 1)
        let popup = controller.window.childWindows?.first?.contentView?.subviews.compactMap { $0 as? WKWebView }.first
        XCTAssertNotNil(popup)
        popup?.evaluateJavaScript("window.close()")
        spin(0.4)
        XCTAssertEqual(controller.window.childWindows?.count ?? 0, 0)
        controller.window.close()
    }

    @MainActor private func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
}
