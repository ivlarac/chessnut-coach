import CoreBluetooth
import Foundation

/// Discovers first-generation ChessUp boards over Bluetooth LE.
///
/// ChessUp exposes a Nordic UART Service (NUS). The public third-party protocol
/// provides board-position and move messages, but it does not expose control of
/// the board LEDs. Accordingly this adapter advertises position capabilities only.
struct ChessUpBoardDiscovery: ElectronicChessBoardDiscovery {
    func scan() -> AsyncStream<ElectronicBoardDescriptor> {
        AsyncStream { continuation in
            let session = ChessUpDiscoverySession(continuation: continuation)
            session.start()

            continuation.onTermination = { @Sendable _ in
                session.stop()
            }
        }
    }
}

struct ChessUpBoardAdapterFactory: ElectronicBoardAdapterFactory {
    static let adapterIdentifier = "chessup.nus"
    static let variantIdentifier = "chessup1"

    let identifier = Self.adapterIdentifier

    func canCreateBoard(for descriptor: ElectronicBoardDescriptor) -> Bool {
        descriptor.adapterIdentifier == identifier
            && descriptor.variantIdentifier == Self.variantIdentifier
    }

    func makeBoard(for descriptor: ElectronicBoardDescriptor) throws -> any ElectronicChessBoard {
        guard canCreateBoard(for: descriptor) else {
            throw ElectronicBoardError.noAdapter(descriptor.name)
        }
        guard UUID(uuidString: descriptor.hardwareIdentifier) != nil else {
            throw ElectronicBoardError.invalidDescriptor("identificador Bluetooth de ChessUp no válido")
        }
        return ChessUpBoardAdapter(descriptor: descriptor)
    }
}

private final class ChessUpDiscoverySession: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<ElectronicBoardDescriptor>.Continuation
    private let queue = DispatchQueue(label: "com.ivlarac.chessnutcoach.chessup.discovery")
    private var central: CBCentralManager?
    private var isStopped = false

    init(continuation: AsyncStream<ElectronicBoardDescriptor>.Continuation) {
        self.continuation = continuation
        super.init()
    }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.isStopped = true
            self.central?.stopScan()
            self.central = nil
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !isStopped else { return }
        guard central.state == .poweredOn else {
            if [.unsupported, .unauthorized].contains(central.state) {
                continuation.finish()
            }
            return
        }

        // ChessUp's reference implementations filter on the local name rather than
        // assuming the NUS service UUID is always present in the advertising packet.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !isStopped else { return }

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? ""
        guard name.caseInsensitiveCompare("ChessUp") == .orderedSame else { return }

        continuation.yield(
            ElectronicBoardDescriptor(
                adapterIdentifier: ChessUpBoardAdapterFactory.adapterIdentifier,
                hardwareIdentifier: peripheral.identifier.uuidString,
                name: name.isEmpty ? "ChessUp" : name,
                manufacturer: "Bryght Labs",
                model: "ChessUp",
                variantIdentifier: ChessUpBoardAdapterFactory.variantIdentifier,
                capabilities: [.positionReading, .realtimePosition]
            )
        )
    }
}

private enum ChessUpBLE {
    // Nordic UART Service used by ChessUp. Keep the UUIDs as Sendable strings:
    // CBUUID itself is not Sendable under Swift 6 strict concurrency.
    static let serviceUUIDString = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let rxUUIDString = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    static let txUUIDString = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

    static let requestBoardPosition: [UInt8] = [0x67]
    static let moveAcknowledgement: [UInt8] = [0x21]
    static let boardPositionPrefix: UInt8 = 0x67
    static let moveFromBoardPrefix: [UInt8] = [0xA3, 0x35]

    // The public driver declares 72 bytes for this frame. It only needs bytes
    // 1...64 to recover physical piece placement, so the adapter deliberately
    // ignores game-metadata bytes after the piece map.
    static let boardPositionFrameLength = 72
    static let moveFromBoardFrameLength = 6
}

enum ChessUpProtocolCodec {
    private static let pieceByCode: [UInt8: Character] = [
        0: "P", 1: "R", 2: "N", 3: "B", 4: "Q", 5: "K",
        8: "p", 9: "r", 10: "n", 11: "b", 12: "q", 13: "k",
    ]

    static func placement(fromBoardPositionMessage message: [UInt8]) -> String? {
        guard message.count >= 65, message.first == ChessUpBLE.boardPositionPrefix else {
            return nil
        }

        var ranks: [String] = []
        ranks.reserveCapacity(8)

        for rank in stride(from: 7, through: 0, by: -1) {
            var output = ""
            var emptyCount = 0

            for file in 0..<8 {
                let code = message[1 + (rank * 8) + file]
                if code == 64 {
                    emptyCount += 1
                    continue
                }

                guard let piece = pieceByCode[code] else { return nil }
                if emptyCount > 0 {
                    output += String(emptyCount)
                    emptyCount = 0
                }
                output.append(piece)
            }

            if emptyCount > 0 {
                output += String(emptyCount)
            }
            ranks.append(output)
        }

        return ranks.joined(separator: "/")
    }
}

