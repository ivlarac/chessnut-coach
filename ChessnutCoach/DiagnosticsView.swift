import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var board: BoardController
    @StateObject private var engineDiagnostic = EngineDiagnosticController()
    @State private var rankIndex = 0
    @State private var fileIndex = 0

    var body: some View {
        NavigationStack {
            Form {
                stockfishSection
                positionSection
                ledSection
                projectSection
            }
            .navigationTitle("Diagnóstico")
        }
    }

    private var stockfishSection: some View {
        Section("Stockfish 18") {
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
                Button {
                    engineDiagnostic.analyze()
                } label: {
                    Label("Analizar posición", systemImage: "brain.head.profile")
                }
            }

            LabeledContent("Mejor movimiento", value: engineDiagnostic.bestMove)
            LabeledContent("Evaluación", value: engineDiagnostic.evaluation)
            LabeledContent("Profundidad", value: engineDiagnostic.depth)
            LabeledContent("Nodos", value: engineDiagnostic.nodes)

            Text("El diagnóstico y la ayuda de jugadas comparten el mismo motor local para reducir el uso de memoria.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var positionSection: some View {
        Section("Posición del tablero") {
            positionValue(
                title: "Física",
                value: board.boardPlacement.isEmpty ? "Sin datos todavía" : board.boardPlacement
            )
            positionValue(title: "Lógica", value: board.logicalPlacement)

            LabeledContent(
                "Sincronización",
                value: board.isBoardSynchronized ? "Correcta" : "En movimiento"
            )
        }
    }

    private var ledSection: some View {
        Section("LEDs") {
            Stepper("Fila: \(rankIndex)", value: $rankIndex, in: 0...7)
            Stepper("Columna: \(fileIndex)", value: $fileIndex, in: 0...7)
            LabeledContent(
                "Casilla",
                value: board.squareNotation(rankIndex: rankIndex, fileIndex: fileIndex)
            )

            Button("Encender LED") {
                board.lightLED(rankIndex: rankIndex, fileIndex: fileIndex)
            }
            .disabled(!board.isConnected)

            Button("Parpadear LED") {
                board.blinkLED(rankIndex: rankIndex, fileIndex: fileIndex)
            }
            .disabled(!board.isConnected)

            Button("Probar los tres patrones") {
                board.demoLEDPatterns()
            }
            .disabled(!board.isConnected)

            Button("Apagar todos") {
                board.ledsOff()
            }
            .disabled(!board.isConnected)

            Text("Prueba simultánea: a1 fijo, b1 lento y c1 rápido. Mapeo: (0,0)=a8 y (7,7)=h1.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var projectSection: some View {
        Section("Versión actual") {
            Label("Partidas y diagnóstico separados", systemImage: "rectangle.3.group")
            Label("Exportación y compartición PGN", systemImage: "doc.badge.arrow.up")
            Label("Juego en solitario previsto para la Fase 9", systemImage: "person.fill.questionmark")
                .foregroundStyle(.secondary)
        }
    }

    private func positionValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
