import SwiftUI
import UIKit

@main
struct ChessnutCoachApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var board = BoardController()

    var body: some Scene {
        WindowGroup {
            ContentView(board: board)
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
