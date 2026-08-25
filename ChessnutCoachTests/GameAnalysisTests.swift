import ChessKit
import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import ChessnutCoachGameCore
#else
@testable import ChessnutCoach
#endif

final class GameAnalysisTreeTests: XCTestCase {
    func testCreatesVariantFromIntermediatePlyWithExactStartingFENAndSAN() throws {
        let game = try makeGame(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"])
        let originalMoves = game.moves
        var tree = AnalysisVariationTree()

        let node = try tree.applyMove(
            from: "f1",
            to: "c4",
            at: .mainline(ply: 4),
            in: game
        )

        XCTAssertEqual(node.rootPly, 4)
        XCTAssertNil(node.parentNodeID)
        XCTAssertEqual(node.fenBefore, GameReplay.fen(for: game, afterPly: 4))
        XCTAssertEqual(node.san, "Bc4")
        XCTAssertEqual(node.uci, "f1c4")
        XCTAssertNotEqual(node.fenAfter, game.moves[4].fenAfter)
        XCTAssertEqual(game.moves, originalMoves, "Analysis must not mutate the mainline")
    }

    func testRejectsIllegalMove() throws {
        let game = try makeGame([])
        var tree = AnalysisVariationTree()

        XCTAssertThrowsError(
            try tree.applyMove(
                from: "e2",
                to: "e5",
                at: .mainline(ply: 0),
                in: game
            )
        ) { error in
            XCTAssertEqual(error as? AnalysisVariationError, .illegalMove)
        }
        XCTAssertTrue(tree.nodes.isEmpty)
    }

    func testContinuesVariantForSeveralMoves() throws {
        let game = try makeGame(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"])
        var tree = AnalysisVariationTree()
        let first = try tree.applyMove(
            from: "f1", to: "c4", at: .mainline(ply: 4), in: game
        )
        let second = try tree.applyMove(
            from: "g8", to: "f6", at: .variation(nodeID: first.id), in: game
        )
        let third = try tree.applyMove(
            from: "d2", to: "d3", at: .variation(nodeID: second.id), in: game
        )

        XCTAssertEqual(tree.path(to: third.id).map(\.san), ["Bc4", "Nf6", "d3"])
        XCTAssertEqual(second.parentNodeID, first.id)
        XCTAssertEqual(third.parentNodeID, second.id)
        XCTAssertEqual(tree.fen(for: .variation(nodeID: third.id), in: game), third.fenAfter)
    }

    func testCreatesSiblingVariantsFromSameMainlineNode() throws {
        let game = try makeGame(["e2e4", "e7e5", "g1f3", "b8c6", "f1b5"])
        var tree = AnalysisVariationTree()
        let italian = try tree.applyMove(
            from: "f1", to: "c4", at: .mainline(ply: 4), in: game
        )
        let center = try tree.applyMove(
            from: "d2", to: "d4", at: .mainline(ply: 4), in: game
        )

        XCTAssertEqual(tree.children(of: .mainline(ply: 4)).map(\.id), [italian.id, center.id])
        XCTAssertNil(italian.parentNodeID)
        XCTAssertNil(center.parentNodeID)
    }

    func testCreatesSubvariationWithoutDestroyingExistingContinuation() throws {
        let game = try makeGame(["e2e4", "e7e5", "g1f3", "b8c6"])
        var tree = AnalysisVariationTree()
        let root = try tree.applyMove(
            from: "f1", to: "c4", at: .mainline(ply: 4), in: game
        )
        let knight = try tree.applyMove(
            from: "g8", to: "f6", at: .variation(nodeID: root.id), in: game
        )
        let bishop = try tree.applyMove(
            from: "f8", to: "c5", at: .variation(nodeID: root.id), in: game
        )

        XCTAssertEqual(Set(tree.children(of: .variation(nodeID: root.id)).map(\.id)), Set([knight.id, bishop.id]))
        XCTAssertEqual(tree.path(to: knight.id).map(\.san), ["Bc4", "Nf6"])
        XCTAssertEqual(tree.path(to: bishop.id).map(\.san), ["Bc4", "Bc5"])
    }

    func testNavigatesBackwardAndForwardByStableNodeIdentity() throws {
        let game = try makeGame(["e2e4", "e7e5"])
        var tree = AnalysisVariationTree()
        let root = try tree.applyMove(
            from: "g1", to: "f3", at: .mainline(ply: 2), in: game
        )
        let child = try tree.applyMove(
            from: "b8", to: "c6", at: .variation(nodeID: root.id), in: game
        )

        XCTAssertEqual(tree.parentReference(of: child.id), .variation(nodeID: root.id))
        XCTAssertEqual(tree.parentReference(of: root.id), .mainline(ply: 2))
        XCTAssertEqual(tree.children(of: .variation(nodeID: root.id)).first?.id, child.id)
    }

    func testDeletingBranchLeavesSiblingsAndMainlineUntouched() throws {
        let game = try makeGame(["e2e4", "e7e5"])
        let originalMoves = game.moves
        var tree = AnalysisVariationTree()
        let first = try tree.applyMove(
            from: "g1", to: "f3", at: .mainline(ply: 2), in: game
        )
        _ = try tree.applyMove(
            from: "b8", to: "c6", at: .variation(nodeID: first.id), in: game
        )
        let sibling = try tree.applyMove(
            from: "d2", to: "d4", at: .mainline(ply: 2), in: game
        )

        let deleted = tree.deleteBranch(startingAt: first.id)

        XCTAssertEqual(deleted.count, 2)
        XCTAssertEqual(tree.nodes.map(\.id), [sibling.id])
        XCTAssertEqual(game.moves, originalMoves)
    }

    func testPersistsAndRestoresVariationsWithGameRecord() throws {
        var game = try makeGame(["e2e4", "e7e5"])
        var tree = AnalysisVariationTree()
        _ = try tree.applyMove(
            from: "g1", to: "f3", at: .mainline(ply: 2), in: game
        )
        game.analysisVariations = tree.nodes

        let data = try JSONEncoder().encode(game)
        let restored = try JSONDecoder().decode(GameRecord.self, from: data)

        XCTAssertEqual(restored, game)
        XCTAssertEqual(restored.analysisVariations, tree.nodes)
    }

    func testDecodesLegacyGameWithoutVariationField() throws {
        let game = try makeGame(["e2e4"])
        let encoded = try JSONEncoder().encode(game)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "analysisVariations")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(GameRecord.self, from: legacyData)

        XCTAssertTrue(decoded.analysisVariations.isEmpty)
        XCTAssertEqual(decoded.moves, game.moves)
    }

    func testPromotionInsideVariationUsesSelectedPieceAndCorrectFEN() throws {
        let game = GameRecord(
            initialFEN: "7k/P7/8/8/8/8/8/K7 w - - 0 1",
            endedAt: Date(),
            status: .finished,
            result: .draw(reason: .agreement)
        )
        var tree = AnalysisVariationTree()

        let node = try tree.applyMove(
            from: "a7",
            to: "a8",
            promotion: .queen,
            at: .mainline(ply: 0),
            in: game
        )

        XCTAssertEqual(node.promotion, "Q")
        XCTAssertEqual(node.uci, "a7a8q")
        XCTAssertTrue(node.san.hasPrefix("a8=Q"))
        XCTAssertEqual(GameReplay.piece(in: node.fenAfter, rankIndex: 0, fileIndex: 0)?.assetName, "white_queen")
    }

    func testCastlingAndEnPassantAreDelegatedToChessKit() throws {
        let castlingGame = GameRecord(
            initialFEN: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",
            endedAt: Date(), status: .finished, result: .draw(reason: .agreement)
        )
        var castlingTree = AnalysisVariationTree()
        let castle = try castlingTree.applyMove(
            from: "e1", to: "g1", at: .mainline(ply: 0), in: castlingGame
        )
        XCTAssertEqual(castle.san, "O-O")
        XCTAssertEqual(GameReplay.piece(in: castle.fenAfter, rankIndex: 7, fileIndex: 5)?.assetName, "white_rook")

        let enPassantGame = GameRecord(
            initialFEN: "7k/8/8/3pP3/8/8/8/K7 w - d6 0 1",
            endedAt: Date(), status: .finished, result: .draw(reason: .agreement)
        )
        var enPassantTree = AnalysisVariationTree()
        let capture = try enPassantTree.applyMove(
            from: "e5", to: "d6", at: .mainline(ply: 0), in: enPassantGame
        )
        XCTAssertEqual(capture.san, "exd6")
        XCTAssertNil(GameReplay.piece(in: capture.fenAfter, rankIndex: 3, fileIndex: 3))
    }

    func testStaleAnalysisRequestCannotReplaceNewSelection() {
        var tracker = AnalysisRequestTracker()
        let old = tracker.begin(fen: "old-fen")
        let current = tracker.begin(fen: "new-fen")

        XCTAssertFalse(tracker.accepts(old))
        XCTAssertTrue(tracker.accepts(current))
    }
}

@MainActor
final class GameAnalysisWorkspaceTests: XCTestCase {
    func testAbortedGameKeepsEvaluationAndVariationWorkspaceAvailable() throws {
        var game = try makeGame(["e2e4"])
        game.status = .aborted
        game.result = .unfinished
        game.endedAt = Date()
        let workspace = GameAnalysisWorkspace(
            game: game,
            initialPly: 1,
            engine: ScriptedAnalysisEngine(moves: []),
            onSave: { _ in }
        )

        XCTAssertTrue(game.allowsAnalysis)
        workspace.exploreCurrentPosition()
        XCTAssertTrue(workspace.isExploring)
        XCTAssertTrue(workspace.canMovePieces)

        workspace.startPlaying(
            AnalysisPlayConfiguration(
                humanSide: .black,
                strength: StockfishStrength(level: 4)
            )
        )
        XCTAssertNotNil(workspace.playConfiguration)
        workspace.stopPlaying()
    }

