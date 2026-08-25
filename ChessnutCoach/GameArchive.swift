import ChessKit
import Foundation

enum ReplayPieceColor: Equatable, Sendable {
    case white
    case black
}

struct ReplayPiece: Equatable, Sendable {
    let assetName: String
    let color: ReplayPieceColor
}

enum ChessBoardPerspective: Equatable, Sendable {
    case whiteAtBottom
    case blackAtBottom

    var opposite: Self {
        switch self {
        case .whiteAtBottom: .blackAtBottom
        case .blackAtBottom: .whiteAtBottom
        }
    }

    func boardPosition(
        displayRankIndex: Int,
        displayFileIndex: Int
    ) -> ChessBoardSquarePosition {
        precondition((0..<8).contains(displayRankIndex))
        precondition((0..<8).contains(displayFileIndex))

        return switch self {
        case .whiteAtBottom:
            ChessBoardSquarePosition(
                rankIndex: displayRankIndex,
                fileIndex: displayFileIndex
            )
        case .blackAtBottom:
            ChessBoardSquarePosition(
                rankIndex: 7 - displayRankIndex,
                fileIndex: 7 - displayFileIndex
            )
        }
    }

    func isLightSquare(displayRankIndex: Int, displayFileIndex: Int) -> Bool {
        let position = boardPosition(
            displayRankIndex: displayRankIndex,
            displayFileIndex: displayFileIndex
        )
        return (position.rankIndex + position.fileIndex).isMultiple(of: 2)
    }
}

struct ChessBoardSquarePosition: Equatable, Sendable {
    let rankIndex: Int
    let fileIndex: Int
}

enum GameReplay {
    static func fen(for record: GameRecord, afterPly ply: Int) -> String {
        guard ply > 0, !record.moves.isEmpty else { return record.initialFEN }
        return record.moves[min(ply, record.moves.count) - 1].fenAfter
    }

    static func move(for record: GameRecord, atPly ply: Int) -> GameMoveRecord? {
        guard ply > 0, ply <= record.moves.count else { return nil }
        return record.moves[ply - 1]
    }

    static func piece(in fen: String, rankIndex: Int, fileIndex: Int) -> ReplayPiece? {
        guard (0..<8).contains(rankIndex), (0..<8).contains(fileIndex) else { return nil }
        let rows = fen.split(separator: " ").first?.split(separator: "/") ?? []
        guard rows.count == 8 else { return nil }

        var expanded: [Character?] = []
        for character in rows[rankIndex] {
            if let count = character.wholeNumberValue {
                expanded.append(contentsOf: Array(repeating: nil, count: count))
            } else {
                expanded.append(character)
            }
        }

        guard expanded.indices.contains(fileIndex), let character = expanded[fileIndex] else {
            return nil
        }
        return pieces[character]
    }

    private static let pieces: [Character: ReplayPiece] = [
        "K": ReplayPiece(assetName: "white_king", color: .white),
        "Q": ReplayPiece(assetName: "white_queen", color: .white),
        "R": ReplayPiece(assetName: "white_rook", color: .white),
        "B": ReplayPiece(assetName: "white_bishop", color: .white),
        "N": ReplayPiece(assetName: "white_knight", color: .white),
        "P": ReplayPiece(assetName: "white_pawn", color: .white),
        "k": ReplayPiece(assetName: "black_king", color: .black),
        "q": ReplayPiece(assetName: "black_queen", color: .black),
        "r": ReplayPiece(assetName: "black_rook", color: .black),
        "b": ReplayPiece(assetName: "black_bishop", color: .black),
        "n": ReplayPiece(assetName: "black_knight", color: .black),
        "p": ReplayPiece(assetName: "black_pawn", color: .black),
    ]
}

enum ChessMoveNotation {
    static func san(forUCI uci: String, inFEN fen: String) -> String? {
        guard let expectedMove = OTBExpectedMove(uci: uci),
              let position = Position(fen: fen)
        else { return nil }

        var board = Board(position: position)
        guard let move = board.move(pieceAt: expectedMove.from, to: expectedMove.to) else {
            return nil
        }

        if case let .promotion(promotionMove) = board.state {
            guard let promotion = expectedMove.promotion else { return nil }
            return board.completePromotion(of: promotionMove, to: promotion).san
        }

        return move.san
    }
}

