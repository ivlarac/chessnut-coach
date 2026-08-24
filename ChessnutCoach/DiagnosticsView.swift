import ChessKit
import SwiftUI

struct ArchivedPositionAnalysis: Identifiable, Equatable, Sendable {
    let ply: Int
    let evaluation: WhitePositionEvaluation
    let bestMove: String
    let depth: Int
    let nodes: UInt64

    var id: Int { ply }

    var statusText: String {
        "Profundidad \(depth) · \(nodes) nodos"
    }
}

@MainActor
final class ArchivedGameAnalysisController: ObservableObject {
    @Published private(set) var evaluation: WhitePositionEvaluation?
    @Published private(set) var bestMove = "—"
    @Published private(set) var status = "Preparado"
    @Published private(set) var isAnalyzing = false

    @Published private(set) var fullGameAnalyses: [ArchivedPositionAnalysis] = []
    @Published private(set) var fullGameProgress = 0.0
    @Published private(set) var fullGameStatus = "Pulsa «Análisis completo» para evaluar toda la partida."
    @Published private(set) var isAnalyzingFullGame = false

    private var analysisTask: Task<Void, Never>?
    private var fullGameTask: Task<Void, Never>?
    private var generation = 0
    private var fullGameGeneration = 0
    private var positionCache: [String: ArchivedPositionAnalysis] = [:]
    private var requestTracker = AnalysisRequestTracker()

