import ChessKit
import Foundation

enum StockfishEngineError: LocalizedError, Sendable {
    case initialization(String)
    case search(String)

    var errorDescription: String? {
        switch self {
        case let .initialization(message), let .search(message):
            message
        }
    }
}

enum StockfishScore: Equatable, Sendable {
    case centipawns(Int)
    case mate(Int)
    case tablebase(Int)

    var displayText: String {
        switch self {
        case let .centipawns(value):
            return String(format: "%+.2f", Double(value) / 100.0)
        case let .mate(plies):
            let moves = max(1, (abs(plies) + 1) / 2)
            return plies >= 0 ? "Mate en \(moves)" : "Recibe mate en \(moves)"
        case let .tablebase(plies):
            return plies >= 0 ? "Tablebase: gana" : "Tablebase: pierde"
        }
    }

    var inverted: StockfishScore {
        switch self {
        case let .centipawns(value): .centipawns(-value)
        case let .mate(plies): .mate(-plies)
        case let .tablebase(plies): .tablebase(-plies)
        }
    }

    /// Common ordering scale used only for coaching comparisons. Centipawn
    /// scores keep their natural units; forced mates/tablebase outcomes sit far
    /// outside normal evaluation values so losing a forced result is classified
    /// decisively while differences in mate distance remain small.
    var coachingValue: Int {
        switch self {
        case let .centipawns(value):
            return value
        case let .mate(plies):
            if plies >= 0 {
                return 100_000 - min(abs(plies), 10_000)
            }
            return -100_000 + min(abs(plies), 10_000)
        case let .tablebase(plies):
            if plies >= 0 {
                return 50_000 - min(abs(plies), 10_000)
            }
            return -50_000 + min(abs(plies), 10_000)
        }
    }

    func centipawnLoss(comparedWith best: StockfishScore) -> Int? {
        guard case let .centipawns(bestValue) = best,
              case let .centipawns(candidateValue) = self
        else { return nil }

        return max(0, bestValue - candidateValue)
    }
}

struct StockfishAnalysis: Equatable, Sendable {
    let version: String
    let bestMove: String
    let score: StockfishScore
    let depth: Int
    let nodes: UInt64

    var summary: String {
        "\(version) · \(bestMove) · \(score.displayText) · profundidad \(depth) · \(nodes) nodos"
    }
}

struct StockfishMoveHint: Equatable, Sendable {
    let square: Square
    let quality: MoveQuality
    let moverScore: StockfishScore
    let centipawnLoss: Int?

    func ledHint(for mode: AssistanceMode) -> LEDHint? {
        guard let pattern = mode.ledPattern(for: quality) else { return nil }
        return LEDHint(square: square, pattern: pattern)
    }

    func detailText(for mode: AssistanceMode) -> String {
        let pattern = mode.ledPattern(for: quality) ?? quality.ledPattern

        if mode == .blunders {
            let label = quality == .blunder ? "blunder" : "legal"
            return "\(square.notation) \(pattern.displayText)/\(label)"
        }

        if let centipawnLoss {
            return "\(square.notation) \(pattern.displayText)/\(quality.displayText) (−\(centipawnLoss) cp)"
        }
        return "\(square.notation) \(pattern.displayText)/\(quality.displayText)"
    }
}

struct StockfishCoachingResult: Equatable, Sendable {
    let baseline: StockfishAnalysis
    let hints: [StockfishMoveHint]
    let analyzedNodes: UInt64
}

private final class StockfishNativeHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        CCStockfishDestroy(pointer)
    }
}

