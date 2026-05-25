import SwiftUI

@main
struct AetherApp: App {
    // `SwiftUI.Scene` qualifié : le Domain définit aussi un type `Scene`.
    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView()
        }
    }
}
