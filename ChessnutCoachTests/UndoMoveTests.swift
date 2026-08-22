import ChessKit
import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import ChessnutCoachGameCore
#else
@testable import ChessnutCoach
#endif

final class UndoMoveTests: XCTestCase {
    func testPhysicalReturnToPreviousPositionAutomaticallyUndoesWhenEnabled() {
        var session = OTBGameSession(allowUndo: true)
        var physicalBoard = Board()

        let played = play(.e2, .e4, to: &session, physicalBoard: &physicalBoard)
        guard case .moveCompleted = played else {
            return XCTFail("Expected e2-e4 to complete")
        }
        XCTAssertEqual(session.moves.count, 1)
        XCTAssertEqual(session.sideToMove, .black)

        let event = session.process(physicalPlacement: placement(from: Position.standard.fen))

        guard case let .moveUndone(move) = event else {
            return XCTFail("Expected automatic moveUndone, got \(event)")
        }
        XCTAssertEqual(move.san, "e4")
        XCTAssertTrue(session.moves.isEmpty)
        XCTAssertEqual(session.sideToMove, .white)
        XCTAssertEqual(session.logicalPlacement, placement(from: Position.standard.fen))
        XCTAssertTrue(session.isSynchronized)
        XCTAssertFalse(session.isAwaitingPhysicalUndo)
    }

    func testPhysicalReturnDoesNotUndoWhenOptionIsDisabled() {
        var session = OTBGameSession(allowUndo: false)
        var physicalBoard = Board()

        _ = play(.e2, .e4, to: &session, physicalBoard: &physicalBoard)
        let event = session.process(physicalPlacement: placement(from: Position.standard.fen))

        if case .moveUndone = event {
            XCTFail("Undo must remain disabled")
        }
        XCTAssertEqual(session.moves.count, 1)
        XCTAssertEqual(session.sideToMove, .black)
        XCTAssertFalse(session.isSynchronized)
    }

    func testManualUndoWaitsForPhysicalBoardToReturnBeforeContinuing() {
        var session = OTBGameSession(allowUndo: true)
        var physicalBoard = Board()

        _ = play(.e2, .e4, to: &session, physicalBoard: &physicalBoard)
        XCTAssertTrue(session.canUndoLastMove)

        let undone = session.undoLastMove()

        XCTAssertEqual(undone?.san, "e4")
        XCTAssertTrue(session.moves.isEmpty)
        XCTAssertEqual(session.sideToMove, .white)
        XCTAssertTrue(session.isAwaitingPhysicalUndo)
        XCTAssertFalse(session.isSynchronized)
        XCTAssertFalse(session.canUndoLastMove)

        let postMovePlacement = placement(from: physicalBoard.position.fen)
        let waiting = session.process(physicalPlacement: postMovePlacement)
        guard case .intermediate = waiting else {
            return XCTFail("The session must wait for the physical rollback")
        }
        XCTAssertTrue(session.isAwaitingPhysicalUndo)

        let synchronized = session.process(physicalPlacement: placement(from: Position.standard.fen))
        guard case .synchronized = synchronized else {
            return XCTFail("Returning the pieces must complete the manual undo")
        }
        XCTAssertFalse(session.isAwaitingPhysicalUndo)
        XCTAssertTrue(session.isSynchronized)
    }

    func testSoloGamesNeverEnableUndoEvenIfConfigurationRequestsIt() {
        let session = OTBGameSession(
            mode: .solo,
            humanSide: .white,
            engineStrength: StockfishStrength(level: 4),
            engineName: "Stockfish 18",
            allowUndo: true
        )

        XCTAssertFalse(session.gameRecord.allowUndo)
        XCTAssertFalse(session.canUndoLastMove)
    }

    func testUndoSettingSurvivesPersistenceAndLegacyRecordsDefaultToDisabled() throws {
        let record = GameRecord(
            initialFEN: Position.standard.fen,
            allowUndo: true
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(GameRecord.self, from: encoded)
        XCTAssertTrue(decoded.allowUndo)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "allowUndo")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyRecord = try JSONDecoder().decode(GameRecord.self, from: legacyData)
        XCTAssertFalse(legacyRecord.allowUndo)
    }

    @discardableResult
    private func play(
        _ from: Square,
        _ to: Square,
        to session: inout OTBGameSession,
        physicalBoard: inout Board
    ) -> OTBGameEvent {
        guard physicalBoard.move(pieceAt: from, to: to) != nil else {
            XCTFail("Shadow move \(from.notation)-\(to.notation) should be legal")
            return .invalid("shadow move failed")
        }

        return session.process(physicalPlacement: placement(from: physicalBoard.position.fen))
    }

    private func placement(from fen: String) -> String {
        fen.split(separator: " ").first.map(String.init) ?? fen
    }
}
