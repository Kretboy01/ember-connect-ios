import SwiftUI

/// Bundle id of the embedded broadcast extension. Kept in one place because
/// the picker will silently do nothing if it does not match the extension's
/// actual `PRODUCT_BUNDLE_IDENTIFIER` in project.yml.
private let broadcastExtensionId = "com.emberwave.EmberConnectMobile.Broadcast"

struct AppLibraryView: View {
    @StateObject private var model = AppModel()
    @State private var launchFailure: String?

    var body: some View {
        // NavigationView rather than NavigationStack: the deployment target is
        // iOS 15 and NavigationStack needs 16. The stack style stops iPad
        // rendering this as a split view with an empty detail pane.
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    mirroringSection
                    librarySection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Ember Connect")
            .refreshable { await model.load() }
            .task { model.loadIfNeeded() }
            .alert("Could not open that app",
                   isPresented: Binding(get: { launchFailure != nil },
                                        set: { if !$0 { launchFailure = nil } })) {
                Button("OK", role: .cancel) { launchFailure = nil }
            } message: {
                Text(launchFailure ?? "")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Mirroring

    private var mirroringSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Screen Mirroring",
                          subtitle: "Show this device inside the desktop app")

            BroadcastButton(extensionBundleId: broadcastExtensionId)

            Label(
                "Keep the device connected by USB. The desktop picks up the stream automatically once the broadcast starts.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "App Library",
                              subtitle: "Apps installed into this container")
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }

            if let error = model.lastError {
                CalloutBox(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "Could not read the library",
                    message: error
                )
            }

            if model.apps.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(model.apps) { app in
                        Button { launch(app) } label: { GuestAppRow(app: app) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The screen the user actually saw before this existed: an empty `List`
    /// showed nothing but the navigation title, which reads as a blank black
    /// screen with one line of white text.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("No apps installed yet")
                .font(.headline)

            Text("Send an app from Ember Connect on your computer — open the Catalog and choose \"Install into Ember Connect Mobile\". It will appear here without using an Apple ID slot.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func launch(_ app: GuestApp) {
        // Returns nil on success, otherwise the specific reason. The previous
        // call was fire-and-forget, so a tap that could not work looked
        // exactly like one that did.
        if let reason = ECRuntime.launchGuestApp(atPath: app.path) {
            launchFailure = reason
        }
    }
}

// MARK: - Pieces

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CalloutBox: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct GuestAppRow: View {
    let app: GuestApp

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "app.dashed")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).foregroundStyle(.primary)
                Text("\(app.bundleId) · \(app.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

@main
struct EmberConnectApp: App {
    var body: some Scene {
        WindowGroup {
            AppLibraryView()
        }
    }
}
