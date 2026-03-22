import SwiftUI

@main
struct getAudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 380, height: 68)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}
