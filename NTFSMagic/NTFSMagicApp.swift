import SwiftUI

@main
struct NTFSMagicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 550, height: 440)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
