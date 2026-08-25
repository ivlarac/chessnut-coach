import ChessKit
import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import ChessnutCoachGameCore
#else
@testable import ChessnutCoach
#endif

final class GameClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testEveryPresetBuildsExpectedStructuredControl() {
        let expected: [GameTimePreset: GameTimeControl] = [
            .unlimited: .unlimited,
            .oneZero: .fischer(initialSeconds: 60, incrementSeconds: 0),
            .twoOne: .fischer(initialSeconds: 120, incrementSeconds: 1),
            .threeZero: .fischer(initialSeconds: 180, incrementSeconds: 0),
            .threeTwo: .fischer(initialSeconds: 180, incrementSeconds: 2),
            .fiveZero: .fischer(initialSeconds: 300, incrementSeconds: 0),
            .fiveThree: .fischer(initialSeconds: 300, incrementSeconds: 3),
            .tenZero: .fischer(initialSeconds: 600, incrementSeconds: 0),
            .tenFive: .fischer(initialSeconds: 600, incrementSeconds: 5),
            .fifteenTen: .fischer(initialSeconds: 900, incrementSeconds: 10),
            .thirtyZero: .fischer(initialSeconds: 1_800, incrementSeconds: 0),
            .thirtyTwenty: .fischer(initialSeconds: 1_800, incrementSeconds: 20),
        ]

