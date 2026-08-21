import SwiftUI

struct ContentView: View {
    private enum FinishAction: String {
        case resign
        case draw
        case abort
    }

    @StateObject private var board = BoardController()
    @State private var rankIndex = 0
    @State private var fileIndex = 0
    @State private var finishAction: FinishAction?
    @State private var isFinishDialogPresented = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                gameSection
                historySection
                positionSection
                ledSection
                notesSection
            }
            .navigationTitle("Chessnut Coach")
            .confirmationDialog(
                finishDialogTitle,
                isPresented: $isFinishDialogPresented,
                titleVisibility: .visible
            ) {
                switch finishAction {
                case .resign:
                    Button("Confirmar abandono", role: .destructive) {
                        board.resignCurrentSide()
                        finishAction = nil
                    }
                case .draw:
                    Button("Confirmar tablas") {
                        board.agreeDraw()
                        finishAction = nil
                    }
                case .abort:
                    Button("Cancelar partida", role: .destructive) {
                        board.abortGame()
                        finishAction = nil
                    }
                case nil:
                    EmptyView()
                }
            }
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
            LabeledContent("Resultado", value: board.gameResultLabel)

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

            if board.isPromotionPending {
                Text("Promoción pendiente: sustituye físicamente el peón por dama, torre, alfil o caballo. La jugada no se guarda hasta reconocer la nueva pieza.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button("Nueva partida desde posición inicial") {
                board.newGame()
            }
            .disabled(!board.isConnected)

            if !board.isGameFinished && board.moveCount > 0 {
                Button("Rendirse (\(board.sideToMoveLabel))", role: .destructive) {
                    presentFinishDialog(.resign)
                }

                Button("Tablas por acuerdo") {
                    presentFinishDialog(.draw)
                }

                Button("Cancelar partida sin resultado", role: .destructive) {
                    presentFinishDialog(.abort)
                }
            }
        }
    }

    private var historySection: some View {
        Section("Historial de la partida") {
            LabeledContent("Medios movimientos", value: "\(board.moveCount)")

            if board.moveHistory.isEmpty {
                Text("Todavía no hay movimientos registrados.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(board.moveHistory.enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .font(.system(.body, design: .monospaced))
                }
            }
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
            Text("La sesión mantiene ahora el historial completo, estado y resultado de la partida. Capturas, enroque y en passant siguen validándose contra la posición física final.")

            Text("Las promociones se completan al sustituir físicamente el peón por dama, torre, alfil o caballo. La persistencia de partidas y la exportación PGN llegarán en una fase posterior.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var finishDialogTitle: String {
        switch finishAction {
        case .resign:
            "¿Confirmar que \(board.sideToMoveLabel.lowercased()) abandonan?"
        case .draw:
            "¿Confirmar tablas por acuerdo?"
        case .abort:
            "¿Cancelar esta partida sin resultado?"
        case nil:
            "Finalizar partida"
        }
    }

    private func presentFinishDialog(_ action: FinishAction) {
        finishAction = action
        isFinishDialogPresented = true
    }
}

#Preview {
    ContentView()
}
