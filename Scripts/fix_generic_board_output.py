from pathlib import Path

path = Path("ChessnutCoach/CurrentGameView.swift")
text = path.read_text()
needle = r'''.disabled((board.hasActiveGame && board.isSoloGame && board.humanSide == .white) || (board.isConnected && !board.supportsLEDs))\n\n            if board.isConnected && !board.supportsLEDs {\n                Text("Las ayudas por LED no están disponibles con el tablero conectado actualmente.")\n                    .font(.footnote)\n                    .foregroundStyle(.secondary)\n            }\n\n            if !board.activeHintSummary.isEmpty {'''
replacement = '''.disabled((board.hasActiveGame && board.isSoloGame && board.humanSide == .white) || (board.isConnected && !board.supportsLEDs))

            if board.isConnected && !board.supportsLEDs {
                Text("Las ayudas por LED no están disponibles con el tablero conectado actualmente.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !board.activeHintSummary.isEmpty {'''

if needle in text:
    path.write_text(text.replace(needle, replacement, 1))
    print("Fixed generated Swift newline escaping")
else:
    print("No generated newline escaping to fix")

renames = {
    "ChessnutAppPhase": "ElectronicBoardAppPhase",
    "ChessnutLifecycleDirective": "ElectronicBoardLifecycleDirective",
    "ChessnutSessionLifecycle": "ElectronicBoardSessionLifecycle",
}

for relative_path in [
    "ChessnutCoach/GameModels.swift",
    "ChessnutCoach/BoardController.swift",
    "ChessnutCoachTests/OTBGameSessionTests.swift",
]:
    file_path = Path(relative_path)
    source = file_path.read_text()
    updated = source
    for old, new in renames.items():
        updated = updated.replace(old, new)
    if updated != source:
        file_path.write_text(updated)
        print(f"Renamed board lifecycle symbols in {relative_path}")
