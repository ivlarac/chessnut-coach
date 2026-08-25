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

    func testSoloEngineTurnAcceptsOnlySuggestedPhysicalMove() throws {
        var session = OTBGameSession(
            whitePlayer: "Stockfish 18",
            blackPlayer: "Jugador",
            mode: .solo,
            humanSide: .black,
            engineStrength: StockfishStrength(elo: 1_600),
            engineName: "Stockfish 18"
        )
        let expected = try XCTUnwrap(OTBExpectedMove(uci: "e2e4"))

        var wrongBoard = Board()
        _ = try XCTUnwrap(wrongBoard.move(pieceAt: .d2, to: .d4))
        let wrongEvent = session.process(
            physicalPlacement: placement(from: wrongBoard.position.fen),
            requiredMove: expected
        )
        guard case .invalid = wrongEvent else {
            return XCTFail("A different legal engine move must be rejected")
        }
        XCTAssertTrue(session.moves.isEmpty)

        var expectedBoard = Board()
        _ = try XCTUnwrap(expectedBoard.move(pieceAt: .e2, to: .e4))
        let expectedEvent = session.process(
            physicalPlacement: placement(from: expectedBoard.position.fen),
            requiredMove: expected
        )
        guard case .moveCompleted = expectedEvent else {
            return XCTFail("The suggested move should complete")
        }
        XCTAssertEqual(session.moves.first?.lan, "e2e4")
        XCTAssertEqual(session.moves.first?.participant, .engine)
    }

    func testSoloConfigurationAndMoveOwnershipSurviveRoundTrip() throws {
        var session = OTBGameSession(
            whitePlayer: "Jugador",
            blackPlayer: "Stockfish 18",
            mode: .solo,
            humanSide: .white,
            engineStrength: StockfishStrength(elo: 2_050),
            engineName: "Stockfish 18"
        )
        var physicalBoard = Board()
        _ = apply(.e2, .e4, to: &session, physicalBoard: &physicalBoard)

        let data = try JSONEncoder().encode(session.gameRecord)
        let decoded = try JSONDecoder().decode(GameRecord.self, from: data)

        XCTAssertEqual(decoded.mode, .solo)
        XCTAssertEqual(decoded.humanSide, .white)
        XCTAssertEqual(decoded.engineStrength, StockfishStrength(elo: 2_050))
        XCTAssertEqual(decoded.engineName, "Stockfish 18")
        XCTAssertEqual(decoded.moves.first?.participant, .human)

        let restored = try OTBGameSession(restoring: decoded)
        XCTAssertEqual(restored.moves.count, 1)
        XCTAssertEqual(restored.sideToMove, .black)
    }

    func testEvaluationBarIsCenteredAndMatesFillOneSide() {
        XCTAssertEqual(WhitePositionEvaluation.centipawns(0).whiteShare, 0.5, accuracy: 0.000_001)
        XCTAssertGreaterThan(WhitePositionEvaluation.centipawns(48).whiteShare, 0.5)
        XCTAssertLessThan(WhitePositionEvaluation.centipawns(-324).whiteShare, 0.5)
        XCTAssertEqual(WhitePositionEvaluation.mate(5).whiteShare, 1)
        XCTAssertEqual(WhitePositionEvaluation.mate(-1).whiteShare, 0)
        XCTAssertEqual(WhitePositionEvaluation.centipawns(48).displayText, "+0,48")
        XCTAssertEqual(WhitePositionEvaluation.centipawns(-324).displayText, "-3,24")
        XCTAssertEqual(WhitePositionEvaluation.mate(5).displayText, "#3")
        XCTAssertEqual(WhitePositionEvaluation.mate(-1).displayText, "#-1")
    }

    func testStockfishStrengthClampsToSupportedEloRange() {
        XCTAssertEqual(StockfishStrength(elo: 100).elo, StockfishStrength.minimumElo)
        XCTAssertEqual(StockfishStrength(elo: 9_999).elo, StockfishStrength.maximumElo)
        XCTAssertNil(StockfishStrength.full.elo)
    }

    func testStockfishLevelsCoverLimitedRangeAndMaximumStrength() {
        XCTAssertEqual(StockfishStrength(level: 0).level, 1)
        XCTAssertEqual(StockfishStrength(level: 1).elo, StockfishStrength.minimumElo)
        XCTAssertEqual(StockfishStrength(level: 19).elo, StockfishStrength.maximumElo)
        XCTAssertEqual(StockfishStrength(level: 20), .full)
        XCTAssertEqual(StockfishStrength(level: 99), .full)
        XCTAssertEqual(StockfishStrength(level: 7).level, 7)
    }

    func testNewGameDraftPreservesEditedPlayerNamesInLaunch() throws {
        var draft = NewGameDraft(
            whitePlayerName: "Blancas",
            blackPlayerName: "Negras",
            whiteAssistance: .legalMoves,
            blackAssistance: .off
        )
        draft.whitePlayerName = "  Ana  "
        draft.blackPlayerName = "Luis"
        draft.whiteAssistance = .blunders
        draft.blackAssistance = .stockfishQuality
        draft.allowUndo = true
        draft.automaticBoardRotation = true

        let launch = try XCTUnwrap(draft.makeLaunch())

        XCTAssertEqual(launch.configuration.mode, .twoPlayer)
        XCTAssertEqual(launch.configuration.whitePlayerName, "Ana")
        XCTAssertEqual(launch.configuration.blackPlayerName, "Luis")
        XCTAssertEqual(
            launch.configuration.assistance,
            AssistanceSettings(white: .blunders, black: .stockfishQuality)
        )
        XCTAssertTrue(launch.configuration.allowUndo)
        XCTAssertTrue(launch.automaticBoardRotation)
    }

    func testSoloNewGameDraftUsesHumanNameAndResolvedColor() throws {
        var draft = NewGameDraft(
            whitePlayerName: "Blancas",
            blackPlayerName: "Negras",
            whiteAssistance: .off,
            blackAssistance: .off
        )
        draft.mode = .solo
        draft.sideChoice = .random
        draft.humanPlayerName = "Iván"
        draft.humanAssistance = .blunders
        draft.stockfishLevel = 8

        let launch = try XCTUnwrap(draft.makeLaunch(randomValue: false))

        XCTAssertEqual(launch.configuration.humanSide, .black)
        XCTAssertEqual(launch.configuration.whitePlayerName, "Stockfish 18")
        XCTAssertEqual(launch.configuration.blackPlayerName, "Iván")
        XCTAssertEqual(launch.configuration.strength.level, 8)
        XCTAssertEqual(
            launch.configuration.assistance,
            AssistanceSettings(white: .off, black: .blunders)
        )
        XCTAssertFalse(launch.configuration.allowUndo)
        XCTAssertFalse(launch.automaticBoardRotation)
    }

    func testNewGameDraftRejectsMissingPlayerName() {
        var draft = NewGameDraft(
            whitePlayerName: "Blancas",
            blackPlayerName: "Negras",
            whiteAssistance: .off,
            blackAssistance: .off
        )
        draft.whitePlayerName = "   "

        XCTAssertFalse(draft.canStart)
        XCTAssertNil(draft.makeLaunch())
    }

