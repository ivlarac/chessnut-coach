import Foundation

enum ReplayPieceColor: Equatable, Sendable {
    case white
    case black
}

struct ReplayPiece: Equatable, Sendable {
    let symbol: String
    let color: ReplayPieceColor

    // U+FE0E forces monochrome text presentation. Without it, iOS renders
    // some chess characters (especially pawns) as multicolour emoji.
    var textSymbol: String { symbol + "\u{FE0E}" }
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
        "K": ReplayPiece(symbol: "♔", color: .white),
        "Q": ReplayPiece(symbol: "♕", color: .white),
        "R": ReplayPiece(symbol: "♖", color: .white),
        "B": ReplayPiece(symbol: "♗", color: .white),
        "N": ReplayPiece(symbol: "♘", color: .white),
        "P": ReplayPiece(symbol: "♙", color: .white),
        "k": ReplayPiece(symbol: "♚", color: .black),
        "q": ReplayPiece(symbol: "♛", color: .black),
        "r": ReplayPiece(symbol: "♜", color: .black),
        "b": ReplayPiece(symbol: "♝", color: .black),
        "n": ReplayPiece(symbol: "♞", color: .black),
        "p": ReplayPiece(symbol: "♟", color: .black),
    ]
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
        ] + setupHeaders(for: record) + [
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