    func testPresentedPlayingGameUnlocksAnalysisWhenPersistedRecordFinishes() throws {
        var playing = try makeGame(["e2e4"])
        playing.status = .playing
        playing.result = .unfinished
        playing.endedAt = nil
        let workspace = GameAnalysisWorkspace(
            game: playing,
            initialPly: playing.moves.count,
            engine: ScriptedAnalysisEngine(moves: []),
            onSave: { _ in }
        )

        XCTAssertFalse(workspace.game.allowsAnalysis)
        var finished = playing
        finished.status = .finished
        finished.result = .draw(reason: .agreement)
        finished.endedAt = Date()

        workspace.synchronize(with: finished)

        XCTAssertTrue(workspace.game.allowsAnalysis)
        XCTAssertEqual(workspace.currentReference, .mainline(ply: 0))
        workspace.exploreCurrentPosition()
        XCTAssertTrue(workspace.isExploring)
    }

    func testTimedMaiaArchiveStillUsesIndependentStockfishAnalysisWorkspace() throws {
        var game = try makeGame(["e2e4"])
        game.mode = .solo
        game.humanSide = .white
        game.opponentEngine = .maia3(Maia3Strength(rating: 800))
        game.timeControl = .fischer(initialSeconds: 300, incrementSeconds: 3)
        let workspace = GameAnalysisWorkspace(
            game: game,
            initialPly: 1,
            engine: ScriptedAnalysisEngine(moves: []),
            onSave: { _ in }
        )

        workspace.exploreCurrentPosition()
        workspace.handleMove(from: "e7", to: "e5")

        XCTAssertTrue(workspace.isExploring)
        guard case .variation = workspace.currentReference else {
            return XCTFail("Expected a variation for a timed Maia archive")
        }
    }

