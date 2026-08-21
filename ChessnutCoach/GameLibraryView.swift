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

    init(game: GameRecord) {
        self.game = game
        _selectedPly = State(initialValue: game.moves.count)
        _exportDocument = State(initialValue: PGNFileDocument(text: PGNExporter.pgn(for: game)))
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
            }

            Section("Reproducción") {
                ReplayBoardView(fen: GameReplay.fen(for: game, afterPly: selectedPly))
                    .aspectRatio(1, contentMode: .fit)
                    .listRowInsets(EdgeInsets())

                Stepper(value: $selectedPly, in: 0...game.moves.count) {
                    if let move = GameReplay.move(for: game, atPly: selectedPly) {
                        Text("\(move.ply). \(move.san) · \(move.from)–\(move.to)")
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

            Section("Movimientos") {
                if game.moves.isEmpty {
                    Text("No hay movimientos registrados.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(game.moves) { move in
                        Button {
                            selectedPly = move.ply
                        } label: {
                            GameMoveRow(move: move, isSelected: selectedPly == move.ply)
                        }
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

                ShareLink(
                    item: PGNExporter.pgn(for: game),
                    subject: Text("Partida Chessnut Coach"),
                    message: Text("\(game.whitePlayer) – \(game.blackPlayer)")
                ) {
                    Label("Compartir PGN", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Detalle")
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
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
}

private struct GameMoveRow: View {
    let move: GameMoveRecord
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(String(move.ply) + ".")
                .foregroundStyle(.secondary)
            Text(move.san)
                .font(.body.monospaced())
            Spacer()
            Text(move.from + "–" + move.to)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .foregroundColor(isSelected ? .accentColor : .primary)
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
                                Text(piece(atRank: rank, file: file))
                                    .font(.system(size: squareSize * 0.72))
                                    .minimumScaleFactor(0.5)
                            }
                            .frame(width: squareSize, height: squareSize)
                        }
                    }
                }
            }
        }
        .accessibilityLabel("Tablero en el medio movimiento \(fen)")
    }

    private func piece(atRank rank: Int, file: Int) -> String {
        let rows = fen.split(separator: " ").first?.split(separator: "/") ?? []
        guard rows.count == 8 else { return "" }

        var expanded: [Character?] = []
        for character in rows[rank] {
            if let count = character.wholeNumberValue {
                expanded.append(contentsOf: Array(repeating: nil, count: count))
            } else {
                expanded.append(character)
            }
        }

        guard expanded.indices.contains(file), let piece = expanded[file] else { return "" }
        return Self.symbols[piece] ?? ""
    }

    private static let symbols: [Character: String] = [
        "K": "♔", "Q": "♕", "R": "♖", "B": "♗", "N": "♘", "P": "♙",
        "k": "♚", "q": "♛", "r": "♜", "b": "♝", "n": "♞", "p": "♟",
    ]
}

private struct PGNFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
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
