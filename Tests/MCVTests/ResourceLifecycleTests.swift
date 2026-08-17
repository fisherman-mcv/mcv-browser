import XCTest
import WebKit
@testable import MCV

@MainActor
final class ResourceLifecycleTests: XCTestCase {
    func testBookmarkFolderCanBeUngroupedWithoutLosingBookmarks() {
        var config = MCVConfig.standard
        config.bookmarkFolders = ["Research"]
        config.bookmarks = [
            "Existing": "https://existing.example",
            "Research/Existing": "https://collision.example",
            "Research/Paper": "https://paper.example",
        ]

        config.ungroupBookmarkFolder(named: "Research")

        XCTAssertFalse(config.bookmarkFolders.contains("Research"))
        XCTAssertEqual(config.bookmarks["Paper"], "https://paper.example")
        XCTAssertEqual(config.bookmarks["Existing"], "https://existing.example")
        XCTAssertEqual(config.bookmarks["Existing 2"], "https://collision.example")
        XCTAssertFalse(config.bookmarks.keys.contains { $0.hasPrefix("Research/") })
    }

    func testBookmarkFolderCanBeDeletedWithItsContents() {
        var config = MCVConfig.standard
        config.bookmarkFolders = ["Delete Me", "Keep"]
        config.bookmarks = ["Delete Me/A": "https://a.example", "Keep/B": "https://b.example"]

        config.deleteBookmarkFolder(named: "Delete Me")

        XCTAssertEqual(config.bookmarkFolders, ["Keep"])
        XCTAssertNil(config.bookmarks["Delete Me/A"])
        XCTAssertEqual(config.bookmarks["Keep/B"], "https://b.example")
    }