    func testSelectingVariationRequestsAnalysisForItsFullFEN() throws {
        let game = try makeGame([])
        let engine = ScriptedAnalysisEngine(moves: [])
        var requestedPositions: [(String, Int?)] = []
        let workspace = GameAnalysisWorkspace(
            game: game,
            initialPly: 0,
            engine: engine,
            onSave: { _ in },
            onPositionChanged: { requestedPositions.append(($0, $1)) }
        )
        workspace.exploreCurrentPosition()
        workspace.handleMove(from: "e2", to: "e4")
        guard case let .variation(nodeID) = workspace.currentReference else {
            return XCTFail("Expected a variation position")
        }
        let variationFEN = workspace.currentFEN
        workspace.selectMainline(ply: 0)
        workspace.selectVariation(nodeID: nodeID)

        XCTAssertEqual(requestedPositions.last?.0, variationFEN)
        XCTAssertNil(requestedPositions.last?.1)
    }

    func testPlayingFromHereUsesExactFENAndEngineMovesFirstLegally() async throws {
        let game = try makeGame(["e2e4"])
        let engine = ScriptedAnalysisEngine(moves: ["e7e5"])
        var savedGame: GameRecord?
        let workspace = GameAnalysisWorkspace(
            game: game,
            initialPly: 1,
            engine: engine,
            onSave: { savedGame = $0 }
        )
        let selectedFEN = workspace.currentFEN

        workspace.startPlaying(
            AnalysisPlayConfiguration(humanSide: .white, strength: StockfishStrength(level: 4))
        )
        await waitUntil { !workspace.isEngineThinking }

        XCTAssertEqual(workspace.playStartFEN, selectedFEN)
        let requestedFENs = await engine.requestedFENs()
        XCTAssertEqual(requestedFENs, [selectedFEN])
        guard case let .variation(nodeID) = workspace.currentReference else {
            return XCTFail("The engine move should create a variation node")
        }
        let engineNode = try XCTUnwrap(workspace.tree.node(id: nodeID))
        XCTAssertEqual(engineNode.uci, "e7e5")
        XCTAssertNotNil(Position(fen: engineNode.fenAfter))
        XCTAssertEqual(savedGame?.moves, game.moves)

        workspace.stopPlaying()
        XCTAssertNil(workspace.playConfiguration)
        XCTAssertEqual(workspace.game.analysisVariations.map(\.id), [engineNode.id])
    }

