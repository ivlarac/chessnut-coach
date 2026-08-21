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
    case promotionRequired(square: Square, legalKinds: [Piece.Kind])
    case intermediate(String)
    case invalid(String)
}

enum OTBGameRestoreError: Error, Equatable {
    case invalidInitialPosition
    case invalidMove(ply: Int)
    case positionMismatch(ply: Int)
}

struct OTBGameSession: Sendable {
    private struct PendingPromotion: Sendable {
        let move: Move
        let fenBefore: String
        let playedAt: Date
    }

    private struct LegalTransition: Sendable {
        let from: Square
        let to: Square
        let promotion: Piece.Kind?
    }

    private static let promotionKinds: [Piece.Kind] = [.queen, .rook, .bishop, .knight]

    private(set) var board: Board
    private(set) var gameRecord: GameRecord
    private(set) var liftedSquare: Square?
    private(set) var legalTargets: [Square] = []
    private(set) var lastMove: OTBDetectedMove?
    private(set) var isSynchronized = false
    private var pendingPromotion: PendingPromotion?

    init(
        position: Position = .standard,
        startedAt: Date = Date(),
        whitePlayer: String = "Blancas",
        blackPlayer: String = "Negras"
    ) {
        board = Board(position: position)
        gameRecord = GameRecord(
            startedAt: startedAt,
            initialFEN: position.fen,
            whitePlayer: whitePlayer,
            blackPlayer: blackPlayer
        )
        applyTerminalBoardStateIfNeeded(at: startedAt)
    }

    init(restoring record: GameRecord) throws {
        guard let position = Position(fen: record.initialFEN) else {
            throw OTBGameRestoreError.invalidInitialPosition
        }

        var restoredBoard = Board(position: position)
        for archivedMove in record.moves.sorted(by: { $0.ply < $1.ply }) {
            let from = Square(archivedMove.from)
            let to = Square(archivedMove.to)
            guard restoredBoard.move(pieceAt: from, to: to) != nil else {
                throw OTBGameRestoreError.invalidMove(ply: archivedMove.ply)
            }

            if case let .promotion(promotionMove) = restoredBoard.state {
                guard let kind = Self.promotionKind(from: archivedMove.promotion) else {
                    throw OTBGameRestoreError.invalidMove(ply: archivedMove.ply)
                }
                _ = restoredBoard.completePromotion(of: promotionMove, to: kind)
            }

            guard restoredBoard.position.fen == archivedMove.fenAfter else {
                throw OTBGameRestoreError.positionMismatch(ply: archivedMove.ply)
            }
        }

        board = restoredBoard
        gameRecord = record
        liftedSquare = nil
        legalTargets = []
        lastMove = record.moves.last.map {
            OTBDetectedMove(from: Square($0.from), to: Square($0.to), san: $0.san)
        }
        isSynchronized = false
    }

    var logicalPlacement: String {
        Self.placementField(from: board.position.fen)
    }

    var sideToMove: Piece.Color {
        board.position.sideToMove
    }

    var moves: [GameMoveRecord] {
        gameRecord.moves
    }

    var result: GameResult {
        gameRecord.result
    }

    var isFinished: Bool {
        gameRecord.status != .playing
    }

    var isPromotionPending: Bool {
        pendingPromotion != nil
    }

    mutating func reset(
        startedAt: Date = Date(),
        whitePlayer: String = "Blancas",
        blackPlayer: String = "Negras"
    ) {
        self = OTBGameSession(
            startedAt: startedAt,
            whitePlayer: whitePlayer,
            blackPlayer: blackPlayer
        )
    }

    mutating func updatePlayers(white: String, black: String) {
        gameRecord.whitePlayer = white
        gameRecord.blackPlayer = black
    }

    @discardableResult
    mutating func resign(color: Piece.Color, at date: Date = Date()) -> GameResult {
        guard gameRecord.status == .playing else { return gameRecord.result }

        let result: GameResult = color == .white
            ? .blackWin(reason: .resignation)
            : .whiteWin(reason: .resignation)
        finish(with: result, at: date)
        return result
    }

    @discardableResult
    mutating func agreeDraw(at date: Date = Date()) -> GameResult {
        guard gameRecord.status == .playing else { return gameRecord.result }
        let result = GameResult.draw(reason: .agreement)
        finish(with: result, at: date)
        return result
    }

    mutating func abort(at date: Date = Date()) {
        guard gameRecord.status == .playing else { return }
        gameRecord.status = .aborted
        gameRecord.result = .unfinished
        gameRecord.endedAt = date
        liftedSquare = nil
        legalTargets = []
        pendingPromotion = nil
    }

