import SwiftUI

@main
struct GunnyCalcApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = GunnyCalcViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    PiPOverlayManager.shared.configureIfNeeded()
                    viewModel.startListening()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        viewModel.refreshFromIPC()
                    }
                }
        }
    }
}
