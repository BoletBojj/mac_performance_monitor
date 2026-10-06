import SwiftUI

@main struct MyApp: App {
    init() {
        // AppKit's default tooltip delay (~1-1.5s) applies to every `.help(_:)`
        // in the app. There's no per-view SwiftUI override, but this
        // UserDefaults key — scoped to this app only, not system-wide — is
        // the standard, documented AppKit lever for it.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
