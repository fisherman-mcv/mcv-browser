import Foundation

struct DownloadItem {
    enum State { case inProgress, completed, failed }
    let id: UUID
    let filename: String
    var fraction: Double
    var state: State
    let destination: URL
}

/// Реєстр завантажень для бічної панелі — оновлюється з WKDownloadDelegate,
/// панель просто підписується на `onChange`.
final class DownloadsCenter {
    static let shared = DownloadsCenter()
    private(set) var items: [DownloadItem] = []
    var onChange: (() -> Void)?

    private init() {}

    @discardableResult
    func add(filename: String, destination: URL) -> UUID {
        let item = DownloadItem(id: UUID(), filename: filename, fraction: 0, state: .inProgress, destination: destination)
        items.insert(item, at: 0)
        onChange?()
        return item.id
    }

    func updateProgress(id: UUID, fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].fraction = fraction
        onChange?()
    }

    func markFinished(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .completed
        items[index].fraction = 1
        onChange?()
    }

    func markFailed(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .failed
        onChange?()
    }

    func clear() {
        items.removeAll()
        onChange?()
    }
}
