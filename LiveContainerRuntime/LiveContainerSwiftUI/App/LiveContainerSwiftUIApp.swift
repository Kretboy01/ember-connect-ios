//
//  LiveContainerSwiftUIApp.swift
//  LiveContainer
//
//  Created by s s on 2025/5/16.
//
import SwiftUI

@main
struct LiveContainerSwiftUIApp : SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @State var appDataFolderNames: [String]
    @State var tweakFolderNames: [String]
    
    init() {
        let fm = FileManager()
        var tempAppDataFolderNames : [String] = []
        var tempTweakFolderNames : [String] = []
        
        var tempApps: [LCAppModel] = []
        var tempHiddenApps: [LCAppModel] = []
        var tempURLSchemes: Set<String>? = DataManager.shared.model.multiLCStatus != 2 ? Set() : nil

        do {
            // load apps
            try fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
            let appDirs = try fm.contentsOfDirectory(atPath: LCPath.bundlePath.path)
            for appDir in appDirs {
                if !appDir.hasSuffix(".app") {
                    continue
                }
                let newApp = LCAppInfo(bundlePath: "\(LCPath.bundlePath.path)/\(appDir)")!
                newApp.relativeBundlePath = appDir
                newApp.isShared = false
                if newApp.isHidden {
                    tempHiddenApps.append(LCAppModel(appInfo: newApp))
                } else {
                    tempApps.append(LCAppModel(appInfo: newApp))
                    tempURLSchemes?.formUnion(newApp.urlSchemes() as! [String])
                }
            }
            if LCPath.lcGroupDocPath != LCPath.docPath {
                try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
                let appDirsShared = try fm.contentsOfDirectory(atPath: LCPath.lcGroupBundlePath.path)
                for appDir in appDirsShared {
                    if !appDir.hasSuffix(".app") {
                        continue
                    }
                    let newApp = LCAppInfo(bundlePath: "\(LCPath.lcGroupBundlePath.path)/\(appDir)")!
                    newApp.relativeBundlePath = appDir
                    newApp.isShared = true
                    if newApp.isHidden {
                        tempHiddenApps.append(LCAppModel(appInfo: newApp))
                    } else {
                        tempApps.append(LCAppModel(appInfo: newApp))
                        tempURLSchemes?.formUnion(newApp.urlSchemes() as! [String])
                    }
                }
            }
            // load document folders
            try fm.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)
            let dataDirs = try fm.contentsOfDirectory(atPath: LCPath.dataPath.path)
            for dataDir in dataDirs {
                let dataDirUrl = LCPath.dataPath.appendingPathComponent(dataDir)
                if !dataDirUrl.hasDirectoryPath {
                    continue
                }
                tempAppDataFolderNames.append(dataDir)
            }
            
            // load tweak folders
            try fm.createDirectory(at: LCPath.tweakPath, withIntermediateDirectories: true)
            
            // Auto-deploy bundled game tweaks to the exact folders and filenames
            // assigned to their guests. The resource name inside EmberTweaks can
            // differ from the on-disk filename (GOI uses a private folder/name so
            // older builds cannot overwrite it accidentally).
            let bundledTweaks: [(resource: String, folder: String, destination: String, bundleIds: [String], keywords: [String])] = [
                ("FlappyPractice", "Flappy Practice", "FlappyPractice.dylib", ["org.brandonplank.flappybird"], ["flappy"]),
                ("GettingOverIt", "GOI Tools", "EmberGOITools.dylib", ["net.foddy.gettingoverit", "com.bennettfoddy.gettingoverit", "com.noodlecake.gettingoverit", "com.noodlecake.gettingoveritios"], ["getting over it", "gettingoverit", "bennettfoddy"]),
                ("Subnautica", "Subnautica", "Subnautica.dylib", ["com.unknownworlds.subnautica"], ["subnautica"])
            ]
            for tweak in bundledTweaks {
                // Remove loose root dylib if it exists from older installs to prevent double injection
                let globalDest = LCPath.tweakPath.appendingPathComponent("\(tweak.resource).dylib")
                if fm.fileExists(atPath: globalDest.path) {
                    try? fm.removeItem(at: globalDest)
                }
                
                if let source = Bundle.main.url(forResource: tweak.resource, withExtension: "dylib", subdirectory: "EmberTweaks") {
                    let folderUrl = LCPath.tweakPath.appendingPathComponent(tweak.folder)
                    try? fm.createDirectory(at: folderUrl, withIntermediateDirectories: true)
                    let destUrl = folderUrl.appendingPathComponent(tweak.destination)

                    // Replace when contents differ. mtime comparison was
                    // unreliable — zip extraction shuffles timestamps enough
                    // that a genuinely newer dylib inside the bundle can end
                    // up looking older than the file already on disk. Comparing
                    // the raw bytes is cheap for a 150 KB dylib and definitive.
                    let bundledData  = (try? Data(contentsOf: source))
                    let existingData = (try? Data(contentsOf: destUrl))
                    let shouldReplace = !fm.fileExists(atPath: destUrl.path)
                        || bundledData == nil
                        || bundledData != existingData
                    if shouldReplace {
                        try? fm.removeItem(at: destUrl)
                        try? fm.copyItem(at: source, to: destUrl)
                        LCParseMachO((destUrl.path as NSString).utf8String, false) { path, header, _, _ in
                            LCPatchAddRPath(path, header)
                        }
                    }
                    for app in tempApps {
                        let bId = app.bundleIdentifier.lowercased()
                        let dName = app.displayName.lowercased()
                        if tweak.bundleIds.contains(bId) || tweak.keywords.contains(where: { bId.contains($0) || dName.contains($0) }) {
                            if app.appInfo.tweakFolder == nil || app.appInfo.tweakFolder?.isEmpty == true {
                                app.appInfo.tweakFolder = tweak.folder
                            }
                        }
                    }
                }
            }
            
            let tweakDirs = try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path)
            for tweakDir in tweakDirs {
                let tweakDirUrl = LCPath.tweakPath.appendingPathComponent(tweakDir)
                if !tweakDirUrl.hasDirectoryPath {
                    continue
                }
                let folderName = tweakDir.hasSuffix(".disabled") ? String(tweakDir.dropLast(".disabled".count)) : tweakDir
                tempTweakFolderNames.append(folderName)
            }
        } catch {
            NSLog("[LC] error:\(error)")
        }
        
        DataManager.shared.model.apps = tempApps
        DataManager.shared.model.hiddenApps = tempHiddenApps
        if let tempURLSchemes {
            UserDefaults.lcShared().set(Array(tempURLSchemes), forKey: "LCGuestURLSchemes")
        }
        
        _appDataFolderNames = State(initialValue: tempAppDataFolderNames)
        _tweakFolderNames = State(initialValue: tempTweakFolderNames)
    }
    
    var body: some Scene {
        WindowGroup(id: "Main") {
            LCTabView(appDataFolderNames: $appDataFolderNames, tweakFolderNames: $tweakFolderNames)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environmentObject(DataManager.shared.model)
                .environmentObject(LCAppSortManager.shared)
        }
        
        if UIApplication.shared.supportsMultipleScenes, #available(iOS 16.1, *) {
            WindowGroup(id: "appView", for: String.self) { $id in
                if let id {
                    MultitaskAppWindow(id: id)
                }
            }

        }
    }
    
}
