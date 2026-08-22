import EasyLinkSwiftSDK
import Foundation

struct ChessnutBoardDiscovery: ElectronicChessBoardDiscovery {
    func scan() -> AsyncStream<ElectronicBoardDescriptor> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for profile in [BoardProfile.classic, .move] {
                        group.addTask {
                            for await device in EasyLinkScanner.scan(profile: profile) {
                                guard !Task.isCancelled else { return }
                                continuation.yield(Self.descriptor(for: device))
                            }
                        }
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func descriptor(for device: EasyLinkDevice) -> ElectronicBoardDescriptor {
        ElectronicBoardDescriptor(
            adapterIdentifier: ChessnutBoardAdapterFactory.adapterIdentifier,
            hardwareIdentifier: device.id.uuidString,
            name: device.name,
            manufacturer: "Chessnut",
            model: device.name,
            variantIdentifier: device.profile.variantIdentifier,
            capabilities: device.profile.electronicBoardCapabilities
        )
    }
}

struct ChessnutBoardAdapterFactory: ElectronicBoardAdapterFactory {
    static let adapterIdentifier = "chessnut.easylink"
    let identifier = Self.adapterIdentifier

    func canCreateBoard(for descriptor: ElectronicBoardDescriptor) -> Bool {
        descriptor.adapterIdentifier == identifier
    }

    func makeBoard(for descriptor: ElectronicBoardDescriptor) throws -> any ElectronicChessBoard {
        guard canCreateBoard(for: descriptor) else {
            throw ElectronicBoardError.noAdapter(descriptor.name)
        }
        guard let deviceID = UUID(uuidString: descriptor.hardwareIdentifier) else {
            throw ElectronicBoardError.invalidDescriptor("identificador Bluetooth no válido")
        }
        guard let profile = BoardProfile(variantIdentifier: descriptor.variantIdentifier) else {
            throw ElectronicBoardError.invalidDescriptor("perfil Chessnut desconocido")
        }

        return ChessnutBoardAdapter(
            descriptor: descriptor,
            profile: profile,
            deviceID: deviceID
        )
    }
}

extension ElectronicBoardAdapterRegistry {
    static var chessnutDefault: Self {
        Self(factories: [ChessnutBoardAdapterFactory()])
    }
}

final class ChessnutBoardAdapter: ElectronicChessBoard, @unchecked Sendable {
    let descriptor: ElectronicBoardDescriptor
    let capabilities: ElectronicBoardCapabilities
    let positionUpdates: AsyncStream<String>
    let connectionEvents: AsyncStream<ElectronicBoardConnectionEvent>

    private let profile: BoardProfile
    private let transport: MonitoredEasyLinkTransport
    private let client: EasyLinkClient
    private let connectionEventContinuation: AsyncStream<ElectronicBoardConnectionEvent>.Continuation
    private var connectionForwardingTask: Task<Void, Never>?

    init(
        descriptor: ElectronicBoardDescriptor,
        profile: BoardProfile,
        deviceID: UUID
    ) {
        self.descriptor = descriptor
        self.profile = profile
        capabilities = profile.electronicBoardCapabilities

        let transport = MonitoredEasyLinkTransport(profile: profile, deviceID: deviceID)
        self.transport = transport
        let client = EasyLinkClient(profile: profile, transport: transport)
        self.client = client
        positionUpdates = client.fenUpdates

        var continuation: AsyncStream<ElectronicBoardConnectionEvent>.Continuation!
        connectionEvents = AsyncStream { continuation = $0 }
        let capturedContinuation = continuation!
        connectionEventContinuation = capturedContinuation

        connectionForwardingTask = Task { [transport, capturedContinuation] in
            for await event in transport.connectionEvents {
                guard !Task.isCancelled else { return }
                switch event {
                case .disconnected:
                    capturedContinuation.yield(.disconnected)
                    return
                }
            }
        }
    }

    deinit {
        connectionForwardingTask?.cancel()
        connectionEventContinuation.finish()
    }

    func connect() async throws {
        try await client.connect()
    }

    func disconnect() async {
        await client.disconnect()
    }

    func enableRealtimeUpdates() async throws {
        try await client.enableRealtimeUpdates()
    }

    func setLEDs(_ frame: ElectronicBoardLEDFrame) async throws {
        guard capabilities.contains(.leds) else {
            throw ElectronicBoardError.unsupportedCapability("LEDs")
        }

        var leds = LEDBoard.allOff
        for rank in 0..<8 {
            for file in 0..<8 {
                leds[rankIndex: rank, fileIndex: file] = frame[rankIndex: rank, fileIndex: file].easyLinkColor
            }
        }
        try await client.setLEDs(leds)
    }

    func batteryStatus(timeout: Duration) async throws -> ElectronicBoardBatteryStatus {
        guard capabilities.contains(.battery) else {
            throw ElectronicBoardError.unsupportedCapability("batería")
        }

        let status = try await client.batteryStatus(timeout: timeout)
        return ElectronicBoardBatteryStatus(
            percentage: status.percentage,
            isCharging: status.isCharging
        )
    }

    func importStoredGames(timeout: Duration) async throws -> [ElectronicBoardStoredGame] {
        guard capabilities.contains(.gameStorage) else {
            throw ElectronicBoardError.unsupportedCapability("almacenamiento de partidas")
        }
        return try await client.importOTBGames(timeout: timeout).map {
            ElectronicBoardStoredGame(positions: $0.positions)
        }
    }

    func setAutomaticPosition(fen: String, force: Bool) async throws {
        guard capabilities.contains(.automaticMovement) else {
            throw ElectronicBoardError.unsupportedCapability("movimiento automático")
        }
        try await client.setAutoMove(fen: fen, force: force)
    }

    func stopAutomaticMovement() async throws {
        guard capabilities.contains(.automaticMovement) else {
            throw ElectronicBoardError.unsupportedCapability("movimiento automático")
        }
        try await client.stopAutoMove()
    }

    func pieceIdentities(timeout: Duration) async throws -> [ElectronicPieceIdentity] {
        guard capabilities.contains(.pieceIdentification) else {
            throw ElectronicBoardError.unsupportedCapability("identificación de piezas")
        }
        return try await client.pieceStatus(timeout: timeout).map {
            ElectronicPieceIdentity(
                index: $0.index,
                piece: $0.piece,
                identityCode: $0.identityCode,
                x: $0.x,
                y: $0.y,
                batteryPercentage: $0.batteryPercentage
            )
        }
    }
}

private extension BoardProfile {
    var variantIdentifier: String {
        switch self {
        case .classic: "classic"
        case .move: "move"
        }
    }

    init?(variantIdentifier: String) {
        switch variantIdentifier {
        case "classic": self = .classic
        case "move": self = .move
        default: return nil
        }
    }

    var electronicBoardCapabilities: ElectronicBoardCapabilities {
        switch self {
        case .classic:
            [.positionReading, .realtimePosition, .leds, .battery, .gameStorage]
        case .move:
            [
                .positionReading,
                .realtimePosition,
                .leds,
                .ledColors,
                .battery,
                .gameStorage,
                .automaticMovement,
                .pieceIdentification,
            ]
        }
    }
}

private extension ElectronicBoardLEDColor {
    var easyLinkColor: LEDColor {
        switch self {
        case .off: .off
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }
}
