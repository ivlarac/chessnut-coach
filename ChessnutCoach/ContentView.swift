import SwiftUI

struct ContentView: View {
    @StateObject private var board = BoardController()
    @State private var rankIndex = 0
    @State private var fileIndex = 0

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                gameSection
                positionSection
                ledSection
                notesSection
            }
            .navigationTitle("Chessnut Coach")
        }
    }

    private var connectionSection: some View {
        Section("Chessnut Air") {
            LabeledContent("Estado", value: board.status)

            if let battery = board.batteryPercentage {
                LabeledContent("Batería", value: "\(battery)%")
            }

            if board.isConnected {
                Button("Actualizar batería") {
                    board.refreshBattery()
                }

                Button("Desconectar", role: .destructive) {
                    board.disconnect()
                }
            } else {
                Button("Conectar") {
                    board.connect()
                }
            }
        }
    }

    private var gameSection: some View {
        Section("Partida OTB") {
            LabeledContent("Turno", value: board.sideToMoveLabel)
            LabeledContent(
                "Tablero",
                value: board.isBoardSynchronized ? "Sincronizado" : "En movimiento"
            )

            Text(board.gameStatus)

            if let liftedSquare = board.liftedSquare {
                LabeledContent("Pieza levantada", value: liftedSquare)
            }

            if !board.legalTargets.isEmpty {
                LabeledContent("Destinos legales", value: board.legalTargets.joined(separator: ", "))
            }

            if let lastMove = board.lastMove {
                LabeledContent("Último movimiento", value: lastMove)
            }

            Button("Nueva partida desde posición inicial") {
                board.newGame()
            }
            .disabled(!board.isConnected)

            Text("Empieza con las piezas en su posición inicial. Al levantar una pieza del jugador que tiene el turno, el Chessnut Air iluminará únicamente sus destinos legales. Al colocarla en un destino legal, la app registrará el movimiento y cambiará el turno.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var positionSection: some View {
        Section("Diagnóstico de posición") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Física")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(board.boardPlacement.isEmpty ? "Sin datos todavía" : board.boardPlacement)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Lógica")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(board.logicalPlacement)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var ledSection: some View {
        Section("Diagnóstico de LEDs") {
            Stepper("Rank index: \(rankIndex)", value: $rankIndex, in: 0...7)
            Stepper("File index: \(fileIndex)", value: $fileIndex, in: 0...7)
            LabeledContent("Casilla", value: board.squareNotation(rankIndex: rankIndex, fileIndex: fileIndex))

            Button("Encender LED") {
                board.lightLED(rankIndex: rankIndex, fileIndex: fileIndex)
            }
            .disabled(!board.isConnected)

            Button("Parpadear LED") {
                board.blinkLED(rankIndex: rankIndex, fileIndex: fileIndex)
            }
            .disabled(!board.isConnected)

            Button("Apagar todos los LEDs") {
                board.ledsOff()
            }
            .disabled(!board.isConnected)

            Text("Mapeo confirmado en Chessnut Air: (0,0)=a8, (0,7)=h8, (7,0)=a1 y (7,7)=h1.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var notesSection: some View {
        Section("Estado del proyecto") {
            Text("Esta versión ya incluye reglas de ajedrez y seguimiento básico de una partida OTB. Todavía no incluye Stockfish ni clasificación de jugadas por calidad.")

            Text("Capturas, enroque y en passant se validan comparando el estado físico final con todas las transiciones legales posibles. La promoción se completará en una fase posterior.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