    func analyze(fen: String, ply: Int? = nil) {
        generation += 1
        let requestedGeneration = generation
        let requestToken = requestTracker.begin(fen: fen)
        analysisTask?.cancel()

        if let cached = positionCache[fen] {
            isAnalyzing = false
            analysisTask = nil
            apply(cached)
            return
        }

        if let ply, let cached = fullGameAnalysis(at: ply) {
            isAnalyzing = false
            analysisTask = nil
            apply(cached)
            return
        }

        guard !isAnalyzingFullGame else { return }

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
                guard self.generation == requestedGeneration,
                      self.requestTracker.accepts(requestToken)
                else { return }

                let positionAnalysis = Self.positionAnalysis(
                    ply: ply ?? 0,
                    fen: fen,
                    analysis: analysis
                )
                self.positionCache[fen] = positionAnalysis
                self.apply(positionAnalysis)
            } catch is CancellationError {
                // The replay moved to a different ply.
            } catch {
                guard self.generation == requestedGeneration,
                      self.requestTracker.accepts(requestToken)
                else { return }
                self.status = "No se pudo analizar: \(error.localizedDescription)"
            }
        }
    }

    func analyzeFullGame(_ game: GameRecord) {
        fullGameGeneration += 1
        let requestedGeneration = fullGameGeneration

        generation += 1
        requestTracker.invalidate()
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false

        fullGameTask?.cancel()
        fullGameAnalyses = []
        fullGameProgress = 0
        fullGameStatus = "Preparando análisis completo…"
        isAnalyzingFullGame = true

        let totalPositions = game.moves.count + 1

        fullGameTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.fullGameGeneration == requestedGeneration {
                    self.isAnalyzingFullGame = false
                    self.fullGameTask = nil
                }
            }

            do {
                for ply in 0...game.moves.count {
                    try Task.checkCancellation()
                    guard self.fullGameGeneration == requestedGeneration else { return }

                    self.fullGameStatus = "Analizando posición \(ply + 1) de \(totalPositions)…"
                    let fen = GameReplay.fen(for: game, afterPly: ply)
                    let engineAnalysis = try await StockfishEngine.shared.analyze(
                        fen: fen,
                        nodeLimit: 30_000
                    )
                    try Task.checkCancellation()
                    guard self.fullGameGeneration == requestedGeneration else { return }

                    let sample = Self.positionAnalysis(
                        ply: ply,
                        fen: fen,
                        analysis: engineAnalysis
                    )
                    self.positionCache[fen] = sample
                    self.fullGameAnalyses.append(sample)
                    self.fullGameProgress = Double(ply + 1) / Double(totalPositions)
                }

                self.fullGameStatus = "Análisis completo · \(totalPositions) posiciones evaluadas"
            } catch is CancellationError {
                guard self.fullGameGeneration == requestedGeneration else { return }
                self.fullGameStatus = self.fullGameAnalyses.isEmpty
                    ? "Análisis completo cancelado"
                    : "Análisis cancelado · \(self.fullGameAnalyses.count) posiciones conservadas"
            } catch {
                guard self.fullGameGeneration == requestedGeneration else { return }
                self.fullGameStatus = "No se pudo completar el análisis: \(error.localizedDescription)"
            }
        }
    }

    func fullGameAnalysis(at ply: Int) -> ArchivedPositionAnalysis? {
        fullGameAnalyses.first { $0.ply == ply }
    }

    func cancelFullGameAnalysis() {
        fullGameGeneration += 1
        fullGameTask?.cancel()
        fullGameTask = nil
        isAnalyzingFullGame = false
        fullGameStatus = fullGameAnalyses.isEmpty
            ? "Análisis completo cancelado"
            : "Análisis cancelado · \(fullGameAnalyses.count) posiciones conservadas"
    }

    func cancel() {
        generation += 1
        fullGameGeneration += 1
        requestTracker.invalidate()
        analysisTask?.cancel()
        fullGameTask?.cancel()
        analysisTask = nil
        fullGameTask = nil
        isAnalyzing = false
        isAnalyzingFullGame = false
    }

    func cachedAnalysis(for fen: String) -> ArchivedPositionAnalysis? {
        positionCache[fen]
    }

    private func apply(_ analysis: ArchivedPositionAnalysis) {
        evaluation = analysis.evaluation
        bestMove = analysis.bestMove
        status = analysis.statusText
    }

    private static func positionAnalysis(
        ply: Int,
        fen: String,
        analysis: StockfishAnalysis
    ) -> ArchivedPositionAnalysis {
        let score = Position(fen: fen)?.sideToMove == .black
            ? analysis.score.inverted
            : analysis.score
        let bestMove = analysis.bestMove.isEmpty
            ? "Fin de partida"
            : ChessMoveNotation.san(forUCI: analysis.bestMove, inFEN: fen) ?? analysis.bestMove

        return ArchivedPositionAnalysis(
            ply: ply,
            evaluation: whiteEvaluation(from: score),
            bestMove: bestMove,
            depth: analysis.depth,
            nodes: analysis.nodes
        )
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

struct FullGameEvaluationGraph: View {
    let samples: [ArchivedPositionAnalysis]
    @Binding var selectedPly: Int
    let totalPly: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    Color.black
                    Color.white
                }

                Canvas { context, size in
                    let middleY = size.height / 2
                    let orderedSamples = samples.sorted { $0.ply < $1.ply }

                    if !orderedSamples.isEmpty {
                        var whiteArea = Path()
                        whiteArea.move(to: CGPoint(x: xPosition(for: orderedSamples[0].ply, width: size.width), y: middleY))
                        for sample in orderedSamples {
                            let intrusion = max(0, graphOffset(for: sample.evaluation))
                            whiteArea.addLine(
                                to: CGPoint(
                                    x: xPosition(for: sample.ply, width: size.width),
                                    y: middleY - intrusion * middleY
                                )
                            )
                        }
                        if let last = orderedSamples.last {
                            whiteArea.addLine(to: CGPoint(x: xPosition(for: last.ply, width: size.width), y: middleY))
                        }
                        whiteArea.closeSubpath()
                        context.fill(whiteArea, with: .color(.white))

                        var blackArea = Path()
                        blackArea.move(to: CGPoint(x: xPosition(for: orderedSamples[0].ply, width: size.width), y: middleY))
                        for sample in orderedSamples {
                            let intrusion = max(0, -graphOffset(for: sample.evaluation))
                            blackArea.addLine(
                                to: CGPoint(
                                    x: xPosition(for: sample.ply, width: size.width),
                                    y: middleY + intrusion * middleY
                                )
                            )
                        }
                        if let last = orderedSamples.last {
                            blackArea.addLine(to: CGPoint(x: xPosition(for: last.ply, width: size.width), y: middleY))
                        }
                        blackArea.closeSubpath()
                        context.fill(blackArea, with: .color(.black))

                        var evaluationLine = Path()
                        for (index, sample) in orderedSamples.enumerated() {
                            let point = CGPoint(
                                x: xPosition(for: sample.ply, width: size.width),
                                y: middleY - graphOffset(for: sample.evaluation) * middleY
                            )
                            if index == 0 {
                                evaluationLine.move(to: point)
                            } else {
                                evaluationLine.addLine(to: point)
                            }
                        }
                        context.stroke(
                            evaluationLine,
                            with: .color(.gray.opacity(0.8)),
                            lineWidth: 1
                        )
                    }

                    var zeroLine = Path()
                    zeroLine.move(to: CGPoint(x: 0, y: middleY))
                    zeroLine.addLine(to: CGPoint(x: size.width, y: middleY))
                    context.stroke(zeroLine, with: .color(.gray), lineWidth: 1)

                    if samples.contains(where: { $0.ply == selectedPly }) {
                        let x = xPosition(for: selectedPly, width: size.width)
                        var selectionLine = Path()
                        selectionLine.move(to: CGPoint(x: x, y: 0))
                        selectionLine.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(selectionLine, with: .color(.blue), lineWidth: 2)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectNearestPly(at: value.location.x, width: geometry.size.width)
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gráfica de evaluación completa de la partida")
        .accessibilityValue("Movimiento seleccionado \(selectedPly) de \(totalPly)")
    }

    private func xPosition(for ply: Int, width: Double) -> Double {
        guard totalPly > 0 else { return 0 }
        return width * Double(ply) / Double(totalPly)
    }

    private func graphOffset(for evaluation: WhitePositionEvaluation) -> Double {
        min(1, max(-1, (evaluation.whiteShare - 0.5) * 2))
    }

    private func selectNearestPly(at x: Double, width: Double) {
        guard width > 0, !samples.isEmpty else { return }
        let clampedX = min(max(0, x), width)
        let targetPly = totalPly > 0
            ? Double(totalPly) * clampedX / width
            : 0

        if let nearest = samples.min(by: {
            abs(Double($0.ply) - targetPly) < abs(Double($1.ply) - targetPly)
        }) {
            selectedPly = nearest.ply
        }
    }
}
