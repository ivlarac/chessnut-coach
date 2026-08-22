import ChessKit
import SwiftUI

@MainActor
final class ArchivedGameAnalysisController: ObservableObject {
    @Published private(set) var evaluation: WhitePositionEvaluation?
    @Published private(set) var bestMove = "—"
    @Published private(set) var status = "Preparado"
    @Published private(set) var isAnalyzing = false

    private var analysisTask: Task<Void, Never>?
    private var generation = 0

    func analyze(fen: String) {
        generation += 1
        let requestedGeneration = generation
        analysisTask?.cancel()
        evaluation = nil
        bestMove = "—"
        status = "Analizando con Stockfish 18…"
        isAnalyzing = true

        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == requestedGeneration {
                    self.isAnalyzing = false
                    self.analysisTask = nil
                }
            }

            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                let analysis = try await StockfishEngine.shared.analyze(
                    fen: fen,
                    nodeLimit: 80_000
                )
                try Task.checkCancellation()
                guard self.generation == requestedGeneration else { return }

                let score = Position(fen: fen)?.sideToMove == .black
                    ? analysis.score.inverted
                    : analysis.score
                self.evaluation = Self.whiteEvaluation(from: score)
                self.bestMove = analysis.bestMove.isEmpty ? "Fin de partida" : analysis.bestMove
                self.status = "Profundidad \(analysis.depth) · \(analysis.nodes) nodos"
            } catch is CancellationError {
                // The replay moved to a different ply.
            } catch {
                guard self.generation == requestedGeneration else { return }
                self.status = "No se pudo analizar: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        generation += 1
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
    }

    private static func whiteEvaluation(from score: StockfishScore) -> WhitePositionEvaluation {
        switch score {
        case let .centipawns(value): .centipawns(value)
        case let .mate(plies): .mate(plies)
        case let .tablebase(value): .tablebase(value)
        }
    }
}

struct EvaluationBarView: View {
    let evaluation: WhitePositionEvaluation?
    let isAnalyzing: Bool

    private var whiteShare: Double { evaluation?.whiteShare ?? 0.5 }

    var body: some View {
        VStack(spacing: 6) {
            Text(evaluation?.displayText ?? (isAnalyzing ? "…" : "—"))
                .font(.caption2.monospacedDigit().weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Color.black
                        .frame(height: geometry.size.height * (1 - whiteShare))
                    Color.white
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    Rectangle()
                        .stroke(Color.secondary.opacity(0.7), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .animation(.easeInOut(duration: 0.25), value: whiteShare)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Evaluación de la posición")
                .accessibilityValue(evaluation?.displayText ?? "Analizando")
            }
        }
    }
}
