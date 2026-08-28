import Network
import ReplayKit
import SwiftUI
import UIKit

/// Ember Connect's screen-mirroring dashboard.
/// Leverages the embedded EmberConnectBroadcast ReplayKit extension to stream
/// hardware H.264 video at 60fps directly over USB (usbmux) or Wi-Fi.
struct EmberMirrorView: View {
    @State private var isPulsing = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background dark obsidian canvas
                EmberTheme.bgBase.ignoresSafeArea()
                
                // Ambient radiant mesh in top corner
                EmberTheme.heroMeshGradient
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        
                        // MARK: - Hero Broadcast Card
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top) {
                                ZStack {
                                    Circle()
                                        .fill(EmberTheme.accent.opacity(0.15))
                                        .frame(width: 56, height: 56)
                                        .scaleEffect(isPulsing ? 1.15 : 0.95)
                                        .animation(
                                            .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                                            value: isPulsing
                                        )
                                    
                                    Circle()
                                        .fill(EmberTheme.flameGradient)
                                        .frame(width: 44, height: 44)
                                        .shadow(color: EmberTheme.accentGlow, radius: 10, x: 0, y: 3)
                                    
                                    Image(systemName: "airplayvideo")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                
                                Spacer()
                                
                                // Live Ready Badge
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(EmberTheme.success)
                                        .frame(width: 8, height: 8)
                                    Text("60 FPS READY")
                                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                                        .foregroundStyle(EmberTheme.success)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(EmberTheme.success.opacity(0.12))
                                        .overlay(Capsule().stroke(EmberTheme.success.opacity(0.25), lineWidth: 1))
                                )
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Live Screen Mirroring")
                                    .font(.system(.title2, design: .rounded).weight(.bold))
                                    .foregroundStyle(Color.white)
                                
                                Text("Stream your iPhone display in real-time hardware H.264 directly to Ember Connect Desktop.")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.white.opacity(0.7))
                                    .lineSpacing(2)
                            }
                            
                            // Tech Spec Pills
                            HStack(spacing: 8) {
                                SpecPill(icon: "bolt.fill", text: "Hardware H.264")
                                SpecPill(icon: "cable.connector", text: "Direct USB / usbmux")
                                SpecPill(icon: "gauge.with.needle", text: "Zero Lag")
                            }
                            
                            Divider()
                                .background(EmberTheme.borderSubtle)
                                .padding(.vertical, 2)
                            
                            // Glowing Broadcast Action Button
                            EmberBroadcastButton()
                        }
                        .padding(20)
                        .emberGlassCard(cornerRadius: 22, withGlow: true)
                        
                        // MARK: - Connection Methods Section
                        Text("Connection Transport")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 4)
                        
                        VStack(spacing: 12) {
                            ConnectionGuideCard(
                                icon: "cable.connector.horizontal",
                                iconColor: EmberTheme.accent,
                                title: "USB usbmux (Recommended)",
                                subtitle: "Connect Lightning or USB-C cable. Zero configuration needed; desktop auto-connects to port 7878 with crystal-clear 60fps."
                            )
                            
                            ConnectionGuideCard(
                                icon: "wifi",
                                iconColor: EmberTheme.cyan,
                                title: "Local Wi-Fi Network",
                                subtitle: "Same Wi-Fi network, no setup: this iPhone advertises itself and the desktop finds it. Allow Local Network access when iOS asks. Set EMBER_MIRROR_HOST on the desktop to pin an address instead."
                            )
                        }
                        
                        // MARK: - Live Container Compatibility Tip
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(EmberTheme.accentHi)
                                .padding(10)
                                .background(
                                    Circle().fill(EmberTheme.accent.opacity(0.15))
                                )
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Multitasking Supported")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundStyle(Color.white)
                                
                                Text("The ReplayKit broadcast stays active system-wide even when you leave Ember Connect or launch guest apps.")
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.65))
                                    .lineSpacing(2)
                            }
                        }
                        .padding(16)
                        .emberGlassCard(cornerRadius: 16)
                        
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Screen Mirror")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(EmberTheme.accent)
                        Text("Ember Mirror")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.white)
                    }
                }
            }
            .onAppear {
                isPulsing = true
                LocalNetworkPermissionPrimer.shared.prime()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

// MARK: - Local network permission

/// Provokes iOS's Local Network permission prompt from the *app*.
///
/// The broadcast extension needs this permission to advertise itself over
/// Bonjour, but an extension has no way to present the prompt — so if it is
/// the first thing to ask, the request is simply denied and wireless
/// discovery never works. Browsing for the same service here, from a screen
/// the user has deliberately opened, puts the dialog in front of them at a
/// moment when it makes sense.
///
/// Failure is not reported: USB does not need this, and the extension falls
/// back to an unadvertised listener if the permission never arrives.
private final class LocalNetworkPermissionPrimer {
    static let shared = LocalNetworkPermissionPrimer()

    private var browser: NWBrowser?
    private var hasPrimed = false

    func prime() {
        guard !hasPrimed else { return }
        hasPrimed = true

        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: MirrorBonjour.type,
            domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.stop()
            default:
                break
            }
        }
        browser.start(queue: .main)

        // The prompt appears as soon as the browse starts; there is nothing to
        // do with the results, so do not keep a multicast browser running
        // behind the user's back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.stop()
        }
    }

    private func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// Duplicated from `Shared/MirrorProtocol.swift`, which is compiled into the
/// broadcast extension only — the host app target does not see it.
private enum MirrorBonjour {
    static let type = "_ember-mirror._tcp"
}

// MARK: - Supporting Views

private struct SpecPill: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(EmberTheme.accentHi)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        )
    }
}

private struct ConnectionGuideCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconColor.opacity(0.12))
                )
            
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.white)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineSpacing(2)
            }
            
            Spacer()
        }
        .padding(14)
        .emberGlassCard(cornerRadius: 14)
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

    /// Finds the control inside `RPSystemBroadcastPickerView` that actually
    /// opens the system sheet.
    ///
    /// The picker's own bounds are mostly transparent padding — only its inner
    /// button is a hit target — which is why laying it across a full-width row
    /// and expecting taps to land does not work. It is parked at 1 pt instead
    /// and its control invoked directly.
    ///
    /// `UIControl` rather than `UIButton`: the private hierarchy is not API and
    /// has changed shape across iOS releases. Every control it has ever used is
    /// a `UIControl`, and matching on the broader type survives the next
    /// reshuffle.
    private func findControl(in view: UIView) -> UIControl? {
        if let control = view as? UIControl { return control }
        for subview in view.subviews {
            if let control = findControl(in: subview) { return control }
        }
        return nil
    }

    func present() -> Bool {
        guard let pickerView else { return false }

        // Lay out first: the control is created lazily, so on the very first
        // tap it may not exist yet in a view that has never been laid out.
        pickerView.layoutIfNeeded()

        guard let control = findControl(in: pickerView) else { return false }
        control.sendActions(for: .touchUpInside)
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
                        .font(.system(size: 20, weight: .bold))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isAvailable ? "Start Broadcast Stream" : "Mirroring Extension Missing")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                        Text(isAvailable ? "Tap to open system broadcast picker" : "Reinstall with ReplayKit extension")
                            .font(.caption)
                            .opacity(0.85)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                }
                .emberFlameButton(isEnabled: isAvailable)
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
                    .foregroundStyle(EmberTheme.danger)
            }
        }
        .alert("Could not open the broadcast picker", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("iOS could not present Ember Connect's ReplayKit broadcast extension.")
        }
    }
}
