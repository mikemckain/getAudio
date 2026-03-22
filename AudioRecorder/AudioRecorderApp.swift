import SwiftUI

@main
struct AudioRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 380, height: 86)
        .windowStyle(.hiddenTitleBar)
    }
}
