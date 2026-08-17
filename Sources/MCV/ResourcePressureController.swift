import AppKit
import WebKit

/// Event-driven resource policy. It has no polling timer, so the controller
/// itself consumes no CPU while the machine and browser are idle.
final class ResourcePressureController {
    private weak var tabManager: TabManager?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []

    init(tabManager: TabManager) { self.tabManager = tabManager }

    func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            self.handleMemoryPressure(event)
        }
        source.resume()
        pressureSource = source

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.adaptToSystemState()
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            _ = self?.tabManager?.hibernateBackgroundTabs(olderThan: 15 * 60)
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            _ = self?.tabManager?.hibernateBackgroundTabs(olderThan: 60)
        })
        adaptToSystemState()
    }

    private func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            evictVolatileWebCache()
            _ = tabManager?.hibernateBackgroundTabs(olderThan: 0)
        } else if event.contains(.warning) {
            _ = tabManager?.hibernateBackgroundTabs(olderThan: 2 * 60)
        }
    }

    private func adaptToSystemState() {
        let info = ProcessInfo.processInfo
        if info.thermalState == .critical {
            evictVolatileWebCache()
            _ = tabManager?.hibernateBackgroundTabs(olderThan: 60)
        } else if info.thermalState == .serious || info.isLowPowerModeEnabled {
            _ = tabManager?.hibernateBackgroundTabs(olderThan: 5 * 60)
        }
    }

    private func evictVolatileWebCache() {
        BrowserTab.purgeVolatileCaches()
        URLCache.shared.removeAllCachedResponses()
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: [WKWebsiteDataTypeMemoryCache]) { records in
            store.removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], for: records) {}
        }
    }

    deinit {
        pressureSource?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
