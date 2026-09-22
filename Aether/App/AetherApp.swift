import SwiftUI

@main
struct AetherApp: App {
    /// Écoute les transactions dès le lancement : un pourboire approuvé plus
    /// tard (Ask to Buy) ou interrompu doit être fini, écran ouvert ou non.
    @State private var tipJar: TipJar

    init() {
        let tipJar = TipJar()
        tipJar.start()
        _tipJar = State(initialValue: tipJar)
    }

    // `SwiftUI.Scene` qualifié : le Domain définit aussi un type `Scene`.
    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView()
                .environment(tipJar)
        }
    }
}
