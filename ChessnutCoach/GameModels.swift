import ChessKit
import Foundation

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
    var endedAt: Date?
    var moves: [GameMoveRecord]
    var status: GameLifecycleStatus
    var result: GameResult

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        initialFEN: String,
        endedAt: Date? = nil,
        moves: [GameMoveRecord] = [],
        status: GameLifecycleStatus = .playing,
        result: GameResult = .unfinished
    ) {
        self.id = id
        self.startedAt = startedAt
        self.initialFEN = initialFEN
        self.endedAt = endedAt
        self.moves = moves
        self.status = status
        self.result = result
    }

    var moveCount: Int { moves.count }
}

enum AssistanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case legalMoves
    case simulatedQuality

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .off:
            "Sin ayuda"
        case .legalMoves:
            "Movimientos legales"
        case .simulatedQuality:
            "Calidad simulada"
        }
    }

    var detailText: String {
        switch self {
        case .off:
            "No ilumina destinos al levantar una pieza."
        case .legalMoves:
            "Ilumina todos los destinos legales de forma fija."
        case .simulatedQuality:
            "Prueba el futuro sistema de calidad: fijo, parpadeo lento y parpadeo rápido."
        }
    }
}

struct AssistanceSettings: Equatable, Codable, Sendable {
    var white: AssistanceMode
    var black: AssistanceMode

    init(
        white: AssistanceMode = .simulatedQuality,
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

    var simulatedQualityText: String {
        switch self {
        case .steady: "mejor"
        case .slowBlink: "jugable"
        case .fastBlink: "evitar"
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
        case .off:
            return []

        case .legalMoves:
            return sortedTargets.map { LEDHint(square: $0, pattern: .steady) }

        case .simulatedQuality:
            guard !sortedTargets.isEmpty else { return [] }
            guard sortedTargets.count > 1 else {
                return [LEDHint(square: sortedTargets[0], pattern: .steady)]
            }

            return sortedTargets.enumerated().map { index, square in
                let pattern: LEDPattern

                if index == 0 {
                    pattern = .steady
                } else if index == sortedTargets.count - 1 {
                    pattern = .fastBlink
                } else {
                    pattern = .slowBlink
                }

                return LEDHint(square: square, pattern: pattern)
            }
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