    @MainActor
    func testTabReorderingCannotCrossPinnedBoundary() {
        _ = NSApplication.shared
        let manager = TabManager(groupsFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let pinnedA = manager.newTab(url: URL(string: "https://a.example"), pinned: true)
        let pinnedB = manager.newTab(url: URL(string: "https://b.example"), pinned: true)
        let normalA = manager.newTab(url: URL(string: "https://c.example"))
        let normalB = manager.newTab(url: URL(string: "https://d.example"))

        XCTAssertFalse(manager.moveTab(from: 2, to: 1))
        XCTAssertEqual(manager.tabs.map(ObjectIdentifier.init), [pinnedA, pinnedB, normalA, normalB].map(ObjectIdentifier.init))
        XCTAssertTrue(manager.moveTab(from: 3, to: 2))
        XCTAssertEqual(manager.tabs.map(ObjectIdentifier.init), [pinnedA, pinnedB, normalB, normalA].map(ObjectIdentifier.init))
        XCTAssertTrue(manager.moveTab(from: 1, to: 0))
        XCTAssertEqual(manager.tabs.map(ObjectIdentifier.init), [pinnedB, pinnedA, normalB, normalA].map(ObjectIdentifier.init))
    }

    @MainActor
    func testTabGroupsCollapseHibernateAndRespectPinnedBoundary() {
        _ = NSApplication.shared
        let manager = TabManager(groupsFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        manager.newTab(url: URL(string: "https://pinned.example"), pinned: true)
        let researchA = manager.newTab(url: URL(string: "https://a.example"))
        let researchB = manager.newTab(url: URL(string: "https://b.example"))

        XCTAssertNil(manager.createGroup(from: 0, with: 1))
        let groupID = try! XCTUnwrap(manager.createGroup(from: 2, with: 1))
        XCTAssertEqual(manager.tabGroups.first { $0.id == groupID }?.colorIndex, -1)
        XCTAssertEqual(manager.group(containing: researchA.id)?.id, groupID)
        XCTAssertEqual(manager.group(containing: researchB.id)?.id, groupID)

        XCTAssertEqual(manager.hibernateGroup(groupID), 2)
        XCTAssertTrue(researchA.isHibernated)
        XCTAssertTrue(researchB.isHibernated)
        XCTAssertTrue(try! XCTUnwrap(manager.tabGroups.first { $0.id == groupID }).isCollapsed)

        let activeIndex = try! XCTUnwrap(manager.tabs.firstIndex { $0 === researchB })
        manager.select(at: activeIndex)
        XCTAssertFalse(researchB.isHibernated)
    }

    @MainActor
    func testClosingCurrentGroupMemberDoesNotCloseWholeGroup() {
        _ = NSApplication.shared
        let manager = TabManager(groupsFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        manager.newTab(url: URL(string: "https://outside.example"))
        let a = manager.newTab(url: URL(string: "https://a.example"))
        manager.newTab(url: URL(string: "https://b.example"))
        manager.newTab(url: URL(string: "https://c.example"))
        let groupID = try! XCTUnwrap(manager.createGroup(from: 3, with: 2))
        _ = manager.createGroup(from: 1, with: 2)
        let aIndex = try! XCTUnwrap(manager.tabs.firstIndex { $0 === a })
        XCTAssertTrue(manager.close(at: aIndex))
        XCTAssertNotNil(manager.tabGroups.first { $0.id == groupID })
        XCTAssertEqual(manager.tabGroups.first { $0.id == groupID }?.tabIDs.count, 2)
    }

    @MainActor
    func testTabGroupsPersistAcrossManagerRestart() {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = TabManager(groupsFileURL: file)
        first.newTab(url: URL(string: "https://one.example"))
        first.newTab(url: URL(string: "https://two.example"))
        let id = try! XCTUnwrap(first.createGroup(from: 1, with: 0))
        first.toggleGroup(id)
        first.setGroupColor(id, colorIndex: 1)

        let restored = TabManager(groupsFileURL: file)
        restored.newTab(url: URL(string: "https://one.example"))
        restored.newTab(url: URL(string: "https://two.example"))
        restored.restoreGroups()

        XCTAssertEqual(restored.tabGroups.count, 1)
        XCTAssertEqual(restored.tabGroups[0].tabIDs.count, 2)
        XCTAssertTrue(restored.tabGroups[0].isCollapsed)
        XCTAssertEqual(restored.tabGroups[0].colorIndex, 1)
    }

    @MainActor
    func testUngroupKeepsEveryTabOpenAndOrdered() {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = TabManager(groupsFileURL: file)
        let first = manager.newTab(url: URL(string: "https://one.example"))
        let second = manager.newTab(url: URL(string: "https://two.example"))
        let id = try! XCTUnwrap(manager.createGroup(from: 1, with: 0))
        let before = manager.tabs.map(\.id)

        manager.ungroup(id)

        XCTAssertTrue(manager.tabGroups.isEmpty)
        XCTAssertEqual(manager.tabs.map(\.id), before)
        XCTAssertTrue(manager.tabs.contains { $0 === first })
        XCTAssertTrue(manager.tabs.contains { $0 === second })
    }

    @MainActor
    func testLocalHelpPageNeverReplacesPinnedTab() {
        _ = NSApplication.shared
        let controller = BrowserWindowController()
        let pinnedURL = URL(string: "https://example.com/important")!
        controller.tabManager.newTab(url: pinnedURL, pinned: true)

        controller.showLocalPage(html: CommandEngine.helpHTML())

        XCTAssertEqual(controller.tabManager.tabs.count, 2)
        XCTAssertTrue(controller.tabManager.tabs[0].isPinned)
        XCTAssertEqual(controller.tabManager.tabs[0].logicalURL, pinnedURL)
        XCTAssertFalse(controller.tabManager.current?.isPinned ?? true)
    }

    @MainActor
    func testAddressNavigationNeverReplacesPinnedTab() {
        _ = NSApplication.shared
        let controller = BrowserWindowController()
        let pinnedURL = URL(string: "https://example.com/important")!
        let destination = URL(string: "https://search.example/result")!
        controller.tabManager.newTab(url: pinnedURL, pinned: true)

        controller.navigate(to: destination, newTab: false)

        XCTAssertEqual(controller.tabManager.tabs.count, 2)
        XCTAssertEqual(controller.tabManager.tabs[0].logicalURL, pinnedURL)
        XCTAssertTrue(controller.tabManager.tabs[0].isPinned)
        XCTAssertEqual(controller.tabManager.current?.logicalURL, destination)
        XCTAssertFalse(controller.tabManager.current?.isPinned ?? true)
    }

    func testSwitchingTabsDoesNotSuspendBackgroundMusic() {
        let manager = TabManager()
        let music = manager.newTab(url: nil)
        _ = manager.newTab(url: nil)
        XCTAssertFalse(music.isMediaSuspended)
        manager.select(at: 0)
        XCTAssertFalse(manager.tabs[1].isMediaSuspended)
        manager.tabs.forEach { $0.teardown() }
    }

    func testNumericShortcutsClampToLastAndCommandNineAlwaysSelectsLast() {
        let manager = TabManager()
        for _ in 0..<4 { manager.newTab(url: nil) }
        manager.select(at: 0)
        manager.selectShortcut(2)
        XCTAssertEqual(manager.currentIndex, 1)
        manager.selectShortcut(5)
        XCTAssertEqual(manager.currentIndex, 3)
        manager.select(at: 0)
        manager.selectShortcut(9)
        XCTAssertEqual(manager.currentIndex, 3)
        manager.tabs.forEach { $0.teardown() }
    }

    func testNewWindowResetCreatesOneNativeBlankTab() {
        let manager = TabManager()
        manager.newTab(url: URL(string: "data:text/html,old")!)
        manager.resetForNewWindow()
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNil(manager.current?.logicalURL)
        manager.tabs.forEach { $0.teardown() }
    }

    func testHibernationPreservesLogicalURLAndWakesOnSelection() async throws {
        let manager = TabManager()
        let first = manager.newTab(url: URL(string: "https://example.com/")!)
        try await waitUntil { first.webView.url?.host == "example.com" && !first.webView.isLoading }
        _ = manager.newTab(url: nil)

        XCTAssertTrue(first.hibernate())
        XCTAssertTrue(first.isHibernated)
        XCTAssertEqual(first.logicalURL?.absoluteString, "https://example.com/")
        XCTAssertEqual(manager.sessionURLs.first, "https://example.com/")

        manager.select(at: 0)
        XCTAssertFalse(first.isHibernated)
        XCTAssertEqual(first.logicalURL?.absoluteString, "https://example.com/")
    }

    private func waitUntil(timeout: TimeInterval = 8,
                           _ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(predicate())
    }
}
