import Foundation
import CryptoKit

enum ExtensionInstallError: LocalizedError {
    case unsupportedPackage, malformedCRX, missingManifest, invalidManifest, unsafeArchive, unsupportedManifest(Int)
    var errorDescription: String? {
        switch self {
        case .unsupportedPackage: return "Supported formats: .crx, .zip, or an unpacked folder"
        case .malformedCRX: return "The CRX is damaged or unsupported"
        case .missingManifest: return "manifest.json was not found"
        case .invalidManifest: return "Invalid manifest.json"
        case .unsafeArchive: return "The archive contains unsafe paths"
        case .unsupportedManifest(let v): return "Manifest V\(v) is not supported"
        }
    }
}

final class ExtensionPackageLoader {
    private let fm = FileManager.default
    private let decoder = JSONDecoder()

    func install(from source: URL, into library: URL) throws -> (InstalledExtension, ExtensionManifest) {
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let staging = library.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw ExtensionInstallError.unsupportedPackage }
        if isDirectory.boolValue {
            try copyDirectoryContents(from: source, to: staging)
        } else if source.pathExtension.lowercased() == "zip" {
            try extractZip(source, to: staging)
        } else if source.pathExtension.lowercased() == "crx" {
            let zip = try extractCRXPayload(source)
            let temporaryZip = staging.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).zip")
            try zip.write(to: temporaryZip, options: .atomic)
            defer { try? fm.removeItem(at: temporaryZip) }
            try extractZip(temporaryZip, to: staging)
        } else { throw ExtensionInstallError.unsupportedPackage }

        try validateExtractedTree(staging)
        let root = try locateManifestRoot(in: staging)
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        guard let manifest = try? decoder.decode(ExtensionManifest.self, from: manifestData) else { throw ExtensionInstallError.invalidManifest }
        guard manifest.manifest_version == 2 || manifest.manifest_version == 3 else {
            throw ExtensionInstallError.unsupportedManifest(manifest.manifest_version)
        }
        let digest = SHA256.hash(data: manifestData)
        let id = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let destination = library.appendingPathComponent(id, isDirectory: true)
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try copyDirectoryContents(from: root, to: destination)
        let installed = InstalledExtension(
            id: id, rootPath: destination.path, enabled: true,
            grantedPermissions: manifest.requestedPermissions, installedAt: Date(),
            manifest: .init(manifestVersion: manifest.manifest_version, name: manifest.name,
                            version: manifest.version, requestedPermissions: manifest.requestedPermissions))
        return (installed, manifest)
    }

    func loadManifest(for extensionItem: InstalledExtension) throws -> ExtensionManifest {
        let data = try Data(contentsOf: extensionItem.rootURL.appendingPathComponent("manifest.json"))
        return try decoder.decode(ExtensionManifest.self, from: data)
    }

    private func locateManifestRoot(in staging: URL) throws -> URL {
        if fm.fileExists(atPath: staging.appendingPathComponent("manifest.json").path) { return staging }
        let children = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        if children.count == 1, fm.fileExists(atPath: children[0].appendingPathComponent("manifest.json").path) { return children[0] }
        throw ExtensionInstallError.missingManifest
    }

    private func extractZip(_ zip: URL, to destination: URL) throws {
        let listing = try ProcessRunner.run("/usr/bin/unzip", ["-Z1", zip.path])
        for line in listing.split(separator: "\n") {
            let path = String(line)
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") { throw ExtensionInstallError.unsafeArchive }
        }
        _ = try ProcessRunner.run("/usr/bin/unzip", ["-qq", zip.path, "-d", destination.path])
    }

    private func extractCRXPayload(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count > 12, String(data: data.prefix(4), encoding: .ascii) == "Cr24" else { throw ExtensionInstallError.malformedCRX }
        let version = data.readUInt32LE(at: 4)
        let offset: Int
        if version == 2 {
            guard data.count >= 16 else { throw ExtensionInstallError.malformedCRX }
            offset = 16 + Int(data.readUInt32LE(at: 8)) + Int(data.readUInt32LE(at: 12))
        } else if version == 3 {
            offset = 12 + Int(data.readUInt32LE(at: 8))
        } else { throw ExtensionInstallError.malformedCRX }
        guard offset < data.count, data[offset] == 0x50, data[offset + 1] == 0x4b else { throw ExtensionInstallError.malformedCRX }
        return data.subdata(in: offset..<data.count)
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            try fm.copyItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
        }
    }

    private func validateExtractedTree(_ root: URL) throws {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ExtensionInstallError.unsafeArchive
            }
        }
    }
}

private enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { throw ExtensionInstallError.unsupportedPackage }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
