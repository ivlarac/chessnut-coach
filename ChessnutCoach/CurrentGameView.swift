import SwiftUI

struct CurrentGameView: View {
    private enum FinishAction: String {
        case resign
        case draw
        case abort
    }

    @ObservedObject var board: BoardController
    @State private var finishAction: FinishAction?
    @State private var isFinishDialogPresented = false
    @State private var isNewGamePresented = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.7"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    connectionCard
                    gameCard
                    assistanceCard
                    historyCard
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chessnut Coach v\(appVersion)")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isNewGamePresented = true
                    } label: {
                        Label("Nueva partida", systemImage: "plus.circle.fill")
                    }
                }
            }
            .confirmationDialog(
                finishDialogTitle,
                isPresented: $isFinishDialogPresented,
                titleVisibility: .visible
            ) {
                finishDialogButtons
            }
            .sheet(isPresented: $isNewGamePresented) {
                NewGameSetupView(
                    whiteAssistance: board.whiteAssistanceMode,
                    blackAssistance: board.blackAssistanceMode
                ) { configuration in
                    board.newGame(configuration: configuration)
                }
            }
        }
    }

    private var connectionCard: some View {
        CoachCard("Chessnut Air", systemImage: "dot.radiowaves.left.and.right") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    StatusPill(
                        text: board.isConnected ? "Conectado" : "Desconectado",
                        systemImage: board.isConnected ? "checkmark.circle.fill" : "circle",
                        color: board.isConnected ? .green : .secondary
                    )
                    Text(board.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let battery = board.batteryPercentage {
                    Label("\(battery)%", systemImage: batterySymbol(for: battery))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(battery > 20 ? Color.primary : Color.red)
                }
            }

            HStack {
                if board.isConnected {
                    Button("Actualizar batería") {
                        board.refreshBattery()
                    }
                    .buttonStyle(.bordered)

                    Button("Desconectar", role: .destructive) {
                        board.disconnect()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        board.connect()
                    } label: {
                        Label("Conectar tablero", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var gameCard: some View {
        CoachCard("Partida actual", systemImage: "checkerboard.rectangle") {
            VStack(spacing: 12) {
                playerField(
                    title: "Blancas",
                    symbolColor: .white,
                    selection: whitePlayerBinding
                )
                .disabled(board.isSoloGame && board.humanSide == .black)
                Divider()
                playerField(
                    title: "Negras",
                    symbolColor: .black,
                    selection: blackPlayerBinding
                )
                .disabled(board.isSoloGame && board.humanSide == .white)
            }

            if board.isSoloGame {
                HStack {
                    StatusPill(
                        text: "Solitario · \(board.humanSide?.displayText ?? "—")",
                        systemImage: "person.fill",
                        color: .coachAccent
                    )
                    Spacer()
                    Text(board.engineStrength?.displayText ?? "Stockfish")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                metric(title: "Turno", value: board.sideToMoveLabel)
                metric(
                    title: "Tablero",
                    value: board.isBoardSynchronized ? "Listo" : "Moviendo"
                )
                metric(title: "Resultado", value: board.gameResultLabel)
            }

            Text(board.gameStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let liftedSquare = board.liftedSquare {
                Label("Pieza levantada: \(liftedSquare)", systemImage: "hand.raised")
                    .font(.subheadline.weight(.medium))
            }

            if !board.legalTargets.isEmpty {
                Text("Destinos: \(board.legalTargets.joined(separator: ", "))")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            if board.isPromotionPending {
                Label(
                    "Sustituye físicamente el peón por la pieza elegida para completar la promoción.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if board.isEngineThinking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Stockfish está pensando…")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let suggestion = board.engineSuggestion {
                Label(
                    "Jugada de Stockfish: \(suggestion.displayText)",
                    systemImage: "cpu"
                )
                .font(.headline)
                .foregroundStyle(Color.coachAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Jugada de Stockfish, de \(suggestion.move.from.notation) a \(suggestion.move.to.notation)")
            }

            Button {
                isNewGamePresented = true
            } label: {
                Label("Nueva partida · Persona o Stockfish", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if board.isUndoAllowed && !board.isGameFinished && board.moveCount > 0 {
                Button {
                    board.undoLastMove()
                } label: {
                    Label("Deshacer última jugada", systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!board.canUndoMove)

                Text("También puedes deshacer devolviendo físicamente la última jugada a la posición anterior.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !board.isGameFinished && board.moveCount > 0 {
                Menu {
                    Button("Tablas por acuerdo") {
                        presentFinishDialog(.draw)
                    }
                    Button("Rendirse", role: .destructive) {
                        presentFinishDialog(.resign)
                    }
                    Button("Cancelar sin resultado", role: .destructive) {
                        presentFinishDialog(.abort)
                    }
                } label: {
                    Label("Finalizar partida…", systemImage: "flag.checkered")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var assistanceCard: some View {
        CoachCard("Ayuda por bando", systemImage: "lightbulb.max.fill") {
            assistancePicker(
                title: "Blancas",
                mode: board.whiteAssistanceMode,
                selection: whiteAssistanceBinding
            )
            .disabled(board.isSoloGame && board.humanSide == .black)

            Divider()

            assistancePicker(
                title: "Negras",
                mode: board.blackAssistanceMode,
                selection: blackAssistanceBinding
            )
            .disabled(board.isSoloGame && board.humanSide == .white)

            if !board.activeHintSummary.isEmpty {
                Label(board.activeHintSummary, systemImage: "light.beacon.max")
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color.coachAccent)
            }

            Text("Calidad Stockfish: fijo hasta 50 cp, lento entre 51 y 200 cp y rápido por encima de 200 cp.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var historyCard: some View {
        CoachCard("Últimas jugadas", systemImage: "list.number") {
            if board.moveHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Sin movimientos")
                        .font(.headline)
                    Text("El historial aparecerá al empezar la partida.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ForEach(Array(board.moveHistory.suffix(8).enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if board.moveHistory.count > 8 {
                    Text("\(board.moveHistory.count - 8) movimientos anteriores en la partida guardada")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func playerField(
        title: String,
        symbolColor: Color,
        selection: Binding<String>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill")
                .foregroundStyle(symbolColor)
                .shadow(color: .primary.opacity(0.35), radius: symbolColor == .white ? 1 : 0)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 62, alignment: .leading)
            TextField("Jugador", text: selection)
                .textInputAutocapitalization(.words)
                .multilineTextAlignment(.trailing)
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func assistancePicker(
        title: String,
        mode: AssistanceMode,
        selection: Binding<AssistanceMode>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Picker("Ayuda para \(title.lowercased())", selection: selection) {
                Text("No").tag(AssistanceMode.off)
                Text("Legales").tag(AssistanceMode.legalMoves)
                Text("Calidad").tag(AssistanceMode.stockfishQuality)
                Text("Blunders").tag(AssistanceMode.blunders)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Ayuda para \(title.lowercased())")
            Text(mode.detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var finishDialogButtons: some View {
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

    private var whitePlayerBinding: Binding<String> {
        Binding(
            get: { board.whitePlayerName },
            set: { board.setWhitePlayerName($0) }
        )
    }

    private var blackPlayerBinding: Binding<String> {
        Binding(
            get: { board.blackPlayerName },
            set: { board.setBlackPlayerName($0) }
        )
    }

    private var finishDialogTitle: String {
        switch finishAction {
        case .resign:
            board.isSoloGame
                ? "¿Confirmar que abandonas la partida?"
                : "¿Confirmar que \(board.sideToMoveLabel.lowercased()) abandonan?"
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

    private func batterySymbol(for percentage: Int) -> String {
        switch percentage {
        case 76...: "battery.100percent"
        case 51...: "battery.75percent"
        case 26...: "battery.50percent"
        case 11...: "battery.25percent"
        default: "battery.0percent"
        }
    }
}

private struct NewGameSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode = GameMode.twoPlayer
    @State private var sideChoice = HumanSideChoice.white
    @State private var stockfishLevel = 4
    @State private var humanAssistance: AssistanceMode
    @State private var whiteAssistance: AssistanceMode
    @State private var blackAssistance: AssistanceMode
    @State private var allowUndo = false

    let onStart: (NewGameConfiguration) -> Void

    init(
        whiteAssistance: AssistanceMode,
        blackAssistance: AssistanceMode,
        onStart: @escaping (NewGameConfiguration) -> Void
    ) {
        _humanAssistance = State(initialValue: whiteAssistance)
        _whiteAssistance = State(initialValue: whiteAssistance)
        _blackAssistance = State(initialValue: blackAssistance)
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("¿Contra quién quieres jugar?") {
                    Picker("Rival", selection: $mode) {
                        ForEach(GameMode.allCases) { mode in
                            Text(mode.displayText).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .solo {
                        Label(
                            "Stockfish propondrá sus jugadas y tú las ejecutarás físicamente en el Chessnut.",
                            systemImage: "cpu"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "Blancas y negras juegan físicamente en el mismo tablero.",
                            systemImage: "person.2.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        Divider()

                        Toggle("Permitir deshacer movimiento", isOn: $allowUndo)

                        Text("Podrás deshacer desde el iPhone o devolviendo físicamente la última jugada a la posición anterior.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if mode == .solo {
                    Section("Tu color") {
                        Picker("Color", selection: $sideChoice) {
                            ForEach(HumanSideChoice.allCases) { choice in
                                Text(choice.displayText).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)

                        if sideChoice == .random {
                            Text("El color se sorteará al pulsar Empezar y se mostrará en la partida actual.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Nivel de Stockfish") {
                        Stepper(
                            value: $stockfishLevel,
                            in: StockfishStrength.minimumLevel...StockfishStrength.maximumLevel
                        ) {
                            LabeledContent("Nivel", value: "\(stockfishLevel)")
                        }

                        Slider(
                            value: Binding(
                                get: { Double(stockfishLevel) },
                                set: { stockfishLevel = Int($0.rounded()) }
                            ),
                            in: Double(StockfishStrength.minimumLevel)...Double(StockfishStrength.maximumLevel),
                            step: 1
                        )

                        HStack {
                            Text("1 · Menor")
                            Spacer()
                            Text("20 · Máxima")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(StockfishStrength(level: stockfishLevel).technicalDetailText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section("Ayuda para ti") {
                        setupAssistancePicker(
                            title: "Tu ayuda",
                            selection: $humanAssistance
                        )

                        Label(
                            soloTurnExplanation,
                            systemImage: "lightbulb.max"
                        )
                        .font(.footnote)
                    }
                } else {
                    Section("Ayuda por bando") {
                        setupAssistancePicker(
                            title: "Blancas",
                            selection: $whiteAssistance
                        )

                        Divider()

                        setupAssistancePicker(
                            title: "Negras",
                            selection: $blackAssistance
                        )
                    }
                }
            }
            .navigationTitle("Nueva partida")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Empezar") {
                        let humanSide = sideChoice.resolvedSide()
                        let assistance = mode == .solo
                            ? AssistanceSettings(
                                white: humanSide == .white ? humanAssistance : .off,
                                black: humanSide == .black ? humanAssistance : .off
                            )
                            : AssistanceSettings(
                                white: whiteAssistance,
                                black: blackAssistance
                            )

                        onStart(
                            NewGameConfiguration(
                                mode: mode,
                                humanSide: humanSide,
                                strength: StockfishStrength(level: stockfishLevel),
                                assistance: assistance,
                                allowUndo: mode == .twoPlayer && allowUndo
                            )
                        )
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var soloTurnExplanation: String {
        switch sideChoice {
        case .white:
            "Después de cada jugada tuya, la app mostrará e iluminará la respuesta de Stockfish."
        case .black:
            "Stockfish moverá primero. La app mostrará la jugada y la iluminará en el tablero."
        case .random:
            "Si te corresponden negras, Stockfish moverá primero. La app mostrará e iluminará cada jugada de la máquina."
        }
    }

    private func setupAssistancePicker(
        title: String,
        selection: Binding<AssistanceMode>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Picker(title, selection: selection) {
                Text("No").tag(AssistanceMode.off)
                Text("Legales").tag(AssistanceMode.legalMoves)
                Text("Calidad").tag(AssistanceMode.stockfishQuality)
                Text("Blunders").tag(AssistanceMode.blunders)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(selection.wrappedValue.detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
