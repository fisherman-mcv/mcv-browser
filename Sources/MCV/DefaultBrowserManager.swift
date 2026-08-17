import AppKit

enum DefaultBrowserManager {
    static var isDefault: Bool {
        guard let probe = URL(string: "https://mcv.local/"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func makeDefault(completion: @escaping (Error?) -> Void) {
        let workspace = NSWorkspace.shared
        let appURL = Bundle.main.bundleURL
        let group = DispatchGroup()
        let lock = NSLock()
        var firstError: Error?

        for scheme in ["http", "https"] {
            group.enter()
            workspace.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { error in
                if let error {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(firstError) }
    }
}
