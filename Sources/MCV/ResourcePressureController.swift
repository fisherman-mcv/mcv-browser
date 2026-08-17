import AppKit

/// Event-driven resource policy. It has no polling timer, so the controller
/// itself consumes no CPU while the machine and browser are idle.
final class ResourcePressureController {
    private weak var tabManager: TabManager?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private var lastPressureResponse = Date.distantPast

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
        // Memory-pressure sources may deliver repeated events while macOS is
        // compressing/swapping. Re-running teardown and cache work on every
        // event creates worse foreground jank than the memory it saves.
        guard Date().timeIntervalSince(lastPressureResponse) >= 30 else { return }
        lastPressureResponse = Date()
        if event.contains(.critical) {
            purgeMCVCache()
            _ = tabManager?.hibernateBackgroundTabs(olderThan: 2 * 60)
        } else if event.contains(.warning) {
            _ = tabManager?.hibernateBackgroundTabs(olderThan: 10 * 60)
        }
    }

    private func adaptToSystemState() {
        let info = ProcessInfo.processInfo
        if info.thermalState == .critical {
            purgeMCVCache()
            _ = tabManager?.hibernateBackgroundTabs(olderThan: 5 * 60)
        } else if info.thermalState == .serious || info.isLowPowerModeEnabled {
            _ = tabManager?.hibernateBackgroundTabs(olderThan: 5 * 60)
        }
    }

    private func purgeMCVCache() {
        // WebKit owns its resource cache and already adapts it to system
        // pressure. Clearing it here caused active pages to re-fetch and
        // re-decode resources under the exact conditions where that is slow.
        BrowserTab.purgeVolatileCaches()
    }

    deinit {
        pressureSource?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