    func testStoppingEngineModePreventsObsoleteMoveFromApplying() async throws {
        let game = try makeGame([])
        let engine = ScriptedAnalysisEngine(moves: ["e2e4"], delayNanoseconds: 80_000_000)
        let workspace = GameAnalysisWorkspace(
            game: game,
            initialPly: 0,
            engine: engine,
            onSave: { _ in }
        )

        workspace.startPlaying(
            AnalysisPlayConfiguration(humanSide: .black, strength: StockfishStrength(level: 2))
        )
        workspace.stopPlaying()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(workspace.currentReference, .mainline(ply: 0))
        XCTAssertTrue(workspace.tree.nodes.isEmpty)
    }

    func testHumanAndEngineMovesAreConservedAsOneAnalysisLine() async throws {
        let game = try makeGame([])
        let engine = ScriptedAnalysisEngine(moves: ["e7e5"])
        let workspace = GameAnalysisWorkspace(
            game: game,
            initialPly: 0,
            engine: engine,
            onSave: { _ in }
        )
        workspace.startPlaying(
            AnalysisPlayConfiguration(humanSide: .white, strength: StockfishStrength(level: 3))
        )
        workspace.handleMove(from: "e2", to: "e4")
        await waitUntil { !workspace.isEngineThinking }
        workspace.stopPlaying()

        guard case let .variation(nodeID) = workspace.currentReference else {
            return XCTFail("Expected a saved analysis line")
        }
        XCTAssertEqual(workspace.path(to: nodeID).map(\.uci), ["e2e4", "e7e5"])
        XCTAssertEqual(workspace.game.moves, game.moves)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private actor ScriptedAnalysisEngine: AnalysisMoveSearching {
    private var moves: [String]
    private var fens: [String] = []
    private let delayNanoseconds: UInt64

    init(moves: [String], delayNanoseconds: UInt64 = 0) {
        self.moves = moves
        self.delayNanoseconds = delayNanoseconds
    }

    func bestMove(
        fen: String,
        nodeLimit: UInt64,
        strength: StockfishStrength
    ) async throws -> String {
        fens.append(fen)
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return moves.isEmpty ? "" : moves.removeFirst()
    }

    func requestedFENs() -> [String] { fens }
}

private func makeGame(_ uciMoves: [String]) throws -> GameRecord {
    let initialFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    let position = try XCTUnwrap(Position(fen: initialFEN))
    var board = Board(position: position)
    var records: [GameMoveRecord] = []

    for (index, uci) in uciMoves.enumerated() {
        let expected = try XCTUnwrap(OTBExpectedMove(uci: uci))
        let fenBefore = board.position.fen
        let move = try XCTUnwrap(board.move(pieceAt: expected.from, to: expected.to))
        let san: String
        if case let .promotion(promotionMove) = board.state {
            san = board.completePromotion(
                of: promotionMove,
                to: try XCTUnwrap(expected.promotion)
            ).san
        } else {
            san = move.san
        }
        records.append(
            GameMoveRecord(
                ply: index + 1,
                san: san,
                lan: uci,
                from: expected.from.notation,
                to: expected.to.notation,
                fenBefore: fenBefore,
                fenAfter: board.position.fen,
                promotion: expected.promotion?.promotionSymbol
            )
        )
    }

    return GameRecord(
        initialFEN: initialFEN,
        endedAt: Date(),
        moves: records,
        status: .finished,
        result: .draw(reason: .agreement)
    )
}