actor StockfishEngine {
    static let shared = StockfishEngine()

    private var handle: StockfishNativeHandle?

    let defaultNodeLimit: UInt64

    init(defaultNodeLimit: UInt64 = 60_000) {
        self.defaultNodeLimit = defaultNodeLimit
    }

    func version() -> String {
        String(cString: CCStockfishVersion())
    }

    func analyze(
        fen: String,
        nodeLimit: UInt64? = nil,
        strength: StockfishStrength = .full
    ) throws -> StockfishAnalysis {
        let requestedFEN = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedFEN.isEmpty, Position(fen: requestedFEN) != nil else {
            throw StockfishEngineError.search("FEN no válida. Corrige la posición antes de analizar.")
        }

        let native = try ensureEngine()

        var scoreKind: Int32 = 0
        var scoreValue: Int32 = 0
        var depth: Int32 = 0
        var nodes: UInt64 = 0
        var bestMove = [CChar](repeating: 0, count: 32)
        var error = [CChar](repeating: 0, count: 512)

        let succeeded = requestedFEN.withCString { fenPointer in
            bestMove.withUnsafeMutableBufferPointer { bestBuffer in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    CCStockfishSearchV2(
                        native,
                        fenPointer,
                        nodeLimit ?? defaultNodeLimit,
                        0,
                        Int32(strength.elo ?? 0),
                        &scoreKind,
                        &scoreValue,
                        &depth,
                        &nodes,
                        bestBuffer.baseAddress,
                        bestBuffer.count,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }

        guard succeeded else {
            throw StockfishEngineError.search(decodeCString(error))
        }

        let score: StockfishScore
        switch scoreKind {
        case Int32(CCStockfishScoreCentipawns):
            score = .centipawns(Int(scoreValue))
        case Int32(CCStockfishScoreMate):
            score = .mate(Int(scoreValue))
        case Int32(CCStockfishScoreTablebase):
            score = .tablebase(Int(scoreValue))
        default:
            throw StockfishEngineError.search("Stockfish devolvió un tipo de evaluación desconocido.")
        }

        return StockfishAnalysis(
            version: version(),
            bestMove: decodeCString(bestMove),
            score: score,
            depth: Int(depth),
            nodes: nodes
        )
    }

    func stop() {
        if let handle {
            CCStockfishStop(handle.pointer)
        }
    }

    private func ensureEngine() throws -> OpaquePointer {
        if let handle {
            return handle.pointer
        }

        guard let resourcePath = Bundle.main.resourceURL?.path else {
            throw StockfishEngineError.initialization("No se pudo localizar el directorio de recursos de la aplicación.")
        }

        var error = [CChar](repeating: 0, count: 512)
        let created = resourcePath.withCString { pathPointer in
            error.withUnsafeMutableBufferPointer { errorBuffer in
                CCStockfishCreate(
                    pathPointer,
                    1,
                    32,
                    errorBuffer.baseAddress,
                    errorBuffer.count
                )
            }
        }

        guard let created else {
            throw StockfishEngineError.initialization(decodeCString(error))
        }

        let nativeHandle = StockfishNativeHandle(created)
        handle = nativeHandle
        return nativeHandle.pointer
    }
}

extension StockfishEngine: AnalysisMoveSearching {
    func bestMove(
        fen: String,
        nodeLimit: UInt64,
        strength: StockfishStrength
    ) async throws -> String {
        try analyze(
            fen: fen,
            nodeLimit: nodeLimit,
            strength: strength
        ).bestMove
    }
}

/// Stockfish's playing adapter deliberately returns only a move. Objective
/// scores remain private to `StockfishEngine` and the analysis/coaching paths.
actor StockfishOpponentEngine: ChessPlayingEngine {
    nonisolated let kind = OpponentEngineKind.stockfish18

    private let engine: StockfishEngine
    private let nodeLimit: UInt64

    init(
        engine: StockfishEngine = StockfishEngine(defaultNodeLimit: 80_000),
        nodeLimit: UInt64 = 80_000
    ) {
        self.engine = engine
        self.nodeLimit = nodeLimit
    }

    func move(for request: ChessPlayingRequest) async throws -> ChessPlayingMove {
        guard request.configuration.kind == kind else {
            throw ChessPlayingEngineError.inference("La configuración no corresponde a Stockfish 18.")
        }

        try Task.checkCancellation()
        let analysis = try await engine.analyze(
            fen: request.fen,
            nodeLimit: nodeLimit,
            strength: request.configuration.stockfishStrength ?? .full
        )
        try Task.checkCancellation()
        _ = try OpponentMoveValidator.validatedMove(uci: analysis.bestMove, fen: request.fen)
        return ChessPlayingMove(uci: analysis.bestMove)
    }

    func cancel() async {
        await engine.stop()
    }
}

private func decodeCString(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

actor StockfishMoveCoach {
    private static let promotionKinds: [Piece.Kind] = [.queen, .rook, .bishop, .knight]

    private let engine: StockfishEngine
    private let baselineNodeLimit: UInt64
    private let candidateNodeLimit: UInt64
    private let thresholds: MoveQualityThresholds

    private var cachedBaselineFEN: String?
    private var cachedBaseline: StockfishAnalysis?

    init(
        engine: StockfishEngine = .shared,
        baselineNodeLimit: UInt64 = 40_000,
        candidateNodeLimit: UInt64 = 12_000,
        thresholds: MoveQualityThresholds = MoveQualityThresholds()
    ) {
        self.engine = engine
        self.baselineNodeLimit = baselineNodeLimit
        self.candidateNodeLimit = candidateNodeLimit
        self.thresholds = thresholds
    }

    func prepare(fen: String) async {
        _ = try? await baseline(for: fen)
    }

    func evaluate(
        fen: String,
        source: Square,
        legalTargets: [Square]
    ) async throws -> StockfishCoachingResult {
        guard !legalTargets.isEmpty else {
            throw StockfishEngineError.search("La pieza levantada no tiene destinos legales que analizar.")
        }

        let baseline = try await baseline(for: fen)
        var hints: [StockfishMoveHint] = []
        var analyzedNodes = baseline.nodes

        for target in legalTargets.sorted(by: { $0.notation < $1.notation }) {
            try Task.checkCancellation()

            let candidateFENs = try resultingFENs(
                from: fen,
                source: source,
                target: target
            )

            var bestMoverScore: StockfishScore?

            for candidateFEN in candidateFENs {
                try Task.checkCancellation()
                let analysis = try await engine.analyze(
                    fen: candidateFEN,
                    nodeLimit: candidateNodeLimit
                )
                analyzedNodes += analysis.nodes

                // After the candidate move, Stockfish evaluates from the
                // opponent's side-to-move. Invert it back to the player who
                // lifted the piece so every score shares the baseline POV.
                let moverScore = analysis.score.inverted
                if bestMoverScore == nil || moverScore.coachingValue > bestMoverScore!.coachingValue {
                    bestMoverScore = moverScore
                }
            }

            guard let moverScore = bestMoverScore else {
                throw StockfishEngineError.search("No se pudo evaluar el destino \(target.notation).")
            }

            let coachingLoss = max(0, baseline.score.coachingValue - moverScore.coachingValue)
            let quality = thresholds.classify(loss: coachingLoss)
            let exactCentipawnLoss = moverScore.centipawnLoss(comparedWith: baseline.score)

            hints.append(
                StockfishMoveHint(
                    square: target,
                    quality: quality,
                    moverScore: moverScore,
                    centipawnLoss: exactCentipawnLoss
                )
            )
        }

        return StockfishCoachingResult(
            baseline: baseline,
            hints: hints,
            analyzedNodes: analyzedNodes
        )
    }

    private func baseline(for fen: String) async throws -> StockfishAnalysis {
        if cachedBaselineFEN == fen, let cachedBaseline {
            return cachedBaseline
        }

        let analysis = try await engine.analyze(fen: fen, nodeLimit: baselineNodeLimit)
        cachedBaselineFEN = fen
        cachedBaseline = analysis
        return analysis
    }

    private func resultingFENs(
        from fen: String,
        source: Square,
        target: Square
    ) throws -> [String] {
        guard let position = Position(fen: fen) else {
            throw StockfishEngineError.search("No se pudo reconstruir la posición lógica para el coaching.")
        }

        var board = Board(position: position)
        guard board.move(pieceAt: source, to: target) != nil else {
            throw StockfishEngineError.search("Stockfish recibió un destino que ChessKit ya no considera legal.")
        }

        guard case .promotion = board.state else {
            return [board.position.fen]
        }

        var promotionFENs: [String] = []
        for kind in Self.promotionKinds {
            var promotedBoard = Board(position: position)
            guard promotedBoard.move(pieceAt: source, to: target) != nil,
                  case let .promotion(promotionMove) = promotedBoard.state
            else { continue }

            _ = promotedBoard.completePromotion(of: promotionMove, to: kind)
            promotionFENs.append(promotedBoard.position.fen)
        }

        guard !promotionFENs.isEmpty else {
            throw StockfishEngineError.search("No se pudieron generar las variantes de promoción para \(target.notation).")
        }

        return promotionFENs
    }
}
