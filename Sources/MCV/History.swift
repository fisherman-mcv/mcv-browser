import Foundation

struct HistoryEntry: Codable {
    let title: String
    let url: String
    let visitedAt: Date
}

/// Глобальна історія переглядів (усі вкладки, усі сесії) — ~/.mcv/history.json.
/// Живить і команду `hist`, і автодоповнення в адресному рядку.
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var entries: [HistoryEntry] = []
    private let maxEntries = 4000
    private let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mcv/history.json")

    private init() { load() }

    func record(title: String, url: String) {
        guard !url.isEmpty, !url.hasPrefix("about:"), !url.hasPrefix("data:") else { return }
        entries.removeAll { $0.url == url } // найсвіжіший візит спливає нагору, дублів нема
        entries.insert(HistoryEntry(title: title, url: url, visitedAt: Date()), at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// Топ-N збігів за підрядком у заголовку або URL, найновіші першими.
    func matching(_ query: String, limit: Int) -> [HistoryEntry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var result: [HistoryEntry] = []
        for entry in entries {
            if entry.title.lowercased().contains(q) || entry.url.lowercased().contains(q) {
                result.append(entry)
                if result.count >= limit { break }
            }
        }
        return result
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL)
        }
    }
}
