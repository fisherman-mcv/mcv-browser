import AppKit
import WebKit
import XCTest
@testable import MCV

final class PictureInPictureTests: XCTestCase {
    @MainActor
    func testFirefoxStyleControlIsInjectedForSupportedVideo() {
        _ = NSApplication.shared
        let tab = BrowserTab(configuration: WKWebViewConfiguration())
        tab.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        tab.webView.loadHTMLString(#"""
        <style>video{display:block;width:640px;height:360px}</style>
        <script>
        HTMLVideoElement.prototype.webkitSupportsPresentationMode = mode => mode === 'picture-in-picture';
        HTMLVideoElement.prototype.webkitSetPresentationMode = function(mode){ this.__mode = mode };
        </script>
        <video></video>
        """#, baseURL: URL(string: "https://video.example"))

        let end = Date().addingTimeInterval(2)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        let expectation = expectation(description: "PiP control query")
        tab.webView.evaluateJavaScript("Boolean(document.querySelector('.mcv-native-pip-control'))") { result, error in
            XCTAssertNil(error)
            XCTAssertEqual(result as? Bool, true)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        tab.teardown()
    }

    @MainActor
    func testFloatingPanelReceivesFullscreenPlayerSurface() {
        _ = NSApplication.shared
        let controller = BrowserWindowController()
        controller.start(homepage: "about:blank")
        controller.window.orderOut(nil)
        let tab = controller.tabManager.current!
        tab.webView.loadHTMLString(#"""
        <div id="movie_player" style="width:640px;height:360px"><video></video><button>Play</button></div>
        """#, baseURL: URL(string: "https://www.youtube.com"))
        spin(seconds: 0.5)

        controller.togglePictureInPicture(for: tab)
        spin(seconds: 0.5)
        XCTAssertTrue(tab.webView.window is NSPanel)

        let fullscreen = evaluate(tab.webView,
            "getComputedStyle(document.querySelector('#movie_player')).position === 'fixed'") as? Bool
        XCTAssertEqual(fullscreen, true)

        controller.togglePictureInPicture(for: tab)
        spin(seconds: 0.2)
        XCTAssertFalse(tab.webView.window is NSPanel)
        controller.window.close()
    }

    @MainActor private func spin(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    @MainActor private func evaluate(_ webView: WKWebView, _ script: String) -> Any? {
        let semaphore = DispatchSemaphore(value: 0)
        var value: Any?
        webView.evaluateJavaScript(script) { result, _ in value = result; semaphore.signal() }
        while semaphore.wait(timeout: .now()) != .success {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return value
    }
}
