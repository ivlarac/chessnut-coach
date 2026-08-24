import ChessKit
import Foundation

enum OpponentEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case stockfish18
    case maia3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stockfish18: "Stockfish 18"
        case .maia3: "Maia 3"
        }
    }

    var styleDescription: String {
        switch self {
        case .stockfish18:
            "Motor de ajedrez debilitado mediante UCI_Elo; incluso su nivel mínimo sigue siendo exigente."
        case .maia3:
            "Modelo que intenta reproducir decisiones humanas condicionadas por nivel, no encontrar siempre la mejor jugada."
        }
    }

    /// Maia3's official code and weights are AGPL-3.0. Shipping a converted
    /// model requires an explicit project-wide licensing/distribution decision,
    /// so it must not be presented as playable until that decision is made.
    var isPlayableInThisBuild: Bool {
        switch self {
        case .stockfish18: true
        case .maia3: false
        }
    }
}

struct Maia3Strength: Equatable, Codable, Sendable {
    static let minimumRating = 600
    static let maximumRating = 2_600
    static let ratingStep = 100

    let rating: Int
    let temperature: Double
    let topP: Double
    let seed: UInt64?

    init(
        rating: Int,
        temperature: Double = 1.0,
        topP: Double = 0.95,
        seed: UInt64? = nil
    ) {
        let clamped = min(max(rating, Self.minimumRating), Self.maximumRating)
        self.rating = Self.minimumRating
            + ((clamped - Self.minimumRating) / Self.ratingStep) * Self.ratingStep
        self.temperature = max(0, temperature)
        self.topP = min(max(topP, 0.01), 1)
        self.seed = seed
    }

    var displayText: String { "Nivel humano ≈ \(rating)" }
}

struct OpponentEngineConfiguration: Equatable, Codable, Sendable {
    let kind: OpponentEngineKind
    let stockfishStrength: StockfishStrength?
    let maia3Strength: Maia3Strength?

    static func stockfish(_ strength: StockfishStrength) -> Self {
        Self(kind: .stockfish18, stockfishStrength: strength, maia3Strength: nil)
    }

    static func maia3(_ strength: Maia3Strength) -> Self {
        Self(kind: .maia3, stockfishStrength: nil, maia3Strength: strength)
    }

    var displayName: String { kind.displayName }

    var strengthDisplayText: String {
        switch kind {
        case .stockfish18:
            (stockfishStrength ?? .full).displayText
        case .maia3:
            (maia3Strength ?? Maia3Strength(rating: 800)).displayText
        }
    }

    private init(
        kind: OpponentEngineKind,
        stockfishStrength: StockfishStrength?,
        maia3Strength: Maia3Strength?
    ) {
        self.kind = kind
        self.stockfishStrength = stockfishStrength
        self.maia3Strength = maia3Strength
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case stockfishStrength
        case maia3Strength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(OpponentEngineKind.self, forKey: .kind)

        switch kind {
        case .stockfish18:
            self = .stockfish(
                try container.decodeIfPresent(StockfishStrength.self, forKey: .stockfishStrength)
                    ?? .full
            )
        case .maia3:
            self = .maia3(
                try container.decodeIfPresent(Maia3Strength.self, forKey: .maia3Strength)
                    ?? Maia3Strength(rating: 800)
            )
        }
    }
}

struct ChessPlayingRequest: Equatable, Sendable {
    let fen: String
    let moveHistory: [String]
    let configuration: OpponentEngineConfiguration
}

struct ChessPlayingMove: Equatable, Sendable {
    let uci: String
}

enum ChessPlayingEngineError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case invalidPosition
    case noLegalMove
    case illegalMove(String)
    case inference(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .inference(message):
            message
        case .invalidPosition:
            "El motor rival recibió una posición no válida."
        case .noLegalMove:
            "El motor rival no encontró ningún movimiento legal."
        case let .illegalMove(uci):
            "El motor rival devolvió el movimiento ilegal \(uci)."
        }
    }
}

protocol ChessPlayingEngine: Sendable {
    var kind: OpponentEngineKind { get }

    func move(for request: ChessPlayingRequest) async throws -> ChessPlayingMove
    func cancel() async
}

enum OpponentMoveValidator {
    static func validatedMove(uci: String, fen: String) throws -> OTBExpectedMove {
        guard let position = Position(fen: fen) else {
            throw ChessPlayingEngineError.invalidPosition
        }
        guard let expected = OTBExpectedMove(uci: uci) else {
            throw ChessPlayingEngineError.illegalMove(uci)
        }

        var board = Board(position: position)
        guard board.move(pieceAt: expected.from, to: expected.to) != nil else {
            throw ChessPlayingEngineError.illegalMove(uci)
        }

        switch board.state {
        case let .promotion(move):
            guard let promotion = expected.promotion else {
                throw ChessPlayingEngineError.illegalMove(uci)
            }
            _ = board.completePromotion(of: move, to: promotion)
        default:
            guard expected.promotion == nil else {
                throw ChessPlayingEngineError.illegalMove(uci)
            }
        }

        return expected
    }
}

/// Deterministic policy sampling used by the future Core ML Maia adapter.
/// `unitInterval` is injected so tests do not depend on global randomness.
enum MaiaMoveSampler {
    static func sample(
        logits: [String: Double],
        legalMoves: Set<String>,
        temperature: Double,
        topP: Double,
        unitInterval: Double
    ) throws -> String {
        let legalLogits = logits
            .filter { legalMoves.contains($0.key) && $0.value.isFinite }
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }

        guard !legalLogits.isEmpty else {
            throw ChessPlayingEngineError.noLegalMove
        }
        guard temperature > 0 else {
            return legalLogits[0].key
        }

        let maximum = legalLogits[0].value
        let weights = legalLogits.map { exp(($0.value - maximum) / temperature) }
        let total = weights.reduce(0, +)
        guard total.isFinite, total > 0 else {
            throw ChessPlayingEngineError.inference("Maia 3 produjo una distribución de movimientos no válida.")
        }

        let probabilities = weights.map { $0 / total }
        let threshold = min(max(topP, 0.01), 1)
        var retainedCount = 0
        var cumulative = 0.0

        repeat {
            cumulative += probabilities[retainedCount]
            retainedCount += 1
        } while retainedCount < probabilities.count && cumulative < threshold

        let retainedTotal = probabilities.prefix(retainedCount).reduce(0, +)
        let target = min(max(unitInterval, 0), 1.0.nextDown) * retainedTotal
        var running = 0.0

        for index in 0..<retainedCount {
            running += probabilities[index]
            if target < running {
                return legalLogits[index].key
            }
        }

        return legalLogits[retainedCount - 1].key
    }
}