#if !SWIFT_PACKAGE
    @MainActor
    func testBoardControllerUsesConfiguredNamesAndReturnsToIdleAfterEnding() {
        let controller = BoardController(library: GameLibrary(inMemory: true))
        let configuration = NewGameConfiguration(
            mode: .twoPlayer,
            assistance: AssistanceSettings(white: .off, black: .off),
            whitePlayerName: "Ana",
            blackPlayerName: "Luis"
        )

        XCTAssertFalse(controller.hasActiveGame)

        controller.newGame(configuration: configuration)

        XCTAssertTrue(controller.hasActiveGame)
        XCTAssertEqual(controller.whitePlayerName, "Ana")
        XCTAssertEqual(controller.blackPlayerName, "Luis")
        XCTAssertEqual(controller.gameResultLabel, "En juego")

        controller.abortGame()

        XCTAssertFalse(controller.hasActiveGame)
        XCTAssertEqual(controller.moveCount, 0)
        XCTAssertEqual(controller.gameResultLabel, "Sin partida")
        XCTAssertTrue(controller.gameStatus.contains("No hay ninguna partida iniciada"))

        controller.newGame(configuration: configuration)
        controller.agreeDraw()

        XCTAssertFalse(controller.hasActiveGame)
        XCTAssertEqual(controller.moveCount, 0)
        XCTAssertEqual(controller.gameResultLabel, "Sin partida")
    }
