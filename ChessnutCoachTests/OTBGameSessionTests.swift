import ChessKit
import XCTest
#if SWIFT_PACKAGE
@testable import ChessnutCoachGameCore
#else
import EasyLinkSwiftSDK
@testable import ChessnutCoach
#endif

final class OTBGameSessionTests: XCTestCase {
    func testLiftedPawnShowsE3AndE4() {
        var session = OTBGameSession()
        let liftedE2 = "rnbqkbnr/pppppppp/8/8/8/8/PPPP1PPP/RNBQKBNR"

        let event = session.process(physicalPlacement: liftedE2)

        guard case let .pieceLifted(source, targets) = event else {
            return XCTFail("Expected pieceLifted, got \(event)")
        }

        XCTAssertEqual(source, .e2)
        XCTAssertEqual(targets.map(\.notation).sorted(), ["e3", "e4"])
        XCTAssertEqual(session.moves.count, 0)
    }

    func testE2E4IsRecordedAndTurnChanges() {
        var session = OTBGameSession()
        var physicalBoard = Board()

        let event = apply(.e2, .e4, to: &session, physicalBoard: &physicalBoard)

        guard case let .moveCompleted(move) = event else {
            return XCTFail("Expected moveCompleted, got \(event)")
        }

        XCTAssertEqual(move.san, "e4")
        XCTAssertEqual(session.sideToMove, .black)
        XCTAssertEqual(session.moves.count, 1)
        XCTAssertEqual(session.moves[0].lan, "e2e4")
        XCTAssertEqual(session.moves[0].from, "e2")
        XCTAssertEqual(session.moves[0].to, "e4")
    }

    func testIllegalPhysicalMoveDoesNotAdvanceGame() {
        var session = OTBGameSession()
        let illegalE2E5 = "rnbqkbnr/pppppppp/8/4P3/8/8/PPPP1PPP/RNBQKBNR"

        let event = session.process(physicalPlacement: illegalE2E5)

        guard case .invalid = event else {
            return XCTFail("Expected invalid, got \(event)")
        }
        XCTAssertEqual(session.moves.count, 0)
        XCTAssertEqual(session.sideToMove, .white)
    }

    func testCaptureIsRecorded() {
        var session = OTBGameSession()
        var physicalBoard = Board()

        _ = apply(.e2, .e4, to: &session, physicalBoard: &physicalBoard)
        _ = apply(.d7, .d5, to: &session, physicalBoard: &physicalBoard)
        let event = apply(.e4, .d5, to: &session, physicalBoard: &physicalBoard)

        guard case let .moveCompleted(move) = event else {
            return XCTFail("Expected capture moveCompleted, got \(event)")
        }

        XCTAssertEqual(move.san, "exd5")
        XCTAssertEqual(session.moves.count, 3)
    }

