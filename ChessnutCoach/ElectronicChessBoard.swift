import Foundation

struct ElectronicBoardCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: UInt16

    static let positionReading = Self(rawValue: 1 << 0)
    static let realtimePosition = Self(rawValue: 1 << 1)
    static let leds = Self(rawValue: 1 << 2)
    static let ledColors = Self(rawValue: 1 << 3)
    static let battery = Self(rawValue: 1 << 4)
    static let gameStorage = Self(rawValue: 1 << 5)
    static let automaticMovement = Self(rawValue: 1 << 6)
    static let pieceIdentification = Self(rawValue: 1 << 7)
}

struct ElectronicBoardDescriptor: Identifiable, Hashable, Sendable {
    let adapterIdentifier: String
    let hardwareIdentifier: String
    let name: String
    let manufacturer: String
    let model: String
    let variantIdentifier: String
    let capabilities: ElectronicBoardCapabilities

    var id: String {
        "\(adapterIdentifier):\(hardwareIdentifier)"
    }
}

/// User-facing compatibility metadata published by a registered adapter.
///
/// Keeping this next to the factory prevents the Information screen from
/// maintaining a second, easily outdated list of supported hardware.
struct ElectronicBoardSupport: Identifiable, Hashable, Sendable {
    let adapterIdentifier: String
    let name: String
    let models: String
    let detail: String
    let capabilities: ElectronicBoardCapabilities

    var id: String {
        "\(adapterIdentifier):\(name)"
    }
}

enum ElectronicBoardLEDColor: UInt8, Hashable, Sendable {
    case off
    case red
    case green
    case blue
}

struct ElectronicBoardLEDFrame: Equatable, Sendable {
    private(set) var colors: [[ElectronicBoardLEDColor]]

    init(colors: [[ElectronicBoardLEDColor]]) {
        precondition(
            colors.count == 8 && colors.allSatisfy { $0.count == 8 },
            "Electronic board LED frames must be 8x8"
        )
        self.colors = colors
    }

    static var allOff: Self {
        Self(colors: Array(repeating: Array(repeating: .off, count: 8), count: 8))
    }

    subscript(rankIndex rankIndex: Int, fileIndex fileIndex: Int) -> ElectronicBoardLEDColor {
        get { colors[rankIndex][fileIndex] }
        set { colors[rankIndex][fileIndex] = newValue }
    }
}

struct ElectronicBoardBatteryStatus: Equatable, Sendable {
    let percentage: Int
    let isCharging: Bool?
}

struct ElectronicBoardStoredGame: Equatable, Sendable {
    let positions: [String]
}

struct ElectronicPieceIdentity: Equatable, Sendable {
    let index: Int
    let piece: Character
    let identityCode: UInt8
    let x: UInt8
    let y: UInt8
    let batteryPercentage: Int
}

enum ElectronicBoardConnectionEvent: Equatable, Sendable {
    case disconnected
}

enum ElectronicBoardError: LocalizedError, Equatable, Sendable {
    case unsupportedCapability(String)
    case noAdapter(String)
    case invalidDescriptor(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedCapability(capability):
            "El tablero no admite la capacidad «\(capability)»."
        case let .noAdapter(identifier):
            "No existe un adaptador para el tablero \(identifier)."
        case let .invalidDescriptor(message):
            "Descriptor de tablero no válido: \(message)"
        }
    }
}

protocol ElectronicChessBoard: AnyObject, Sendable {
    var descriptor: ElectronicBoardDescriptor { get }
    var capabilities: ElectronicBoardCapabilities { get }
    var positionUpdates: AsyncStream<String> { get }
    var connectionEvents: AsyncStream<ElectronicBoardConnectionEvent> { get }

    func connect() async throws
    func disconnect() async
    func enableRealtimeUpdates() async throws

    func setLEDs(_ frame: ElectronicBoardLEDFrame) async throws
    func batteryStatus(timeout: Duration) async throws -> ElectronicBoardBatteryStatus
    func importStoredGames(timeout: Duration) async throws -> [ElectronicBoardStoredGame]
    func setAutomaticPosition(fen: String, force: Bool) async throws
    func stopAutomaticMovement() async throws
    func pieceIdentities(timeout: Duration) async throws -> [ElectronicPieceIdentity]
}

extension ElectronicChessBoard {
    func setLEDs(_ frame: ElectronicBoardLEDFrame) async throws {
        // A board without the .leds capability intentionally ignores LED frames.
        // Callers can keep game flow vendor-neutral without requiring a fake LED implementation.
        _ = frame
    }

    func batteryStatus(timeout: Duration = .seconds(3)) async throws -> ElectronicBoardBatteryStatus {
        _ = timeout
        throw ElectronicBoardError.unsupportedCapability("batería")
    }

    func importStoredGames(timeout: Duration = .seconds(120)) async throws -> [ElectronicBoardStoredGame] {
        _ = timeout
        throw ElectronicBoardError.unsupportedCapability("almacenamiento de partidas")
    }

    func setAutomaticPosition(fen: String, force: Bool = true) async throws {
        _ = fen
        _ = force
        throw ElectronicBoardError.unsupportedCapability("movimiento automático")
    }

    func stopAutomaticMovement() async throws {
        throw ElectronicBoardError.unsupportedCapability("movimiento automático")
    }

    func pieceIdentities(timeout: Duration = .seconds(3)) async throws -> [ElectronicPieceIdentity] {
        _ = timeout
        throw ElectronicBoardError.unsupportedCapability("identificación de piezas")
    }
}

protocol ElectronicChessBoardDiscovery: Sendable {
    func scan() -> AsyncStream<ElectronicBoardDescriptor>
}

/// Multiplexes any number of vendor-specific discovery implementations into one
/// stream. BoardController therefore does not need to know which manufacturers
/// are supported by the application.
struct CompositeElectronicBoardDiscovery: ElectronicChessBoardDiscovery {
    let discoveries: [any ElectronicChessBoardDiscovery]

    func scan() -> AsyncStream<ElectronicBoardDescriptor> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for discovery in discoveries {
                        group.addTask {
                            for await descriptor in discovery.scan() {
                                guard !Task.isCancelled else { return }
                                continuation.yield(descriptor)
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
}

protocol ElectronicBoardAdapterFactory: Sendable {
    var identifier: String { get }
    var supportedBoards: [ElectronicBoardSupport] { get }
    func canCreateBoard(for descriptor: ElectronicBoardDescriptor) -> Bool
    func makeBoard(for descriptor: ElectronicBoardDescriptor) throws -> any ElectronicChessBoard
}

extension ElectronicBoardAdapterFactory {
    var supportedBoards: [ElectronicBoardSupport] { [] }
}

struct ElectronicBoardAdapterRegistry: Sendable {
    private let factories: [any ElectronicBoardAdapterFactory]

    init(factories: [any ElectronicBoardAdapterFactory]) {
        self.factories = factories
    }

    var supportedBoards: [ElectronicBoardSupport] {
        factories.flatMap(\.supportedBoards)
    }

    func makeBoard(for descriptor: ElectronicBoardDescriptor) throws -> any ElectronicChessBoard {
        guard let factory = factories.first(where: { $0.canCreateBoard(for: descriptor) }) else {
            throw ElectronicBoardError.noAdapter(descriptor.name)
        }
        return try factory.makeBoard(for: descriptor)
    }
}
