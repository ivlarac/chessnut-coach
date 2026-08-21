import Foundation

enum GameReplay {
    static func fen(for record: GameRecord, afterPly ply: Int) -> String {
        guard ply > 0, !record.moves.isEmpty else { return record.initialFEN }
        return record.moves[min(ply, record.moves.count) - 1].fenAfter
    }

    static func move(for record: GameRecord, atPly ply: Int) -> GameMoveRecord? {
        guard ply > 0, ply <= record.moves.count else { return nil }
        return record.moves[ply - 1]
    }
}

enum PGNExporter {
    static func pgn(for record: GameRecord) -> String {
        let headers = [
            header("Event", value: "Chessnut Coach OTB"),
            header("Site", value: "Chessnut Air"),
            header("Date", value: pgnDate(record.startedAt)),
            header("White", value: normalizedPlayer(record.whitePlayer, fallback: "White")),
            header("Black", value: normalizedPlayer(record.blackPlayer, fallback: "Black")),
            header("Result", value: record.result.pgnValue),
        ] + setupHeaders(for: record)

        let moveText = formattedMoves(record.moves, result: record.result.pgnValue)
        return (headers + ["", moveText]).joined(separator: "\n") + "\n"
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

    private static func formattedMoves(_ moves: [GameMoveRecord], result: String) -> String {
        var tokens: [String] = []

        for (index, move) in moves.enumerated() {
            if index.isMultiple(of: 2) {
                tokens.append("\((index / 2) + 1).")
            }
            tokens.append(move.san)
        }

        tokens.append(result)
        return tokens.joined(separator: " ")
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

    private static func header(_ name: String, value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "[\(name) \"\(escaped)\"]"
    }

    private static let standardInitialFEN =
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
}