    func testCastlingMatchesFinalPhysicalPosition() throws {
        let position = try XCTUnwrap(Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"))
        var session = OTBGameSession(position: position)
        var physicalBoard = Board(position: position)

        let event = apply(.e1, .g1, to: &session, physicalBoard: &physicalBoard)

        guard case let .moveCompleted(move) = event else {
            return XCTFail("Expected castling moveCompleted, got \(event)")
        }

        XCTAssertEqual(move.san, "O-O")
        XCTAssertEqual(session.moves.count, 1)
    }

    func testEnPassantMatchesFinalPhysicalPosition() throws {
        let position = try XCTUnwrap(Position(fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1"))
        var session = OTBGameSession(position: position)
        var physicalBoard = Board(position: position)

        let event = apply(.e5, .d6, to: &session, physicalBoard: &physicalBoard)

        guard case let .moveCompleted(move) = event else {
            return XCTFail("Expected en passant moveCompleted, got \(event)")
        }

        XCTAssertEqual(move.san, "exd6")
        XCTAssertEqual(session.moves.count, 1)
    }

    func testDirectPhysicalPromotionIsRecorded() throws {
        let position = try XCTUnwrap(Position(fen: "k7/4P3/8/8/8/8/8/4K3 w - - 0 1"))
        var session = OTBGameSession(position: position)
        var physicalBoard = Board(position: position)

        let event = apply(.e7, .e8, promotion: .queen, to: &session, physicalBoard: &physicalBoard)

        guard case let .moveCompleted(move) = event else {
            return XCTFail("Expected promoted moveCompleted, got \(event)")
        }

        XCTAssertTrue(move.san.contains("=Q"))
        XCTAssertEqual(session.moves.count, 1)
        XCTAssertEqual(session.moves[0].promotion, "Q")
        XCTAssertFalse(session.isPromotionPending)
    }

    func testTwoStepPhysicalPromotionWaitsForReplacementPiece() throws {
        let position = try XCTUnwrap(Position(fen: "k7/4P3/8/8/8/8/8/4K3 w - - 0 1"))
        var session = OTBGameSession(position: position)
        var physicalBoard = Board(position: position)

        _ = try XCTUnwrap(physicalBoard.move(pieceAt: .e7, to: .e8))
        let pawnPlacement = placement(from: physicalBoard.position.fen)

        let pendingEvent = session.process(physicalPlacement: pawnPlacement)
        guard case let .promotionRequired(square, _) = pendingEvent else {
            return XCTFail("Expected promotionRequired, got \(pendingEvent)")
        }

        XCTAssertEqual(square, .e8)
        XCTAssertEqual(session.moves.count, 0)
        XCTAssertTrue(session.isPromotionPending)

        guard case let .promotion(promotionMove) = physicalBoard.state else {
            return XCTFail("Shadow board should require promotion")
        }
        _ = physicalBoard.completePromotion(of: promotionMove, to: .queen)

        let completedEvent = session.process(physicalPlacement: placement(from: physicalBoard.position.fen))
        guard case .moveCompleted = completedEvent else {
            return XCTFail("Expected moveCompleted after replacing pawn, got \(completedEvent)")
        }

        XCTAssertEqual(session.moves.count, 1)
        XCTAssertEqual(session.moves[0].promotion, "Q")
        XCTAssertFalse(session.isPromotionPending)
    }

    func testFoolsMateFinishesGame() {
        var session = OTBGameSession()
        var physicalBoard = Board()

        _ = apply(.f2, .f3, to: &session, physicalBoard: &physicalBoard)
        _ = apply(.e7, .e5, to: &session, physicalBoard: &physicalBoard)
        _ = apply(.g2, .g4, to: &session, physicalBoard: &physicalBoard)
        _ = apply(.d8, .h4, to: &session, physicalBoard: &physicalBoard)

        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.result, .blackWin(reason: .checkmate))
        XCTAssertEqual(session.gameRecord.status, .finished)
        XCTAssertNotNil(session.gameRecord.endedAt)
    }

    func testInsufficientMaterialIsDetectedAtSessionStart() throws {
        let position = try XCTUnwrap(Position(fen: "4k3/8/8/8/8/8/8/4K3 w - - 0 1"))
        let session = OTBGameSession(position: position)

        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.result, .draw(reason: .insufficientMaterial))
    }

    func testManualResignationAndAgreementDraw() {
        var resignation = OTBGameSession()
        XCTAssertEqual(resignation.resign(color: .white), .blackWin(reason: .resignation))
        XCTAssertTrue(resignation.isFinished)

        var agreement = OTBGameSession()
        XCTAssertEqual(agreement.agreeDraw(), .draw(reason: .agreement))
        XCTAssertTrue(agreement.isFinished)
    }

    func testAssistanceSettingsAreIndependentByColor() {
        var settings = AssistanceSettings(white: .stockfishQuality, black: .off)

        XCTAssertEqual(settings.mode(for: .white), .stockfishQuality)
        XCTAssertEqual(settings.mode(for: .black), .off)

        settings.black = .legalMoves

        XCTAssertEqual(settings.mode(for: .white), .stockfishQuality)
        XCTAssertEqual(settings.mode(for: .black), .legalMoves)
    }

    func testLegalMoveAssistanceUsesOnlySteadyLEDs() {
        let hints = AssistanceHintPlanner.hints(
            for: [.e4, .e3],
            mode: .legalMoves
        )

        XCTAssertEqual(hints.map { $0.square.notation }, ["e3", "e4"])
        XCTAssertTrue(hints.allSatisfy { $0.pattern == .steady })
    }

    func testStockfishQualityDoesNotFallBackToSimulatedHints() {
        let hints = AssistanceHintPlanner.hints(
            for: [.d4, .a1, .h8, .c3],
            mode: .stockfishQuality
        )

        XCTAssertTrue(hints.isEmpty)
    }

    func testBlunderModeKeepsNonBlundersSteadyAndWarnsOnlyWithFastBlink() {
        XCTAssertEqual(
            AssistanceMode.allCases,
            [.off, .legalMoves, .stockfishQuality, .blunders]
        )
        XCTAssertTrue(AssistanceMode.blunders.requiresStockfishAnalysis)
        XCTAssertEqual(AssistanceMode.blunders.ledPattern(for: .good), .steady)
        XCTAssertEqual(AssistanceMode.blunders.ledPattern(for: .acceptable), .steady)
        XCTAssertEqual(AssistanceMode.blunders.ledPattern(for: .blunder), .fastBlink)

        let simulatedHints = AssistanceHintPlanner.hints(
            for: [.d4, .a1, .h8, .c3],
            mode: .blunders
        )
        XCTAssertTrue(simulatedHints.isEmpty)
    }

    func testMoveQualityThresholdsMapToRequestedLEDPatterns() {
        let thresholds = MoveQualityThresholds()

        XCTAssertEqual(thresholds.classify(loss: 0), .good)
        XCTAssertEqual(thresholds.classify(loss: 50), .good)
        XCTAssertEqual(thresholds.classify(loss: 51), .acceptable)
        XCTAssertEqual(thresholds.classify(loss: 200), .acceptable)
        XCTAssertEqual(thresholds.classify(loss: 201), .blunder)

        XCTAssertEqual(MoveQuality.good.ledPattern, .steady)
        XCTAssertEqual(MoveQuality.acceptable.ledPattern, .slowBlink)
        XCTAssertEqual(MoveQuality.blunder.ledPattern, .fastBlink)
    }

    func testLifecycleInvalidatesTransientWorkOnlyAtBackgroundAndResumeBoundaries() {
        var lifecycle = ChessnutSessionLifecycle()

        XCTAssertEqual(lifecycle.transition(to: .active), .none)
        XCTAssertEqual(lifecycle.transition(to: .inactive), .none)

        let background = lifecycle.transition(to: .background)
        XCTAssertTrue(background.invalidateTransientAssistance)
        XCTAssertFalse(background.requestFreshBoardSnapshot)
        XCTAssertFalse(background.probeConnection)

        let active = lifecycle.transition(to: .active)
        XCTAssertTrue(active.invalidateTransientAssistance)
        XCTAssertTrue(active.requestFreshBoardSnapshot)
        XCTAssertTrue(active.probeConnection)
        XCTAssertEqual(lifecycle.transition(to: .active), .none)
    }

    func testGameRecordRoundTripsPlayersAndDuration() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(125)
        let record = GameRecord(
            startedAt: start,
            initialFEN: Position.standard.fen,
            whitePlayer: "Ana",
            blackPlayer: "Luis",
            endedAt: end,
            status: .finished,
            result: .draw(reason: .agreement)
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(GameRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.whitePlayer, "Ana")
        XCTAssertEqual(decoded.blackPlayer, "Luis")
        XCTAssertEqual(decoded.duration, 125, accuracy: 0.001)
    }

    func testPGNExporterIncludesMetadataMovesAndResult() {
        let date = Date(timeIntervalSince1970: 1_704_110_400) // 2024-01-01 UTC
        let moves = [
            GameMoveRecord(
                ply: 1,
                san: "e4",
                lan: "e2e4",
                from: "e2",
                to: "e4",
                fenBefore: Position.standard.fen,
                fenAfter: "after-e4",
                playedAt: date
            ),
            GameMoveRecord(
                ply: 2,
                san: "e5",
                lan: "e7e5",
                from: "e7",
                to: "e5",
                fenBefore: "after-e4",
                fenAfter: "after-e5",
                playedAt: date
            ),
            GameMoveRecord(
                ply: 3,
                san: "Nf3",
                lan: "g1f3",
                from: "g1",
                to: "f3",
                fenBefore: "after-e5",
                fenAfter: "after-nf3",
                playedAt: date
            ),
        ]
        let record = GameRecord(
            startedAt: date,
            initialFEN: Position.standard.fen,
            whitePlayer: "Ana \"A\"",
            blackPlayer: "Luis",
            endedAt: date,
            moves: moves,
            status: .finished,
            result: .whiteWin(reason: .resignation)
        )

        let pgn = PGNExporter.pgn(for: record)

        XCTAssertTrue(pgn.contains("[White \"Ana \\\"A\\\"\"]"))
        XCTAssertTrue(pgn.contains("[Black \"Luis\"]"))
        XCTAssertTrue(pgn.contains("[Result \"1-0\"]"))
        XCTAssertTrue(pgn.contains("[Round \"-\"]"))
        XCTAssertTrue(pgn.contains("[PlyCount \"3\"]"))
        XCTAssertTrue(pgn.contains("[Termination \"normal\"]"))
        XCTAssertTrue(pgn.contains("1. e4 e5 2. Nf3 1-0"))
        XCTAssertFalse(pgn.contains("[SetUp"))
        XCTAssertEqual(String(decoding: PGNExporter.data(for: record), as: UTF8.self), pgn)
    }

    func testPGNExporterNumbersCustomBlackToMovePositionCorrectly() {
        let date = Date(timeIntervalSince1970: 1_704_110_400)
        let initialFEN = "7k/8/8/8/8/8/K7/8 b - - 0 23"
        let moves = [
            GameMoveRecord(
                ply: 1,
                san: "Kh7",
                lan: "h8h7",
                from: "h8",
                to: "h7",
                fenBefore: initialFEN,
                fenAfter: "7/7k/8/8/8/8/K7/8 w - - 1 24",
                playedAt: date
            ),
            GameMoveRecord(
                ply: 2,
                san: "Ka2",
                lan: "a2a3",
                from: "a2",
                to: "a3",
                fenBefore: "7/7k/8/8/8/8/K7/8 w - - 1 24",
                fenAfter: "7/7k/8/8/8/K7/8/8 b - - 2 24",
                playedAt: date
            ),
        ]
        let record = GameRecord(
            startedAt: date,
            initialFEN: initialFEN,
            moves: moves,
            status: .playing
        )

        let pgn = PGNExporter.pgn(for: record)

        XCTAssertTrue(pgn.contains("[SetUp \"1\"]"))
        XCTAssertTrue(pgn.contains("[FEN \"\(initialFEN)\"]"))
        XCTAssertTrue(pgn.contains("[Termination \"unterminated\"]"))
        XCTAssertTrue(pgn.contains("23... Kh7 24. Ka2 *"))
    }

    func testPGNExporterPreservesSpecialSANAndWrapsMoveTextAt80Columns() {
        let date = Date(timeIntervalSince1970: 1_704_110_400)
        let specialSAN = ["O-O", "exd6", "e8=Q+", "Qh4#"]
        let longSAN = Array(repeating: "Nabcdefghxabcdefgh=Q+", count: 14)
        let allSAN = specialSAN + longSAN
        let moves = allSAN.enumerated().map { index, san in
            GameMoveRecord(
                ply: index + 1,
                san: san,
                lan: "a1a2",
                from: "a1",
                to: "a2",
                fenBefore: Position.standard.fen,
                fenAfter: Position.standard.fen,
                playedAt: date
            )
        }
        let record = GameRecord(
            startedAt: date,
            initialFEN: Position.standard.fen,
            moves: moves,
            status: .aborted
        )

        let pgn = PGNExporter.pgn(for: record)
        let moveText = pgn.components(separatedBy: "\n\n").last ?? ""

        XCTAssertTrue(moveText.contains("1. O-O exd6 2. e8=Q+ Qh4#"))
        XCTAssertTrue(pgn.contains("[Termination \"abandoned\"]"))
        XCTAssertTrue(moveText.split(separator: "\n").allSatisfy { $0.count <= 80 })
        XCTAssertTrue(moveText.hasSuffix("*\n"))
    }

    func testReplayAndSessionRestoreReturnEveryArchivedPosition() throws {
        var session = OTBGameSession(whitePlayer: "Ana", blackPlayer: "Luis")
        var physicalBoard = Board()

        _ = apply(.e2, .e4, to: &session, physicalBoard: &physicalBoard)
        _ = apply(.e7, .e5, to: &session, physicalBoard: &physicalBoard)

        let record = session.gameRecord
        let restored = try OTBGameSession(restoring: record)

        XCTAssertEqual(restored.gameRecord, record)
        XCTAssertEqual(restored.board.position.fen, session.board.position.fen)
        XCTAssertEqual(restored.sideToMove, .white)
        XCTAssertEqual(GameReplay.fen(for: record, afterPly: 0), record.initialFEN)
        XCTAssertEqual(GameReplay.fen(for: record, afterPly: 1), record.moves[0].fenAfter)
        XCTAssertEqual(GameReplay.fen(for: record, afterPly: 2), record.moves[1].fenAfter)
    }

    func testReplayBoardUsesFENColorAndForcesTextPresentationForEveryPiece() throws {
        let fen = Position.standard.fen

        for file in 0..<8 {
            let blackBackRank = try XCTUnwrap(
                GameReplay.piece(in: fen, rankIndex: 0, fileIndex: file)
            )
            let blackPawn = try XCTUnwrap(
                GameReplay.piece(in: fen, rankIndex: 1, fileIndex: file)
            )
            let whitePawn = try XCTUnwrap(
                GameReplay.piece(in: fen, rankIndex: 6, fileIndex: file)
            )
            let whiteBackRank = try XCTUnwrap(
                GameReplay.piece(in: fen, rankIndex: 7, fileIndex: file)
            )

            XCTAssertEqual(blackBackRank.color, .black)
            XCTAssertEqual(blackPawn.color, .black)
            XCTAssertEqual(whitePawn.color, .white)
            XCTAssertEqual(whiteBackRank.color, .white)
            XCTAssertEqual(blackBackRank.textSymbol.unicodeScalars.last?.value, 0xFE0E)
            XCTAssertEqual(blackPawn.textSymbol.unicodeScalars.last?.value, 0xFE0E)
            XCTAssertEqual(whitePawn.textSymbol.unicodeScalars.last?.value, 0xFE0E)
            XCTAssertEqual(whiteBackRank.textSymbol.unicodeScalars.last?.value, 0xFE0E)
        }

        XCTAssertNil(GameReplay.piece(in: fen, rankIndex: 4, fileIndex: 4))
    }

    func testLEDFrameComposerKeepsSteadyWhileBlinkPatternsChange() {
        let hints = [
            LEDHint(square: .a1, pattern: .steady),
            LEDHint(square: .b1, pattern: .slowBlink),
            LEDHint(square: .c1, pattern: .fastBlink),
        ]

        XCTAssertEqual(
            LEDHintFrameComposer.activeSquares(for: hints, tick: 0).map(\.notation),
            ["a1", "b1", "c1"]
        )
        XCTAssertEqual(
            LEDHintFrameComposer.activeSquares(for: hints, tick: 1).map(\.notation),
            ["a1", "b1"]
        )
        XCTAssertEqual(
            LEDHintFrameComposer.activeSquares(for: hints, tick: 3).map(\.notation),
            ["a1"]
        )
        XCTAssertEqual(
            LEDHintFrameComposer.activeSquares(for: hints, tick: 4).map(\.notation),
            ["a1", "c1"]
        )
        XCTAssertEqual(
            LEDHintFrameComposer.activeSquares(for: hints, tick: 6).map(\.notation),
            ["a1", "b1", "c1"]
        )
    }

#if !SWIFT_PACKAGE
    @MainActor
    func testCoreDataLibraryUpsertsUpdatesAndDeletesGame() {
        let library = GameLibrary(inMemory: true)
        var record = GameRecord(initialFEN: Position.standard.fen)
        record.moves = [
            GameMoveRecord(
                ply: 1,
                san: "e4",
                lan: "e2e4",
                from: "e2",
                to: "e4",
                fenBefore: Position.standard.fen,
                fenAfter: "after-e4"
            )
        ]

        library.upsert(record)
        XCTAssertEqual(library.games, [record])

        record.whitePlayer = "Ana"
        library.upsert(record)
        XCTAssertEqual(library.games.count, 1)
        XCTAssertEqual(library.games.first?.whitePlayer, "Ana")

        library.delete(record)
        XCTAssertTrue(library.games.isEmpty)
    }

    @MainActor
    func testCoreDataLibrarySurvivesStoreReload() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        var record = GameRecord(
            initialFEN: Position.standard.fen,
            whitePlayer: "Ana",
            blackPlayer: "Luis"
        )
        record.moves = [
            GameMoveRecord(
                ply: 1,
                san: "e4",
                lan: "e2e4",
                from: "e2",
                to: "e4",
                fenBefore: Position.standard.fen,
                fenAfter: "after-e4"
            )
        ]

        do {
            let firstLaunch = GameLibrary(storeURL: storeURL)
            firstLaunch.upsert(record)
            XCTAssertEqual(firstLaunch.games.count, 1)
        }

        let secondLaunch = GameLibrary(storeURL: storeURL)
        XCTAssertEqual(secondLaunch.games, [record])
    }

