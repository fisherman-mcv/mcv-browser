import Foundation

enum CompatibilityLevel: String, Codable { case pass = "PASS", partial = "PARTIAL", unsupported = "UNSUPPORTED" }

struct ExtensionCompatibilityReport {
    let overall: CompatibilityLevel
    let features: [String: CompatibilityLevel]
    let notes: [String]
}

enum ExtensionCompatibility {
    static let nativeAPIs: Set<String> = [
        "storage", "tabs", "windows", "runtime", "scripting", "activeTab", "commands",
        "contextMenus", "bookmarks", "history", "downloads", "notifications", "permissions", "webNavigation"
    ]
    static let partialAPIs: Set<String> = ["webRequest", "declarativeNetRequest", "background", "service_worker"]
    static let unavailableAPIs: Set<String> = [
        "debugger", "devtools", "management", "nativeMessaging", "proxy", "sidePanel",
        "tabCapture", "desktopCapture", "offscreen", "identity", "enterprise", "vpnProvider"
    ]

    static func analyze(_ manifest: ExtensionManifest) -> ExtensionCompatibilityReport {
        var features: [String: CompatibilityLevel] = [:]
        var notes: [String] = []
        for permission in manifest.requestedPermissions where !permission.contains("://") && permission != "<all_urls>" {
            if nativeAPIs.contains(permission) { features[permission] = .pass }
            else if partialAPIs.contains(permission) { features[permission] = .partial }
            else if unavailableAPIs.contains(permission) { features[permission] = .unsupported }
            else { features[permission] = .partial; notes.append("Unknown permission: \(permission)") }
        }
        if manifest.background?.service_worker != nil {
            features["MV3 service worker"] = .partial
            notes.append("Runs as an isolated persistent WebKit event page; worker suspension semantics differ from Chrome.")
        }
        if manifest.content_scripts?.isEmpty == false { features["content scripts"] = .pass }
        if manifest.popupPath != nil { features["popup"] = .pass }
        if manifest.optionsPath != nil { features["options"] = .pass }
        if manifest.declarative_net_request != nil { features["declarativeNetRequest"] = .partial }
        let overall: CompatibilityLevel = features.values.contains(.unsupported) ? .unsupported
            : (features.values.contains(.partial) ? .partial : .pass)
        return .init(overall: overall, features: features, notes: notes)
    }
}
