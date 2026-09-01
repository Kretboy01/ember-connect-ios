//
//  LCTweaksView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LCTweakItem : Hashable {
    let fileUrl: URL
    let isFolder: Bool
    let isFramework: Bool
    let isTweak: Bool
    let isEnabled: Bool

    var displayName: String {
        let name = fileUrl.lastPathComponent
        return isEnabled ? name : String(name.dropLast(LCTweakItem.disabledSuffix.count))
    }

    static let disabledSuffix = ".disabled"
}

struct BundledTweakPreset: Identifiable {
    let id: String
    let name: String
    let resourceName: String
    let dylibName: String
    let folderName: String
    let targetBundleIdentifiers: [String]
    let targetNameKeywords: [String]
    let icon: String
    let description: String
}

struct LCTweakFolderView : View {
    @State var baseUrl : URL
    @State var tweakItems : [LCTweakItem]
    private var isRoot : Bool
    @Binding var tweakFolders : [String]
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    
    @StateObject private var newFolderInput = InputHelper()
    
    @StateObject private var renameFileInput = InputHelper()
    
    @State private var choosingTweak = false
    
    @State private var isTweakSigning = false

    private static let bundledPresets: [BundledTweakPreset] = [
        BundledTweakPreset(
            id: "eightbp-offline-lines",
            name: "8BP Offline Lines",
            resourceName: "EightBPOfflineLines",
            dylibName: "EightBPOfflineLines.dylib",
            folderName: "8BP Offline Lines",
            targetBundleIdentifiers: ["com.miniclip.8ballpoolmult"],
            targetNameKeywords: ["8 ball pool", "8ballpool"],
            icon: "scope",
            description: "Native extended aiming lines for offline/practice games. Strict network-state guard keeps it inactive online."
        ),
        BundledTweakPreset(
            id: "flappy",
            name: "Flappy Practice",
            resourceName: "FlappyPractice",
            dylibName: "FlappyPractice.dylib",
            folderName: "Flappy Practice",
            targetBundleIdentifiers: ["org.brandonplank.flappybird"],
            targetNameKeywords: ["flappy"],
            icon: "speedometer",
            description: "Practice controls for Flappy Bird: speed/gravity/flap power, ghost mode, wide gaps, auto-pilot, and HUD."
        ),
        BundledTweakPreset(
            id: "gettingoverit",
            name: "Getting Over It Tools",
            resourceName: "GettingOverIt",
            dylibName: "EmberGOITools.dylib",
            folderName: "GOI Tools",
            targetBundleIdentifiers: ["net.Foddy.GettingOverIt", "com.BennettFoddy.GettingOverIt", "com.noodlecake.gettingoverit", "com.noodlecake.gettingoveritios"],
            targetNameKeywords: ["getting over it", "gettingoverit", "bennettfoddy"],
            icon: "figure.climbing",
            description: "Practice tools for Getting Over It: Time.timeScale speed control, Physics2D gravity control, ghost mode, and HUD."
        ),
        BundledTweakPreset(
            id: "subnautica",
            name: "Subnautica Tools",
            resourceName: "Subnautica",
            dylibName: "Subnautica.dylib",
            folderName: "Subnautica",
            targetBundleIdentifiers: ["com.UnknownWorlds.Subnautica"],
            targetNameKeywords: ["subnautica"],
            icon: "water.waves",
            description: "Console-backed survival, cheat, vehicle, blueprint, and game-speed controls for Subnautica."
        )
    ]
    
    init(baseUrl: URL, isRoot: Bool = false, tweakFolders: Binding<[String]>) {
        _baseUrl = State(initialValue: baseUrl)
        _tweakFolders = tweakFolders
        self.isRoot = isRoot
        var tmpTweakItems : [LCTweakItem] = []
        let fm = FileManager()
        do {
            let files = try fm.contentsOfDirectory(atPath: baseUrl.path)
            for fileName in files {
                let fileUrl = baseUrl.appendingPathComponent(fileName)
                var isFolder : ObjCBool = false
                fm.fileExists(atPath: fileUrl.path, isDirectory: &isFolder)
                let isEnabled = !fileName.hasSuffix(LCTweakItem.disabledSuffix)
                let baseName = isEnabled ? fileName : String(fileName.dropLast(LCTweakItem.disabledSuffix.count))
                let isFramework = isFolder.boolValue && baseName.hasSuffix(".framework")
                let isTweak = !isFolder.boolValue && baseName.hasSuffix(".dylib")
                tmpTweakItems.append(LCTweakItem(fileUrl: fileUrl, isFolder: isFolder.boolValue, isFramework: isFramework, isTweak: isTweak, isEnabled: isEnabled))
            }
            _tweakItems = State(initialValue: tmpTweakItems)
        } catch {
            NSLog("[LC] failed to load tweaks \(error.localizedDescription)")
            _errorShow = State(initialValue: true)
            _errorInfo = State(initialValue: error.localizedDescription)
            _tweakItems = State(initialValue: [])
        }
    }

