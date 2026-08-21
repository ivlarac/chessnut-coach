import Foundation
import CoreBluetooth

/// Keeps the application ready to restore BLE state transitions while iOS moves
/// the app between foreground and background states.
final class BackgroundBluetoothSupport: NSObject, CBCentralManagerDelegate {
    static let shared = BackgroundBluetoothSupport()

    private var centralManager: CBCentralManager?

    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // BoardController owns the Chessnut peripheral lifecycle.
        // This object only ensures CoreBluetooth remains initialized.
    }
}
