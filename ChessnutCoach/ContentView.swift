import SwiftUI

struct ContentView: View {
    private enum FinishAction: String {
        case resign
        case draw
        case abort
    }

    @ObservedObject var board: BoardController
    @StateObject private var engineDiagnostic = EngineDiagnosticController()
    @State private var rankIndex = 0
    @State private var fileIndex = 0
    @State private var finishAction: FinishAction?
    @State private var isFinishDialogPresented = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                assistanceSection
                stockfishSection
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

    private var assistanceSection: some View {
        Section("Ayuda por bando") {
            assistancePicker(
                title: "Blancas",
                mode: board.whiteAssistanceMode,
                selection: whiteAssistanceBinding
            )

            assistancePicker(
                title: "Negras",
                mode: board.blackAssistanceMode,
                selection: blackAssistanceBinding
            )

            if !board.activeHintSummary.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Patrón activo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(board.activeHintSummary)
                        .font(.system(.footnote, design: .monospaced))
                }
            }

            Text("Calidad Stockfish: pérdida ≤50 cp = fijo/bueno; 51–200 cp = parpadeo lento/aceptable; >200 cp = parpadeo rápido/blunder. La comparación se hace contra la mejor jugada global de la posición.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func assistancePicker(
        title: String,
        mode: AssistanceMode,
        selection: Binding<AssistanceMode>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Picker("Ayuda \(title.lowercased())", selection: selection) {
                Text("No").tag(AssistanceMode.off)
                Text("Legales").tag(AssistanceMode.legalMoves)
                Text("Calidad").tag(AssistanceMode.stockfishQuality)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Ayuda para \(title.lowercased())")

            Text(mode.detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var stockfishSection: some View {
        Section("Stockfish 18 · diagnóstico") {
            LabeledContent("Motor", value: engineDiagnostic.version)
            LabeledContent("Estado", value: engineDiagnostic.status)

            TextField("FEN", text: $engineDiagnostic.fen, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Button("Inicial") {
                    engineDiagnostic.useStartingPosition()
                }
                .buttonStyle(.borderless)

                Button("Tras 1.e4") {
                    engineDiagnostic.useAfterE4Position()
                }
                .buttonStyle(.borderless)
            }

            if engineDiagnostic.isAnalyzing {
                ProgressView("Analizando…")
                Button("Detener", role: .destructive) {
                    engineDiagnostic.stop()
                }
            } else {
                Button("Analizar FEN con Stockfish 18") {
                    engineDiagnostic.analyze()
                }
            }

            LabeledContent("Mejor movimiento", value: engineDiagnostic.bestMove)
            LabeledContent("Evaluación", value: engineDiagnostic.evaluation)
            LabeledContent("Profundidad", value: engineDiagnostic.depth)
            LabeledContent("Nodos", value: engineDiagnostic.nodes)

            Text("El mismo Stockfish 18 local se reutiliza para el diagnóstico y para valorar los destinos del Chessnut, evitando cargar dos motores NNUE en memoria.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

            Button("Probar fijo + lento + rápido") {
                board.demoLEDPatterns()
            }
            .disabled(!board.isConnected)

            Button("Apagar todos los LEDs") {
                board.ledsOff()
            }
            .disabled(!board.isConnected)

            Text("Prueba simultánea: a1 fijo, b1 parpadeo lento y c1 parpadeo rápido. El controlador compone un único frame para el Chessnut cada 250 ms.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Mapeo confirmado en Chessnut Air: (0,0)=a8, (0,7)=h8, (7,0)=a1 y (7,7)=h1.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var notesSection: some View {
        Section("Estado del proyecto") {
            Text("Fase 5: Stockfish 18 clasifica en tiempo real los destinos legales de la pieza levantada y controla los patrones LED del Chessnut Air.")

            Text("El motor precalcula la evaluación global al comenzar cada turno. Al levantar una pieza sólo analiza sus destinos, y descarta el resultado si la posición física cambia antes de terminar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var whiteAssistanceBinding: Binding<AssistanceMode> {
        Binding(
            get: { board.whiteAssistanceMode },
            set: { board.setWhiteAssistanceMode($0) }
        )
    }

    private var blackAssistanceBinding: Binding<AssistanceMode> {
        Binding(
            get: { board.blackAssistanceMode },
            set: { board.setBlackAssistanceMode($0) }
        )
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
    ContentView(board: BoardController())
}
