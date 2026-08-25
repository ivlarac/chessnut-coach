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

    var selectionLabel: String {
        switch self {
        case .stockfish18: "Stockfish 18"
        case .maia3: "Maia 3 · estilo humano"
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

    var isPlayableInThisBuild: Bool { true }
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
    /// Chronological FEN positions, including the initial and current position.
    /// Maia 3 consumes at most the eight most recent entries.
    let positionHistory: [String]
    let configuration: OpponentEngineConfiguration

    init(
        fen: String,
        moveHistory: [String],
        positionHistory: [String] = [],
        configuration: OpponentEngineConfiguration
    ) {
        self.fen = fen
        self.moveHistory = moveHistory
        self.positionHistory = positionHistory
        self.configuration = configuration
    }
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

/// Deterministic policy sampling used by the Core ML Maia adapter.
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

struct Maia3PolicyInput: Equatable, Sendable {
    static let historyLength = 8
    static let squareCount = 64
    static let pieceChannelCount = 12
    static let featureCount = historyLength * pieceChannelCount

    let boardHistory: [Float]
    let selfRating: Float
    let opponentRating: Float
}

protocol Maia3PolicyPredicting: Sendable {
    func predict(input: Maia3PolicyInput) async throws -> [Double]
}

enum Maia3InputEncoder {
    static func encode(
        currentFEN: String,
        positionHistory: [String],
        rating: Int
    ) throws -> Maia3PolicyInput {
        guard Position(fen: currentFEN) != nil else {
            throw ChessPlayingEngineError.invalidPosition
        }

        var history: [Position] = []
        for fen in positionHistory {
            guard let position = Position(fen: fen) else {
                throw ChessPlayingEngineError.invalidPosition
            }
            history.append(position)
        }
        if history.last?.fen != currentFEN, let current = Position(fen: currentFEN) {
            history.append(current)
        }
        if history.isEmpty, let current = Position(fen: currentFEN) {
            history = [current]
        }

        history = Array(history.suffix(Maia3PolicyInput.historyLength))
        guard let earliest = history.first else {
            throw ChessPlayingEngineError.invalidPosition
        }
        while history.count < Maia3PolicyInput.historyLength {
            history.insert(earliest, at: 0)
        }

        var values = Array(
            repeating: Float.zero,
            count: Maia3PolicyInput.squareCount * Maia3PolicyInput.featureCount
        )

        for (historyIndex, position) in history.enumerated() {
            for piece in position.pieces {
                let squareIndex = modelSquareIndex(
                    for: piece.square,
                    sideToMove: position.sideToMove
                )
                let channel = modelPieceChannel(
                    for: piece,
                    sideToMove: position.sideToMove
                )
                let featureIndex = historyIndex * Maia3PolicyInput.pieceChannelCount + channel
                values[squareIndex * Maia3PolicyInput.featureCount + featureIndex] = 1
            }
        }

        return Maia3PolicyInput(
            boardHistory: values,
            selfRating: Float(rating),
            opponentRating: Float(rating)
        )
    }

    private static func modelSquareIndex(
        for square: Square,
        sideToMove: Piece.Color
    ) -> Int {
        guard sideToMove == .black else { return square.rawValue }
        let mirroredRank = 9 - square.rank.value
        return (mirroredRank - 1) * 8 + (square.file.number - 1)
    }

    private static func modelPieceChannel(
        for piece: Piece,
        sideToMove: Piece.Color
    ) -> Int {
        let kind: Int = switch piece.kind {
        case .pawn: 0
        case .knight: 1
        case .bishop: 2
        case .rook: 3
        case .queen: 4
        case .king: 5
        }
        let modelColor = sideToMove == .black ? piece.color.opposite : piece.color
        return kind + (modelColor == .black ? 6 : 0)
    }
}

enum Maia3MoveVocabulary {
    static let count = 4_352
    private static let promotionKinds: [Piece.Kind] = [.queen, .rook, .bishop, .knight]

    static func legalMoves(fen: String) throws -> [String: Int] {
        guard let position = Position(fen: fen) else {
            throw ChessPlayingEngineError.invalidPosition
        }

        let sideToMove = position.sideToMove
        let board = Board(position: position)
        var result: [String: Int] = [:]

        for piece in position.pieces where piece.color == sideToMove {
            for target in board.legalMoves(forPieceAt: piece.square) {
                var candidate = board
                guard candidate.move(pieceAt: piece.square, to: target) != nil else { continue }

                let base = piece.square.notation + target.notation
                if case .promotion = candidate.state {
                    for kind in promotionKinds {
                        let uci = base + promotionSymbol(for: kind)
                        if let index = vocabularyIndex(for: uci, sideToMove: sideToMove) {
                            result[uci] = index
                        }
                    }
                } else if let index = vocabularyIndex(for: base, sideToMove: sideToMove) {
                    result[base] = index
                }
            }
        }

        return result
    }

    static func vocabularyIndex(for uci: String, sideToMove: Piece.Color) -> Int? {
        let normalized = sideToMove == .black ? mirrorRanks(in: uci) : uci.lowercased()
        guard let move = OTBExpectedMove(uci: normalized) else { return nil }

        if let promotion = move.promotion {
            guard move.from.rank.value == 7, move.to.rank.value == 8,
                  let promotionIndex = promotionKinds.firstIndex(of: promotion)
            else { return nil }
            return 4_096
                + (move.from.file.number - 1) * 32
                + (move.to.file.number - 1) * 4
                + promotionIndex
        }

        return move.from.rawValue * 64 + move.to.rawValue
    }

    private static func mirrorRanks(in uci: String) -> String {
        let characters = Array(uci.lowercased())
        guard characters.count == 4 || characters.count == 5,
              let fromRank = characters[1].wholeNumberValue,
              let toRank = characters[3].wholeNumberValue
        else { return uci.lowercased() }

        var mirrored = characters
        mirrored[1] = Character(String(9 - fromRank))
        mirrored[3] = Character(String(9 - toRank))
        return String(mirrored)
    }

    private static func promotionSymbol(for kind: Piece.Kind) -> String {
        switch kind {
        case .queen: "q"
        case .rook: "r"
        case .bishop: "b"
        case .knight: "n"
        case .pawn, .king: ""
        }
    }
}

actor Maia3OpponentEngine: ChessPlayingEngine {
    nonisolated let kind = OpponentEngineKind.maia3

    private let predictor: any Maia3PolicyPredicting
    private let randomUnitInterval: (@Sendable () -> Double)?
    private var generation: UInt64 = 0

    init(
        predictor: any Maia3PolicyPredicting,
        randomUnitInterval: (@Sendable () -> Double)? = nil
    ) {
        self.predictor = predictor
        self.randomUnitInterval = randomUnitInterval
    }

    func move(for request: ChessPlayingRequest) async throws -> ChessPlayingMove {
        guard request.configuration.kind == kind else {
            throw ChessPlayingEngineError.inference("La configuración no corresponde a Maia 3.")
        }
        let strength = request.configuration.maia3Strength ?? Maia3Strength(rating: 800)
        generation &+= 1
        let requestGeneration = generation

        try Task.checkCancellation()
        let input = try Maia3InputEncoder.encode(
            currentFEN: request.fen,
            positionHistory: request.positionHistory,
            rating: strength.rating
        )
        let logits = try await predictor.predict(input: input)
        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        guard logits.count == Maia3MoveVocabulary.count else {
            throw ChessPlayingEngineError.inference(
                "Maia 3 devolvió \(logits.count) logits; se esperaban \(Maia3MoveVocabulary.count)."
            )
        }

        let indexedMoves = try Maia3MoveVocabulary.legalMoves(fen: request.fen)
        let legalMoves = Set(indexedMoves.keys)
        let legalLogits = Dictionary(uniqueKeysWithValues: indexedMoves.map { move, index in
            (move, logits[index])
        })
        let selected = try MaiaMoveSampler.sample(
            logits: legalLogits,
            legalMoves: legalMoves,
            temperature: strength.temperature,
            topP: strength.topP,
            unitInterval: randomValue(seed: strength.seed, fen: request.fen)
        )

        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        _ = try OpponentMoveValidator.validatedMove(uci: selected, fen: request.fen)
        return ChessPlayingMove(uci: selected)
    }

    func cancel() async {
        generation &+= 1
    }

    private func randomValue(seed: UInt64?, fen: String) -> Double {
        if let randomUnitInterval {
            return min(max(randomUnitInterval(), 0), 1.0.nextDown)
        }
        guard let seed else { return Double.random(in: 0..<1) }

        var hash = seed ^ 0xcbf29ce484222325
        for byte in fen.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        hash &+= 0x9e3779b97f4a7c15
        var mixed = hash
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58476d1ce4e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d049bb133111eb
        mixed ^= mixed >> 31
        return Double(mixed >> 11) / Double(UInt64(1) << 53)
    }
}
