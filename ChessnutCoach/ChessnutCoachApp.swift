import SwiftUI
import UIKit

@main
struct ChessnutCoachApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // A Chessnut Air session requires the app visible while the board
                    // is being used. Prevent iOS from locking the screen mid-game.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}