        XCTAssertNil(GameTimePreset.custom.timeControl)
        for (preset, control) in expected {
            XCTAssertEqual(preset.timeControl, control, "Unexpected mapping for \(preset)")
        }
    }

    func testCustomControlValidationUsesCentralizedLimits() {
        XCTAssertEqual(
            GameTimeLimits.customControl(initialMinutes: 7, incrementSeconds: 4),
            .fischer(initialSeconds: 420, incrementSeconds: 4)
        )
        XCTAssertNil(GameTimeLimits.customControl(initialMinutes: 0, incrementSeconds: 4))
        XCTAssertNil(GameTimeLimits.customControl(initialMinutes: 7, incrementSeconds: -1))
        XCTAssertNil(GameTimeLimits.customControl(initialMinutes: 181, incrementSeconds: 4))

        var draft = standardDraft()
        draft.timePreset = .custom
        draft.customInitialMinutes = 0
        XCTAssertFalse(draft.canLaunch)
        draft.customInitialMinutes = 12
        draft.customIncrementSeconds = 8
        XCTAssertEqual(
            draft.makeLaunch(randomValue: true)?.configuration.timeControl,
            .fischer(initialSeconds: 720, incrementSeconds: 8)
        )
    }

    func testUnlimitedGameKeepsLegacyBehaviorAndHasNoClock() {
        var session = OTBGameSession(timeControl: .unlimited)
        session.startClockIfNeeded(at: start)
        XCTAssertNil(session.clockState)

        let lifted = session.process(
            physicalPlacement: "rnbqkbnr/pppppppp/8/8/8/8/PPPP1PPP/RNBQKBNR",
            at: start.addingTimeInterval(20)
        )
        guard case .pieceLifted = lifted else { return XCTFail("Expected a lifted piece") }
        XCTAssertEqual(session.sideToMove, .white)
        XCTAssertTrue(session.moves.isEmpty)
    }

    func testClockStartsWithWhiteAndUsesTimestamps() throws {
        var clock = GameClockState(timeControl: .fischer(initialSeconds: 300, incrementSeconds: 3))
        XCTAssertEqual(clock.pauseReason, .initialSetup)
        clock.start(at: start)

        XCTAssertEqual(clock.activeSide, .white)
        XCTAssertEqual(clock.remaining(for: .white, at: start.addingTimeInterval(4)), 296, accuracy: 0.001)
        XCTAssertEqual(clock.remaining(for: .black, at: start.addingTimeInterval(4)), 300, accuracy: 0.001)

        XCTAssertTrue(clock.completeMove(by: .white, at: start.addingTimeInterval(4)))
        XCTAssertEqual(clock.remaining(for: .white, at: start.addingTimeInterval(4)), 299, accuracy: 0.001)
        XCTAssertEqual(clock.activeSide, .black)
    }

    func testCompletedOTBMoveAppliesIncrementAndChangesClock() throws {
        var session = timedSession()
        session.startClockIfNeeded(at: start)
        var physical = Board()
        _ = try XCTUnwrap(physical.move(pieceAt: .e2, to: .e4))

        let event = session.process(
            physicalPlacement: placement(physical.position.fen),
            at: start.addingTimeInterval(4)
        )
        guard case .moveCompleted = event else { return XCTFail("Expected completed move") }
        XCTAssertEqual(session.clockRemaining(for: .white, at: start.addingTimeInterval(4))!, 299, accuracy: 0.001)
        XCTAssertEqual(session.clockRemaining(for: .black, at: start.addingTimeInterval(4))!, 300, accuracy: 0.001)
        XCTAssertEqual(session.clockState?.activeSide, .black)
    }

    func testLiftReturnIntermediateAndIllegalPositionsNeverChangeClockTurn() throws {
        var session = timedSession()
        session.startClockIfNeeded(at: start)

        let liftedPlacement = "rnbqkbnr/pppppppp/8/8/8/8/PPPP1PPP/RNBQKBNR"
        guard case .pieceLifted = session.process(
            physicalPlacement: liftedPlacement,
            at: start.addingTimeInterval(1)
        ) else { return XCTFail("Expected lift") }
        XCTAssertEqual(session.clockState?.activeSide, .white)

        guard case .synchronized = session.process(
            physicalPlacement: placement(Position.standard.fen),
            at: start.addingTimeInterval(2)
        ) else { return XCTFail("Expected returned piece") }
        XCTAssertEqual(session.clockState?.activeSide, .white)

        let intermediate = "rnbqkbnr/pppp1ppp/8/8/8/8/PPPPPPPP/RNBQKBNR"
        guard case .intermediate = session.process(
            physicalPlacement: intermediate,
            at: start.addingTimeInterval(3)
        ) else { return XCTFail("Expected intermediate placement") }
        XCTAssertEqual(session.clockState?.activeSide, .white)

        let illegal = "rnbqkbnr/pppppppp/8/4P3/8/8/PPPP1PPP/RNBQKBNR"
        guard case .invalid = session.process(
            physicalPlacement: illegal,
            at: start.addingTimeInterval(4)
        ) else { return XCTFail("Expected illegal placement") }
        XCTAssertEqual(session.clockState?.activeSide, .white)
        XCTAssertTrue(session.moves.isEmpty)
    }

    func testPromotionChangesClockOnlyAfterItIsResolved() throws {
        let position = try XCTUnwrap(Position(fen: "7k/P7/8/8/8/8/8/7K w - - 0 1"))
        var session = OTBGameSession(position: position, timeControl: .fischer(initialSeconds: 60, incrementSeconds: 2))
        session.startClockIfNeeded(at: start)

        var pawnOnLastRank = Board(position: position)
        _ = try XCTUnwrap(pawnOnLastRank.move(pieceAt: .a7, to: .a8))
        guard case .promotionRequired = session.process(
            physicalPlacement: placement(pawnOnLastRank.position.fen),
            at: start.addingTimeInterval(3)
        ) else { return XCTFail("Expected pending promotion") }
        XCTAssertEqual(session.clockState?.activeSide, .white)
        XCTAssertTrue(session.moves.isEmpty)

        _ = pawnOnLastRank.completePromotion(
            of: try XCTUnwrap(promotionMove(in: pawnOnLastRank)),
            to: .queen
        )
        guard case .moveCompleted = session.process(
            physicalPlacement: placement(pawnOnLastRank.position.fen),
            at: start.addingTimeInterval(5)
        ) else { return XCTFail("Expected completed promotion") }
        XCTAssertEqual(session.clockRemaining(for: .white, at: start.addingTimeInterval(5))!, 57, accuracy: 0.001)
        XCTAssertEqual(session.clockState?.activeSide, .black)
    }

    func testWhiteAndBlackTimeoutProduceExplicitResults() throws {
        var whiteFlags = OTBGameSession(timeControl: .fischer(initialSeconds: 5, incrementSeconds: 0))
        whiteFlags.startClockIfNeeded(at: start)
        XCTAssertEqual(whiteFlags.processClockTimeoutIfNeeded(at: start.addingTimeInterval(5)), .white)
        XCTAssertEqual(whiteFlags.result, .blackWin(reason: .timeout))
        XCTAssertTrue(whiteFlags.isFinished)

        var blackFlags = OTBGameSession(timeControl: .fischer(initialSeconds: 5, incrementSeconds: 0))
        blackFlags.startClockIfNeeded(at: start)
        var physical = Board()
        _ = try XCTUnwrap(physical.move(pieceAt: .e2, to: .e4))
        _ = blackFlags.process(
            physicalPlacement: placement(physical.position.fen),
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(blackFlags.processClockTimeoutIfNeeded(at: start.addingTimeInterval(6)), .black)
        XCTAssertEqual(blackFlags.result, .whiteWin(reason: .timeout))
    }

    func testSuspensionAndRestorationRecalculateFromPersistedTimestamp() throws {
        var session = timedSession()
        session.startClockIfNeeded(at: start)
        XCTAssertEqual(session.clockRemaining(for: .white, at: start.addingTimeInterval(17))!, 283, accuracy: 0.001)

        let data = try JSONEncoder().encode(session.gameRecord)
        let record = try JSONDecoder().decode(GameRecord.self, from: data)
        var restored = try OTBGameSession(restoring: record)
        XCTAssertEqual(restored.clockRemaining(for: .white, at: start.addingTimeInterval(25))!, 275, accuracy: 0.001)
        XCTAssertNil(restored.processClockTimeoutIfNeeded(at: start.addingTimeInterval(25)))
    }

    func testLegacyRecordWithoutClockFieldsDecodesAsUnlimited() throws {
        let record = GameRecord(initialFEN: Position.standard.fen)
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "timeControl")
        object.removeValue(forKey: "clockState")

        let decoded = try JSONDecoder().decode(
            GameRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.timeControl, .unlimited)
        XCTAssertNil(decoded.clockState)
    }

    func testUndoRestoresPreMoveClockSnapshotAndRemovesIncrement() throws {
        var session = OTBGameSession(
            allowUndo: true,
            timeControl: .fischer(initialSeconds: 300, incrementSeconds: 3)
        )
        session.startClockIfNeeded(at: start)
        var physical = Board()
        _ = try XCTUnwrap(physical.move(pieceAt: .e2, to: .e4))
        _ = session.process(
            physicalPlacement: placement(physical.position.fen),
            at: start.addingTimeInterval(4)
        )
        _ = try XCTUnwrap(physical.move(pieceAt: .e7, to: .e5))
        _ = session.process(
            physicalPlacement: placement(physical.position.fen),
            at: start.addingTimeInterval(6)
        )

        XCTAssertNotNil(session.undoLastMove(awaitPhysicalRestore: false, at: start.addingTimeInterval(10)))
        XCTAssertEqual(session.clockState?.activeSide, .black)
        XCTAssertEqual(session.clockRemaining(for: .white, at: start.addingTimeInterval(10))!, 299, accuracy: 0.001)
        XCTAssertEqual(session.clockRemaining(for: .black, at: start.addingTimeInterval(10))!, 298, accuracy: 0.001)
    }

    func testClockConfigurationIsIndependentOfPersonStockfishAndMaiaModes() {
        let control = GameTimeControl.fischer(initialSeconds: 600, incrementSeconds: 5)
        let person = OTBGameSession(mode: .twoPlayer, timeControl: control)
        let stockfish = OTBGameSession(
            mode: .solo,
            humanSide: .white,
            opponentEngine: .stockfish(StockfishStrength(level: 4)),
            timeControl: control
        )
        let maia = OTBGameSession(
            mode: .solo,
            humanSide: .white,
            opponentEngine: .maia3(Maia3Strength(rating: 800)),
            timeControl: control
        )

        XCTAssertEqual(person.timeControl, control)
        XCTAssertEqual(stockfish.timeControl, control)
        XCTAssertEqual(maia.timeControl, control)
        XCTAssertEqual(stockfish.gameRecord.opponentEngine?.kind, .stockfish18)
        XCTAssertEqual(maia.gameRecord.opponentEngine?.kind, .maia3)
    }

    func testPhysicalEngineTransferPausesBothClocksUntilMoveConfirmation() throws {
        let control = GameTimeControl.fischer(initialSeconds: 300, incrementSeconds: 3)
        var session = OTBGameSession(
            whitePlayer: "Jugador",
            blackPlayer: "Maia 3",
            mode: .solo,
            humanSide: .white,
            opponentEngine: .maia3(Maia3Strength(rating: 800)),
            timeControl: control
        )
        session.startClockIfNeeded(at: start)
        var physical = Board()
        _ = try XCTUnwrap(physical.move(pieceAt: .e2, to: .e4))
        _ = session.process(
            physicalPlacement: placement(physical.position.fen),
            at: start.addingTimeInterval(4)
        )

        session.pauseClockForEngineMoveTransfer(at: start.addingTimeInterval(6))
        XCTAssertEqual(session.clockState?.pauseReason, .engineMoveTransfer)
        XCTAssertEqual(session.clockRemaining(for: .black, at: start.addingTimeInterval(30))!, 298, accuracy: 0.001)

        let expected = try XCTUnwrap(OTBExpectedMove(uci: "e7e5"))
        _ = try XCTUnwrap(physical.move(pieceAt: .e7, to: .e5))
        guard case .moveCompleted = session.process(
            physicalPlacement: placement(physical.position.fen),
            at: start.addingTimeInterval(30),
            requiredMove: expected
        ) else { return XCTFail("Expected physical engine move confirmation") }
        XCTAssertEqual(session.clockRemaining(for: .black, at: start.addingTimeInterval(30))!, 301, accuracy: 0.001)
        XCTAssertEqual(session.clockState?.activeSide, .white)
        XCTAssertTrue(session.clockState?.isRunning == true)
    }

    func testPGNTimeControlAndUnlimitedExport() {
        let timed = GameRecord(
            initialFEN: Position.standard.fen,
            timeControl: .fischer(initialSeconds: 300, incrementSeconds: 3)
        )
        XCTAssertTrue(PGNExporter.pgn(for: timed).contains("[TimeControl \"300+3\"]"))

        let unlimited = GameRecord(initialFEN: Position.standard.fen)
        XCTAssertFalse(PGNExporter.pgn(for: unlimited).contains("[TimeControl"))
    }

    func testTimeControlAndClockStateRoundTripThroughPersistence() throws {
        var clock = GameClockState(timeControl: .fischer(initialSeconds: 180, incrementSeconds: 2))
        clock.start(at: start)
        let record = GameRecord(
            initialFEN: Position.standard.fen,
            timeControl: clock.timeControl,
            clockState: clock
        )

        let decoded = try JSONDecoder().decode(
            GameRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.timeControl, record.timeControl)
        XCTAssertEqual(decoded.clockState, record.clockState)
    }

    private func timedSession() -> OTBGameSession {
        OTBGameSession(timeControl: .fischer(initialSeconds: 300, incrementSeconds: 3))
    }

    private func standardDraft() -> NewGameDraft {
        NewGameDraft(
            whitePlayerName: "Ana",
            blackPlayerName: "Luis",
            whiteAssistance: .off,
            blackAssistance: .off
        )
    }

    private func placement(_ fen: String) -> String {
        fen.split(separator: " ").first.map(String.init) ?? fen
    }

    private func promotionMove(in board: Board) -> Move? {
        guard case let .promotion(move) = board.state else { return nil }
        return move
    }
}
