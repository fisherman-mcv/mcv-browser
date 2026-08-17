import AppKit
import Sparkle

/// Sparkle is deliberately dormant in developer builds until both immutable
/// release values are injected into Info.plist. Update verification is never
/// downgraded to a checksum or an unsigned GitHub download.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let updaterController: SPUStandardUpdaterController
    let isConfigured: Bool

    private init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = feed.hasPrefix("https://") && !feed.contains("MCV_UPDATE_")
            && !key.isEmpty && !key.contains("MCV_UPDATE_")
        updaterController = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = "Updates are not configured in this build"
            alert.informativeText = "Build MCV with a signed Sparkle feed URL and EdDSA public key. Developer builds never install unsigned updates."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        updaterController.checkForUpdates(nil)
    }
}
