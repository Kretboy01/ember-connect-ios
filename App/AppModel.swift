import Foundation
import Combine
import ZIPFoundation

struct GuestApp: Identifiable {
    let id = UUID()
    let name: String
    let bundleId: String
    let path: String
    let version: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var apps: [GuestApp] = []
    @Published private(set) var isLoading = false
    /// Surfaced in the UI. Previously every failure here went to `print`,
    /// where nobody would ever see it.
    @Published var lastError: String?

    private var hasLoadedOnce = false

    /// Where the desktop drops IPAs for pickup, relative to the app's
    /// Documents folder (which is what `install_to_container_operation`
    /// writes into over AFC).
    private static let autoInstallDirName = "AutoInstall"
    private static let appsDirName = "Apps"

    func loadIfNeeded() {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        Task { await load() }
    }

    func reload() {
        Task { await load() }
    }

    /// Scans for guest apps, installing anything the desktop has dropped into
    /// `AutoInstall/` first.
    ///
    /// All of this is file I/O and zip extraction. It used to run inline on
    /// the main thread from `onAppear`, so unpacking a large IPA froze the UI
    /// for the duration.
    func load() async {
        isLoading = true
        lastError = nil

        let result = await Task.detached(priority: .userInitiated) { () -> Result<[GuestApp], Error> in
            do {
                return .success(try Self.scanDisk())
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let loaded):
            apps = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .failure(let error):
            lastError = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Disk work (runs off the main actor)

    private nonisolated static func scanDisk() throws -> [GuestApp] {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw MirrorError.noDocumentsDirectory
        }

        let appsDir = documentsURL.appendingPathComponent(appsDirName)
        let autoInstallDir = documentsURL.appendingPathComponent(autoInstallDirName)

        for dir in [appsDir, autoInstallDir] where !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        install(from: autoInstallDir, into: appsDir, fileManager: fileManager)

        let contents = try fileManager.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil)
        return contents.compactMap { item -> GuestApp? in
            guard item.pathExtension == "app" else { return nil }
            let infoPlistPath = item.appendingPathComponent("Info.plist")
            guard let dict = NSDictionary(contentsOf: infoPlistPath) else { return nil }
            let name = dict["CFBundleDisplayName"] as? String
                ?? dict["CFBundleName"] as? String
                ?? item.deletingPathExtension().lastPathComponent
            return GuestApp(
                name: name,
                bundleId: dict["CFBundleIdentifier"] as? String ?? "unknown",
                path: item.path,
                version: dict["CFBundleShortVersionString"] as? String ?? "1.0"
            )
        }
    }

    /// Unpacks every IPA in `source` into `destination`.
    ///
    /// A failure on one IPA must not abort the rest of the scan, so each is
    /// handled independently and a broken archive is left in place rather than
    /// deleted — otherwise the evidence disappears and the app simply appears
    /// to ignore it.
    private nonisolated static func install(from source: URL, into destination: URL, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            return
        }

        for ipaURL in entries where ipaURL.pathExtension.lowercased() == "ipa" {
            let scratch = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fileManager.removeItem(at: scratch) }

            do {
                try fileManager.unzipItem(at: ipaURL, to: scratch)
                let payloadDir = scratch.appendingPathComponent("Payload")
                let payload = try fileManager.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil)

                var installedAny = false
                for app in payload where app.pathExtension == "app" {
                    let target = destination.appendingPathComponent(app.lastPathComponent)
                    if fileManager.fileExists(atPath: target.path) {
                        try fileManager.removeItem(at: target)
                    }
                    try fileManager.moveItem(at: app, to: target)
                    installedAny = true
                }

                // Only consume the IPA once something was actually extracted.
                if installedAny {
                    try? fileManager.removeItem(at: ipaURL)
                }
            } catch {
                NSLog("[EmberConnect] could not install \(ipaURL.lastPathComponent): \(error)")
            }
        }
    }
}

enum MirrorError: LocalizedError {
    case noDocumentsDirectory

    var errorDescription: String? {
        switch self {
        case .noDocumentsDirectory:
            return "This app has no Documents directory, so it cannot store apps."
        }
    }
}
