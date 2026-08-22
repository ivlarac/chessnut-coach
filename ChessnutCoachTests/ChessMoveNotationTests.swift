import XCTest
#if SWIFT_PACKAGE
@testable import ChessnutCoachGameCore
#else
@testable import ChessnutCoach
#endif

final class ChessMoveNotationTests: XCTestCase {
    func testSANDisambiguatesRooksOnSameFileByRank() {
        let fen = "r3k2r/p3npb1/1pp1p1pp/4P3/1n3B2/2NR1N2/PPP2PPP/3R2K1 w - - 0 1"

        XCTAssertEqual(
            ChessMoveNotation.san(forUCI: "d3d2", inFEN: fen),
            "R3d2"
        )
    }

    func testSANKnightCaptureIncludesCaptureMarker() {
        let fen = "r3k2r/p2R1pb1/1pp1p1pp/3NP3/1n3B2/5N2/PPP2PPP/3R2K1 b - - 0 1"

        XCTAssertEqual(
            ChessMoveNotation.san(forUCI: "b4d5", inFEN: fen),
            "Nxd5"
        )
    }
}
