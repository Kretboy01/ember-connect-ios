import SwiftUI
import ReplayKit

/// Wraps `RPSystemBroadcastPickerView`, the only supported way to start a
/// broadcast from inside an app.
///
/// The system view renders its own small button. Pinning `preferredExtension`
/// to our extension means one tap goes straight to Ember Connect instead of
/// making the user pick from a list.
struct BroadcastPicker: UIViewRepresentable {
    let extensionBundleId: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 60, height: 60)
        )
        picker.preferredExtension = extensionBundleId
        // The microphone toggle is noise here — this streams video only.
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = extensionBundleId
    }
}

/// A full-width, styled row that triggers the system picker.
///
/// `RPSystemBroadcastPickerView` cannot be restyled, so rather than fight it
/// the real control is drawn underneath and the picker is laid over it at low
/// opacity to catch the tap. Tapping anywhere on the row therefore opens the
/// system sheet, which is what people expect from a row this size.
struct BroadcastButton: View {
    let extensionBundleId: String

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.title2)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start Mirroring")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Streams this screen to the desktop app")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.95, green: 0.35, blue: 0.15),
                             Color(red: 0.85, green: 0.18, blue: 0.30)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            BroadcastPicker(extensionBundleId: extensionBundleId)
                .opacity(0.02)
        }
        .frame(maxWidth: .infinity)
    }
}