    func testMonitoredTransportBroadcastsDisconnectWithoutHidingItFromClientStream() async {
        let underlying = TestEasyLinkTransport()
        let monitored = MonitoredEasyLinkTransport(wrapping: underlying)
        var clientNotifications = monitored.notifications.makeAsyncIterator()
        var connectionEvents = monitored.connectionEvents.makeAsyncIterator()

        underlying.emit(.disconnected)

        let clientNotification = await clientNotifications.next()
        let connectionEvent = await connectionEvents.next()

        XCTAssertEqual(clientNotification, .disconnected)
        XCTAssertEqual(connectionEvent, .disconnected)
    }

    func testStockfishScoreInversionAndOrderingForCoaching() {
        XCTAssertEqual(StockfishScore.centipawns(-42).inverted, .centipawns(42))
        XCTAssertEqual(StockfishScore.mate(5).inverted, .mate(-5))
        XCTAssertGreaterThan(StockfishScore.mate(5).coachingValue, StockfishScore.centipawns(10_000).coachingValue)
        XCTAssertLessThan(StockfishScore.mate(-5).coachingValue, StockfishScore.centipawns(-10_000).coachingValue)
    }

    func testBlunderModeSummaryDoesNotRevealGoodVersusAcceptableMoves() {
        let acceptable = StockfishMoveHint(
            square: .e4,
            quality: .acceptable,
            moverScore: .centipawns(20),
            centipawnLoss: 100
        )
        let blunder = StockfishMoveHint(
            square: .d4,
            quality: .blunder,
            moverScore: .centipawns(-250),
            centipawnLoss: 370
        )

        XCTAssertEqual(acceptable.detailText(for: .blunders), "e4 fijo/legal")
        XCTAssertEqual(blunder.detailText(for: .blunders), "d4 rápido/blunder")
    }

