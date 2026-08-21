import ChessKit
import Foundation

enum ChessnutAppPhase: Equatable, Sendable {
    case active
    case inactive
    case background
}

struct ChessnutLifecycleDirective: Equatable, Sendable {
    let invalidateTransientAssistance: Bool
    let requestFreshBoardSnapshot: Bool
    let probeConnection: Bool

    static let none = ChessnutLifecycleDirective(
        invalidateTransientAssistance: false,
        requestFreshBoardSnapshot: false,
        probeConnection: false
    )
}

struct ChessnutSessionLifecycle: Equatable, Sendable {
    private(set) var phase: ChessnutAppPhase = .active

    mutating func transition(to newPhase: ChessnutAppPhase) -> ChessnutLifecycleDirective {
        guard newPhase != phase else { return .none }
        phase = newPhase

        switch newPhase {
        case .inactive:
            return .none
        case .background:
            return ChessnutLifecycleDirective(
                invalidateTransientAssistance: true,
                requestFreshBoardSnapshot: false,
                probeConnection: false
            )
        case .active:
            return ChessnutLifecycleDirective(
                invalidateTransientAssistance: true,
                requestFreshBoardSnapshot: true,
                probeConnection: true
            )
        }
    }
}

enum GameLifecycleStatus: String, Codable, Sendable {
    case playing
    case finished
    case aborted
}

enum GameEndReason: String, Codable, Sendable {
    case checkmate
    case resignation
}

enum GameDrawReason: String, Codable, Sendable {
    case stalemate
    case fiftyMoves
    case repetition
    case insufficientMaterial
    case agreement
}

enum GameResult: Equatable, Codable, Sendable {
    case unfinished
    case whiteWin(reason: GameEndReason)
    case blackWin(reason: GameEndReason)
    case draw(reason: GameDrawReason)

    var pgnValue: String {
        switch self {
        case .unfinished:
            "*"
        case .whiteWin:
            "1-0"
        case .blackWin:
            "0-1"
        case .draw:
            "1/2-1/2"
        }
    }

    var displayText: String {
        switch self {
        case .unfinished:
            "En juego"
        case let .whiteWin(reason):
            "1-0 · Blancas ganan por \(reason.displayText)"
        case let .blackWin(reason):
            "0-1 · Negras ganan por \(reason.displayText)"
        case let .draw(reason):
            "½-½ · Tablas por \(reason.displayText)"
        }
    }
}

extension GameEndReason {
    var displayText: String {
        switch self {
        case .checkmate: "jaque mate"
        case .resignation: "abandono"
        }
    }
}

extension GameDrawReason {
    var displayText: String {
        switch self {
        case .stalemate: "ahogado"
        case .fiftyMoves: "regla de 50 movimientos"
        case .repetition: "triple repetición"
        case .insufficientMaterial: "material insuficiente"
        case .agreement: "acuerdo"
        }
    }
}

struct GameMoveRecord: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let ply: Int
    let san: String
    let lan: String
    let from: String
    let to: String
    let fenBefore: String
    let fenAfter: String
    let playedAt: Date
    let promotion: String?

    init(
        id: UUID = UUID(),
        ply: Int,
        san: String,
        lan: String,
        from: String,
        to: String,
        fenBefore: String,
        fenAfter: String,
        playedAt: Date = Date(),
        promotion: String? = nil
    ) {
        self.id = id
        self.ply = ply
        self.san = san
        self.lan = lan
        self.from = from
        self.to = to
        self.fenBefore = fenBefore
        self.fenAfter = fenAfter
        self.playedAt = playedAt
        self.promotion = promotion
    }
}

