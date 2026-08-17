import Foundation

struct ExtensionManifest: Decodable, Sendable {
    struct Action: Decodable, Sendable { let default_popup: String?; let default_title: String? }
    struct Background: Decodable, Sendable {
        let scripts: [String]?
        let page: String?
        let service_worker: String?
        let type: String?
    }
    struct ContentScript: Decodable, Sendable {
        let matches: [String]
        let exclude_matches: [String]?
        let js: [String]?
        let css: [String]?
        let run_at: String?
        let all_frames: Bool?
        let match_about_blank: Bool?
        let world: String?
    }
    struct Command: Decodable, Sendable {
        struct SuggestedKey: Decodable, Sendable { let `default`: String?; let mac: String? }
        let suggested_key: SuggestedKey?
        let description: String?
    }

    let manifest_version: Int
    let name: String
    let version: String
    let description: String?
    let permissions: [String]?
    let optional_permissions: [String]?
    let host_permissions: [String]?
    let optional_host_permissions: [String]?
    let content_scripts: [ContentScript]?
    let background: Background?
    let action: Action?
    let browser_action: Action?
    let page_action: Action?
    let options_page: String?
    let options_ui: OptionsUI?
    let commands: [String: Command]?
    let web_accessible_resources: JSONValue?
    let content_security_policy: JSONValue?
    let declarative_net_request: DeclarativeNetRequest?

    struct OptionsUI: Decodable, Sendable { let page: String; let open_in_tab: Bool? }
    struct DeclarativeNetRequest: Decodable, Sendable {
        struct RuleResource: Decodable, Sendable { let id: String; let enabled: Bool; let path: String }
        let rule_resources: [RuleResource]
    }

    var requestedPermissions: Set<String> {
        Set((permissions ?? []) + (host_permissions ?? []) + (content_scripts ?? []).flatMap(\.matches)).filter { !$0.isEmpty }
    }
    var popupPath: String? { action?.default_popup ?? browser_action?.default_popup ?? page_action?.default_popup }
    var optionsPath: String? { options_ui?.page ?? options_page }
}

enum JSONValue: Decodable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
}

struct InstalledExtension: Codable, Identifiable, Sendable {
    let id: String
    var rootPath: String
    var enabled: Bool
    var grantedPermissions: Set<String>
    var installedAt: Date
    var manifest: ExtensionManifestSnapshot

    var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }
}

struct ExtensionManifestSnapshot: Codable, Sendable {
    let manifestVersion: Int
    let name: String
    let version: String
    let requestedPermissions: Set<String>
}

enum ExtensionMatchPattern {
    static func matches(_ pattern: String, url: URL) -> Bool {
        if pattern == "<all_urls>" { return ["http", "https", "file", "ftp"].contains(url.scheme ?? "") }
        guard let split = pattern.range(of: "://") else { return false }
        let scheme = String(pattern[..<split.lowerBound])
        let rest = String(pattern[split.upperBound...])
        guard let slash = rest.firstIndex(of: "/") else { return false }
        let hostPattern = String(rest[..<slash])
        let pathPattern = String(rest[slash...])
        if scheme != "*", scheme != url.scheme { return false }
        let host = url.host ?? ""
        if hostPattern != "*" {
            if hostPattern.hasPrefix("*.") {
                let suffix = String(hostPattern.dropFirst(2))
                if host != suffix && !host.hasSuffix("." + suffix) { return false }
            } else if host != hostPattern { return false }
        }
        return wildcard(pathPattern, matches: url.path.isEmpty ? "/" : url.path)
    }

    private static func wildcard(_ pattern: String, matches value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        return value.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}
