import SwiftUI

struct AppLibraryView: View {
    @StateObject private var model = AppModel()
    
    var body: some View {
        NavigationView {
            List(model.apps) { app in
                Button(action: {
                    launchApp(app)
                }) {
                    HStack {
                        Image(systemName: "app.fill")
                            .resizable()
                            .frame(width: 50, height: 50)
                            .foregroundColor(.blue)
                            .padding(.trailing, 10)
                        
                        VStack(alignment: .leading) {
                            Text(app.name)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(app.version)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            .navigationTitle("Ember Connect")
            .onAppear {
                model.loadApps()
            }
        }
    }
    
    private func launchApp(_ app: GuestApp) {
        print("Launching \(app.name) at \(app.path)")
        // Call the Objective-C runtime method
        ECRuntime.launchGuestApp(atPath: app.path)
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
