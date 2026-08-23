#!/usr/bin/env python3
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path, pattern, replacement, *, flags=0, label="replacement"):
    file_path = ROOT / path
    text = file_path.read_text()
    updated, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f"Expected exactly one {label} in {path}, found {count}")
    file_path.write_text(updated)


# ReplayPiece now carries semantic piece kind and exposes the asset catalog name.
replace_once(
    "ChessnutCoach/GameArchive.swift",
    r"struct ReplayPiece: Equatable, Sendable \{.*?\n\}\n\nenum ChessBoardPerspective",
    '''enum ReplayPieceKind: String, Equatable, Sendable {
    case king
    case queen
    case rook
    case bishop
    case knight
    case pawn
}

struct ReplayPiece: Equatable, Sendable {
    let kind: ReplayPieceKind
    let color: ReplayPieceColor

    var assetName: String {
        let colorPrefix = color == .white ? "white" : "black"
        return "\\(colorPrefix)_\\(kind.rawValue)"
    }
}

enum ChessBoardPerspective''',
    flags=re.S,
    label="ReplayPiece model replacement",
)

replace_once(
    "ChessnutCoach/GameArchive.swift",
    r"    private static let pieces: \[Character: ReplayPiece\] = \[.*?\n    \]\n\}",
    '''    private static let pieces: [Character: ReplayPiece] = [
        "K": ReplayPiece(kind: .king, color: .white),
        "Q": ReplayPiece(kind: .queen, color: .white),
        "R": ReplayPiece(kind: .rook, color: .white),
        "B": ReplayPiece(kind: .bishop, color: .white),
        "N": ReplayPiece(kind: .knight, color: .white),
        "P": ReplayPiece(kind: .pawn, color: .white),
        "k": ReplayPiece(kind: .king, color: .black),
        "q": ReplayPiece(kind: .queen, color: .black),
        "r": ReplayPiece(kind: .rook, color: .black),
        "b": ReplayPiece(kind: .bishop, color: .black),
        "n": ReplayPiece(kind: .knight, color: .black),
        "p": ReplayPiece(kind: .pawn, color: .black),
    ]
}''',
    flags=re.S,
    label="ReplayPiece FEN mapping replacement",
)

# Common visual component. 0.97 frame * 0.906 non-transparent artwork height ~= 0.88 square.
app_theme = ROOT / "ChessnutCoach/AppTheme.swift"
text = app_theme.read_text()
if "struct ChessPieceView: View" in text:
    raise SystemExit("ChessPieceView already exists unexpectedly")
text += '''

struct ChessPieceView: View {
    let piece: ReplayPiece
    let squareSize: CGFloat

    var body: some View {
        Image(piece.assetName)
            .resizable()
            .scaledToFit()
            .frame(width: squareSize * 0.97, height: squareSize * 0.97)
            .accessibilityLabel(piece.assetName.replacingOccurrences(of: "_", with: " "))
    }
}
'''
app_theme.write_text(text)

# Replace Unicode piece glyphs in the interactive/on-screen board.
replace_once(
    "ChessnutCoach/CurrentGameView.swift",
    r'''(?P<indent>[ \t]*)Text\(piece\.textSymbol\)\n[ \t]+\.font\(\.system\(size: squareSize \* 0\.74, design: \.serif\)\)\n[ \t]+\.foregroundStyle\(piece\.color == \.white \? Color\.white : Color\.black\)\n[ \t]+\.shadow\(\n[ \t]+color: \(piece\.color == \.white \? Color\.black : Color\.white\)\.opacity\(0\.7\),\n[ \t]+radius: 1\n[ \t]+\)\n[ \t]+\.minimumScaleFactor\(0\.5\)''',
    r'''\g<indent>ChessPieceView(piece: piece, squareSize: squareSize)''',
    label="OnScreenChessBoard Unicode renderer",
)

