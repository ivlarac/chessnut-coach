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

struct OTBExpectedMove: Equatable, Sendable {
    let from: Square
    let to: Square
    let promotion: Piece.Kind?

    init?(uci: String) {
        let value = uci.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 4 || value.count == 5 else { return nil }
        let characters = Array(value)
        guard ("a"..."h").contains(String(characters[0])),
              ("1"..."8").contains(String(characters[1])),
              ("a"..."h").contains(String(characters[2])),
              ("1"..."8").contains(String(characters[3]))
        else { return nil }
        let from = Square(String(characters[0...1]))
        let to = Square(String(characters[2...3]))

        let promotion: Piece.Kind?
        if characters.count == 5 {
            switch characters[4] {
            case "q": promotion = .queen
            case "r": promotion = .rook
            case "b": promotion = .bishop
            case "n": promotion = .knight
            default: return nil
            }
        } else {
            promotion = nil
        }

        self.from = from
        self.to = to
        self.promotion = promotion
    }

    var displayText: String { "\(from.notation)→\(to.notation)" }
}

enum OTBGameEvent: Equatable, Sendable {
    case synchronized
    case pieceLifted(source: Square, legalTargets: [Square])
    case moveCompleted(OTBDetectedMove)
    case moveUndone(GameMoveRecord)
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
        let requiredKind: Piece.Kind?
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
    private(set) var isAwaitingPhysicalUndo = false
    private var pendingPromotion: PendingPromotion?

    init(
        position: Position = .standard,
        startedAt: Date = Date(),
        whitePlayer: String = "Blancas",
        blackPlayer: String = "Negras",
        mode: GameMode = .twoPlayer,
        humanSide: PlayerSide? = nil,
        opponentEngine: OpponentEngineConfiguration? = nil,
        engineStrength: StockfishStrength? = nil,
        engineName: String? = nil,
        allowUndo: Bool = false,
        timeControl: GameTimeControl = .unlimited
    ) {
        board = Board(position: position)
        gameRecord = GameRecord(
            startedAt: startedAt,
            initialFEN: position.fen,
            whitePlayer: whitePlayer,
            blackPlayer: blackPlayer,
            mode: mode,
            humanSide: humanSide,
            opponentEngine: opponentEngine,
            engineStrength: engineStrength,
            engineName: engineName,
            allowUndo: mode == .twoPlayer && allowUndo,
            timeControl: timeControl
        )
        applyTerminalBoardStateIfNeeded(at: startedAt)
    }

