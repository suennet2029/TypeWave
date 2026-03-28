import SwiftUI

@main
struct VoiceCodingNativeApp: App {
    @StateObject private var coordinator: AppCoordinator

    init() {
        let coordinator = AppCoordinator()
        _coordinator = StateObject(wrappedValue: coordinator)
        coordinator.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(coordinator: coordinator)
        } label: {
            Label(
                "Voice Coding",
                systemImage: coordinator.runtime.isRecording ? "waveform.circle.fill" : "waveform.circle"
            )
        }
        .menuBarExtraStyle(.window)
    }
}