enum PGNExporter {
    static func pgn(for record: GameRecord) -> String {
        let headers = [
            header("Event", value: "Chessnut Coach OTB"),
            header("Site", value: "Chessnut Air"),
            header("Date", value: pgnDate(record.startedAt)),
            header("Round", value: "-"),
            header("White", value: normalizedPlayer(record.whitePlayer, fallback: "White")),
            header("Black", value: normalizedPlayer(record.blackPlayer, fallback: "Black")),
            header("Result", value: record.result.pgnValue),
        ] + setupHeaders(for: record) + timeControlHeaders(for: record) + soloHeaders(for: record) + [
            header("PlyCount", value: String(record.moves.count)),
            header("Termination", value: termination(for: record)),
        ]

        let moveText = formattedMoves(
            record.moves,
            initialFEN: record.initialFEN,
            result: record.result.pgnValue
        )
        return (headers + ["", moveText]).joined(separator: "\n") + "\n"
    }

    static func data(for record: GameRecord) -> Data {
        Data(pgn(for: record).utf8)
    }

    static func suggestedFilename(for record: GameRecord) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: record.startedAt)
        let date = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        return "Chessnut-\(date)-\(record.id.uuidString.prefix(8)).pgn"
    }

    private static func setupHeaders(for record: GameRecord) -> [String] {
        guard record.initialFEN != standardInitialFEN else { return [] }
        return [
            header("SetUp", value: "1"),
            header("FEN", value: record.initialFEN),
        ]
    }

    private static func soloHeaders(for record: GameRecord) -> [String] {
        guard record.mode == .solo else { return [] }
        let opponent = record.opponentEngine
            ?? .stockfish(record.engineStrength ?? .full)
        return [
            header("Mode", value: "Solo"),
            header("HumanSide", value: record.humanSide?.displayText ?? "Unknown"),
            header("Engine", value: opponent.displayName),
            header("EngineKind", value: opponent.kind.rawValue),
            header("EngineStrength", value: opponent.strengthDisplayText),
        ]
    }

    private static func timeControlHeaders(for record: GameRecord) -> [String] {
        guard let value = record.timeControl.pgnValue else { return [] }
        return [header("TimeControl", value: value)]
    }

    private static func formattedMoves(
        _ moves: [GameMoveRecord],
        initialFEN: String,
        result: String
    ) -> String {
        var tokens: [String] = []
        let fields = initialFEN.split(separator: " ")
        var isWhiteToMove = fields.count > 1 ? fields[1] != "b" : true
        var fullMoveNumber = fields.count > 5 ? Int(fields[5]) ?? 1 : 1

        for move in moves {
            if isWhiteToMove {
                tokens.append("\(fullMoveNumber).")
            } else if tokens.isEmpty {
                tokens.append("\(fullMoveNumber)...")
            }
            tokens.append(move.san)

            if isWhiteToMove {
                isWhiteToMove = false
            } else {
                isWhiteToMove = true
                fullMoveNumber += 1
            }
        }

        tokens.append(result)
        return wrapped(tokens, maximumLineLength: 80)
    }

    private static func wrapped(_ tokens: [String], maximumLineLength: Int) -> String {
        var lines: [String] = []
        var currentLine = ""

        for token in tokens {
            let candidate = currentLine.isEmpty ? token : currentLine + " " + token
            if candidate.count <= maximumLineLength || currentLine.isEmpty {
                currentLine = candidate
            } else {
                lines.append(currentLine)
                currentLine = token
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        return lines.joined(separator: "\n")
    }

    private static func pgnDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d.%02d.%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func normalizedPlayer(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func termination(for record: GameRecord) -> String {
        if record.result.isTimeoutResult { return "time forfeit" }
        switch record.status {
        case .playing:
            "unterminated"
        case .aborted:
            "abandoned"
        case .finished:
            "normal"
        }
    }

    private static func header(_ name: String, value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "[\(name) \"\(escaped)\"]"
    }

    private static let standardInitialFEN =
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
}