    mutating func process(physicalPlacement: String, at date: Date = Date()) -> OTBGameEvent {
        let physicalPlacement = Self.placementField(from: physicalPlacement)

        if gameRecord.status != .playing {
            isSynchronized = physicalPlacement == logicalPlacement
            return isSynchronized
                ? .synchronized
                : .invalid("La partida ya está finalizada. Inicia una nueva partida para continuar.")
        }

        if pendingPromotion != nil {
            return processPendingPromotion(physicalPlacement: physicalPlacement, at: date)
        }

        if physicalPlacement == logicalPlacement {
            liftedSquare = nil
            legalTargets = []
            isSynchronized = true
            return .synchronized
        }

        if let transition = matchingLegalTransition(for: physicalPlacement) {
            return apply(transition: transition, physicalPlacement: physicalPlacement, at: date)
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

    private mutating func apply(
        transition: LegalTransition,
        physicalPlacement: String,
        at date: Date
    ) -> OTBGameEvent {
        let fenBefore = board.position.fen

        guard let initialMove = board.move(pieceAt: transition.from, to: transition.to) else {
            isSynchronized = false
            return .invalid("No se pudo aplicar el movimiento detectado.")
        }

        if case let .promotion(move) = board.state {
            if let promotionKind = transition.promotion {
                let finalMove = board.completePromotion(of: move, to: promotionKind)
                return complete(move: finalMove, fenBefore: fenBefore, playedAt: date)
            }

            pendingPromotion = PendingPromotion(move: move, fenBefore: fenBefore, playedAt: date)
            liftedSquare = nil
            legalTargets = []
            isSynchronized = physicalPlacement == logicalPlacement
            return .promotionRequired(square: initialMove.end, legalKinds: Self.promotionKinds)
        }

        return complete(move: initialMove, fenBefore: fenBefore, playedAt: date)
    }

    private mutating func processPendingPromotion(
        physicalPlacement: String,
        at date: Date
    ) -> OTBGameEvent {
        guard let pendingPromotion else {
            return .invalid("Estado de promoción inconsistente.")
        }

        if physicalPlacement == logicalPlacement {
            isSynchronized = true
            return .promotionRequired(square: pendingPromotion.move.end, legalKinds: Self.promotionKinds)
        }

        for kind in Self.promotionKinds {
            var candidate = board
            let finalMove = candidate.completePromotion(of: pendingPromotion.move, to: kind)

            if Self.placementField(from: candidate.position.fen) == physicalPlacement {
                let appliedMove = board.completePromotion(of: pendingPromotion.move, to: kind)
                self.pendingPromotion = nil
                return complete(
                    move: appliedMove,
                    fenBefore: pendingPromotion.fenBefore,
                    playedAt: pendingPromotion.playedAt
                )
            }

            _ = finalMove
        }

        isSynchronized = false
        return .intermediate(
            "Promoción en curso. Sustituye el peón de \(pendingPromotion.move.end.notation) por dama, torre, alfil o caballo."
        )
    }

    private mutating func complete(
        move: Move,
        fenBefore: String,
        playedAt: Date
    ) -> OTBGameEvent {
        let detected = OTBDetectedMove(from: move.start, to: move.end, san: move.san)
        let record = GameMoveRecord(
            ply: gameRecord.moves.count + 1,
            san: move.san,
            lan: move.lan,
            from: move.start.notation,
            to: move.end.notation,
            fenBefore: fenBefore,
            fenAfter: board.position.fen,
            playedAt: playedAt,
            promotion: move.promotedPiece?.kind.promotionSymbol
        )

        gameRecord.moves.append(record)
        liftedSquare = nil
        legalTargets = []
        lastMove = detected
        isSynchronized = true
        applyTerminalBoardStateIfNeeded(at: playedAt)
        return .moveCompleted(detected)
    }

    private func matchingLegalTransition(for physicalPlacement: String) -> LegalTransition? {
        let movingColor = board.position.sideToMove

        for piece in board.position.pieces where piece.color == movingColor {
            for target in board.legalMoves(forPieceAt: piece.square) {
                var candidate = board
                guard candidate.move(pieceAt: piece.square, to: target) != nil else { continue }

                if Self.placementField(from: candidate.position.fen) == physicalPlacement {
                    return LegalTransition(from: piece.square, to: target, promotion: nil)
                }

                if case let .promotion(move) = candidate.state {
                    for kind in Self.promotionKinds {
                        var promotedCandidate = candidate
                        _ = promotedCandidate.completePromotion(of: move, to: kind)

                        if Self.placementField(from: promotedCandidate.position.fen) == physicalPlacement {
                            return LegalTransition(from: piece.square, to: target, promotion: kind)
                        }
                    }
                }
            }
        }

        return nil
    }

    private mutating func applyTerminalBoardStateIfNeeded(at date: Date) {
        guard gameRecord.status == .playing else { return }

        switch board.state {
        case let .checkmate(color):
            let result: GameResult = color == .white
                ? .blackWin(reason: .checkmate)
                : .whiteWin(reason: .checkmate)
            finish(with: result, at: date)

        case let .draw(reason):
            finish(with: .draw(reason: Self.drawReason(from: reason)), at: date)

        case .active, .check, .promotion:
            break
        }
    }

    private mutating func finish(with result: GameResult, at date: Date) {
        gameRecord.status = .finished
        gameRecord.result = result
        gameRecord.endedAt = date
        liftedSquare = nil
        legalTargets = []
        pendingPromotion = nil
    }

    private static func drawReason(from reason: Board.State.DrawReason) -> GameDrawReason {
        switch reason {
        case .agreement: .agreement
        case .fiftyMoves: .fiftyMoves
        case .insufficientMaterial: .insufficientMaterial
        case .repetition: .repetition
        case .stalemate: .stalemate
        }
    }

    private static func promotionKind(from symbol: String?) -> Piece.Kind? {
        switch symbol?.uppercased() {
        case "Q": .queen
        case "R": .rook
        case "B": .bishop
        case "N": .knight
        default: nil
        }
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
