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

class AppModel: ObservableObject {
    @Published var apps: [GuestApp] = []
    
    func loadApps() {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        let appsDir = documentsURL.appendingPathComponent("Apps")
        let autoInstallDir = documentsURL.appendingPathComponent("AutoInstall")
        
        if !fileManager.fileExists(atPath: appsDir.path) {
            try? fileManager.createDirectory(at: appsDir, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: autoInstallDir.path) {
            try? fileManager.createDirectory(at: autoInstallDir, withIntermediateDirectories: true)
        }
        
        // Auto-install IPAs
        if let autoIPAs = try? fileManager.contentsOfDirectory(at: autoInstallDir, includingPropertiesForKeys: nil) {
            for ipaURL in autoIPAs where ipaURL.pathExtension == "ipa" {
                print("Auto-installing: \(ipaURL.lastPathComponent)")
                let tempExtract = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try fileManager.unzipItem(at: ipaURL, to: tempExtract)
                    let payloadDir = tempExtract.appendingPathComponent("Payload")
                    if let appsInPayload = try? fileManager.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil) {
                        for app in appsInPayload where app.pathExtension == "app" {
                            let dest = appsDir.appendingPathComponent(app.lastPathComponent)
                            if fileManager.fileExists(atPath: dest.path) {
                                try fileManager.removeItem(at: dest)
                            }
                            try fileManager.moveItem(at: app, to: dest)
                            print("Successfully installed \(app.lastPathComponent)")
                        }
                    }
                    try fileManager.removeItem(at: ipaURL) // delete IPA after install
                    try fileManager.removeItem(at: tempExtract) // clean up temp
                } catch {
                    print("Failed to unzip \(ipaURL.lastPathComponent): \(error)")
                }
            }
        }
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil)
            var loadedApps: [GuestApp] = []
            
            for item in contents {
                if item.pathExtension == "app" {
                    let infoPlistPath = item.appendingPathComponent("Info.plist")
                    if let dict = NSDictionary(contentsOf: infoPlistPath) {
                        let name = dict["CFBundleDisplayName"] as? String ?? dict["CFBundleName"] as? String ?? item.lastPathComponent
                        let bundleId = dict["CFBundleIdentifier"] as? String ?? "unknown"
                        let version = dict["CFBundleShortVersionString"] as? String ?? "1.0"
                        
                        loadedApps.append(GuestApp(name: name, bundleId: bundleId, path: item.path, version: version))
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.apps = loadedApps
            }
            
        } catch {
            print("Failed to load apps: \(error)")
        }
    }
}
