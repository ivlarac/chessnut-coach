import SwiftUI
import UniformTypeIdentifiers

struct GameLibraryView: View {
    @ObservedObject var library: GameLibrary
    @ObservedObject var board: BoardController
    @State private var gamePendingDeletion: GameRecord?

    var body: some View {
        List {
            if let errorMessage = library.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            if library.games.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Sin partidas guardadas")
                        .font(.headline)
                    Text("La primera partida aparecerá aquí automáticamente al registrar un movimiento.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ForEach(library.games) { game in
                    NavigationLink {
                        GameDetailView(game: game)
                    } label: {
                        GameSummaryRow(
                            game: game,
                            isCurrent: game.id == board.currentGameID
                        )
                    }
                    .swipeActions {
                        Button("Borrar", role: .destructive) {
                            gamePendingDeletion = game
                        }
                    }
                }
            }
        }
        .navigationTitle("Partidas")
        .refreshable {
            library.reload()
        }
        .confirmationDialog(
            "¿Borrar esta partida?",
            isPresented: Binding(
                get: { gamePendingDeletion != nil },
                set: { if !$0 { gamePendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: gamePendingDeletion
        ) { game in
            Button("Borrar definitivamente", role: .destructive) {
                board.deleteArchivedGame(game)
                gamePendingDeletion = nil
            }
            Button("Cancelar", role: .cancel) {
                gamePendingDeletion = nil
            }
        } message: { game in
            if game.id == board.currentGameID {
                Text("Es la partida actual. Al borrarla también se reiniciará la sesión del tablero.")
            } else {
                Text("Esta acción elimina la partida y todos sus movimientos del dispositivo.")
            }
        }
    }
}

private struct GameSummaryRow: View {
    let game: GameRecord
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(displayName(game.whitePlayer)) – \(displayName(game.blackPlayer))")
                    .font(.headline)
                Spacer()
                Text(game.result.pgnValue)
                    .font(.headline.monospaced())
            }

            Text(game.startedAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label("\(game.fullMoveCount) jugadas", systemImage: "arrow.left.arrow.right")
                Label(formatDuration(game.duration), systemImage: "clock")
                if game.mode == .solo {
                    Label("Solitario", systemImage: "person.fill")
                }
                if isCurrent && game.status == .playing {
                    Label("Actual", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(game.status.displayText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func displayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }
}

struct GameDetailView: View {
    let game: GameRecord
    @State private var selectedPly: Int
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportDocument: PGNFileDocument
    @State private var shareFileURL: URL?
    @StateObject private var analysis = ArchivedGameAnalysisController()

    init(game: GameRecord) {
        self.game = game
        _selectedPly = State(initialValue: game.status == .finished ? 0 : game.moves.count)
        _exportDocument = State(initialValue: PGNFileDocument(text: PGNExporter.pgn(for: game)))
        _shareFileURL = State(initialValue: try? PGNShareFile.make(for: game))
    }

    var body: some View {
        List {
            Section("Resumen") {
                LabeledContent("Blancas", value: game.whitePlayer)
                LabeledContent("Negras", value: game.blackPlayer)
                LabeledContent("Fecha") {
                    Text(game.startedAt, format: .dateTime.day().month().year().hour().minute())
                }
                LabeledContent("Resultado", value: game.result.displayText)
                LabeledContent("Jugadas", value: "\(game.fullMoveCount) (\(game.moveCount) medios movimientos)")
                LabeledContent("Duración", value: formatDuration(game.duration))
                LabeledContent("Modo", value: game.mode.displayText)
                if game.mode == .solo {
                    LabeledContent("Tu color", value: game.humanSide?.displayText ?? "—")
                    LabeledContent("Nivel", value: game.engineStrength?.displayText ?? "Máxima")
                }
            }

            Section(game.status == .finished ? "Análisis" : "Reproducción") {
                if game.status == .finished {
                    HStack(alignment: .top, spacing: 8) {
                        EvaluationBarView(
                            evaluation: analysis.evaluation,
                            isAnalyzing: analysis.isAnalyzing
                        )
                        .frame(width: 42)

                        ReplayBoardView(fen: replayFEN)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                    LabeledContent("Evaluación") {
                        if analysis.isAnalyzing {
                            ProgressView()
                        } else {
                            Text(analysis.evaluation?.displayText ?? "—")
                                .font(.body.monospacedDigit())
                        }
                    }
                    LabeledContent("Mejor movimiento", value: analysis.bestMove)
                    Text(analysis.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ReplayBoardView(fen: replayFEN)
                        .aspectRatio(1, contentMode: .fit)
                        .listRowInsets(EdgeInsets())

                    Text("Finaliza la partida para activar el análisis posición a posición con Stockfish.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Stepper(value: $selectedPly, in: 0...game.moves.count) {
                    if let move = GameReplay.move(for: game, atPly: selectedPly) {
                        Text(savedMoveNotation(for: move))
                    } else {
                        Text("Posición inicial")
                    }
                }

                HStack {
                    Button {
                        selectedPly = max(0, selectedPly - 1)
                    } label: {
                        Label("Anterior", systemImage: "backward.end")
                    }
                    .disabled(selectedPly == 0)

                    Spacer()

                    Text("\(selectedPly)/\(game.moves.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        selectedPly = min(game.moves.count, selectedPly + 1)
                    } label: {
                        Label("Siguiente", systemImage: "forward.end")
                    }
                    .disabled(selectedPly == game.moves.count)
                }
                .buttonStyle(.borderless)
            }

            if game.status == .finished {
                Section("Análisis completo") {
                    if analysis.isAnalyzingFullGame {
                        ProgressView(value: analysis.fullGameProgress) {
                            Text("Analizando toda la partida con Stockfish 18")
                        } currentValueLabel: {
                            Text("\(Int((analysis.fullGameProgress * 100).rounded())) %")
                                .font(.caption.monospacedDigit())
                        }

                        Button(role: .destructive) {
                            analysis.cancelFullGameAnalysis()
                        } label: {
                            Label("Detener análisis completo", systemImage: "stop.circle")
                        }
                    } else {
                        Button {
                            analysis.analyzeFullGame(game)
                        } label: {
                            Label(
                                analysis.fullGameAnalyses.isEmpty ? "Análisis completo" : "Reanalizar partida",
                                systemImage: "chart.xyaxis.line"
                            )
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Text(analysis.fullGameStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !analysis.fullGameAnalyses.isEmpty {
                        FullGameEvaluationGraph(
                            samples: analysis.fullGameAnalyses,
                            selectedPly: $selectedPly,
                            totalPly: game.moves.count
                        )
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                        if let selectedAnalysis = analysis.fullGameAnalysis(at: selectedPly) {
                            HStack {
                                Text(selectedPly == 0 ? "Posición inicial" : "Medio movimiento \(selectedPly)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(selectedAnalysis.evaluation.displayText)
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                            }
                        }

                        Text("La línea central representa 0,00. Una evaluación favorable a blancas hace subir el área blanca sobre la mitad negra; una favorable a negras hace bajar el área negra sobre la mitad blanca. Toca o arrastra sobre la gráfica para saltar a esa posición.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Movimientos") {
                if game.moves.isEmpty {
                    Text("No hay movimientos registrados.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(savedMoveRows) { row in
                        GameMoveRow(
                            row: row,
                            selectedPly: selectedPly,
                            selectMove: { selectedPly = $0 }
                        )
                    }
                }
            }

            Section("Exportar") {
                Button {
                    exportDocument = PGNFileDocument(text: PGNExporter.pgn(for: game))
                    isExporting = true
                } label: {
                    Label("Guardar archivo PGN", systemImage: "square.and.arrow.down")
                }

                if let shareFileURL {
                    ShareLink(
                        item: shareFileURL,
                        subject: Text("Partida Chessnut Coach"),
                        message: Text("\(game.whitePlayer) – \(game.blackPlayer)")
                    ) {
                        Label("Compartir archivo PGN", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        do {
                            shareFileURL = try PGNShareFile.make(for: game)
                        } catch {
                            exportError = error.localizedDescription
                        }
                    } label: {
                        Label("Preparar archivo PGN", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationTitle("Detalle")
        .task(id: selectedPly) {
            if game.status == .finished {
                analysis.analyze(fen: replayFEN, ply: selectedPly)
            }
        }
        .onDisappear {
            analysis.cancel()
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .portableGameNotation,
            defaultFilename: PGNExporter.suggestedFilename(for: game)
        ) { result in
            if case let .failure(error) = result {
                exportError = error.localizedDescription
            }
        }
        .alert("No se pudo exportar", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(exportError ?? "Error desconocido")
        }
    }

    private var replayFEN: String {
        GameReplay.fen(for: game, afterPly: selectedPly)
    }

    private var savedMoveRows: [SavedMoveRow] {
        var rows: [SavedMoveRow] = []

        for move in game.moves {
            let notation = moveNotationComponents(for: move)

            if let lastIndex = rows.indices.last,
               rows[lastIndex].moveNumber == notation.moveNumber {
                if notation.isWhiteMove {
                    rows[lastIndex].whiteMove = move
                } else {
                    rows[lastIndex].blackMove = move
                }
            } else {
                rows.append(
                    SavedMoveRow(
                        id: move.id,
                        moveNumber: notation.moveNumber,
                        whiteMove: notation.isWhiteMove ? move : nil,
                        blackMove: notation.isWhiteMove ? nil : move
                    )
                )
            }
        }

        return rows
    }

    private func savedMoveNotation(for move: GameMoveRecord) -> String {
        let notation = moveNotationComponents(for: move)
        let prefix = notation.isWhiteMove ? "\(notation.moveNumber)." : "\(notation.moveNumber)..."
        return "\(prefix) \(move.san)"
    }

    private func moveNotationComponents(for move: GameMoveRecord) -> (moveNumber: Int, isWhiteMove: Bool) {
        let fields = move.fenBefore.split(separator: " ")
        let fallbackMoveNumber = max(1, (move.ply + 1) / 2)
        let moveNumber = fields.count > 5 ? Int(fields[5]) ?? fallbackMoveNumber : fallbackMoveNumber
        let isWhiteMove = fields.count > 1 ? fields[1] != "b" : !move.ply.isMultiple(of: 2)
        return (moveNumber, isWhiteMove)
    }
}

private struct SavedMoveRow: Identifiable {
    let id: UUID
    let moveNumber: Int
    var whiteMove: GameMoveRecord?
    var blackMove: GameMoveRecord?
}

private struct GameMoveRow: View {
    let row: SavedMoveRow
    let selectedPly: Int
    let selectMove: (Int) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.whiteMove == nil ? "\(row.moveNumber)..." : "\(row.moveNumber).")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(.secondary)

            moveCell(row.whiteMove)
            moveCell(row.blackMove)
        }
    }

    @ViewBuilder
    private func moveCell(_ move: GameMoveRecord?) -> some View {
        if let move {
            Button {
                selectMove(move.ply)
            } label: {
                Text(move.san)
                    .font(.body.monospaced())
                    .foregroundColor(selectedPly == move.ply ? .accentColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Text("")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ReplayBoardView: View {
    let fen: String

    var body: some View {
        GeometryReader { geometry in
            let squareSize = geometry.size.width / 8
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { rank in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { file in
                            ZStack {
                                ((rank + file).isMultiple(of: 2) ? Color.boardLight : Color.boardDark)
                                if let piece = GameReplay.piece(
                                    in: fen,
                                    rankIndex: rank,
                                    fileIndex: file
                                ) {
                                    Text(piece.textSymbol)
                                        .font(.system(size: squareSize * 0.72, design: .serif))
                                        .foregroundStyle(piece.foregroundColor)
                                        .shadow(
                                            color: piece.contrastColor.opacity(0.65),
                                            radius: 1
                                        )
                                        .minimumScaleFactor(0.5)
                                }
                            }
                            .frame(width: squareSize, height: squareSize)
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Tablero en el medio movimiento \(fen)")
    }
}

private extension ReplayPiece {
    var foregroundColor: Color {
        color == .white ? .white : .black
    }

    var contrastColor: Color {
        color == .white ? .black : .white
    }
}

private struct PGNFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.portableGameNotation] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private enum PGNShareFile {
    static func make(for game: GameRecord) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChessnutCoach-PGN", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(PGNExporter.suggestedFilename(for: game))
        try PGNExporter.data(for: game).write(to: url, options: .atomic)
        return url
    }
}

private extension UTType {
    static let portableGameNotation = UTType(
        exportedAs: "com.ivlarac.chessnutcoach.pgn",
        conformingTo: .plainText
    )
}

private func formatDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainingSeconds = seconds % 60

    if hours > 0 {
        return "\(hours) h \(minutes) min"
    }
    if minutes > 0 {
        return "\(minutes) min \(remainingSeconds) s"
    }
    return "\(remainingSeconds) s"
}

private extension GameLifecycleStatus {
    var displayText: String {
        switch self {
        case .playing: "En juego"
        case .finished: "Finalizada"
        case .aborted: "Cancelada"
        }
    }
}

private extension Color {
    static let boardLight = Color(red: 0.91, green: 0.82, blue: 0.68)
    static let boardDark = Color(red: 0.49, green: 0.34, blue: 0.23)
}
