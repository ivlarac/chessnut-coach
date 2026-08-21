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