    init(restoring record: GameRecord) throws {
        board = try Self.restoredBoard(initialFEN: record.initialFEN, moves: record.moves)
        gameRecord = record
        liftedSquare = nil
        legalTargets = []
        lastMove = record.moves.last.map {
            OTBDetectedMove(from: Square($0.from), to: Square($0.to), san: $0.san)
        }
        isSynchronized = false
        isAwaitingPhysicalUndo = false
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

    var timeControl: GameTimeControl { gameRecord.timeControl }
    var clockState: GameClockState? { gameRecord.clockState }

    var canUndoLastMove: Bool {
        undoFeatureEnabled
            && gameRecord.status == .playing
            && !gameRecord.moves.isEmpty
            && pendingPromotion == nil
            && !isAwaitingPhysicalUndo
            && isSynchronized
    }

    mutating func reset(
        startedAt: Date = Date(),
        whitePlayer: String = "Blancas",
        blackPlayer: String = "Negras",
        mode: GameMode = .twoPlayer,
        humanSide: PlayerSide? = nil,
        opponentEngine: OpponentEngineConfiguration? = nil,
        engineStrength: StockfishStrength? = nil,
        engineName: String? = nil,
        allowUndo: Bool = false,
        timeControl: GameTimeControl = .unlimited
    ) {
        self = OTBGameSession(
            startedAt: startedAt,
            whitePlayer: whitePlayer,
            blackPlayer: blackPlayer,
            mode: mode,
            humanSide: humanSide,
            opponentEngine: opponentEngine,
            engineStrength: engineStrength,
            engineName: engineName,
            allowUndo: allowUndo,
            timeControl: timeControl
        )
    }

    mutating func startClockIfNeeded(at date: Date = Date()) {
        guard var clock = gameRecord.clockState,
              clock.activeSide == nil,
              gameRecord.status == .playing
        else { return }
        clock.start(side: Self.playerSide(for: board.position.sideToMove), at: date)
        gameRecord.clockState = clock
    }

    mutating func resumeClockAfterSynchronization(at date: Date = Date()) {
        guard var clock = gameRecord.clockState,
              clock.activeSide != nil,
              clock.pauseReason == .initialSetup || clock.pauseReason == .undoSynchronization,
              gameRecord.status == .playing
        else { return }
        clock.resume(at: date)
        gameRecord.clockState = clock
    }

    mutating func resumeClockForVirtualBoard(at date: Date = Date()) {
        guard var clock = gameRecord.clockState,
              clock.activeSide != nil,
              clock.pauseReason != nil,
              gameRecord.status == .playing
        else { return }
        clock.resume(at: date)
        gameRecord.clockState = clock
    }

    mutating func pauseClockForEngineMoveTransfer(at date: Date = Date()) {
        guard var clock = gameRecord.clockState,
              gameRecord.status == .playing
        else { return }
        clock.pause(at: date, reason: .engineMoveTransfer)
        gameRecord.clockState = clock
    }

    func clockRemaining(for side: PlayerSide, at date: Date = Date()) -> TimeInterval? {
        gameRecord.clockState?.remaining(for: side, at: date)
    }

    @discardableResult
    mutating func processClockTimeoutIfNeeded(at date: Date = Date()) -> PlayerSide? {
        guard let timedOutSide = gameRecord.clockState?.timedOutSide(at: date),
              gameRecord.status == .playing
        else { return nil }

        if case .draw(.insufficientMaterial) = board.state {
            finish(with: .draw(reason: .insufficientMaterial), at: date)
        } else {
            let result: GameResult = timedOutSide == .white
                ? .blackWin(reason: .timeout)
                : .whiteWin(reason: .timeout)
            finish(with: result, at: date)
        }
        return timedOutSide
    }

    mutating func updatePlayers(white: String, black: String) {
        gameRecord.whitePlayer = white
        gameRecord.blackPlayer = black
    }

    @discardableResult
    mutating func undoLastMove(
        awaitPhysicalRestore: Bool = true,
        at date: Date = Date()
    ) -> GameMoveRecord? {
        guard undoFeatureEnabled,
              gameRecord.status == .playing,
              pendingPromotion == nil,
              !isAwaitingPhysicalUndo,
              let undoneMove = gameRecord.moves.last
        else { return nil }

        if awaitPhysicalRestore && !isSynchronized {
            return nil
        }

        let remainingMoves = Array(gameRecord.moves.dropLast())
        guard let restoredBoard = try? Self.restoredBoard(
            initialFEN: gameRecord.initialFEN,
            moves: remainingMoves
        ) else { return nil }

        board = restoredBoard
        gameRecord.moves = remainingMoves
        gameRecord.status = .playing
        gameRecord.result = .unfinished
        gameRecord.endedAt = nil
        if var clock = gameRecord.clockState {
            _ = clock.undoLastMove(at: date)
            if awaitPhysicalRestore {
                clock.pause(at: date, reason: .undoSynchronization)
            }
            gameRecord.clockState = clock
        }
        liftedSquare = nil
        legalTargets = []
        pendingPromotion = nil
        lastMove = remainingMoves.last.map {
            OTBDetectedMove(from: Square($0.from), to: Square($0.to), san: $0.san)
        }
        isAwaitingPhysicalUndo = awaitPhysicalRestore
        isSynchronized = !awaitPhysicalRestore
        return undoneMove
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
        isAwaitingPhysicalUndo = false
        if var clock = gameRecord.clockState {
            clock.stop(at: date)
            gameRecord.clockState = clock
        }
    }

    mutating func process(
        physicalPlacement: String,
        at date: Date = Date(),
        requiredMove: OTBExpectedMove? = nil
    ) -> OTBGameEvent {
        let physicalPlacement = Self.placementField(from: physicalPlacement)

        if processClockTimeoutIfNeeded(at: date) != nil {
            isSynchronized = physicalPlacement == logicalPlacement
            return .invalid(gameRecord.result.displayText)
        }

        if gameRecord.status != .playing {
            isSynchronized = physicalPlacement == logicalPlacement
            return isSynchronized
                ? .synchronized
                : .invalid("La partida ya está finalizada. Inicia una nueva partida para continuar.")
        }

        if pendingPromotion != nil {
            return processPendingPromotion(physicalPlacement: physicalPlacement, at: date)
        }

        if isAwaitingPhysicalUndo {
            if physicalPlacement == logicalPlacement {
                isAwaitingPhysicalUndo = false
                isSynchronized = true
                return .synchronized
            }

            liftedSquare = nil
            legalTargets = []
            isSynchronized = false
            return .intermediate("Deshacer en curso. Devuelve las piezas a la posición anterior para continuar.")
        }

        if physicalPlacement == logicalPlacement {
            liftedSquare = nil
            legalTargets = []
            isSynchronized = true
            return .synchronized
        }

        if shouldAutomaticallyUndo(to: physicalPlacement),
           let undoneMove = undoLastMove(awaitPhysicalRestore: false, at: date) {
            return .moveUndone(undoneMove)
        }

        if let transition = matchingLegalTransition(for: physicalPlacement, requiredMove: requiredMove) {
            return apply(
                transition: transition,
                physicalPlacement: physicalPlacement,
                at: date,
                requiredMove: requiredMove
            )
        }

        let logicalPieces = Self.parsePlacement(logicalPlacement)
        let physicalPieces = Self.parsePlacement(physicalPlacement)
        let movingColor = board.position.sideToMove

        let ownMissingPieces = board.position.pieces.filter { piece in
            piece.color == movingColor && physicalPieces[piece.square] == nil
        }

        if ownMissingPieces.count == 1 {
            let source = ownMissingPieces[0].square
            if let requiredMove, source != requiredMove.from {
                liftedSquare = nil
                legalTargets = []
                isSynchronized = false
                let opponentName = gameRecord.opponentEngine?.displayName ?? "el motor rival"
                return .invalid("Es el turno de \(opponentName). Ejecuta \(requiredMove.displayText) en el tablero.")
            }
            let allTargets = board.legalMoves(forPieceAt: source)
            let targets = requiredMove.map { allTargets.contains($0.to) ? [$0.to] : [] } ?? allTargets
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

    private var undoFeatureEnabled: Bool {
        gameRecord.mode == .twoPlayer && gameRecord.allowUndo
    }

    private func shouldAutomaticallyUndo(to physicalPlacement: String) -> Bool {
        guard undoFeatureEnabled,
              gameRecord.status == .playing,
              pendingPromotion == nil,
              let lastMove = gameRecord.moves.last
        else { return false }

        return physicalPlacement == Self.placementField(from: lastMove.fenBefore)
    }

    private mutating func apply(
        transition: LegalTransition,
        physicalPlacement: String,
        at date: Date,
        requiredMove: OTBExpectedMove?
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

            pendingPromotion = PendingPromotion(
                move: move,
                fenBefore: fenBefore,
                requiredKind: requiredMove?.promotion
            )
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

        let allowedKinds = pendingPromotion.requiredKind.map { [$0] } ?? Self.promotionKinds
        for kind in allowedKinds {
            var candidate = board
            let finalMove = candidate.completePromotion(of: pendingPromotion.move, to: kind)

            if Self.placementField(from: candidate.position.fen) == physicalPlacement {
                let appliedMove = board.completePromotion(of: pendingPromotion.move, to: kind)
                self.pendingPromotion = nil
                return complete(
                    move: appliedMove,
                    fenBefore: pendingPromotion.fenBefore,
                    playedAt: date
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
            promotion: move.promotedPiece?.kind.promotionSymbol,
            participant: participant(forFEN: fenBefore)
        )

        gameRecord.moves.append(record)
        if var clock = gameRecord.clockState,
           let position = Position(fen: fenBefore) {
            _ = clock.completeMove(
                by: Self.playerSide(for: position.sideToMove),
                at: playedAt
            )
            gameRecord.clockState = clock
        }
        liftedSquare = nil
        legalTargets = []
        lastMove = detected
        isSynchronized = true
        isAwaitingPhysicalUndo = false
        applyTerminalBoardStateIfNeeded(at: playedAt)
        return .moveCompleted(detected)
    }

    private func matchingLegalTransition(
        for physicalPlacement: String,
        requiredMove: OTBExpectedMove?
    ) -> LegalTransition? {
        let movingColor = board.position.sideToMove

        for piece in board.position.pieces where piece.color == movingColor {
            if let requiredMove, piece.square != requiredMove.from { continue }
            for target in board.legalMoves(forPieceAt: piece.square) {
                if let requiredMove, target != requiredMove.to { continue }
                var candidate = board
                guard candidate.move(pieceAt: piece.square, to: target) != nil else { continue }

                if Self.placementField(from: candidate.position.fen) == physicalPlacement {
                    return LegalTransition(from: piece.square, to: target, promotion: nil)
                }

                if case let .promotion(move) = candidate.state {
                    for kind in Self.promotionKinds {
                        var promotedCandidate = candidate
                        _ = promotedCandidate.completePromotion(of: move, to: kind)

                        if let requiredMove,
                           let requiredPromotion = requiredMove.promotion,
                           kind != requiredPromotion {
                            continue
                        }

                        if Self.placementField(from: promotedCandidate.position.fen) == physicalPlacement {
                            return LegalTransition(from: piece.square, to: target, promotion: kind)
                        }
                    }
                }
            }
        }

        return nil
    }

    private func participant(forFEN fen: String) -> MoveParticipant {
        guard gameRecord.mode == .solo,
              let humanSide = gameRecord.humanSide,
              let position = Position(fen: fen)
        else { return .player }

        return position.sideToMove == humanSide.pieceColor ? .human : .engine
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
        if var clock = gameRecord.clockState {
            clock.stop(at: date)
            gameRecord.clockState = clock
        }
        gameRecord.status = .finished
        gameRecord.result = result
        gameRecord.endedAt = date
        liftedSquare = nil
        legalTargets = []
        pendingPromotion = nil
        isAwaitingPhysicalUndo = false
    }

    private static func restoredBoard(
        initialFEN: String,
        moves: [GameMoveRecord]
    ) throws -> Board {
        guard let position = Position(fen: initialFEN) else {
            throw OTBGameRestoreError.invalidInitialPosition
        }

        var restoredBoard = Board(position: position)
        for archivedMove in moves.sorted(by: { $0.ply < $1.ply }) {
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

        return restoredBoard
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

    private static func playerSide(for color: Piece.Color) -> PlayerSide {
        color == .white ? .white : .black
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
