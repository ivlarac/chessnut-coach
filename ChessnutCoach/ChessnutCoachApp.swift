import SwiftUI
import UIKit
import CoreBluetooth

@main
struct ChessnutCoachApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Keep CoreBluetooth restoration/background behavior available for the Chessnut Air.
        // The actual peripheral session remains managed by BoardController.
        CBCentralManager(delegate: nil, queue: nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            NotificationCenter.default.post(name: .chessnutAppBecameActive, object: nil)
        case .inactive:
            NotificationCenter.default.post(name: .chessnutAppBecameInactive, object: nil)
        case .background:
            NotificationCenter.default.post(name: .chessnutAppEnteredBackground, object: nil)
        @unknown default:
            break
        }
    }
}

extension Notification.Name {
    static let chessnutAppBecameActive = Notification.Name("ChessnutAppBecameActive")
    static let chessnutAppBecameInactive = Notification.Name("ChessnutAppBecameInactive")
    static let chessnutAppEnteredBackground = Notification.Name("ChessnutAppEnteredBackground")
}
