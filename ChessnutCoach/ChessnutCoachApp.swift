import SwiftUI
import UIKit

@main
struct ChessnutCoachApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: GameLibrary
    @StateObject private var board: BoardController

    init() {
        let library = GameLibrary()
        _library = StateObject(wrappedValue: library)
        _board = StateObject(wrappedValue: BoardController(library: library))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(board: board, library: library)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            board.handleAppPhase(.active)
        case .inactive:
            board.handleAppPhase(.inactive)
        case .background:
            board.handleAppPhase(.background)
        @unknown default:
            break
        }
    }
}
