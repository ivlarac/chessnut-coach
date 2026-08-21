import SwiftUI

struct ContentView: View {
    @StateObject private var board = BoardController()
    @State private var rankIndex = 0
    @State private var fileIndex = 0

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
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

    private var positionSection: some View {
        Section("Posición física") {
            if board.boardPlacement.isEmpty {
                Text("Sin datos todavía")
                    .foregroundStyle(.secondary)
            } else {
                Text(board.boardPlacement)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            Text("Al levantar o colocar una pieza, esta cadena debe cambiar inmediatamente.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var ledSection: some View {
        Section("Prueba de LEDs") {
            Stepper("Rank index: \(rankIndex)", value: $rankIndex, in: 0...7)
            Stepper("File index: \(fileIndex)", value: $fileIndex, in: 0...7)

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
        }
    }

    private var notesSection: some View {
        Section("Objetivo de esta PoC") {
            Text("1. Conectar por Bluetooth.\n2. Recibir la posición del tablero.\n3. Encender una casilla.\n4. Hacerla parpadear.")

            Text("Todavía no incluye reglas de ajedrez ni Stockfish. Es intencionado: primero validamos el hardware real.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
