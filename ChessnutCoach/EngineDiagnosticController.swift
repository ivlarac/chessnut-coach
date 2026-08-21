import Combine
import Foundation

@MainActor
final class EngineDiagnosticController: ObservableObject {
    static let startingFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    static let afterE4FEN = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"

    @Published var fen = startingFEN
    @Published private(set) var status = "Preparado para iniciar Stockfish 18"
    @Published private(set) var version = "Stockfish 18"
    @Published private(set) var bestMove = "—"
    @Published private(set) var evaluation = "—"
    @Published private(set) var depth = "—"
    @Published private(set) var nodes = "—"
    @Published private(set) var isAnalyzing = false

    private let engine = StockfishEngine.shared
    private var analysisTask: Task<Void, Never>?

    func useStartingPosition() {
        fen = Self.startingFEN
    }

    func useAfterE4Position() {
        fen = Self.afterE4FEN
    }

    func analyze() {
        guard !isAnalyzing else { return }

        let requestedFEN = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedFEN.isEmpty else {
            status = "Introduce una FEN completa antes de analizar."
            return
        }

        isAnalyzing = true
        status = "Analizando localmente…"
        bestMove = "—"
        evaluation = "—"
        depth = "—"
        nodes = "—"

        analysisTask?.cancel()
        analysisTask = Task { [weak self, engine] in
            do {
                let result = try await engine.analyze(fen: requestedFEN)
                guard !Task.isCancelled else { return }
                guard let self else { return }

                self.version = result.version
                self.bestMove = result.bestMove.isEmpty ? "(posición terminal)" : result.bestMove
                self.evaluation = result.score.displayText
                self.depth = "\(result.depth)"
                self.nodes = result.nodes.formatted()
                self.status = "Análisis completado en el dispositivo"
                self.isAnalyzing = false
            } catch {
                guard let self else { return }
                self.status = "Error: \(error.localizedDescription)"
                self.isAnalyzing = false
            }
        }
    }

    func stop() {
        analysisTask?.cancel()
        analysisTask = nil
        Task { [engine] in
            await engine.stop()
        }
        isAnalyzing = false
        status = "Análisis detenido"
    }
}
