import ChessKit
import Foundation

struct OTBDetectedMove: Equatable, Sendable {
    let from: Square
    let to: Square
    let san: String

    var coordinateNotation: String {
        "\(from.notation)–\(to.notation)"
    }
}

enum OTBGameEvent: Equatable, Sendable {
    case synchronized
    case pieceLifted(source: Square, legalTargets: [Square])
    case moveCompleted(OTBDetectedMove)
    case intermediate(String)
    case invalid(String)
}

struct OTBGameSession: Sendable {
    private(set) var board = Board()
    private(set) var liftedSquare: Square?
    private(set) var legalTargets: [Square] = []
    private(set) var lastMove: OTBDetectedMove?
    private(set) var isSynchronized = false

    var logicalPlacement: String {
        Self.placementField(from: board.position.fen)
    }

    var sideToMove: Piece.Color {
        board.position.sideToMove
    }

    mutating func reset() {
        board = Board()
        liftedSquare = nil
        legalTargets = []
        lastMove = nil
        isSynchronized = false
    }

    mutating func process(physicalPlacement: String) -> OTBGameEvent {
        let physicalPlacement = Self.placementField(from: physicalPlacement)

        if physicalPlacement == logicalPlacement {
            liftedSquare = nil
            legalTargets = []
            isSynchronized = true
            return .synchronized
        }

        if let completed = matchingLegalMove(for: physicalPlacement) {
            let positionBeforeMove = board.position
            guard let move = board.move(pieceAt: completed.from, to: completed.to) else {
                isSynchronized = false
                return .invalid("No se pudo aplicar el movimiento detectado.")
            }

            let detected = OTBDetectedMove(
                from: completed.from,
                to: completed.to,
                san: Move(result: move.result, piece: move.piece, start: move.start, end: move.end, checkState: move.checkState).san
            )

            // SAN uses the pre-move position internally via the Move metadata. Keep
            // this read so the intended sequencing remains explicit when promotion
            // support is added.
            _ = positionBeforeMove

            liftedSquare = nil
            legalTargets = []
            lastMove = detected
            isSynchronized = true
            return .moveCompleted(detected)
        }

        let logicalPieces = Self.parsePlacement(logicalPlacement)
        let physicalPieces = Self.parsePlacement(physicalPlacement)
        let movingColor = board.position.sideToMove

        let ownMissingPieces = board.position.pieces.filter { piece in
            piece.color == movingColor && physicalPieces[piece.square] == nil
        }

        if ownMissingPieces.count == 1 {
            let source = ownMissingPieces[0].square
            let targets = board.legalMoves(forPieceAt: source)
            let unexpectedPieces = physicalPieces.filter { square, piece in
                logicalPieces[square] != piece
            }

            if unexpectedPieces.isEmpty {
                liftedSquare = source
                legalTargets = targets
                isSynchronized = false
                return .pieceLifted(source: source, legalTargets: targets)
            }

            if let physicalDestination = unexpectedPieces.first(where: { square, piece in
                guard targets.contains(square),
                      let sourcePiece = logicalPieces[source]
                else { return false }
                return piece == sourcePiece
            })?.key {
                liftedSquare = source
                legalTargets = targets
                isSynchronized = false
                return .intermediate(
                    "Movimiento \(source.notation)→\(physicalDestination.notation) en curso; termina de ajustar las piezas."
                )
            }
        }

        let missingOpponentOnly = board.position.pieces.contains { piece in
            piece.color != movingColor && physicalPieces[piece.square] == nil
        } && ownMissingPieces.isEmpty

        liftedSquare = nil
        legalTargets = []
        isSynchronized = false

        if missingOpponentOnly {
            return .intermediate("Captura en curso; levanta ahora la pieza que va a mover.")
        }

        return .invalid("La posición física no corresponde todavía a un movimiento legal. Corrige el tablero o completa el movimiento.")
    }

    private func matchingLegalMove(for physicalPlacement: String) -> (from: Square, to: Square)? {
        let movingColor = board.position.sideToMove

        for piece in board.position.pieces where piece.color == movingColor {
            for target in board.legalMoves(forPieceAt: piece.square) {
                var candidate = board
                guard candidate.move(pieceAt: piece.square, to: target) != nil else { continue }

                if Self.placementField(from: candidate.position.fen) == physicalPlacement {
                    return (piece.square, target)
                }
            }
        }

        return nil
    }

    private static func placementField(from fenOrPlacement: String) -> String {
        fenOrPlacement.split(separator: " ").first.map(String.init) ?? fenOrPlacement
    }

    private static func parsePlacement(_ placement: String) -> [Square: Character] {
        var pieces: [Square: Character] = [:]
        let rows = placement.split(separator: "/", omittingEmptySubsequences: false)
        guard rows.count == 8 else { return pieces }

        for (rowIndex, row) in rows.enumerated() {
            let rank = 8 - rowIndex
            var fileNumber = 1

            for character in row {
                if let emptyCount = character.wholeNumberValue {
                    fileNumber += emptyCount
                    continue
                }

                guard (1...8).contains(fileNumber) else { continue }
                let square = Square(Square.File(fileNumber), Square.Rank(rank))
                pieces[square] = character
                fileNumber += 1
            }
        }

        return pieces
    }
}
