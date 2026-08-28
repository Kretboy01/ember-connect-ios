import SwiftUI
import ReplayKit
import UIKit

/// Locates and drives the system broadcast picker.
///
/// Two things make this less straightforward than it looks:
///
/// 1. **The extension's bundle id is not knowable at compile time.** Ember
///    Connect signs with a free Apple ID, which rewrites bundle ids to keep
///    them unique per team — `com.emberwave.EmberConnectMobile` arrives on the
///    device as something like `com.vix.emberwave.R6X73538LZ`, and the
///    extension is renamed to match. A hardcoded `preferredExtension` can
///    therefore never match, and the picker silently offers nothing. So the
///    id is discovered at runtime by reading our own `PlugIns` directory.
///
/// 2. **`RPSystemBroadcastPickerView` cannot be styled or resized.** It draws
///    its own small button, and only that button is a hit target. Overlaying
///    the view on a full-width row means taps land on transparent padding and
///    do nothing — the row looks tappable and simply isn't. Instead the picker
///    is parked in the hierarchy at 1pt and its button is invoked
///    programmatically, which frees the visible control to be any size.
final class BroadcastPickerController: ObservableObject {
    /// Bundle id of the embedded broadcast extension, or nil when it is not
    /// present — which is worth surfacing rather than leaving a dead button.
    @Published private(set) var extensionBundleId: String?

    fileprivate weak var pickerView: RPSystemBroadcastPickerView?

    init() {
        extensionBundleId = Self.discoverBroadcastExtension()
    }

    /// Finds the embedded upload extension by inspecting `PlugIns`.
    ///
    /// Matching on `NSExtensionPointIdentifier` rather than on a name means
    /// this keeps working no matter how the bundle id was rewritten at
    /// signing time.
    static func discoverBroadcastExtension() -> String? {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: pluginsURL,
                  includingPropertiesForKeys: nil
              ) else {
            return nil
        }

        for url in entries where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let info = bundle.infoDictionary,
                  let extensionInfo = info["NSExtension"] as? [String: Any],
                  let point = extensionInfo["NSExtensionPointIdentifier"] as? String,
                  point == "com.apple.broadcast-services-upload",
                  let identifier = bundle.bundleIdentifier else { continue }
            return identifier
        }
        return nil
    }

    /// Walks the picker's subtree for its button.
    ///
    /// Searched recursively rather than over direct children only: Apple has
    /// reshuffled this view's internals between releases, and a direct-child
    /// assumption breaks silently when they do.
    private func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for subview in view.subviews {
            if let found = findButton(in: subview) { return found }
        }
        return nil
    }

    /// Opens the system sheet. Returns false when the button could not be
    /// reached, so the caller can say so instead of appearing to do nothing.
    @discardableResult
    func presentPicker() -> Bool {
        guard let pickerView, let button = findButton(in: pickerView) else { return false }
        button.sendActions(for: .touchUpInside)
        return true
    }
}

/// Hosts the system picker off-screen so its button can be triggered.
private struct BroadcastPickerHost: UIViewRepresentable {
    let controller: BroadcastPickerController

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 44, height: 44)
        )
        picker.preferredExtension = controller.extensionBundleId
        // This streams video only; the mic toggle would just confuse things.
        picker.showsMicrophoneButton = false
        controller.pickerView = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = controller.extensionBundleId
        controller.pickerView = uiView
    }
}

/// Full-width, styled control that starts a broadcast.
struct BroadcastButton: View {
    @StateObject private var controller = BroadcastPickerController()
    @State private var showUnavailable = false

    private var isAvailable: Bool { controller.extensionBundleId != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if !controller.presentPicker() {
                    showUnavailable = true
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isAvailable ? "record.circle" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isAvailable ? "Start Mirroring" : "Mirroring Unavailable")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(isAvailable
                             ? "Streams this screen to the desktop app"
                             : "The broadcast extension is not installed")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: isAvailable
                            ? [Color(red: 0.95, green: 0.35, blue: 0.15),
                               Color(red: 0.85, green: 0.18, blue: 0.30)]
                            : [Color(white: 0.35), Color(white: 0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            // Parked at 1pt: the picker must be in the hierarchy for its
            // button to be reachable, but it must not be what the user aims at.
            .background(
                BroadcastPickerHost(controller: controller)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )

            if !isAvailable {
                Text("The app was installed without its broadcast extension. Re-install from Ember Connect on the desktop — the .ipa must contain PlugIns/EmberConnectBroadcast.appex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Could not open the broadcast picker",
               isPresented: $showUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("iOS did not present the broadcast sheet. Make sure the app was installed with its extension, then try again.")
        }
    }
}
