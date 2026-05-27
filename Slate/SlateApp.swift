import SwiftUI

@main
struct SlateApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}   // no "New Window"
        }
    }
}
