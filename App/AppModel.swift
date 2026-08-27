import Foundation
import Combine

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
        
        if !fileManager.fileExists(atPath: appsDir.path) {
            try? fileManager.createDirectory(at: appsDir, withIntermediateDirectories: true)
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
