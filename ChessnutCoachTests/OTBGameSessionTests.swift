import ChessKit
import XCTest
@testable import ChessnutCoach

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

        let promotionMove = try XCTUnwrap(physicalBoard.move(pieceAt: .e7, to: .e8))
        let pawnPlacement = placement(from: physicalBoard.position.fen)

        let pendingEvent = session.process(physicalPlacement: pawnPlacement)
        guard case let .promotionRequired(square, _) = pendingEvent else {
            return XCTFail("Expected promotionRequired, got \(pendingEvent)")
        }

        XCTAssertEqual(square, .e8)
        XCTAssertEqual(session.moves.count, 0)
        XCTAssertTrue(session.isPromotionPending)

        guard case let .promotion(move) = physicalBoard.state else {
            return XCTFail("Shadow board should require promotion")
        }
        _ = physicalBoard.completePromotion(of: move, to: .queen)

        let completedEvent = session.process(physicalPlacement: placement(from: physicalBoard.position.fen))
        guard case .moveCompleted = completedEvent else {
            return XCTFail("Expected moveCompleted after replacing pawn, got \(completedEvent)")
        }

        XCTAssertEqual(session.moves.count, 1)
        XCTAssertEqual(session.moves[0].promotion, "Q")
        XCTAssertFalse(session.isPromotionPending)
        _ = promotionMove
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