#endif

    func testManualAndRandomHumanColorChoicesResolveCorrectly() {
        XCTAssertEqual(HumanSideChoice.white.resolvedSide(randomValue: false), .white)
        XCTAssertEqual(HumanSideChoice.black.resolvedSide(randomValue: true), .black)
        XCTAssertEqual(HumanSideChoice.random.resolvedSide(randomValue: true), .white)
        XCTAssertEqual(HumanSideChoice.random.resolvedSide(randomValue: false), .black)
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

    func testAssistanceSettingsDecodeLegacyValuesWithCompatibleDefaults() throws {
        let legacy = Data(#"{"white":"legalMoves","black":"off"}"#.utf8)

        let settings = try JSONDecoder().decode(AssistanceSettings.self, from: legacy)

        XCTAssertEqual(settings.white, .legalMoves)
        XCTAssertEqual(settings.black, .off)
        XCTAssertEqual(settings.maximumPiecesPerTurn, .unlimited)
        XCTAssertEqual(settings.blunderThreshold, .twoHundred)
    }

    func testThreePieceLimitAllowsFirstThreeAndPreviouslyConsultedSources() {
        var policy = TurnAssistanceAccessPolicy(limit: .three)

        XCTAssertTrue(policy.requestAssistance(for: .g1))
        XCTAssertTrue(policy.requestAssistance(for: .b1))
        XCTAssertTrue(policy.requestAssistance(for: .e2))
        XCTAssertFalse(policy.requestAssistance(for: .d2))
        XCTAssertTrue(policy.requestAssistance(for: .g1))
        XCTAssertTrue(policy.requestAssistance(for: .e2))
        XCTAssertEqual(policy.consultedSources, Set([.g1, .b1, .e2]))
    }

    func testUnlimitedPieceAssistancePreservesExistingBehavior() {
        var policy = TurnAssistanceAccessPolicy(limit: .unlimited)

        for square in [Square.a2, .b2, .c2, .d2, .e2, .f2, .g2, .h2] {
            XCTAssertTrue(policy.requestAssistance(for: square))
        }
        XCTAssertEqual(policy.consultedSources.count, 8)
    }

    func testOnePieceLimitDoesNotChargeRepeatedConsultation() {
        var policy = TurnAssistanceAccessPolicy(limit: .one)

        XCTAssertTrue(policy.requestAssistance(for: .g1))
        XCTAssertFalse(policy.requestAssistance(for: .b1))
        XCTAssertTrue(policy.requestAssistance(for: .g1))
    }

    func testAssistanceLimitResetsOnlyForCompletedTurnEvents() {
        var policy = TurnAssistanceAccessPolicy(limit: .one)
        XCTAssertTrue(policy.requestAssistance(for: .e2))

        policy.handle(.synchronized)
        policy.handle(.intermediate("Recolocación en curso"))
        policy.handle(.promotionRequired(square: .a8, legalKinds: [.queen]))
        XCTAssertFalse(policy.requestAssistance(for: .d2))

        policy.handle(
            .moveCompleted(OTBDetectedMove(from: .a7, to: .a8, san: "a8=Q"))
        )
        XCTAssertTrue(policy.requestAssistance(for: .d2))
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
        XCTAssertEqual(thresholds.classify(loss: 199), .acceptable)
        XCTAssertEqual(thresholds.classify(loss: 200), .blunder)
        XCTAssertEqual(thresholds.classify(loss: 201), .blunder)

        XCTAssertEqual(MoveQuality.good.ledPattern, .steady)
        XCTAssertEqual(MoveQuality.acceptable.ledPattern, .slowBlink)
        XCTAssertEqual(MoveQuality.blunder.ledPattern, .fastBlink)
    }

    func testConfigurableBlunderThresholdCoversBelowExactAndAboveValues() {
        let thresholds = MoveQualityThresholds(blunderThreshold: .twoHundredFifty)

        XCTAssertEqual(thresholds.classify(loss: 249), .acceptable)
        XCTAssertEqual(thresholds.classify(loss: 250), .blunder)
        XCTAssertEqual(thresholds.classify(loss: 251), .blunder)
        XCTAssertEqual(thresholds.classify(loss: .decisive), .blunder)
    }

    func testLifecycleInvalidatesTransientWorkOnlyAtBackgroundAndResumeBoundaries() {
        var lifecycle = ElectronicBoardSessionLifecycle()

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

    func testReplayBoardMapsEveryFENPieceToItsColorSpecificAsset() throws {
        let fen = Position.standard.fen
        let expectedBlackBackRankAssets = [
            "black_rook", "black_knight", "black_bishop", "black_queen",
            "black_king", "black_bishop", "black_knight", "black_rook",
        ]
        let expectedWhiteBackRankAssets = [
            "white_rook", "white_knight", "white_bishop", "white_queen",
            "white_king", "white_bishop", "white_knight", "white_rook",
        ]

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
            XCTAssertEqual(blackBackRank.assetName, expectedBlackBackRankAssets[file])
            XCTAssertEqual(blackPawn.assetName, "black_pawn")
            XCTAssertEqual(whitePawn.assetName, "white_pawn")
            XCTAssertEqual(whiteBackRank.assetName, expectedWhiteBackRankAssets[file])
        }

        XCTAssertNil(GameReplay.piece(in: fen, rankIndex: 4, fileIndex: 4))
    }

    func testChessBoardPerspectiveRotatesTheEntireBoardAndCanBeFlippedRepeatedly() {
        XCTAssertEqual(
            ChessBoardPerspective.whiteAtBottom.boardPosition(
                displayRankIndex: 0,
                displayFileIndex: 0
            ),
            ChessBoardSquarePosition(rankIndex: 0, fileIndex: 0)
        )
        XCTAssertEqual(
            ChessBoardPerspective.whiteAtBottom.boardPosition(
                displayRankIndex: 7,
                displayFileIndex: 7
            ),
            ChessBoardSquarePosition(rankIndex: 7, fileIndex: 7)
        )
        XCTAssertEqual(
            ChessBoardPerspective.blackAtBottom.boardPosition(
                displayRankIndex: 0,
                displayFileIndex: 0
            ),
            ChessBoardSquarePosition(rankIndex: 7, fileIndex: 7)
        )
        XCTAssertEqual(
            ChessBoardPerspective.blackAtBottom.boardPosition(
                displayRankIndex: 0,
                displayFileIndex: 7
            ),
            ChessBoardSquarePosition(rankIndex: 7, fileIndex: 0)
        )
        XCTAssertEqual(
            ChessBoardPerspective.blackAtBottom.boardPosition(
                displayRankIndex: 7,
                displayFileIndex: 0
            ),
            ChessBoardSquarePosition(rankIndex: 0, fileIndex: 7)
        )
        XCTAssertEqual(
            ChessBoardPerspective.blackAtBottom.boardPosition(
                displayRankIndex: 7,
                displayFileIndex: 7
            ),
            ChessBoardSquarePosition(rankIndex: 0, fileIndex: 0)
        )

        for perspective in [
            ChessBoardPerspective.whiteAtBottom,
            ChessBoardPerspective.blackAtBottom,
        ] {
            for displayRank in 0..<8 {
                for displayFile in 0..<8 {
                    let position = perspective.boardPosition(
                        displayRankIndex: displayRank,
                        displayFileIndex: displayFile
                    )
                    XCTAssertEqual(
                        perspective.isLightSquare(
                            displayRankIndex: displayRank,
                            displayFileIndex: displayFile
                        ),
                        (position.rankIndex + position.fileIndex).isMultiple(of: 2)
                    )
                }
            }
        }

        var perspective = ChessBoardPerspective.whiteAtBottom
        for _ in 0..<100 {
            perspective = perspective.opposite
        }
        XCTAssertEqual(perspective, .whiteAtBottom)
        XCTAssertEqual(perspective.opposite, .blackAtBottom)
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

    func testElectronicBoardCapabilitiesRepresentOptionalHardwareFeatures() {
        let minimal: ElectronicBoardCapabilities = [.positionReading, .realtimePosition]
        XCTAssertTrue(minimal.contains(.positionReading))
        XCTAssertTrue(minimal.contains(.realtimePosition))
        XCTAssertFalse(minimal.contains(.leds))
        XCTAssertFalse(minimal.contains(.battery))
        XCTAssertFalse(minimal.contains(.automaticMovement))

        let rich: ElectronicBoardCapabilities = [
            .positionReading, .realtimePosition, .leds, .ledColors, .battery,
            .gameStorage, .automaticMovement, .pieceIdentification,
        ]
        XCTAssertTrue(rich.contains(.ledColors))
        XCTAssertTrue(rich.contains(.pieceIdentification))
    }

    func testElectronicBoardRegistrySelectsMatchingAdapter() throws {
        let descriptor = TestElectronicChessBoard.makeDescriptor(adapterIdentifier: "test.adapter")
        let fake = TestElectronicChessBoard(descriptor: descriptor)
        let registry = ElectronicBoardAdapterRegistry(
            factories: [TestElectronicBoardFactory(board: fake)]
        )

        let selected = try registry.makeBoard(for: descriptor)
        XCTAssertEqual(selected.descriptor, descriptor)

        let unsupported = TestElectronicChessBoard.makeDescriptor(adapterIdentifier: "other.adapter")
        XCTAssertThrowsError(try registry.makeBoard(for: unsupported))
    }

#if !SWIFT_PACKAGE
    func testDefaultRegistryPublishesChessUpPositionSupport() throws {
        let registry = ElectronicBoardAdapterRegistry.appDefault
        let chessUp = try XCTUnwrap(
            registry.supportedBoards.first {
                $0.adapterIdentifier == ChessUpBoardAdapterFactory.adapterIdentifier
            }
        )

        XCTAssertEqual(chessUp.name, "ChessUp")
        XCTAssertEqual(chessUp.models, "1.ª generación")
        XCTAssertTrue(chessUp.capabilities.contains(.positionReading))
        XCTAssertTrue(chessUp.capabilities.contains(.realtimePosition))
        XCTAssertFalse(chessUp.capabilities.contains(.leds))

        let descriptor = ElectronicBoardDescriptor(
            adapterIdentifier: ChessUpBoardAdapterFactory.adapterIdentifier,
            hardwareIdentifier: UUID().uuidString,
            name: "ChessUp",
            manufacturer: "Bryght Labs",
            model: "ChessUp",
            variantIdentifier: ChessUpBoardAdapterFactory.variantIdentifier,
            capabilities: chessUp.capabilities
        )
        XCTAssertTrue(try registry.makeBoard(for: descriptor) is ChessUpBoardAdapter)
    }

    func testChessUpPositionCodecMapsTheInitialPosition() throws {
        var message = [UInt8](repeating: 64, count: 72)
        message[0] = 0x67

        let whiteBackRank: [UInt8] = [1, 2, 3, 4, 5, 3, 2, 1]
        let blackBackRank: [UInt8] = [9, 10, 11, 12, 13, 11, 10, 9]
        message.replaceSubrange(1...8, with: whiteBackRank)
        message.replaceSubrange(9...16, with: Array(repeating: 0, count: 8))
        message.replaceSubrange(49...56, with: Array(repeating: 8, count: 8))
        message.replaceSubrange(57...64, with: blackBackRank)

        XCTAssertEqual(
            ChessUpProtocolCodec.placement(fromBoardPositionMessage: message),
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"
        )
        XCTAssertNil(ChessUpProtocolCodec.placement(fromBoardPositionMessage: [0x67]))

        message[1] = 0xFF
        XCTAssertNil(ChessUpProtocolCodec.placement(fromBoardPositionMessage: message))
    }

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

    @MainActor
    func testEmptySoloGameDoesNotResumeBeforeFirstMove() {
        let library = GameLibrary(inMemory: true)
        let record = GameRecord(
            initialFEN: Position.standard.fen,
            whitePlayer: "Stockfish 18",
            blackPlayer: "Jugador",
            mode: .solo,
            humanSide: .black,
            engineStrength: StockfishStrength(elo: 1_600),
            engineName: "Stockfish 18"
        )

        library.upsert(record)

        XCTAssertNil(library.resumableGame)
    }

    @MainActor
    func testNewSoloGameAppliesHumanAssistanceAndEngineLevel() {
        let controller = BoardController(library: GameLibrary(inMemory: true))

        controller.newGame(
            configuration: NewGameConfiguration(
                mode: .solo,
                humanSide: .black,
                strength: StockfishStrength(level: 7),
                assistance: AssistanceSettings(white: .off, black: .blunders)
            )
        )

        XCTAssertTrue(controller.isSoloGame)
        XCTAssertEqual(controller.humanSide, .black)
        XCTAssertEqual(controller.engineStrength?.level, 7)
        XCTAssertEqual(controller.whiteAssistanceMode, .off)
        XCTAssertEqual(controller.blackAssistanceMode, .blunders)
    }

    @MainActor
    func testVirtualBoardSharesPieceLimitAndStillAllowsBlockedPieceMove() {
        let controller = BoardController(
            library: GameLibrary(inMemory: true),
            preferences: UserDefaults(suiteName: UUID().uuidString)!
        )
        controller.newGame(
            configuration: NewGameConfiguration(
                assistance: AssistanceSettings(
                    white: .legalMoves,
                    black: .legalMoves,
                    maximumPiecesPerTurn: .three
                )
            )
        )

        controller.handleScreenSquareTap("g1")
        XCTAssertFalse(controller.screenHints.isEmpty)
        controller.handleScreenSquareTap("b1")
        XCTAssertFalse(controller.screenHints.isEmpty)
        controller.handleScreenSquareTap("e2")
        XCTAssertFalse(controller.screenHints.isEmpty)

        controller.handleScreenSquareTap("d2")
        XCTAssertTrue(controller.screenHints.isEmpty)
        XCTAssertTrue(controller.gameStatus.contains("máximo de piezas"))

        controller.handleScreenSquareTap("g1")
        XCTAssertFalse(controller.screenHints.isEmpty)

        controller.handleScreenSquareTap("d2")
        controller.handleScreenMove(from: "d2", to: "d4")
        XCTAssertEqual(controller.moveCount, 1, "The limit must never block a legal move")

        controller.handleScreenSquareTap("e7")
        XCTAssertFalse(controller.screenHints.isEmpty, "A completed move starts a fresh turn quota")
    }

    @MainActor
    func testAssistanceLimitAndBlunderThresholdPersistAsDefaults() {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let first = BoardController(
            library: GameLibrary(inMemory: true),
            preferences: preferences
        )

        first.setMaximumAssistancePieces(.four)
        first.setBlunderThreshold(.threeHundred)

        let restored = BoardController(
            library: GameLibrary(inMemory: true),
            preferences: preferences
        )
        XCTAssertEqual(restored.maximumAssistancePieces, .four)
        XCTAssertEqual(restored.blunderThreshold, .threeHundred)
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

    @MainActor
    func testBoardControllerConnectsDisconnectsAndReceivesGenericBoardPositions() async throws {
        let descriptor = TestElectronicChessBoard.makeDescriptor(
            capabilities: [.positionReading, .realtimePosition, .battery]
        )
        let fake = TestElectronicChessBoard(descriptor: descriptor)
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let controller = BoardController(
            library: GameLibrary(inMemory: true),
            boardDiscovery: TestElectronicBoardDiscovery(devices: [descriptor]),
            adapterRegistry: ElectronicBoardAdapterRegistry(
                factories: [TestElectronicBoardFactory(board: fake)]
            ),
            preferences: preferences
        )

        controller.connect(to: descriptor)
        try await waitUntil { controller.isConnected }
        XCTAssertEqual(controller.connectedBoard, descriptor)
        XCTAssertTrue(controller.supportsBattery)

        let placement = Position.standard.fen.split(separator: " ").first.map(String.init)!
        fake.emitPosition(placement)
        try await waitUntil { controller.boardPlacement == placement }

        controller.disconnect()
        try await waitUntil { !controller.isConnected }
        XCTAssertNil(controller.connectedBoard)
    }

    @MainActor
    func testBoardControllerKeepsGameWorkingWhenBoardHasNoLEDs() async throws {
        let descriptor = TestElectronicChessBoard.makeDescriptor(
            capabilities: [.positionReading, .realtimePosition]
        )
        let fake = TestElectronicChessBoard(descriptor: descriptor)
        let controller = BoardController(
            library: GameLibrary(inMemory: true),
            boardDiscovery: TestElectronicBoardDiscovery(devices: [descriptor]),
            adapterRegistry: ElectronicBoardAdapterRegistry(
                factories: [TestElectronicBoardFactory(board: fake)]
            ),
            preferences: UserDefaults(suiteName: UUID().uuidString)!
        )

        controller.newGame(
            configuration: NewGameConfiguration(
                assistance: AssistanceSettings(white: .legalMoves, black: .legalMoves)
            )
        )
        controller.connect(to: descriptor)
        try await waitUntil { controller.isConnected }

        let initial = Position.standard.fen.split(separator: " ").first.map(String.init)!
        fake.emitPosition(initial)
        try await waitUntil { controller.isBoardSynchronized }

        controller.handleScreenMove(from: "e2", to: "e4")
        XCTAssertEqual(controller.moveCount, 0)
        XCTAssertEqual(controller.logicalPlacement, initial)

        let liftedE2 = "rnbqkbnr/pppppppp/8/8/8/8/PPPP1PPP/RNBQKBNR"
        fake.emitPosition(liftedE2)
        try await waitUntil {
            controller.liftedSquare == "e2" && controller.screenHints.count == 2
        }

        XCTAssertTrue(controller.isConnected)
        XCTAssertFalse(controller.supportsLEDs)
        XCTAssertEqual(controller.legalTargets, ["e3", "e4"])
        XCTAssertEqual(controller.screenHints.map(\.square.notation).sorted(), ["e3", "e4"])
        XCTAssertTrue(controller.screenHints.allSatisfy { $0.pattern == .steady })
        XCTAssertFalse(controller.activeHintSummary.isEmpty)
        XCTAssertTrue(controller.gameStatus.contains("tablero virtual"))
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 80,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for asynchronous board state")
    }

    func testStockfishScoreInversionAndOrderingForCoaching() {
        XCTAssertEqual(StockfishScore.centipawns(-42).inverted, .centipawns(42))
        XCTAssertEqual(StockfishScore.mate(5).inverted, .mate(-5))
        XCTAssertTrue(StockfishScore.mate(5).isBetterForCoaching(than: .centipawns(10_000)))
        XCTAssertTrue(StockfishScore.centipawns(-10_000).isBetterForCoaching(than: .mate(-5)))
        XCTAssertTrue(StockfishScore.mate(3).isBetterForCoaching(than: .mate(7)))
        XCTAssertTrue(StockfishScore.mate(-9).isBetterForCoaching(than: .mate(-3)))
    }

    func testCentipawnLossUsesMoverPointOfViewForBlackAndSignChanges() {
        let baselineForBlack = StockfishScore.centipawns(50)
        let afterMoveFromWhitePointOfView = StockfishScore.centipawns(250)
        let afterMoveForBlack = afterMoveFromWhitePointOfView.inverted

        XCTAssertEqual(
            afterMoveForBlack.coachingLoss(comparedWith: baselineForBlack),
            .centipawns(300)
        )
    }

    func testMateTransitionsAreClassifiedWithoutSyntheticCentipawns() {
        let thresholds = MoveQualityThresholds(blunderThreshold: .fiveHundred)

        XCTAssertEqual(
            StockfishScore.centipawns(400).coachingLoss(comparedWith: .mate(5)),
            .decisive
        )
        XCTAssertEqual(
            StockfishScore.mate(-3).coachingLoss(comparedWith: .centipawns(-500)),
            .decisive
        )
        XCTAssertEqual(
            StockfishScore.mate(9).coachingLoss(comparedWith: .mate(5)),
            .centipawns(0)
        )
        XCTAssertEqual(
            StockfishScore.mate(3).coachingLoss(comparedWith: .centipawns(0)),
            .centipawns(0)
        )
        XCTAssertEqual(
            thresholds.classify(
                loss: StockfishScore.centipawns(400).coachingLoss(comparedWith: .mate(5))
            ),
            .blunder
        )
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

        let limited = try await engine.analyze(
            fen: startFEN,
            strength: StockfishStrength(elo: StockfishStrength.minimumElo)
        )
        XCTAssertFalse(limited.bestMove.isEmpty)
        XCTAssertGreaterThan(limited.nodes, 0)
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


private final class TestElectronicChessBoard: ElectronicChessBoard, @unchecked Sendable {
    let descriptor: ElectronicBoardDescriptor
    let capabilities: ElectronicBoardCapabilities
    let positionUpdates: AsyncStream<String>
    let connectionEvents: AsyncStream<ElectronicBoardConnectionEvent>

    private let positionContinuation: AsyncStream<String>.Continuation
    private let connectionContinuation: AsyncStream<ElectronicBoardConnectionEvent>.Continuation

    init(descriptor: ElectronicBoardDescriptor) {
        self.descriptor = descriptor
        capabilities = descriptor.capabilities

        var positionContinuation: AsyncStream<String>.Continuation!
        positionUpdates = AsyncStream { positionContinuation = $0 }
        self.positionContinuation = positionContinuation

        var connectionContinuation: AsyncStream<ElectronicBoardConnectionEvent>.Continuation!
        connectionEvents = AsyncStream { connectionContinuation = $0 }
        self.connectionContinuation = connectionContinuation
    }

    func connect() async throws {}
    func enableRealtimeUpdates() async throws {}

    func disconnect() async {
        connectionContinuation.yield(.disconnected)
    }

    func batteryStatus(timeout: Duration) async throws -> ElectronicBoardBatteryStatus {
        _ = timeout
        guard capabilities.contains(.battery) else {
            throw ElectronicBoardError.unsupportedCapability("batería")
        }
        return ElectronicBoardBatteryStatus(percentage: 73, isCharging: false)
    }

    func emitPosition(_ placement: String) {
        positionContinuation.yield(placement)
    }

    static func makeDescriptor(
        adapterIdentifier: String = "test.adapter",
        capabilities: ElectronicBoardCapabilities = [.positionReading, .realtimePosition]
    ) -> ElectronicBoardDescriptor {
        ElectronicBoardDescriptor(
            adapterIdentifier: adapterIdentifier,
            hardwareIdentifier: UUID().uuidString,
            name: "Test Board",
            manufacturer: "Tests",
            model: "Fake",
            variantIdentifier: "fake",
            capabilities: capabilities
        )
    }
}

private struct TestElectronicBoardFactory: ElectronicBoardAdapterFactory {
    let identifier: String
    let board: any ElectronicChessBoard

    init(board: any ElectronicChessBoard) {
        self.board = board
        identifier = board.descriptor.adapterIdentifier
    }

    func canCreateBoard(for descriptor: ElectronicBoardDescriptor) -> Bool {
        descriptor.adapterIdentifier == identifier
    }

    func makeBoard(for descriptor: ElectronicBoardDescriptor) throws -> any ElectronicChessBoard {
        guard canCreateBoard(for: descriptor) else {
            throw ElectronicBoardError.noAdapter(descriptor.name)
        }
        return board
    }
}

private struct TestElectronicBoardDiscovery: ElectronicChessBoardDiscovery {
    let devices: [ElectronicBoardDescriptor]

    func scan() -> AsyncStream<ElectronicBoardDescriptor> {
        AsyncStream { continuation in
            for device in devices {
                continuation.yield(device)
            }
            continuation.finish()
        }
    }
}