    func testStockfish18AnalyzesRejectsInvalidFENAndRecovers() async throws {
        let engine = StockfishEngine(defaultNodeLimit: 10_000)
        let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        let afterE4FEN = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"

        let version = await engine.version()
        XCTAssertEqual(version, "Stockfish 18")

        let first = try await engine.analyze(fen: startFEN)
        XCTAssertEqual(first.version, "Stockfish 18")
        XCTAssertFalse(first.bestMove.isEmpty)
        XCTAssertGreaterThan(first.depth, 0)
        XCTAssertGreaterThan(first.nodes, 0)

        do {
            _ = try await engine.analyze(fen: "not a fen")
            XCTFail("An invalid FEN should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("FEN no válida"))
        }

        let recovered = try await engine.analyze(fen: afterE4FEN)
        XCTAssertEqual(recovered.version, "Stockfish 18")
        XCTAssertFalse(recovered.bestMove.isEmpty)
        XCTAssertGreaterThan(recovered.nodes, 0)
    }

    func testStockfishCoachEvaluatesEveryDestinationOfLiftedE2Pawn() async throws {
        let engine = StockfishEngine(defaultNodeLimit: 8_000)
        let coach = StockfishMoveCoach(
            engine: engine,
            baselineNodeLimit: 8_000,
            candidateNodeLimit: 4_000
        )
        let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

        let result = try await coach.evaluate(
            fen: startFEN,
            source: .e2,
            legalTargets: [.e3, .e4]
        )

        XCTAssertEqual(result.hints.map { $0.square.notation }, ["e3", "e4"])
        XCTAssertEqual(result.hints.count, 2)
        XCTAssertTrue(result.hints.allSatisfy { $0.centipawnLoss != nil })
        XCTAssertGreaterThan(result.analyzedNodes, 0)
        XCTAssertFalse(result.baseline.bestMove.isEmpty)
    }
#endif

    @discardableResult
    private func apply(
        _ from: Square,
        _ to: Square,
        promotion: Piece.Kind? = nil,
        to session: inout OTBGameSession,
        physicalBoard: inout Board
    ) -> OTBGameEvent {
        guard let move = physicalBoard.move(pieceAt: from, to: to) else {
            XCTFail("Shadow move \(from.notation)-\(to.notation) should be legal")
            return .invalid("shadow move failed")
        }

        if case let .promotion(promotionMove) = physicalBoard.state {
            guard let promotion else {
                XCTFail("Shadow move requires a promotion kind")
                return .invalid("promotion kind missing")
            }
            _ = physicalBoard.completePromotion(of: promotionMove, to: promotion)
        }

        _ = move
        return session.process(physicalPlacement: placement(from: physicalBoard.position.fen))
    }

    private func placement(from fen: String) -> String {
        fen.split(separator: " ").first.map(String.init) ?? fen
    }
}

#if !SWIFT_PACKAGE
private final class TestEasyLinkTransport: EasyLinkTransport, @unchecked Sendable {
    let notifications: AsyncStream<EasyLinkNotification>
    private let continuation: AsyncStream<EasyLinkNotification>.Continuation

    init() {
        var continuation: AsyncStream<EasyLinkNotification>.Continuation!
        notifications = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {}

    func disconnect() async {
        emit(.disconnected)
    }

    func write(_ command: [UInt8]) async throws {
        _ = command
    }

    func emit(_ notification: EasyLinkNotification) {
        continuation.yield(notification)
    }
}
#endif