    var body: some View {
        List {
            if isRoot {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("How tweaks work", systemImage: "lightbulb.fill")
                            .font(.headline)

                        Text("A tweak is an arm64 .dylib or framework that Ember Connect signs, injects, and loads inside a guest app when it starts.")
                            .font(.subheadline)

                        Text("Enabled only means the file may load. An app-specific folder must also be assigned to the guest app. Loose dylibs and frameworks at this top level are global and load into every guest app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(Self.bundledPresets) { preset in
                        let isInstalled = isPresetInstalled(preset)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(preset.name, systemImage: preset.icon)
                                    .font(.headline)
                                Spacer()
                                Button {
                                    installBundledPreset(preset)
                                } label: {
                                    Text(isInstalled ? "Reinstall" : "Install & Assign")
                                        .font(.subheadline.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(isInstalled ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15))
                                        .foregroundColor(isInstalled ? .orange : .blue)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                            Text(preset.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Bundled Game Tweaks")
                } footer: {
                    Text("Installing a bundled tweak creates its app folder, patches RPATH, and automatically assigns the folder to matching installed guest apps. Relaunch the game after installing.")
                }
            }

            Section {
                ForEach(tweakItems, id:\.self) { tweakItem in
                    HStack {
                        Group {
                            if tweakItem.isFolder && !tweakItem.isFramework {
                                // hidden link so the row navigates without the toggle triggering it
                                ZStack {
                                    NavigationLink {
                                        LCTweakFolderView(baseUrl: tweakItem.fileUrl, isRoot: false, tweakFolders: $tweakFolders)
                                    } label: {
                                        EmptyView()
                                    }
                                    .opacity(0)
                                    HStack {
                                        Label(tweakItem.displayName, systemImage: "folder.fill")
                                        Spacer()
                                        Image(systemName: "chevron.forward")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            } else if tweakItem.isFramework {
                                Label(tweakItem.displayName, systemImage: "shippingbox.fill")
                                Spacer()
                            } else if tweakItem.isTweak {
                                Label(tweakItem.displayName, systemImage: "building.columns.fill")
                                Spacer()
                            } else {
                                Label(tweakItem.displayName, systemImage: "document.fill")
                                Spacer()
                            }
                        }
                        .opacity(tweakItem.isEnabled ? 1 : 0.4)
                        if tweakItem.displayName != "TweakLoader.dylib" {
                            Toggle("", isOn: Binding(
                                get: { tweakItem.isEnabled },
                                set: { setTweakEnabled(tweakItem: tweakItem, enabled: $0) }
                            ))
                            .labelsHidden()
                        }
                    }
                    .contextMenu {
                        Button {
                            Task { await renameTweakItem(tweakItem: tweakItem)}
                        } label: {
                            Label("lc.common.rename".loc, systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            deleteTweakItem(tweakItem: tweakItem)
                        } label: {
                            Label("lc.common.delete".loc, systemImage: "trash")
                        }
                    }

                }.onDelete { indexSet in
                    deleteTweakItem(indexSet: indexSet)
                }
            } footer: {
                if isRoot {
                    Text("lc.tweakView.globalFolderDesc".loc)
                        .foregroundStyle(.gray)
                        .font(.system(size: 12))
                } else {
                    Text("lc.tweakView.appFolderDesc".loc)
                        .foregroundStyle(.gray)
                        .font(.system(size: 12))
                }
            }
        }
        .navigationTitle(isRoot ? "lc.tabView.tweaks".loc : baseUrl.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !isTweakSigning && LCSharedUtils.certificatePassword() != nil {
                    Button {
                        Task { await signAllTweaks() }
                    } label: {
                        Label("sign".loc, systemImage: "signature")
                    }
                }

            }
            ToolbarItem(placement: .topBarTrailing) {
                if !isTweakSigning {
                    Menu {
                        Button {
                            if choosingTweak {
                                choosingTweak = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                                    choosingTweak = true
                                })
                            } else {
                                choosingTweak = true
                            }
                        } label: {
                            Label("lc.tweakView.importTweak".loc, systemImage: "square.and.arrow.down")
                        }
                        
                        Button {
                            Task { await createNewFolder() }
                        } label: {
                            Label("lc.tweakView.newFolder".loc, systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Label("add", systemImage: "plus")
                    }
                } else {
                    ProgressView().progressViewStyle(.circular)
                }

            }
        }
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, action: {
            })
        } message: {
            Text(errorInfo)
        }
        .textFieldAlert(
            isPresented: $newFolderInput.show,
            title: "lc.common.enterNewFolderName".loc,
            text: $newFolderInput.initVal,
            placeholder: "",
            action: { newText in
                newFolderInput.close(result: newText)
            },
            actionCancel: {_ in
                newFolderInput.close(result: "")
            }
        )
        .textFieldAlert(
            isPresented: $renameFileInput.show,
            title: "lc.common.enterNewName".loc,
            text: $renameFileInput.initVal,
            placeholder: "",
            action: { newText in
                renameFileInput.close(result: newText)
            },
            actionCancel: {_ in
                renameFileInput.close(result: "")
            }
        )
        .betterFileImporter(isPresented: $choosingTweak, types: [.dylib, .lcFramework, /*.deb*/], multiple: true, callback: { fileUrls in
            Task { await startInstallTweak(fileUrls) }
        }, onDismiss: {
            choosingTweak = false
        })
    }

    private func isPresetInstalled(_ preset: BundledTweakPreset) -> Bool {
        tweakItems.contains { $0.isFolder && $0.displayName == preset.folderName }
    }

    func installBundledPreset(_ preset: BundledTweakPreset) {
        guard let source = Bundle.main.url(forResource: preset.resourceName,
                                           withExtension: "dylib",
                                           subdirectory: "EmberTweaks") else {
            errorShow = true
            errorInfo = "The bundled \(preset.name) tweak is missing from EmberTweaks. Rebuild Ember Connect Mobile and try again."
            return
        }

        let fm = FileManager.default
        let folder = baseUrl.appendingPathComponent(preset.folderName)
        let disabledFolder = baseUrl.appendingPathComponent(preset.folderName + LCTweakItem.disabledSuffix)
        let destination = folder.appendingPathComponent(preset.dylibName)

        do {
            if !fm.fileExists(atPath: folder.path), fm.fileExists(atPath: disabledFolder.path) {
                try fm.moveItem(at: disabledFolder, to: folder)
            }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            LCParseMachO((destination.path as NSString).utf8String, false) { path, header, _, _ in
                LCPatchAddRPath(path, header)
            }
            let globalDestination = baseUrl.appendingPathComponent(preset.dylibName)
            if fm.fileExists(atPath: globalDestination.path) {
                try? fm.removeItem(at: globalDestination)
            }

            if let existing = tweakItems.firstIndex(where: {
                $0.isFolder && $0.displayName == preset.folderName
            }) {
                tweakItems[existing] = LCTweakItem(fileUrl: folder,
                                                    isFolder: true,
                                                    isFramework: false,
                                                    isTweak: false,
                                                    isEnabled: true)
            } else {
                tweakItems.append(LCTweakItem(fileUrl: folder,
                                              isFolder: true,
                                              isFramework: false,
                                              isTweak: false,
                                              isEnabled: true))
            }
            if !tweakFolders.contains(preset.folderName) {
                tweakFolders.append(preset.folderName)
            }
            
            // Assign to any matching installed guest app
            let matchingApps = DataManager.shared.model.apps.filter { app in
                let bundleId = app.bundleIdentifier.lowercased()
                let appName = app.displayName.lowercased()
                let targetIds = preset.targetBundleIdentifiers.map { $0.lowercased() }
                if targetIds.contains(bundleId) { return true }
                for keyword in preset.targetNameKeywords {
                    if bundleId.contains(keyword) || appName.contains(keyword) { return true }
                }
                return false
            }
            for matchingApp in matchingApps {
                matchingApp.uiTweakFolder = preset.folderName
            }
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
        }
    }
    
    func setTweakEnabled(tweakItem: LCTweakItem, enabled: Bool) {
        if tweakItem.isEnabled == enabled {
            return
        }
        let displayName = tweakItem.displayName
        let newName = enabled ? displayName : displayName + LCTweakItem.disabledSuffix
        let newUrl = baseUrl.appendingPathComponent(newName)
        let fm = FileManager()
        do {
            try fm.moveItem(at: tweakItem.fileUrl, to: newUrl)
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        guard let index = tweakItems.firstIndex(of: tweakItem) else {
            return
        }
        tweakItems[index] = LCTweakItem(fileUrl: newUrl, isFolder: tweakItem.isFolder, isFramework: tweakItem.isFramework, isTweak: tweakItem.isTweak, isEnabled: enabled)
    }

    func deleteTweakItem(indexSet: IndexSet) {
        var indexToRemove : [Int] = []
        let fm = FileManager()
        do {
            for i in indexSet {
                let tweakItem = tweakItems[i]
                try fm.removeItem(at: tweakItem.fileUrl)
                indexToRemove.append(i)
            }
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        if isRoot {
            for iToRemove in indexToRemove {
                tweakFolders.removeAll(where: { s in
                    return s == tweakItems[iToRemove].displayName
                })
            }
        }

        tweakItems.remove(atOffsets: IndexSet(indexToRemove))
    }

    func deleteTweakItem(tweakItem: LCTweakItem) {
        var indexToRemove : Int?
        let fm = FileManager()
        do {

            try fm.removeItem(at: tweakItem.fileUrl)
            indexToRemove = tweakItems.firstIndex(where: { s in
                return s == tweakItem
            })
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }

        guard let indexToRemove = indexToRemove else {
            return
        }
        tweakItems.remove(at: indexToRemove)
        if isRoot {
            tweakFolders.removeAll(where: { s in
                return s == tweakItem.displayName
            })
        }
    }
    
    func renameTweakItem(tweakItem: LCTweakItem) async {
        guard let newName = await renameFileInput.open(initVal: tweakItem.displayName), newName != "" else {
            return
        }

        let indexToRename = tweakItems.firstIndex(where: { s in
            return s == tweakItem
        })
        guard let indexToRename = indexToRename else {
            return
        }
        let newFileName = tweakItem.isEnabled ? newName : newName + LCTweakItem.disabledSuffix
        let newUrl = self.baseUrl.appendingPathComponent(newFileName)

        let fm = FileManager()
        do {
            try fm.moveItem(at: tweakItem.fileUrl, to: newUrl)
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        tweakItems.remove(at: indexToRename)
        let newTweakItem = LCTweakItem(fileUrl: newUrl, isFolder: tweakItem.isFolder, isFramework: tweakItem.isFramework, isTweak: tweakItem.isTweak, isEnabled: tweakItem.isEnabled)
        tweakItems.insert(newTweakItem, at: indexToRename)

        if isRoot {
            let indexToRename2 = tweakFolders.firstIndex(of: tweakItem.displayName)
            guard let indexToRename2 = indexToRename2 else {
                return
            }
            tweakFolders.remove(at: indexToRename2)
            tweakFolders.insert(newName, at: indexToRename2)

        }
    }
    
    func signAllTweaks() async {
        do {
            defer {
                isTweakSigning = false
            }
            
            try await LCUtils.signTweaks(tweakFolderUrl: self.baseUrl, force: true) { p in
                isTweakSigning = true
            }

        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func createNewFolder() async {
        guard let newName = await renameFileInput.open(), newName != "" else {
            return
        }
        let fm = FileManager()
        let dest = baseUrl.appendingPathComponent(newName)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        tweakItems.append(LCTweakItem(fileUrl: dest, isFolder: true, isFramework: false, isTweak: false, isEnabled: true))
        if isRoot {
            tweakFolders.append(newName)
        }
    }
    
    func startInstallTweak(_ urls: [URL]) async {
        do {
            let fm = FileManager()
            // we will sign later before app launch
            
            for fileUrl in urls {
                // handle deb file
                if(!fileUrl.isFileURL) {
                    throw "lc.tweakView.notFileError %@".localizeWithFormat(fileUrl.lastPathComponent)
                }
                let toPath = self.baseUrl.appendingPathComponent(fileUrl.lastPathComponent)
                try fm.moveItem(at: fileUrl, to: toPath)
                LCParseMachO((toPath.path as NSString).utf8String, false) { path, header, _, _ in
                    LCPatchAddRPath(path, header);
                }

                let isFramework = toPath.lastPathComponent.hasSuffix(".framework")
                let isTweak = toPath.lastPathComponent.hasSuffix(".dylib")
                self.tweakItems.append(LCTweakItem(fileUrl: toPath, isFolder: false, isFramework: isFramework, isTweak: isTweak, isEnabled: true))
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true            
            return
        }
    }
}

struct LCTweaksView: View {
    @Binding var tweakFolders : [String]
    
    var body: some View {
        NavigationView {
            LCTweakFolderView(baseUrl: LCPath.tweakPath, isRoot: true, tweakFolders: $tweakFolders)
        }
        .navigationViewStyle(StackNavigationViewStyle())

    }
}
