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

if needle not in text:
    print("No generated newline escaping to fix")
else:
    path.write_text(text.replace(needle, replacement, 1))
    print("Fixed generated Swift newline escaping")
