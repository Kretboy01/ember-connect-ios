import ReplayKit
import SwiftUI
import UIKit

/// Ember Connect's screen-mirroring controls. The actual capture and H.264
/// transport live in the embedded EmberConnectBroadcast ReplayKit extension.
struct EmberMirrorView: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 52))
                        .foregroundStyle(.orange)

                    Text("Mirror this iPhone")
                        .font(.title2.bold())

                    Text("Keep Ember Connect Desktop open, then start the broadcast here. The desktop connects over USB or your local network and displays the phone at full frame rate.")
                        .foregroundStyle(.secondary)

                    EmberBroadcastButton()

                    Text("The broadcast continues while you open and use guest apps inside Ember Connect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Screen Mirror")
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private final class EmberBroadcastPickerController: ObservableObject {
    @Published private(set) var extensionBundleIdentifier: String?
    fileprivate weak var pickerView: RPSystemBroadcastPickerView?

    init() {
        extensionBundleIdentifier = Self.findBroadcastExtension()
    }

    private static func findBroadcastExtension() -> String? {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: pluginsURL,
                includingPropertiesForKeys: nil
              ) else {
            return nil
        }

        for url in entries where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let extensionInfo = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload",
                  let identifier = bundle.bundleIdentifier else {
                continue
            }
            return identifier
        }
        return nil
    }

    private func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }

    func present() -> Bool {
        guard let pickerView, let button = findButton(in: pickerView) else { return false }
        button.sendActions(for: .touchUpInside)
        return true
    }
}

private struct EmberBroadcastPickerHost: UIViewRepresentable {
    let controller: EmberBroadcastPickerController

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = controller.extensionBundleIdentifier
        picker.showsMicrophoneButton = false
        controller.pickerView = picker
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        picker.preferredExtension = controller.extensionBundleIdentifier
        controller.pickerView = picker
    }
}

private struct EmberBroadcastButton: View {
    @StateObject private var controller = EmberBroadcastPickerController()
    @State private var showError = false

    private var isAvailable: Bool {
        controller.extensionBundleIdentifier != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if !controller.present() { showError = true }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isAvailable ? "record.circle" : "exclamationmark.triangle.fill")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isAvailable ? "Start Mirroring" : "Mirroring Unavailable")
                            .font(.headline)
                        Text(isAvailable ? "Open the system broadcast sheet" : "Broadcast extension is missing")
                            .font(.caption)
                            .opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: isAvailable ? [.orange, .red] : [.gray, Color(white: 0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .background(
                EmberBroadcastPickerHost(controller: controller)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )

            if !isAvailable {
                Text("Reinstall Ember Connect Mobile from an IPA that contains EmberConnectBroadcast.appex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Could not open the broadcast picker", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("iOS could not present Ember Connect's ReplayKit broadcast extension.")
        }
    }
}
