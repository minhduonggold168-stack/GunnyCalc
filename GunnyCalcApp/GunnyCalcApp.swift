import SwiftUI

@main
struct GunnyCalcApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    PiPOverlayManager.shared.configureIfNeeded()
                }
        }
    }
}
