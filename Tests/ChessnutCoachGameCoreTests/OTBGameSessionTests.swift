import ChessKit
import XCTest
@testable import ChessnutCoachGameCore

final class OTBGameSessionTests: XCTestCase {
    private let initial = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"

    func testLiftedPawnReportsLegalTargetsWithoutChangingTurn() {
        var session = OTBGameSession()
        XCTAssertEqual(session.process(physicalPlacement: initial), .synchronized)

        let event = session.process(
            physicalPlacement: "rnbqkbnr/pppppppp/8/8/8/8/PPPP1PPP/RNBQKBNR"
        )

        guard case let .pieceLifted(source, targets) = event else {
            return XCTFail("Expected pieceLifted, got \(event)")
        }

        XCTAssertEqual(source.notation, "e2")
        XCTAssertEqual(Set(targets.map(\.notation)), Set(["e3", "e4"]))
        XCTAssertEqual(session.sideToMove, .white)
        XCTAssertTrue(session.moves.isEmpty)
    }

    func testCompletedMoveIsRecordedAndChangesTurn() {
        var session = OTBGameSession()

        let event = session.process(
            physicalPlacement: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"
        )

        guard case let .moveCompleted(move) = event else {
            return XCTFail("Expected moveCompleted, got \(event)")
        }

        XCTAssertEqual(move.san, "e4")
        XCTAssertEqual(session.sideToMove, .black)
        XCTAssertEqual(session.moves.count, 1)
        XCTAssertEqual(session.moves[0].ply, 1)
        XCTAssertEqual(session.moves[0].san, "e4")
        XCTAssertEqual(session.moves[0].lan, "e2e4")
        XCTAssertEqual(session.moves[0].from, "e2")
        XCTAssertEqual(session.moves[0].to, "e4")
        XCTAssertEqual(session.result, .unfinished)
    }

    func testIllegalPhysicalMoveDoesNotMutateLogicalGame() {
        var session = OTBGameSession()

        let event = session.process(
            physicalPlacement: "rnbqkbnr/pppppppp/8/4P3/8/8/PPPP1PPP/RNBQKBNR"
        )

        guard case .invalid = event else {
            return XCTFail("Expected invalid, got \(event)")
        }

        XCTAssertEqual(session.logicalPlacement, initial)
        XCTAssertEqual(session.sideToMove, .white)
        XCTAssertTrue(session.moves.isEmpty)
    }

    func testMoveHistoryKeepsSANAndFENForSeveralPlies() {
        var session = OTBGameSession()

        _ = session.process(
            physicalPlacement: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"
        )
        _ = session.process(
            physicalPlacement: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR"
        )
        _ = session.process(
            physicalPlacement: "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R"
        )

        XCTAssertEqual(session.moves.map(\.san), ["e4", "e5", "Nf3"])
        XCTAssertEqual(session.moves.map(\.ply), [1, 2, 3])
        XCTAssertTrue(session.moves.allSatisfy { !$0.fenBefore.isEmpty && !$0.fenAfter.isEmpty })
        XCTAssertEqual(session.sideToMove, .black)
    }

    func testFoolsMateFinishesGameWithBlackWin() {
        var session = OTBGameSession()

        _ = session.process(
            physicalPlacement: "rnbqkbnr/pppppppp/8/8/8/5P2/PPPPP1PP/RNBQKBNR"
        )
        _ = session.process(
            physicalPlacement: "rnbqkbnr/pppp1ppp/8/4p3/8/5P2/PPPPP1PP/RNBQKBNR"
        )
        _ = session.process(
            physicalPlacement: "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR"
        )
        let event = session.process(
            physicalPlacement: "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR"
        )

        guard case .moveCompleted = event else {
            return XCTFail("Expected final move to complete, got \(event)")
        }

        XCTAssertEqual(session.moves.last?.san, "Qh4#")
        XCTAssertEqual(session.result, .blackWin(reason: .checkmate))
        XCTAssertTrue(session.isFinished)
        XCTAssertNotNil(session.gameRecord.endedAt)
    }

    func testCastlingMatchesFinalPhysicalPosition() throws {
        let position = try XCTUnwrap(Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"))
        var session = OTBGameSession(position: position)

        let event = session.process(
            physicalPlacement: "r3k2r/8/8/8/8/8/8/R4RK1"
        )

        guard case .moveCompleted = event else {
            return XCTFail("Expected castling move, got \(event)")
        }

        XCTAssertEqual(session.moves.count, 1)
        XCTAssertEqual(session.moves[0].san, "O-O")
        XCTAssertEqual(session.moves[0].from, "e1")
        XCTAssertEqual(session.moves[0].to, "g1")
    }

    func testEnPassantMatchesPhysicalCapture() throws {
        let position = try XCTUnwrap(Position(fen: "7k/8/8/3pP3/8/8/8/7K w - d6 0 1"))
        var session = OTBGameSession(position: position)

        let event = session.process(
            physicalPlacement: "7k/8/3P4/8/8/8/8/7K"
        )

        guard case .moveCompleted = event else {
            return XCTFail("Expected en passant capture, got \(event)")
        }

        XCTAssertEqual(session.moves.count, 1)
        XCTAssertEqual(session.moves[0].from, "e5")
        XCTAssertEqual(session.moves[0].to, "d6")
        XCTAssertEqual(session.moves[0].san, "exd6")
    }

    func testPromotionCanBeCompletedByReplacingPawnPhysically() throws {
        let position = try XCTUnwrap(Position(fen: "7k/P7/8/8/8/8/8/7K w - - 0 1"))
        var session = OTBGameSession(position: position)

        let pending = session.process(
            physicalPlacement: "P6k/8/8/8/8/8/8/7K"
        )

        guard case let .promotionRequired(square, _) = pending else {
            return XCTFail("Expected promotionRequired, got \(pending)")
        }
        XCTAssertEqual(square.notation, "a8")
        XCTAssertTrue(session.isPromotionPending)
        XCTAssertTrue(session.moves.isEmpty)

        let completed = session.process(
            physicalPlacement: "Q6k/8/8/8/8/8/8/7K"
        )

        guard case .moveCompleted = completed else {
            return XCTFail("Expected promoted move to complete, got \(completed)")
        }

        XCTAssertFalse(session.isPromotionPending)
        XCTAssertEqual(session.moves.count, 1)
        XCTAssertEqual(session.moves[0].promotion, "Q")
        XCTAssertTrue(session.moves[0].san.contains("=Q"))
        XCTAssertEqual(session.logicalPlacement, "Q6k/8/8/8/8/8/8/7K")
    }

    func testManualGameEndings() {
        var resigned = OTBGameSession()
        XCTAssertEqual(resigned.resign(color: .white), .blackWin(reason: .resignation))
        XCTAssertTrue(resigned.isFinished)

        var draw = OTBGameSession()
        XCTAssertEqual(draw.agreeDraw(), .draw(reason: .agreement))
        XCTAssertTrue(draw.isFinished)

        var aborted = OTBGameSession()
        aborted.abort()
        XCTAssertTrue(aborted.isFinished)
        XCTAssertEqual(aborted.result, .unfinished)
        XCTAssertEqual(aborted.gameRecord.status, .aborted)
    }
}