struct GameRecord: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let initialFEN: String
    var whitePlayer: String
    var blackPlayer: String
    var endedAt: Date?
    var moves: [GameMoveRecord]
    var status: GameLifecycleStatus
    var result: GameResult

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        initialFEN: String,
        whitePlayer: String = "Blancas",
        blackPlayer: String = "Negras",
        endedAt: Date? = nil,
        moves: [GameMoveRecord] = [],
        status: GameLifecycleStatus = .playing,
        result: GameResult = .unfinished
    ) {
        self.id = id
        self.startedAt = startedAt
        self.initialFEN = initialFEN
        self.whitePlayer = whitePlayer
        self.blackPlayer = blackPlayer
        self.endedAt = endedAt
        self.moves = moves
        self.status = status
        self.result = result
    }

    var moveCount: Int { moves.count }
    var fullMoveCount: Int { (moves.count + 1) / 2 }

    var lastActivityAt: Date {
        endedAt ?? moves.last?.playedAt ?? startedAt
    }

    var duration: TimeInterval {
        max(0, lastActivityAt.timeIntervalSince(startedAt))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case initialFEN
        case whitePlayer
        case blackPlayer
        case endedAt
        case moves
        case status
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        initialFEN = try container.decode(String.self, forKey: .initialFEN)
        whitePlayer = try container.decodeIfPresent(String.self, forKey: .whitePlayer) ?? "Blancas"
        blackPlayer = try container.decodeIfPresent(String.self, forKey: .blackPlayer) ?? "Negras"
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        moves = try container.decode([GameMoveRecord].self, forKey: .moves)
        status = try container.decode(GameLifecycleStatus.self, forKey: .status)
        result = try container.decode(GameResult.self, forKey: .result)
    }
}

enum AssistanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case legalMoves
    case stockfishQuality

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .off:
            "Sin ayuda"
        case .legalMoves:
            "Movimientos legales"
        case .stockfishQuality:
            "Calidad Stockfish"
        }
    }

    var detailText: String {
        switch self {
        case .off:
            "No ilumina destinos al levantar una pieza."
        case .legalMoves:
            "Ilumina todos los destinos legales de forma fija."
        case .stockfishQuality:
            "Stockfish 18 compara cada destino con la mejor jugada de la posición: fijo = bueno, lento = aceptable, rápido = blunder."
        }
    }
}

struct AssistanceSettings: Equatable, Codable, Sendable {
    var white: AssistanceMode
    var black: AssistanceMode

    init(
        white: AssistanceMode = .stockfishQuality,
        black: AssistanceMode = .off
    ) {
        self.white = white
        self.black = black
    }

    func mode(for color: Piece.Color) -> AssistanceMode {
        color == .white ? white : black
    }
}

enum LEDPattern: String, CaseIterable, Codable, Sendable {
    case steady
    case slowBlink
    case fastBlink

    var displayText: String {
        switch self {
        case .steady: "fijo"
        case .slowBlink: "lento"
        case .fastBlink: "rápido"
        }
    }

    func isLit(at tick: Int) -> Bool {
        switch self {
        case .steady:
            true
        case .slowBlink:
            (tick / 3).isMultiple(of: 2)
        case .fastBlink:
            tick.isMultiple(of: 2)
        }
    }
}

enum MoveQuality: String, CaseIterable, Codable, Sendable {
    case good
    case acceptable
    case blunder

    var displayText: String {
        switch self {
        case .good: "bueno"
        case .acceptable: "aceptable"
        case .blunder: "blunder"
        }
    }

    var ledPattern: LEDPattern {
        switch self {
        case .good: .steady
        case .acceptable: .slowBlink
        case .blunder: .fastBlink
        }
    }
}

struct MoveQualityThresholds: Equatable, Sendable {
    var goodMaxCentipawnLoss: Int = 50
    var acceptableMaxCentipawnLoss: Int = 200

    func classify(loss: Int) -> MoveQuality {
        let normalizedLoss = max(0, loss)
        if normalizedLoss <= goodMaxCentipawnLoss {
            return .good
        }
        if normalizedLoss <= acceptableMaxCentipawnLoss {
            return .acceptable
        }
        return .blunder
    }
}

struct LEDHint: Equatable, Sendable {
    let square: Square
    let pattern: LEDPattern
}

enum AssistanceHintPlanner {
    static func hints(
        for legalTargets: [Square],
        mode: AssistanceMode
    ) -> [LEDHint] {
        let sortedTargets = legalTargets.sorted { $0.notation < $1.notation }

        switch mode {
        case .off, .stockfishQuality:
            return []
        case .legalMoves:
            return sortedTargets.map { LEDHint(square: $0, pattern: .steady) }
        }
    }
}

enum LEDHintFrameComposer {
    static func activeSquares(for hints: [LEDHint], tick: Int) -> [Square] {
        hints.compactMap { hint in
            hint.pattern.isLit(at: tick) ? hint.square : nil
        }
    }
}

extension Piece.Kind {
    var promotionSymbol: String? {
        switch self {
        case .queen: "Q"
        case .rook: "R"
        case .bishop: "B"
        case .knight: "N"
        case .pawn, .king: nil
        }
    }
}