private enum ChessUpBoardError: LocalizedError {
    case bluetoothUnavailable(String)
    case peripheralUnavailable
    case serviceUnavailable
    case characteristicsUnavailable
    case connectionFailed(String)
    case notReady

    var errorDescription: String? {
        switch self {
        case let .bluetoothUnavailable(reason):
            "Bluetooth no está disponible para ChessUp: \(reason)."
        case .peripheralUnavailable:
            "No se pudo recuperar el ChessUp seleccionado. Vuelve a buscar tableros."
        case .serviceUnavailable:
            "ChessUp no expone el servicio Bluetooth esperado."
        case .characteristicsUnavailable:
            "ChessUp no expone las características Bluetooth esperadas."
        case let .connectionFailed(reason):
            "No se pudo conectar con ChessUp: \(reason)."
        case .notReady:
            "ChessUp todavía no está preparado para intercambiar datos."
        }
    }
}

final class ChessUpBoardAdapter: NSObject, ElectronicChessBoard, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    let descriptor: ElectronicBoardDescriptor
    let capabilities: ElectronicBoardCapabilities = [.positionReading, .realtimePosition]
    let positionUpdates: AsyncStream<String>
    let connectionEvents: AsyncStream<ElectronicBoardConnectionEvent>

    private let positionContinuation: AsyncStream<String>.Continuation
    private let connectionContinuation: AsyncStream<ElectronicBoardConnectionEvent>.Continuation
    private let queue = DispatchQueue(label: "com.ivlarac.chessnutcoach.chessup.connection")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectionTimeout: DispatchWorkItem?
    private var receiveBuffer: [UInt8] = []
    private var isDisconnecting = false

    init(descriptor: ElectronicBoardDescriptor) {
        self.descriptor = descriptor

        var positionContinuation: AsyncStream<String>.Continuation!
        positionUpdates = AsyncStream { positionContinuation = $0 }
        self.positionContinuation = positionContinuation

        var connectionContinuation: AsyncStream<ElectronicBoardConnectionEvent>.Continuation!
        connectionEvents = AsyncStream { connectionContinuation = $0 }
        self.connectionContinuation = connectionContinuation

        super.init()
    }

    deinit {
        connectionTimeout?.cancel()
        positionContinuation.finish()
        connectionContinuation.finish()
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard self.connectContinuation == nil else {
                    continuation.resume(throwing: ChessUpBoardError.connectionFailed("ya hay una conexión en curso"))
                    return
                }

                self.isDisconnecting = false
                self.connectContinuation = continuation
                self.central = CBCentralManager(delegate: self, queue: self.queue)

                let timeout = DispatchWorkItem { [weak self] in
                    self?.failPendingConnection(
                        ChessUpBoardError.connectionFailed("tiempo de conexión agotado")
                    )
                }
                self.connectionTimeout = timeout
                self.queue.asyncAfter(deadline: .now() + 10, execute: timeout)
            }
        }
    }

    func disconnect() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                self.isDisconnecting = true
                self.connectionTimeout?.cancel()
                self.connectionTimeout = nil
                self.connectContinuation?.resume(throwing: CancellationError())
                self.connectContinuation = nil
                self.central?.stopScan()

                if let central = self.central, let peripheral = self.peripheral {
                    central.cancelPeripheralConnection(peripheral)
                }

                self.rxCharacteristic = nil
                self.txCharacteristic = nil
                self.peripheral = nil
                self.central = nil
                self.receiveBuffer.removeAll(keepingCapacity: false)
                continuation.resume()
            }
        }
    }

    func enableRealtimeUpdates() async throws {
        try await write(ChessUpBLE.requestBoardPosition)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard connectContinuation != nil else { return }

        switch central.state {
        case .poweredOn:
            beginConnection(using: central)
        case .unsupported:
            failPendingConnection(ChessUpBoardError.bluetoothUnavailable("el dispositivo no admite Bluetooth LE"))
        case .unauthorized:
            failPendingConnection(ChessUpBoardError.bluetoothUnavailable("permiso denegado"))
        case .poweredOff:
            failPendingConnection(ChessUpBoardError.bluetoothUnavailable("Bluetooth está apagado"))
        case .resetting, .unknown:
            break
        @unknown default:
            failPendingConnection(ChessUpBoardError.bluetoothUnavailable("estado desconocido"))
        }
    }

    private func beginConnection(using central: CBCentralManager) {
        guard let identifier = UUID(uuidString: descriptor.hardwareIdentifier) else {
            failPendingConnection(ElectronicBoardError.invalidDescriptor("identificador Bluetooth de ChessUp no válido"))
            return
        }

        if let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connect(to: known, using: central)
            return
        }

        // The peripheral may have been discovered by a different CBCentralManager.
        // Scan again and match the stable CoreBluetooth identifier before connecting.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard peripheral.identifier.uuidString == descriptor.hardwareIdentifier else { return }
        central.stopScan()
        connect(to: peripheral, using: central)
    }

    private func connect(to peripheral: CBPeripheral, using central: CBCentralManager) {
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        central.stopScan()
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: ChessUpBLE.serviceUUIDString)])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        failPendingConnection(
            ChessUpBoardError.connectionFailed(error?.localizedDescription ?? "error Bluetooth desconocido")
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        if connectContinuation != nil {
            failPendingConnection(
                ChessUpBoardError.connectionFailed(error?.localizedDescription ?? "desconectado durante la conexión")
            )
            return
        }

        rxCharacteristic = nil
        txCharacteristic = nil
        self.peripheral = nil
        receiveBuffer.removeAll(keepingCapacity: false)

        if !isDisconnecting {
            connectionContinuation.yield(.disconnected)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            failPendingConnection(ChessUpBoardError.connectionFailed(error.localizedDescription))
            return
        }

        let serviceUUID = CBUUID(string: ChessUpBLE.serviceUUIDString)
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            failPendingConnection(ChessUpBoardError.serviceUnavailable)
            return
        }
        peripheral.discoverCharacteristics(
            [
                CBUUID(string: ChessUpBLE.rxUUIDString),
                CBUUID(string: ChessUpBLE.txUUIDString),
            ],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        if let error {
            failPendingConnection(ChessUpBoardError.connectionFailed(error.localizedDescription))
            return
        }

        let rxUUID = CBUUID(string: ChessUpBLE.rxUUIDString)
        let txUUID = CBUUID(string: ChessUpBLE.txUUIDString)
        rxCharacteristic = service.characteristics?.first(where: { $0.uuid == rxUUID })
        txCharacteristic = service.characteristics?.first(where: { $0.uuid == txUUID })

        guard rxCharacteristic != nil, let txCharacteristic else {
            failPendingConnection(ChessUpBoardError.characteristicsUnavailable)
            return
        }
        peripheral.setNotifyValue(true, for: txCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard characteristic.uuid == CBUUID(string: ChessUpBLE.txUUIDString) else { return }

        if let error {
            failPendingConnection(ChessUpBoardError.connectionFailed(error.localizedDescription))
            return
        }
        guard characteristic.isNotifying else {
            failPendingConnection(ChessUpBoardError.characteristicsUnavailable)
            return
        }

        connectionTimeout?.cancel()
        connectionTimeout = nil
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard characteristic.uuid == CBUUID(string: ChessUpBLE.txUUIDString) else { return }
        guard error == nil, let data = characteristic.value else { return }

        receiveBuffer.append(contentsOf: data)
        consumeReceiveBuffer()
    }

    private func consumeReceiveBuffer() {
        while !receiveBuffer.isEmpty {
            if receiveBuffer[0] == ChessUpBLE.boardPositionPrefix {
                guard receiveBuffer.count >= ChessUpBLE.boardPositionFrameLength else { return }
                let frame = Array(receiveBuffer.prefix(ChessUpBLE.boardPositionFrameLength))
                receiveBuffer.removeFirst(ChessUpBLE.boardPositionFrameLength)

                if let placement = ChessUpProtocolCodec.placement(fromBoardPositionMessage: frame) {
                    positionContinuation.yield(placement)
                }
                continue
            }

            if receiveBuffer.starts(with: ChessUpBLE.moveFromBoardPrefix) {
                guard receiveBuffer.count >= ChessUpBLE.moveFromBoardFrameLength else { return }
                receiveBuffer.removeFirst(ChessUpBLE.moveFromBoardFrameLength)

                // ChessUp expects an acknowledgement for board-originated moves. Then
                // request the authoritative full position, which keeps Chessnut Coach
                // independent of ChessUp's move-state machine and promotion details.
                try? writeSynchronously(ChessUpBLE.moveAcknowledgement)
                try? writeSynchronously(ChessUpBLE.requestBoardPosition)
                continue
            }

            // The board publishes additional protocol messages (touch, battery,
            // settings, etc.) that Chessnut Coach does not need. Resynchronise on the
            // next message prefix rather than coupling the game layer to those frames.
            receiveBuffer.removeFirst()
        }
    }

    private func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                do {
                    guard let self else {
                        throw CancellationError()
                    }
                    try self.writeSynchronously(bytes)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writeSynchronously(_ bytes: [UInt8]) throws {
        guard let peripheral, let rxCharacteristic else {
            throw ChessUpBoardError.notReady
        }

        let writeType: CBCharacteristicWriteType
        if rxCharacteristic.properties.contains(.write) {
            writeType = .withResponse
        } else if rxCharacteristic.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
        } else {
            throw ChessUpBoardError.characteristicsUnavailable
        }

        peripheral.writeValue(Data(bytes), for: rxCharacteristic, type: writeType)
    }

    private func failPendingConnection(_ error: any Error) {
        connectionTimeout?.cancel()
        connectionTimeout = nil
        central?.stopScan()

        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }

        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        peripheral = nil
    }
}