# Replace Unicode piece glyphs in replay/analysis board.
replace_once(
    "ChessnutCoach/GameLibraryView.swift",
    r'''(?P<indent>[ \t]*)Text\(piece\.textSymbol\)\n[ \t]+\.font\(\.system\(size: squareSize \* 0\.72, design: \.serif\)\)\n[ \t]+\.foregroundStyle\(piece\.foregroundColor\)\n[ \t]+\.shadow\(\n[ \t]+color: piece\.contrastColor\.opacity\(0\.65\),\n[ \t]+radius: 1\n[ \t]+\)\n[ \t]+\.minimumScaleFactor\(0\.5\)''',
    r'''\g<indent>ChessPieceView(piece: piece, squareSize: squareSize)''',
    label="ReplayBoardView Unicode renderer",
)

replace_once(
    "ChessnutCoach/GameLibraryView.swift",
    r'''\nprivate extension ReplayPiece \{\n    var foregroundColor: Color \{\n        color == \.white \? \.white : \.black\n    \}\n\n    var contrastColor: Color \{\n        color == \.white \? \.black : \.white\n    \}\n\}\n''',
    "\n",
    label="obsolete ReplayPiece color extension",
)

# Replace text-symbol test with complete asset mapping coverage.
replace_once(
    "ChessnutCoachTests/OTBGameSessionTests.swift",
    r'''    func testReplayBoardUsesFENColorAndForcesTextPresentationForEveryPiece\(\) throws \{.*?\n    \}\n\n    func testChessUpPositionCodecMapsTheInitialPosition''',
    '''    func testReplayBoardUsesFENColorAndAssetMappingForEveryPiece() throws {
        let fen = Position.standard.fen
        let blackBackRankAssets = [
            "black_rook", "black_knight", "black_bishop", "black_queen",
            "black_king", "black_bishop", "black_knight", "black_rook",
        ]
        let whiteBackRankAssets = [
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
            XCTAssertEqual(blackBackRank.assetName, blackBackRankAssets[file])
            XCTAssertEqual(blackPawn.assetName, "black_pawn")
            XCTAssertEqual(whitePawn.assetName, "white_pawn")
            XCTAssertEqual(whiteBackRank.assetName, whiteBackRankAssets[file])
        }

        XCTAssertNil(GameReplay.piece(in: fen, rankIndex: 4, fileIndex: 4))
    }

    func testChessUpPositionCodecMapsTheInitialPosition''',
    flags=re.S,
    label="ReplayPiece asset mapping test",
)

# Xcode version/build bump exactly once for this PR (Debug + Release settings).
project = ROOT / "ChessnutCoach.xcodeproj/project.pbxproj"
text = project.read_text()
if text.count("CURRENT_PROJECT_VERSION = 17;") != 2:
    raise SystemExit("Expected build 17 in exactly two target configurations")
if text.count("MARKETING_VERSION = 0.0.17;") != 2:
    raise SystemExit("Expected marketing version 0.0.17 in exactly two target configurations")
text = text.replace("CURRENT_PROJECT_VERSION = 17;", "CURRENT_PROJECT_VERSION = 18;")
text = text.replace("MARKETING_VERSION = 0.0.17;", "MARKETING_VERSION = 0.0.18;")
project.write_text(text)

# Add each PNG as its own imageset. PNG files are already present in the bootstrap commit.
asset_names = [
    "white_king", "white_queen", "white_rook", "white_bishop", "white_knight", "white_pawn",
    "black_king", "black_queen", "black_rook", "black_bishop", "black_knight", "black_pawn",
]
for asset_name in asset_names:
    imageset = ROOT / "ChessnutCoach/Assets.xcassets" / f"{asset_name}.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    contents = {
        "images": [
            {"filename": f"{asset_name}.png", "idiom": "universal", "scale": "1x"},
            {"idiom": "universal", "scale": "2x"},
            {"idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (imageset / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")

# Bootstrap artifacts must not remain in the final PR diff.
(ROOT / "Scripts/apply_png_piece_assets.py").unlink()
(ROOT / ".github/workflows/apply-png-piece-assets.yml").unlink()
