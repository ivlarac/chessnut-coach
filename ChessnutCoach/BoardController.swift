import ChessKit
import Combine
import Foundation

struct SoloEngineSuggestion: Equatable, Sendable {
    let move: OTBExpectedMove

    var displayText: String { move.displayText }
}

enum ScreenPromotionChoice: String, CaseIterable, Identifiable, Sendable {
    case queen
    case rook
    case bishop
    case knight

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .queen: "Dama"
        case .rook: "Torre"
        case .bishop: "Alfil"
        case .knight: "Caballo"
        }
    }

    var pieceKind: Piece.Kind {
        switch self {
        case .queen: .queen
        case .rook: .rook
        case .bishop: .bishop
        case .knight: .knight
        }
    }
}

struct ScreenPromotionRequest: Equatable, Sendable {
    let from: Square
    let to: Square
}

@MainActor
final class BoardController: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var status = "Desconectado"
    @Published private(set) var boardPlacement = ""
    @Published private(set) var batteryPercentage: Int?
    @Published private(set) var discoveredBoards: [ElectronicBoardDescriptor] = []
    @Published private(set) var isScanningForBoards = false
    @Published private(set) var connectedBoard: ElectronicBoardDescriptor?

    @Published private(set) var logicalPlacement = OTBGameSession().logicalPlacement
    @Published private(set) var gameStatus = "No hay ninguna partida iniciada. Pulsa «Nueva partida» para comenzar."
    @Published private(set) var sideToMoveLabel = "—"
    @Published private(set) var liftedSquare: String?
    @Published private(set) var legalTargets: [String] = []
    @Published private(set) var lastMove: String?
    @Published private(set) var isBoardSynchronized = false
    @Published private(set) var moveHistory: [String] = []
    @Published private(set) var moveCount = 0
    @Published private(set) var gameResultLabel = "Sin partida"
    @Published private(set) var isGameFinished = false
    @Published private(set) var isPromotionPending = false
    @Published private(set) var whitePlayerName = "Blancas"
    @Published private(set) var blackPlayerName = "Negras"
    @Published private(set) var gameMode = GameMode.twoPlayer
    @Published private(set) var humanSide: PlayerSide?
    @Published private(set) var opponentEngineConfiguration: OpponentEngineConfiguration?
    @Published private(set) var engineStrength: StockfishStrength?
    @Published private(set) var engineSuggestion: SoloEngineSuggestion?
    @Published private(set) var isEngineThinking = false
    @Published private(set) var isUndoAllowed = false
    @Published private(set) var canUndoMove = false
    @Published private(set) var hasActiveGame = false
    @Published private(set) var screenHints: [LEDHint] = []
    @Published private(set) var screenPromotionRequest: ScreenPromotionRequest?
    @Published private(set) var timeControlLabel = "Ilimitado"
    @Published private(set) var isClockEnabled = false
    @Published private(set) var whiteClockText = ""
    @Published private(set) var blackClockText = ""
    @Published private(set) var activeClockSide: PlayerSide?
    @Published private(set) var clockPauseLabel: String?
    @Published private(set) var isWhiteLowOnTime = false
    @Published private(set) var isBlackLowOnTime = false

    @Published private(set) var assistanceSettings = AssistanceSettings()
    @Published private(set) var activeHintSummary = ""

    var whiteAssistanceMode: AssistanceMode { assistanceSettings.white }
    var blackAssistanceMode: AssistanceMode { assistanceSettings.black }
    var maximumAssistancePieces: AssistancePieceLimit { assistanceSettings.maximumPiecesPerTurn }
    var blunderThreshold: BlunderThreshold { assistanceSettings.blunderThreshold }
    var currentGameID: UUID { gameSession.gameRecord.id }
    var supportedBoards: [ElectronicBoardSupport] { adapterRegistry.supportedBoards }
    var boardDisplayName: String { connectedBoard?.name ?? selectedBoard?.name ?? "Tablero electrónico" }
    var supportsLEDs: Bool { client?.capabilities.contains(.leds) ?? false }
    var supportsBattery: Bool { client?.capabilities.contains(.battery) ?? false }
    var isSoloGame: Bool { gameMode == .solo }
    var opponentDisplayName: String {
        opponentEngineConfiguration?.displayName ?? "Motor rival"
    }
    var isEngineTurn: Bool {
        hasActiveGame
            && gameMode == .solo
            && humanSide?.pieceColor != gameSession.sideToMove
            && !gameSession.isFinished
    }

    private var client: (any ElectronicChessBoard)?
    private let boardDiscovery: any ElectronicChessBoardDiscovery
    private let adapterRegistry: ElectronicBoardAdapterRegistry
    private let preferences: UserDefaults
    private var selectedBoard: ElectronicBoardDescriptor?
    private var discoveryTask: Task<Void, Never>?
    private var discoveryTimeoutTask: Task<Void, Never>?
    private let lastBoardPreferenceKey = "LastElectronicChessBoardID"
    private static let assistanceSettingsPreferenceKey = "AssistanceSettings"
    private var connectionTask: Task<Void, Never>?
    private var reconnectionTask: Task<Void, Never>?
    private var disconnectionTask: Task<Void, Never>?
    private var resumeValidationTask: Task<Void, Never>?
    private var fenTask: Task<Void, Never>?
    private var fenDebounceTask: Task<Void, Never>?
    private var ledTask: Task<Void, Never>?
    private var coachingTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var engineMoveTask: Task<Void, Never>?
    private var currentOpponentEngine: (any ChessPlayingEngine)?
    private var gameSession = OTBGameSession()
    private let stockfishCoach = StockfishMoveCoach()
    private var turnAssistancePolicy = TurnAssistanceAccessPolicy()
    private let opponentEngineBuilder: @Sendable (OpponentEngineConfiguration) throws -> any ChessPlayingEngine
    private let nowProvider: () -> Date
    private weak var gameLibrary: GameLibrary?
    private var clockRefreshCancellable: AnyCancellable?

    private var currentStockfishHints: [StockfishMoveHint] = []
    private var currentStockfishHintFEN: String?
    private var currentStockfishHintSource: Square?
    private var shouldMaintainConnection = false
    private var lifecycle = ElectronicBoardSessionLifecycle()
    private var assistanceGeneration = 0
    private var engineMoveGeneration = 0
    private var physicalSnapshotRevision = 0

    // Electronic boards can emit several physical snapshots while a hand is moving a
    // piece. Never let LED writes block consumption of that realtime stream:
    // keep only the newest snapshot and process it after a very short settle.
    private var latestPhysicalPlacement = ""
    private var lastProcessedPlacement = ""
    private let fenSettleDelay: Duration = .milliseconds(100)
    private let ledTickDelay: Duration = .milliseconds(250)
    private let reconnectDelay: Duration = .seconds(2)
    private let resumeSnapshotDelay: Duration = .milliseconds(500)

    private var logicalFEN: String {
        gameSession.board.position.fen
    }

    private var idleGameStatus: String {
        "No hay ninguna partida iniciada. Pulsa «Nueva partida» para comenzar."
    }

    init(
        library: GameLibrary? = nil,
        boardDiscovery: any ElectronicChessBoardDiscovery = DefaultElectronicBoardDiscovery(),
        adapterRegistry: ElectronicBoardAdapterRegistry = .appDefault,
        preferences: UserDefaults = .standard,
        nowProvider: @escaping () -> Date = { Date() },
        opponentEngineBuilder: @escaping @Sendable (OpponentEngineConfiguration) throws -> any ChessPlayingEngine = {
            configuration in
            switch configuration.kind {
            case .stockfish18: StockfishOpponentEngine()
            case .maia3: Maia3OpponentEngine(predictor: Maia3CoreMLPolicyModel.shared)
            }
        }
    ) {
        gameLibrary = library
        self.boardDiscovery = boardDiscovery
        self.adapterRegistry = adapterRegistry
        self.preferences = preferences
        self.nowProvider = nowProvider
        self.opponentEngineBuilder = opponentEngineBuilder

        if let savedSettings = Self.loadAssistanceSettings(from: preferences) {
            assistanceSettings = savedSettings
        }
        turnAssistancePolicy.limit = assistanceSettings.maximumPiecesPerTurn

        if let savedGame = library?.resumableGame,
           let restoredSession = try? OTBGameSession(restoring: savedGame) {
            gameSession = restoredSession
            hasActiveGame = true
            if gameSession.processClockTimeoutIfNeeded(at: nowProvider()) != nil {
                gameStatus = gameSession.result.displayText
                library?.upsert(gameSession.gameRecord)
            } else {
                gameStatus = "Partida recuperada. Puedes continuar en pantalla o conectar un tablero físico."
            }
        }

        publishGameState()
        configureOpponentEngineIfNeeded()
        if hasActiveGame {
            prepareScreenTurn()
        } else {
            gameStatus = idleGameStatus
        }

        clockRefreshCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshClockFromRealTime()
            }
    }

    func connect() {
        shouldMaintainConnection = true
        if selectedBoard != nil {
            startConnection(isReconnect: false)
        } else {
            scanForBoards()
        }
    }

    func scanForBoards() {
        guard !isConnected else { return }

        shouldMaintainConnection = true
        connectionTask?.cancel()
        connectionTask = nil
        reconnectionTask?.cancel()
        reconnectionTask = nil
        stopDiscovery()

        selectedBoard = nil
        discoveredBoards = []
        isScanningForBoards = true
        status = "Buscando tableros electrónicos compatibles…"

        let rememberedID = preferences.string(forKey: lastBoardPreferenceKey)
        let stream = boardDiscovery.scan()
        discoveryTask = Task { [weak self] in
            guard let self else { return }

            for await descriptor in stream {
                guard !Task.isCancelled else { return }

                if !self.discoveredBoards.contains(where: { $0.id == descriptor.id }) {
                    self.discoveredBoards.append(descriptor)
                    self.discoveredBoards.sort {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                }

                if descriptor.id == rememberedID {
                    self.selectedBoard = descriptor
                    self.preferences.set(descriptor.id, forKey: self.lastBoardPreferenceKey)
                    self.stopDiscovery()
                    self.startConnection(isReconnect: false)
                    return
                }

                self.status = self.discoveredBoards.count == 1
                    ? "Tablero encontrado. Selecciónalo para conectar."
                    : "Se encontraron \(self.discoveredBoards.count) tableros. Selecciona uno."
            }

            guard !Task.isCancelled else { return }
            self.isScanningForBoards = false
            self.discoveryTask = nil
            if self.discoveredBoards.isEmpty {
                self.status = "No se encontraron tableros compatibles"
            }
        }

        discoveryTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
                try Task.checkCancellation()
                guard let self else { return }

                self.discoveryTask?.cancel()
                self.discoveryTask = nil
                self.discoveryTimeoutTask = nil
                self.isScanningForBoards = false
                self.status = self.discoveredBoards.isEmpty
                    ? "No se encontraron tableros compatibles"
                    : (self.discoveredBoards.count == 1
                        ? "Tablero encontrado. Selecciónalo para conectar."
                        : "Se encontraron \(self.discoveredBoards.count) tableros. Selecciona uno.")
            } catch {
                // Scanning was stopped because a board was selected or a new scan started.
            }
        }
    }

    func connect(to descriptor: ElectronicBoardDescriptor) {
        guard !isConnected else { return }

        shouldMaintainConnection = true
        selectedBoard = descriptor
        preferences.set(descriptor.id, forKey: lastBoardPreferenceKey)
        stopDiscovery()
        startConnection(isReconnect: false)
    }

    private func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        isScanningForBoards = false
    }

    private func startConnection(isReconnect: Bool) {
        guard shouldMaintainConnection,
              connectionTask == nil,
              !isConnected,
              let descriptor = selectedBoard
        else { return }

        reconnectionTask?.cancel()
        reconnectionTask = nil
        status = isReconnect
            ? "Reconectando a \(descriptor.name)…"
            : "Conectando a \(descriptor.name)…"

        connectionTask = Task { [weak self] in
            guard let self else { return }

            do {
                let client = try self.adapterRegistry.makeBoard(for: descriptor)

                do {
                    try await client.connect()
                    try await client.enableRealtimeUpdates()
                } catch {
                    await client.disconnect()
                    throw error
                }

                guard !Task.isCancelled, self.shouldMaintainConnection else {
                    await client.disconnect()
                    return
                }

                self.client = client
                self.connectedBoard = descriptor
                self.isConnected = true
                self.status = isReconnect
                    ? "\(descriptor.name) reconectado · validando posición…"
                    : "\(descriptor.name) conectado · esperando posición…"
                self.clearScreenInteraction()
                self.prepareForFreshPhysicalSnapshot()
                self.startDisconnectionStream(client: client)
                self.startFENStream(client: client)
                self.refreshBattery()
            } catch {
                guard !Task.isCancelled else { return }
                self.client = nil
                self.connectedBoard = nil
                self.isConnected = false
                self.status = isReconnect
                    ? "Conexión perdida · nuevo intento en breve"
                    : "No se pudo conectar a \(descriptor.name): \(error.localizedDescription)"
                self.prepareScreenTurn()
            }

            self.connectionTask = nil

            if !self.isConnected, self.shouldMaintainConnection {
                self.scheduleReconnect()
            }
        }
    }

    func disconnect() {
        shouldMaintainConnection = false
        stopDiscovery()
        connectionTask?.cancel()
        connectionTask = nil
        reconnectionTask?.cancel()
        reconnectionTask = nil
        disconnectionTask?.cancel()
        disconnectionTask = nil
        resumeValidationTask?.cancel()
        resumeValidationTask = nil
        fenTask?.cancel()
        fenTask = nil
        fenDebounceTask?.cancel()
        fenDebounceTask = nil
        ledTask?.cancel()
        ledTask = nil
        cancelEngineMoveRequest(clearSuggestion: false)
        invalidateTransientAssistance(turnOffLEDs: false)

        guard let client else {
            resetConnectionState()
            return
        }

        self.client = nil

        Task { [weak self] in
            if client.capabilities.contains(.leds) {
                try? await client.setLEDs(.allOff)
            }
            await client.disconnect()
            self?.resetConnectionState()
        }
    }

    func handleAppPhase(_ phase: ElectronicBoardAppPhase) {
        let directive = lifecycle.transition(to: phase)

        if directive.invalidateTransientAssistance {
            invalidateTransientAssistance(turnOffLEDs: isConnected)
        }

        if phase == .background {
            refreshClockFromRealTime()
            persistCurrentGameIfNeeded()
        } else if phase == .active {
            refreshClockFromRealTime()
        }

        if directive.probeConnection, shouldMaintainConnection {
            if isConnected {
                probeConnectionAndRequestFreshSnapshot(
                    shouldRequestSnapshot: directive.requestFreshBoardSnapshot
                )
            } else {
                scheduleReconnect(immediately: true)
                prepareScreenTurn()
            }
        }
    }

    func refreshBattery() {
        guard let client, client.capabilities.contains(.battery) else {
            batteryPercentage = nil
            return
        }

        Task { [weak self] in
            await self?.refreshBattery(using: client)
        }
    }

    func newGame(configuration: NewGameConfiguration = NewGameConfiguration()) {
        invalidateTransientAssistance(turnOffLEDs: isConnected)
        cancelEngineMoveRequest(clearSuggestion: true)
        screenPromotionRequest = nil
        assistanceSettings = configuration.assistance
        turnAssistancePolicy = TurnAssistanceAccessPolicy(
            limit: configuration.assistance.maximumPiecesPerTurn
        )
        persistAssistanceSettings()

        let opponentConfiguration = configuration.opponentEngine
        let engineName = opponentConfiguration.displayName
        let requestedWhiteName = configuration.whitePlayerName ?? whitePlayerName
        let requestedBlackName = configuration.blackPlayerName ?? blackPlayerName
        let humanName = normalizedHumanName(
            configuration.humanSide == .white ? requestedWhiteName : requestedBlackName
        )
        let white = configuration.mode == .solo
            ? (configuration.humanSide == .white ? humanName : engineName)
            : normalizedNonEnginePlayerName(requestedWhiteName, fallback: "Blancas")
        let black = configuration.mode == .solo
            ? (configuration.humanSide == .black ? humanName : engineName)
            : normalizedNonEnginePlayerName(requestedBlackName, fallback: "Negras")

        if hasActiveGame && !gameSession.isFinished {
            if gameSession.moves.isEmpty {
                gameLibrary?.delete(gameSession.gameRecord)
            } else {
                gameSession.abort()
                persistCurrentGameIfNeeded()
            }
        }

        gameSession.reset(
            startedAt: nowProvider(),
            whitePlayer: white,
            blackPlayer: black,
            mode: configuration.mode,
            humanSide: configuration.mode == .solo ? configuration.humanSide : nil,
            opponentEngine: configuration.mode == .solo ? opponentConfiguration : nil,
            engineStrength: configuration.mode == .solo
                ? opponentConfiguration.stockfishStrength
                : nil,
            engineName: configuration.mode == .solo ? engineName : nil,
            allowUndo: configuration.mode == .twoPlayer && configuration.allowUndo,
            timeControl: configuration.timeControl
        )
        hasActiveGame = true
        configureOpponentEngineIfNeeded()
        lastProcessedPlacement = ""
        activeHintSummary = ""
        publishGameState()
        persistCurrentGameIfNeeded()

        if !isConnected {
            prepareScreenTurn()
            return
        }

        gameStatus = configuration.mode == .solo
            ? "Partida en solitario preparada. Coloca todas las piezas en la posición inicial."
            : "Nueva partida. Coloca todas las piezas en la posición inicial."

        guard let client, !boardPlacement.isEmpty else { return }
        schedulePhysicalPlacement(boardPlacement, client: client, force: true)
    }

    func setWhiteAssistanceMode(_ mode: AssistanceMode) {
        assistanceSettings.white = mode
        persistAssistanceSettings()
        refreshCurrentAssistanceIfNeeded()
        if !isConnected {
            refreshScreenAssistanceIfNeeded()
        }
        scheduleStockfishPrewarmIfNeeded()
    }

    func setBlackAssistanceMode(_ mode: AssistanceMode) {
        assistanceSettings.black = mode
        persistAssistanceSettings()
        refreshCurrentAssistanceIfNeeded()
        if !isConnected {
            refreshScreenAssistanceIfNeeded()
        }
        scheduleStockfishPrewarmIfNeeded()
    }

    func setMaximumAssistancePieces(_ limit: AssistancePieceLimit) {
        assistanceSettings.maximumPiecesPerTurn = limit
        turnAssistancePolicy.limit = limit
        persistAssistanceSettings()
        refreshCurrentAssistanceIfNeeded()
        if !isConnected {
            refreshScreenAssistanceIfNeeded()
        }
    }

    func setBlunderThreshold(_ threshold: BlunderThreshold) {
        assistanceSettings.blunderThreshold = threshold
        persistAssistanceSettings()
        refreshCurrentAssistanceIfNeeded()
        if !isConnected {
            refreshScreenAssistanceIfNeeded()
        }
        scheduleStockfishPrewarmIfNeeded()
    }

    func setWhitePlayerName(_ name: String) {
        guard !(hasActiveGame && gameMode == .solo && humanSide == .black) else { return }
        whitePlayerName = name
        gameSession.updatePlayers(white: name, black: blackPlayerName)
        persistCurrentGameIfNeeded()
    }

    func setBlackPlayerName(_ name: String) {
        guard !(hasActiveGame && gameMode == .solo && humanSide == .white) else { return }
        blackPlayerName = name
        gameSession.updatePlayers(white: whitePlayerName, black: name)
        persistCurrentGameIfNeeded()
    }

    func undoLastMove() {
        guard hasActiveGame,
              let undoneMove = gameSession.undoLastMove(
                awaitPhysicalRestore: isConnected,
                at: nowProvider()
              )
        else { return }

        invalidateTransientAssistance(turnOffLEDs: isConnected)
        cancelEngineMoveRequest(clearSuggestion: true)
        screenPromotionRequest = nil
        resetTurnAssistancePolicy()
        publishGameState()
        persistAfterUndo()

        if isConnected {
            gameStatus = "Jugada \(undoneMove.san) deshecha. Devuelve físicamente las piezas a la posición anterior para continuar."
        } else {
            gameStatus = "Jugada \(undoneMove.san) deshecha. Continúa desde el tablero en pantalla."
            prepareScreenTurn()
        }
    }

    func resignCurrentSide() {
        guard hasActiveGame, !gameSession.isFinished else { return }
        let resigningColor = gameMode == .solo
            ? (humanSide?.pieceColor ?? gameSession.sideToMove)
            : gameSession.sideToMove
        _ = gameSession.resign(color: resigningColor, at: nowProvider())
        persistCurrentGameIfNeeded()
        returnToIdleState()
    }

    func agreeDraw() {
        guard hasActiveGame, !gameSession.isFinished else { return }
        _ = gameSession.agreeDraw(at: nowProvider())
        persistCurrentGameIfNeeded()
        returnToIdleState()
    }

    func abortGame() {
        guard hasActiveGame, !gameSession.isFinished else { return }
        gameSession.abort(at: nowProvider())
        persistCurrentGameIfNeeded()
        returnToIdleState()
    }

    func deleteArchivedGame(_ game: GameRecord) {
        if hasActiveGame && game.id == gameSession.gameRecord.id {
            returnToIdleState()
        }

        gameLibrary?.delete(game)
    }

    func squareNotation(rankIndex: Int, fileIndex: Int) -> String {
        guard (0..<8).contains(rankIndex), (0..<8).contains(fileIndex) else { return "—" }
        let file = Square.File(fileIndex + 1)
        let rank = Square.Rank(8 - rankIndex)
        return Square(file, rank).notation
    }

    func lightLED(rankIndex: Int, fileIndex: Int) {
        guard let client, client.capabilities.contains(.leds) else { return }
        guard (0..<8).contains(rankIndex), (0..<8).contains(fileIndex) else { return }

        invalidateTransientAssistance(turnOffLEDs: false)
        ledTask = Task { [weak self] in
            var leds = ElectronicBoardLEDFrame.allOff
            leds[rankIndex: rankIndex, fileIndex: fileIndex] = .red

            do {
                try await client.setLEDs(leds)
                let notation = self?.squareNotation(rankIndex: rankIndex, fileIndex: fileIndex) ?? "?"
                self?.status = "LED activo en \(notation)"
            } catch is CancellationError {
                // Another board event took priority over the manual test.
            } catch {
                self?.status = "Error LEDs: \(error.localizedDescription)"
                self?.handleClientFailure(error, client: client)
            }
        }
    }

    func blinkLED(rankIndex: Int, fileIndex: Int) {
        guard let client, client.capabilities.contains(.leds) else { return }
        guard (0..<8).contains(rankIndex), (0..<8).contains(fileIndex) else { return }

        invalidateTransientAssistance(turnOffLEDs: false)
        ledTask = Task { [weak self] in
            var leds = ElectronicBoardLEDFrame.allOff
            leds[rankIndex: rankIndex, fileIndex: fileIndex] = .red

            do {
                for _ in 0..<10 {
                    try Task.checkCancellation()
                    try await client.setLEDs(leds)
                    try await Task.sleep(for: .milliseconds(300))
                    try Task.checkCancellation()
                    try await client.setLEDs(.allOff)
                    try await Task.sleep(for: .milliseconds(300))
                }

                self?.status = "Prueba de parpadeo completada"
            } catch is CancellationError {
                // A newer LED request owns the board now.
            } catch {
                self?.status = "Error parpadeo: \(error.localizedDescription)"
                self?.handleClientFailure(error, client: client)
            }
        }
    }

    func demoLEDPatterns() {
        guard let client, client.capabilities.contains(.leds) else { return }

        invalidateTransientAssistance(turnOffLEDs: false)

        let hints = [
            LEDHint(square: .a1, pattern: .steady),
            LEDHint(square: .b1, pattern: .slowBlink),
            LEDHint(square: .c1, pattern: .fastBlink),
        ]

        activeHintSummary = "a1 fijo · b1 lento · c1 rápido"
        status = "Prueba simultánea de patrones LED"
        startLEDHints(hints, client: client)
    }

    func ledsOff() {
        guard let client, client.capabilities.contains(.leds) else { return }

        invalidateTransientAssistance(turnOffLEDs: false)
        ledTask = Task { [weak self] in
            do {
                try await client.setLEDs(.allOff)
                self?.status = "LEDs apagados"
            } catch {
                self?.status = "Error LEDs: \(error.localizedDescription)"
                self?.handleClientFailure(error, client: client)
            }
        }
    }

    private func startDisconnectionStream(client: any ElectronicChessBoard) {
        disconnectionTask?.cancel()
        disconnectionTask = Task { [weak self] in
            for await event in client.connectionEvents {
                guard !Task.isCancelled else { return }

                switch event {
                case .disconnected:
                    self?.handleUnexpectedDisconnect(client: client)
                    return
                }
            }
        }
    }

    private func handleUnexpectedDisconnect(client disconnectedClient: any ElectronicChessBoard) {
        guard shouldMaintainConnection,
              let client,
              client === disconnectedClient
        else { return }

        self.client = nil
        connectedBoard = nil
        isConnected = false
        batteryPercentage = nil
        status = "\(selectedBoard?.name ?? "Tablero") desconectado · reconectando…"

        disconnectionTask?.cancel()
        disconnectionTask = nil
        fenTask?.cancel()
        fenTask = nil
        fenDebounceTask?.cancel()
        fenDebounceTask = nil
        resumeValidationTask?.cancel()
        resumeValidationTask = nil
        invalidateTransientAssistance(turnOffLEDs: false)
        cancelEngineMoveRequest(clearSuggestion: false)
        prepareForFreshPhysicalSnapshot()
        prepareScreenTurn()
        Task {
            await disconnectedClient.disconnect()
        }
        scheduleReconnect()
    }

    private func handleClientFailure(_ error: Error, client failedClient: any ElectronicChessBoard) {
        guard !(error is CancellationError),
              let client,
              client === failedClient
        else { return }

        handleUnexpectedDisconnect(client: failedClient)
    }

    private func scheduleReconnect(immediately: Bool = false) {
        guard shouldMaintainConnection,
              !isConnected,
              connectionTask == nil,
              reconnectionTask == nil
        else { return }

        reconnectionTask = Task { [weak self] in
            guard let self else { return }

            do {
                if !immediately {
                    try await Task.sleep(for: self.reconnectDelay)
                }
                try Task.checkCancellation()
                self.reconnectionTask = nil
                self.startConnection(isReconnect: true)
            } catch is CancellationError {
                // A manual disconnect or a newer connection attempt won.
            } catch {
                self.reconnectionTask = nil
            }
        }
    }

    private func prepareForFreshPhysicalSnapshot() {
        boardPlacement = ""
        latestPhysicalPlacement = ""
        lastProcessedPlacement = ""
        isBoardSynchronized = false
        activeHintSummary = ""
        gameStatus = hasActiveGame
            ? "Conexión activa. Esperando la posición actual del tablero para recuperar la partida."
            : idleGameStatus
    }

    private func probeConnectionAndRequestFreshSnapshot(shouldRequestSnapshot: Bool) {
        guard let client else { return }

        resumeValidationTask?.cancel()
        let startingRevision = physicalSnapshotRevision

        resumeValidationTask = Task { [weak self] in
            guard let self else { return }

            do {
                if client.capabilities.contains(.battery) {
                    let battery = try await client.batteryStatus(timeout: .seconds(3))
                    try Task.checkCancellation()
                    guard self.client === client else { return }
                    self.batteryPercentage = battery.percentage
                } else {
                    self.batteryPercentage = nil
                }

                if shouldRequestSnapshot {
                    try await client.enableRealtimeUpdates()
                    try await Task.sleep(for: self.resumeSnapshotDelay)
                    try Task.checkCancellation()
                    guard self.client === client else { return }

                    if self.physicalSnapshotRevision > startingRevision,
                       !self.latestPhysicalPlacement.isEmpty {
                        self.schedulePhysicalPlacement(
                            self.latestPhysicalPlacement,
                            client: client,
                            force: true
                        )
                    } else {
                        self.isBoardSynchronized = false
                        self.status = "Conectado · esperando posición actual del tablero…"
                        self.gameStatus = self.hasActiveGame
                            ? "Mueve o levanta una pieza para validar la posición física tras volver a la app."
                            : self.idleGameStatus
                    }
                }
            } catch is CancellationError {
                // A newer lifecycle transition superseded this validation.
            } catch {
                self.handleClientFailure(error, client: client)
            }
        }
    }

    private func startFENStream(client: any ElectronicChessBoard) {
        fenTask?.cancel()
        fenTask = Task { [weak self] in
            for await placement in client.positionUpdates {
                guard !Task.isCancelled else { return }
                self?.receivePhysicalPlacement(placement, client: client)
            }
        }
    }

    private func receivePhysicalPlacement(_ placement: String, client: any ElectronicChessBoard) {
        boardPlacement = placement
        physicalSnapshotRevision += 1

        guard placement != latestPhysicalPlacement else { return }

        latestPhysicalPlacement = placement
        schedulePhysicalPlacement(placement, client: client)
    }

    private func schedulePhysicalPlacement(
        _ placement: String,
        client: any ElectronicChessBoard,
        force: Bool = false
    ) {
        fenDebounceTask?.cancel()

        fenDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.fenSettleDelay ?? .milliseconds(100))
                try Task.checkCancellation()
                guard let self else { return }

                guard force || placement == self.latestPhysicalPlacement else { return }
                guard force || placement != self.lastProcessedPlacement else { return }

                await self.processStablePhysicalPlacement(placement, client: client)
            } catch is CancellationError {
                // Expected whenever a newer physical snapshot supersedes this one.
            } catch {
                self?.gameStatus = "Error procesando el tablero: \(error.localizedDescription)"
            }
        }
    }

    private func processStablePhysicalPlacement(_ placement: String, client: any ElectronicChessBoard) async {
        guard placement == latestPhysicalPlacement else { return }

        lastProcessedPlacement = placement
        invalidateTransientAssistance(turnOffLEDs: false)

        guard hasActiveGame else {
            isBoardSynchronized = false
            gameStatus = idleGameStatus
            do {
                try await client.setLEDs(.allOff)
            } catch {
                status = "Conexión BLE interrumpida: \(error.localizedDescription)"
                handleClientFailure(error, client: client)
            }
            return
        }

        let wasEngineTurn = isEngineTurn
        let physicalPlacement = placement.split(separator: " ").first.map(String.init) ?? placement
        let event: OTBGameEvent
        if wasEngineTurn,
           engineSuggestion == nil,
           physicalPlacement != gameSession.logicalPlacement {
            event = .invalid("Espera a que \(opponentDisplayName) proponga su jugada antes de mover sus piezas.")
        } else {
            event = gameSession.process(
                physicalPlacement: placement,
                at: nowProvider(),
                requiredMove: wasEngineTurn ? engineSuggestion?.move : nil
            )
        }

        if case .synchronized = event {
            gameSession.startClockIfNeeded(at: nowProvider())
            gameSession.resumeClockAfterSynchronization(at: nowProvider())
            persistCurrentGameIfNeeded()
        }

        if case .moveCompleted = event, wasEngineTurn {
            cancelEngineMoveRequest(clearSuggestion: true)
        }
        turnAssistancePolicy.limit = assistanceSettings.maximumPiecesPerTurn
        turnAssistancePolicy.handle(event)
        publishGameState()
        switch event {
        case .moveCompleted:
            persistCurrentGameIfNeeded()
        case .moveUndone:
            persistAfterUndo()
        default:
            break
        }

        if gameSession.isFinished, gameSession.result.isTimeoutResult {
            persistCurrentGameIfNeeded()
            gameStatus = gameSession.result.displayText
            do {
                try await client.setLEDs(.allOff)
            } catch {
                status = "Conexión BLE interrumpida: \(error.localizedDescription)"
                handleClientFailure(error, client: client)
            }
            return
        }

        if case .moveCompleted = event, gameSession.isFinished {
            do {
                try await client.setLEDs(.allOff)
            } catch {
                status = "Conexión BLE interrumpida: \(error.localizedDescription)"
                handleClientFailure(error, client: client)
            }
            returnToIdleState()
            return
        }

        do {
            switch event {
            case .synchronized:
                clearStockfishHints()
                if gameSession.isFinished {
                    gameStatus = gameSession.result.displayText
                } else if gameSession.isPromotionPending {
                    gameStatus = "Promoción pendiente. Sustituye físicamente el peón por la pieza elegida."
                } else {
                    if isEngineTurn {
                        gameStatus = engineSuggestion.map {
                            "Turno de \(opponentDisplayName): ejecuta \($0.displayText) en el tablero."
                        } ?? "\(opponentDisplayName) está calculando su jugada…"
                    } else {
                        gameStatus = lastMove == nil
                            ? "Tablero sincronizado. Levanta una pieza de las blancas para empezar."
                            : "Movimiento registrado. Turno de \(sideToMoveLabel.lowercased())."
                    }
                }
                try await client.setLEDs(.allOff)
                if isEngineTurn {
                    scheduleEngineMoveIfNeeded(client: client)
                } else {
                    scheduleStockfishPrewarmIfNeeded()
                }

            case let .pieceLifted(source, legalTargets):
                clearStockfishHints()
                if wasEngineTurn, let suggestion = engineSuggestion {
                    gameStatus = "Jugada de \(opponentDisplayName): lleva \(suggestion.displayText)."
                    activeHintSummary = "Origen fijo · destino intermitente"
                    startEngineMoveLEDs(suggestion.move, client: client)
                } else if legalTargets.isEmpty {
                    gameStatus = "\(source.notation) no tiene movimientos legales."
                    try await client.setLEDs(.allOff)
                } else {
                    let mode = assistanceSettings.mode(for: gameSession.sideToMove)

                    guard canProvideAssistance(
                        for: source,
                        legalTargets: legalTargets,
                        mode: mode
                    ) else {
                        showAssistanceLimitReached(for: source)
                        if client.capabilities.contains(.leds) {
                            try await client.setLEDs(.allOff)
                        }
                        break
                    }

                    switch mode {
                    case .off:
                        screenHints = []
                        gameStatus = "Pieza levantada en \(source.notation). Ayuda desactivada para \(sideToMoveLabel.lowercased())."
                        if client.capabilities.contains(.leds) {
                            try await client.setLEDs(.allOff)
                        }

                    case .legalMoves:
                        let hints = AssistanceHintPlanner.hints(for: legalTargets, mode: mode)
                        gameStatus = client.capabilities.contains(.leds)
                            ? "Pieza levantada en \(source.notation). LEDs y puntos verdes fijos = destinos legales."
                            : "Pieza levantada en \(source.notation). Puntos verdes fijos en el tablero virtual = destinos legales."
                        activeHintSummary = hintSummary(hints)
                        startLEDHints(hints, client: client)

                    case .stockfishQuality, .blunders:
                        gameStatus = "Pieza levantada en \(source.notation). Stockfish 18 está valorando sus destinos…"
                        activeHintSummary = "Stockfish 18 analizando \(source.notation)…"
                        if client.capabilities.contains(.leds) {
                            try await client.setLEDs(.allOff)
                        }
                        startStockfishCoaching(
                            source: source,
                            legalTargets: legalTargets,
                            mode: mode,
                            client: client
                        )
                    }
                }

            case let .moveCompleted(move):
                clearStockfishHints()
                gameStatus = "Registrado \(move.san) (\(move.coordinateNotation)). Turno de \(sideToMoveLabel.lowercased())."
                try await client.setLEDs(.allOff)
                if isEngineTurn {
                    scheduleEngineMoveIfNeeded(client: client)
                } else {
                    scheduleStockfishPrewarmIfNeeded()
                }

            case let .moveUndone(move):
                clearStockfishHints()
                gameStatus = "Jugada \(move.san) deshecha automáticamente. Turno de \(sideToMoveLabel.lowercased())."
                try await client.setLEDs(.allOff)
                scheduleStockfishPrewarmIfNeeded()

            case let .promotionRequired(square, legalKinds):
                clearStockfishHints()
                let pieces = legalKinds.compactMap(\.promotionSymbol).joined(separator: ", ")
                gameStatus = "Promoción en \(square.notation): sustituye el peón por \(pieces)."
                try await client.setLEDs(ledBoard(for: [square]))

            case let .intermediate(message):
                gameStatus = message
                if wasEngineTurn, let suggestion = engineSuggestion {
                    gameStatus = "Completa la jugada de \(opponentDisplayName) \(suggestion.displayText)."
                    activeHintSummary = "Origen fijo · destino intermitente"
                    startEngineMoveLEDs(suggestion.move, client: client)
                } else if !gameSession.legalTargets.isEmpty {
                    let mode = assistanceSettings.mode(for: gameSession.sideToMove)

                    guard let source = gameSession.liftedSquare,
                          canProvideAssistance(
                              for: source,
                              legalTargets: gameSession.legalTargets,
                              mode: mode
                          )
                    else {
                        if let source = gameSession.liftedSquare, mode != .off {
                            showAssistanceLimitReached(for: source)
                        }
                        try await client.setLEDs(.allOff)
                        break
                    }

                    switch mode {
                    case .off:
                        try await client.setLEDs(.allOff)

                    case .legalMoves:
                        let hints = AssistanceHintPlanner.hints(
                            for: gameSession.legalTargets,
                            mode: mode
                        )
                        activeHintSummary = hintSummary(hints)
                        startLEDHints(hints, client: client)

                    case .stockfishQuality, .blunders:
                        if currentStockfishHintFEN == logicalFEN,
                           currentStockfishHintSource == gameSession.liftedSquare,
                           !currentStockfishHints.isEmpty {
                            let hints = currentStockfishHints.compactMap { $0.ledHint(for: mode) }
                            activeHintSummary = stockfishHintSummary(currentStockfishHints, mode: mode)
                            startLEDHints(hints, client: client)
                        } else {
                            try await client.setLEDs(.allOff)
                        }
                    }
                }

            case let .invalid(message):
                clearStockfishHints()
                gameStatus = message
                if wasEngineTurn, let suggestion = engineSuggestion {
                    activeHintSummary = "\(opponentDisplayName): \(suggestion.displayText)"
                    startEngineMoveLEDs(suggestion.move, client: client)
                } else {
                    try await client.setLEDs(.allOff)
                }
            }
        } catch {
            status = "Conexión BLE interrumpida: \(error.localizedDescription)"
            handleClientFailure(error, client: client)
        }
    }

    private func refreshCurrentAssistanceIfNeeded() {
        guard hasActiveGame,
              let client,
              let source = gameSession.liftedSquare,
              !gameSession.legalTargets.isEmpty,
              !gameSession.isFinished,
              !isEngineTurn
        else { return }

        invalidateTransientAssistance(turnOffLEDs: false)

        let mode = assistanceSettings.mode(for: gameSession.sideToMove)
        guard canProvideAssistance(
            for: source,
            legalTargets: gameSession.legalTargets,
            mode: mode
        ) else {
            showAssistanceLimitReached(for: source)
            if client.capabilities.contains(.leds) {
                Task { [weak self] in
                    do {
                        try await client.setLEDs(.allOff)
                    } catch {
                        self?.handleClientFailure(error, client: client)
                    }
                }
            }
            return
        }

        switch mode {
        case .off:
            screenHints = []
            activeHintSummary = ""
            guard client.capabilities.contains(.leds) else { return }
            Task { [weak self] in
                do {
                    try await client.setLEDs(.allOff)
                } catch {
                    self?.handleClientFailure(error, client: client)
                }
            }

        case .legalMoves:
            let hints = AssistanceHintPlanner.hints(for: gameSession.legalTargets, mode: mode)
            activeHintSummary = hintSummary(hints)
            startLEDHints(hints, client: client)

        case .stockfishQuality, .blunders:
            activeHintSummary = "Stockfish 18 analizando \(source.notation)…"
            startStockfishCoaching(
                source: source,
                legalTargets: gameSession.legalTargets,
                mode: mode,
                client: client
            )
        }
    }

    private func scheduleStockfishPrewarmIfNeeded() {
        prewarmTask?.cancel()
        prewarmTask = nil

        guard hasActiveGame,
              !gameSession.isFinished,
              !isEngineTurn,
              gameSession.liftedSquare == nil,
              assistanceSettings.mode(for: gameSession.sideToMove).requiresStockfishAnalysis
        else { return }

        let fen = logicalFEN
        let coach = stockfishCoach
        prewarmTask = Task {
            await coach.prepare(fen: fen)
        }
    }

    private func startStockfishCoaching(
        source: Square,
        legalTargets: [Square],
        mode: AssistanceMode,
        client: any ElectronicChessBoard
    ) {
        coachingTask?.cancel()
        clearStockfishHints()

        let fen = logicalFEN
        let coach = stockfishCoach
        let generation = assistanceGeneration
        let thresholds = MoveQualityThresholds(
            blunderThreshold: assistanceSettings.blunderThreshold
        )

        coachingTask = Task { [weak self] in
            do {
                let result = try await coach.evaluate(
                    fen: fen,
                    source: source,
                    legalTargets: legalTargets,
                    thresholds: thresholds
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard self.hasActiveGame,
                      self.assistanceGeneration == generation,
                      self.logicalFEN == fen,
                      self.gameSession.liftedSquare == source,
                      self.assistanceSettings.mode(for: self.gameSession.sideToMove) == mode,
                      mode.requiresStockfishAnalysis,
                      self.isConnected
                else { return }

                self.currentStockfishHints = result.hints
                self.currentStockfishHintFEN = fen
                self.currentStockfishHintSource = source
                let hints = result.hints.compactMap { $0.ledHint(for: mode) }
                self.screenHints = hints
                self.activeHintSummary = self.stockfishHintSummary(result.hints, mode: mode)
                self.gameStatus = self.stockfishCoachingStatus(for: mode)
                self.startLEDHints(hints, client: client)
            } catch is CancellationError {
                // The piece was returned/moved or a newer assistance request won.
            } catch {
                guard let self, !Task.isCancelled else { return }
                guard self.hasActiveGame,
                      self.assistanceGeneration == generation,
                      self.logicalFEN == fen,
                      self.gameSession.liftedSquare == source
                else { return }

                self.clearStockfishHints()
                self.screenHints = []
                self.activeHintSummary = ""
                self.gameStatus = "No se pudo analizar \(source.notation) con Stockfish 18: \(error.localizedDescription)"
                if client.capabilities.contains(.leds) {
                    do {
                        try await client.setLEDs(.allOff)
                    } catch {
                        self.handleClientFailure(error, client: client)
                    }
                }
            }
        }
    }

    private func startLEDHints(_ hints: [LEDHint], client: any ElectronicChessBoard) {
        ledTask?.cancel()
        let generation = assistanceGeneration
        screenHints = hints

        guard client.capabilities.contains(.leds), !hints.isEmpty else { return }

        let hasBlinkingPattern = hints.contains { $0.pattern != .steady }

        if !hasBlinkingPattern {
            ledTask = Task { [weak self] in
                guard let self else { return }

                do {
                    guard self.assistanceGeneration == generation else { return }
                    try await client.setLEDs(self.ledBoard(for: hints.map(\.square)))
                    guard self.assistanceGeneration == generation else {
                        try await client.setLEDs(.allOff)
                        return
                    }
                } catch is CancellationError {
                    // A newer LED request owns the board now.
                } catch {
                    self.status = "Conectado · error LEDs: \(error.localizedDescription)"
                    self.handleClientFailure(error, client: client)
                }
            }
            return
        }

        ledTask = Task { [weak self] in
            guard let self else { return }
            var tick = 0

            do {
                while !Task.isCancelled {
                    guard self.assistanceGeneration == generation else { return }
                    let activeSquares = LEDHintFrameComposer.activeSquares(for: hints, tick: tick)
                    try await client.setLEDs(self.ledBoard(for: activeSquares))
                    tick += 1
                    try await Task.sleep(for: self.ledTickDelay)
                }
            } catch is CancellationError {
                // The next board state or LED request takes ownership immediately.
            } catch {
                self.status = "Conectado · error patrones LED: \(error.localizedDescription)"
                self.handleClientFailure(error, client: client)
            }
        }
    }

    private func scheduleEngineMoveIfNeeded(client: any ElectronicChessBoard) {
        guard isEngineTurn,
              gameSession.isSynchronized,
              engineMoveTask == nil
        else { return }

        if let suggestion = engineSuggestion {
            activeHintSummary = "\(opponentDisplayName): \(suggestion.displayText)"
            gameStatus = "Turno de \(opponentDisplayName): ejecuta \(suggestion.displayText) en el tablero."
            startEngineMoveLEDs(suggestion.move, client: client)
            return
        }

        engineMoveGeneration += 1
        let generation = engineMoveGeneration
        let fen = logicalFEN
        let history = gameSession.moves.map(\.lan)
        let positionHistory = [gameSession.gameRecord.initialFEN]
            + gameSession.moves.map(\.fenAfter)
        let configuration = resolvedOpponentConfiguration
        guard let engine = currentOpponentEngine else {
            gameStatus = "No se pudo iniciar el motor rival \(opponentDisplayName)."
            return
        }
        isEngineThinking = true
        gameStatus = "\(opponentDisplayName) está calculando su jugada (\(configuration.strengthDisplayText))…"

        engineMoveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.engineMoveGeneration == generation {
                    self.engineMoveTask = nil
                    self.isEngineThinking = false
                }
            }

            do {
                let response = try await engine.move(
                    for: ChessPlayingRequest(
                        fen: fen,
                        moveHistory: history,
                        positionHistory: positionHistory,
                        configuration: configuration
                    )
                )
                let expectedMove = try OpponentMoveValidator.validatedMove(
                    uci: response.uci,
                    fen: fen
                )
                try Task.checkCancellation()
                guard self.engineMoveGeneration == generation,
                      self.logicalFEN == fen,
                      self.isEngineTurn
                else { return }

                let suggestion = SoloEngineSuggestion(move: expectedMove)
                let responseDate = self.nowProvider()
                if self.gameSession.processClockTimeoutIfNeeded(at: responseDate) != nil {
                    self.publishGameState()
                    self.persistCurrentGameIfNeeded()
                    self.gameStatus = self.gameSession.result.displayText
                    return
                }
                self.gameSession.pauseClockForEngineMoveTransfer(at: responseDate)
                self.engineSuggestion = suggestion
                self.publishGameState()
                self.persistCurrentGameIfNeeded()
                self.gameStatus = "Turno de \(self.opponentDisplayName): ejecuta \(suggestion.displayText) en el tablero."
                self.activeHintSummary = "\(self.opponentDisplayName): \(suggestion.displayText) · origen fijo · destino intermitente"
                if self.client === client, self.isConnected {
                    self.startEngineMoveLEDs(expectedMove, client: client)
                }
            } catch is CancellationError {
                // A new game or completed engine move superseded this search.
            } catch {
                guard self.engineMoveGeneration == generation else { return }
                self.gameStatus = "No se pudo obtener la jugada de \(self.opponentDisplayName): \(error.localizedDescription)"
            }
        }
    }

    private func startEngineMoveLEDs(_ move: OTBExpectedMove, client: any ElectronicChessBoard) {
        startLEDHints(
            [
                LEDHint(square: move.from, pattern: .steady),
                LEDHint(square: move.to, pattern: .slowBlink),
            ],
            client: client
        )
    }

    private func cancelEngineMoveRequest(clearSuggestion: Bool) {
        engineMoveGeneration += 1
        engineMoveTask?.cancel()
        engineMoveTask = nil
        if let currentOpponentEngine {
            Task { await currentOpponentEngine.cancel() }
        }
        isEngineThinking = false
        if clearSuggestion {
            engineSuggestion = nil
        }
    }

    private func hintSummary(_ hints: [LEDHint]) -> String {
        hints
            .map { "\($0.square.notation) \($0.pattern.displayText)" }
            .joined(separator: " · ")
    }

    private func stockfishHintSummary(
        _ hints: [StockfishMoveHint],
        mode: AssistanceMode
    ) -> String {
        hints.map { $0.detailText(for: mode) }.joined(separator: " · ")
    }

    private func stockfishCoachingStatus(for mode: AssistanceMode) -> String {
        let threshold = assistanceSettings.blunderThreshold.rawValue
        return switch mode {
        case .stockfishQuality:
            "Stockfish 18: fijo = bueno (≤50 cp), lento = aceptable, rápido = blunder (≥\(threshold) cp)."
        case .blunders:
            "Stockfish 18: destinos legales fijos; blunders (≥\(threshold) cp) parpadean rápido."
        case .off, .legalMoves:
            ""
        }
    }

    private func canProvideAssistance(
        for source: Square,
        legalTargets: [Square],
        mode: AssistanceMode
    ) -> Bool {
        guard mode != .off, !legalTargets.isEmpty else { return true }
        turnAssistancePolicy.limit = assistanceSettings.maximumPiecesPerTurn
        return turnAssistancePolicy.requestAssistance(for: source)
    }

    private func showAssistanceLimitReached(for source: Square) {
        clearStockfishHints()
        screenHints = []
        activeHintSummary = ""
        gameStatus = "\(source.notation) supera el máximo de piezas con ayuda de este turno. Puedes moverla normalmente."
    }

    private func resetTurnAssistancePolicy() {
        turnAssistancePolicy.limit = assistanceSettings.maximumPiecesPerTurn
        turnAssistancePolicy.resetForNextTurn()
    }

    private func clearStockfishHints() {
        currentStockfishHints = []
        currentStockfishHintFEN = nil
        currentStockfishHintSource = nil
    }

    private func invalidateTransientAssistance(turnOffLEDs: Bool) {
        assistanceGeneration += 1
        coachingTask?.cancel()
        coachingTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
        ledTask?.cancel()
        ledTask = nil
        clearStockfishHints()
        screenHints = []
        activeHintSummary = ""

        guard turnOffLEDs, let client, client.capabilities.contains(.leds) else { return }
        let generation = assistanceGeneration

        Task { [weak self] in
            guard let self,
                  self.assistanceGeneration == generation,
                  self.client === client
            else { return }

            do {
                try await client.setLEDs(.allOff)
                guard self.assistanceGeneration == generation else {
                    self.refreshCurrentAssistanceIfNeeded()
                    return
                }
            } catch {
                self.handleClientFailure(error, client: client)
            }
        }
    }

    private func ledBoard(for squares: [Square]) -> ElectronicBoardLEDFrame {
        var leds = ElectronicBoardLEDFrame.allOff

        for square in squares {
            let rankIndex = 8 - square.rank.value
            let fileIndex = square.file.number - 1
            leds[rankIndex: rankIndex, fileIndex: fileIndex] = .red
        }

        return leds
    }

    private func publishGameState() {
        logicalPlacement = gameSession.logicalPlacement
        sideToMoveLabel = gameSession.sideToMove == .white ? "Blancas" : "Negras"
        liftedSquare = gameSession.liftedSquare?.notation
        legalTargets = gameSession.legalTargets.map(\.notation).sorted()
        lastMove = gameSession.lastMove.map { "\($0.san) · \($0.coordinateNotation)" }
        isBoardSynchronized = gameSession.isSynchronized
        moveCount = gameSession.moves.count
        moveHistory = formattedMoveHistory(gameSession.moves)
        gameResultLabel = gameSession.result.displayText
        isGameFinished = gameSession.isFinished
        isPromotionPending = gameSession.isPromotionPending
        whitePlayerName = gameSession.gameRecord.whitePlayer
        blackPlayerName = gameSession.gameRecord.blackPlayer
        gameMode = gameSession.gameRecord.mode
        humanSide = gameSession.gameRecord.humanSide
        opponentEngineConfiguration = gameSession.gameRecord.opponentEngine
        engineStrength = opponentEngineConfiguration?.stockfishStrength
        isUndoAllowed = gameSession.gameRecord.mode == .twoPlayer && gameSession.gameRecord.allowUndo
        canUndoMove = gameSession.canUndoLastMove
        publishClockState(at: nowProvider())

        if !hasActiveGame {
            sideToMoveLabel = "—"
            liftedSquare = nil
            legalTargets = []
            lastMove = nil
            isBoardSynchronized = false
            moveCount = 0
            moveHistory = []
            gameResultLabel = "Sin partida"
            isGameFinished = false
            isPromotionPending = false
            humanSide = nil
            opponentEngineConfiguration = nil
            engineStrength = nil
            isUndoAllowed = false
            canUndoMove = false
            screenHints = []
            screenPromotionRequest = nil
            timeControlLabel = "Ilimitado"
            isClockEnabled = false
            whiteClockText = ""
            blackClockText = ""
            activeClockSide = nil
            clockPauseLabel = nil
            isWhiteLowOnTime = false
            isBlackLowOnTime = false
        }
    }

    private func publishClockState(at date: Date) {
        timeControlLabel = gameSession.timeControl.summaryText
        guard let clock = gameSession.clockState else {
            isClockEnabled = false
            whiteClockText = ""
            blackClockText = ""
            activeClockSide = nil
            clockPauseLabel = nil
            isWhiteLowOnTime = false
            isBlackLowOnTime = false
            return
        }

        let whiteRemaining = clock.remaining(for: .white, at: date)
        let blackRemaining = clock.remaining(for: .black, at: date)
        isClockEnabled = true
        whiteClockText = GameClockFormatter.string(for: whiteRemaining)
        blackClockText = GameClockFormatter.string(for: blackRemaining)
        activeClockSide = clock.isRunning ? clock.activeSide : nil
        clockPauseLabel = clock.pauseReason?.displayText
        isWhiteLowOnTime = clock.activeSide == .white && whiteRemaining <= 30
        isBlackLowOnTime = clock.activeSide == .black && blackRemaining <= 30
    }

    private func refreshClockFromRealTime() {
        guard hasActiveGame, gameSession.timeControl.isTimed else { return }
        let date = nowProvider()

        if gameSession.processClockTimeoutIfNeeded(at: date) != nil {
            invalidateTransientAssistance(turnOffLEDs: isConnected)
            cancelEngineMoveRequest(clearSuggestion: true)
            screenPromotionRequest = nil
            publishGameState()
            persistCurrentGameIfNeeded()
            gameStatus = gameSession.result.displayText
            return
        }

        publishClockState(at: date)
    }

    private func formattedMoveHistory(_ moves: [GameMoveRecord]) -> [String] {
        guard !moves.isEmpty else { return [] }

        var rows: [String] = []
        var index = 0

        while index < moves.count {
            let moveNumber = (index / 2) + 1
            let white = moves[index].san
            let black = index + 1 < moves.count ? moves[index + 1].san : ""
            rows.append("\(moveNumber). \(white)\(black.isEmpty ? "" : "   \(black)")")
            index += 2
        }

        return rows
    }

    private func persistCurrentGameIfNeeded() {
        guard hasActiveGame,
              !gameSession.moves.isEmpty || gameSession.timeControl.isTimed
        else { return }
        gameLibrary?.upsert(gameSession.gameRecord)
    }

    private func persistAssistanceSettings() {
        guard let data = try? JSONEncoder().encode(assistanceSettings) else { return }
        preferences.set(data, forKey: Self.assistanceSettingsPreferenceKey)
    }

    private static func loadAssistanceSettings(from preferences: UserDefaults) -> AssistanceSettings? {
        guard let data = preferences.data(forKey: assistanceSettingsPreferenceKey) else { return nil }
        return try? JSONDecoder().decode(AssistanceSettings.self, from: data)
    }

    private func persistAfterUndo() {
        guard hasActiveGame else { return }
        if gameSession.gameRecord.mode == .twoPlayer,
           gameSession.moves.isEmpty,
           !gameSession.timeControl.isTimed {
            gameLibrary?.delete(gameSession.gameRecord)
        } else {
            persistCurrentGameIfNeeded()
        }
    }

    private func returnToIdleState() {
        invalidateTransientAssistance(turnOffLEDs: isConnected)
        cancelEngineMoveRequest(clearSuggestion: true)
        screenPromotionRequest = nil
        resetTurnAssistancePolicy()

        let idleWhite = normalizedNonEnginePlayerName(whitePlayerName, fallback: "Blancas")
        let idleBlack = normalizedNonEnginePlayerName(blackPlayerName, fallback: "Negras")

        hasActiveGame = false
        currentOpponentEngine = nil
        gameSession.reset(
            whitePlayer: idleWhite,
            blackPlayer: idleBlack
        )
        lastProcessedPlacement = ""
        publishGameState()
        gameStatus = idleGameStatus
    }

    private var resolvedOpponentConfiguration: OpponentEngineConfiguration {
        gameSession.gameRecord.opponentEngine
            ?? .stockfish(gameSession.gameRecord.engineStrength ?? .full)
    }

    private func configureOpponentEngineIfNeeded() {
        guard hasActiveGame, gameSession.gameRecord.mode == .solo else {
            currentOpponentEngine = nil
            return
        }

        let configuration = resolvedOpponentConfiguration
        do {
            currentOpponentEngine = try opponentEngineBuilder(configuration)
        } catch {
            currentOpponentEngine = nil
            gameStatus = "No se pudo preparar \(configuration.displayName): \(error.localizedDescription)"
        }
    }

    private func normalizedHumanName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !isReservedEngineName(trimmed),
              trimmed.localizedCaseInsensitiveCompare("Blancas") != .orderedSame,
              trimmed.localizedCaseInsensitiveCompare("Negras") != .orderedSame
        else {
            return "Jugador"
        }
        return trimmed
    }

    private func normalizedNonEnginePlayerName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isReservedEngineName(trimmed) else {
            return fallback
        }
        return trimmed
    }

    private func isReservedEngineName(_ value: String) -> Bool {
        OpponentEngineKind.allCases.contains {
            value.localizedCaseInsensitiveContains($0.displayName)
                || value.localizedCaseInsensitiveContains($0.rawValue)
        }
    }

    private func turnOffAutomaticLEDs() {
        invalidateTransientAssistance(turnOffLEDs: isConnected)
    }

    private func refreshBattery(using client: any ElectronicChessBoard) async {
        guard client.capabilities.contains(.battery) else {
            batteryPercentage = nil
            return
        }

        do {
            let battery = try await client.batteryStatus(timeout: .seconds(3))
            batteryPercentage = battery.percentage
        } catch {
            batteryPercentage = nil
        }
    }

    private func resetConnectionState() {
        isConnected = false
        connectedBoard = nil
        status = "Desconectado"
        boardPlacement = ""
        batteryPercentage = nil
        latestPhysicalPlacement = ""
        lastProcessedPlacement = ""
        physicalSnapshotRevision = 0
        isBoardSynchronized = false
        clearStockfishHints()
        activeHintSummary = ""
        if hasActiveGame {
            prepareScreenTurn()
        } else {
            gameStatus = idleGameStatus
        }
    }
}

extension BoardController {
    func screenHintPattern(for notation: String) -> LEDPattern? {
        screenHints.first(where: { $0.square.notation == notation })?.pattern
    }

    func handleScreenSquareTap(_ notation: String) {
        guard !isConnected,
              hasActiveGame,
              !gameSession.isFinished,
              !isEngineTurn,
              screenPromotionRequest == nil
        else { return }

        let square = Square(notation)

        if let selected = liftedSquare.map(Square.init), selected == square {
            clearScreenInteraction()
            gameStatus = "Selección cancelada. Turno de \(sideToMoveLabel.lowercased())."
            return
        }

        if let selected = liftedSquare.map(Square.init),
           legalTargets.contains(notation) {
            performScreenMove(from: selected, to: square)
            return
        }

        selectScreenSource(square)
    }

    func handleScreenMove(from sourceNotation: String, to targetNotation: String) {
        guard !isConnected,
              hasActiveGame,
              !gameSession.isFinished,
              !isEngineTurn,
              screenPromotionRequest == nil,
              sourceNotation != targetNotation
        else { return }

        let source = Square(sourceNotation)
        let target = Square(targetNotation)
        guard isSelectableScreenPiece(at: source) else { return }
        let targets = gameSession.board.legalMoves(forPieceAt: source)
        guard targets.contains(target) else {
            selectScreenSource(source)
            return
        }
        performScreenMove(from: source, to: target)
    }

    func completeScreenPromotion(_ choice: ScreenPromotionChoice) {
        guard !isConnected,
              let request = screenPromotionRequest,
              hasActiveGame,
              !gameSession.isFinished
        else { return }

        performScreenMove(
            from: request.from,
            to: request.to,
            promotion: choice.pieceKind
        )
    }

    func cancelScreenPromotion() {
        guard screenPromotionRequest != nil else { return }
        screenPromotionRequest = nil
        clearScreenInteraction()
        gameStatus = "Promoción cancelada. Elige de nuevo la pieza que quieres mover."
    }

    private func prepareScreenTurn() {
        guard !isConnected, hasActiveGame, !gameSession.isFinished else { return }

        clearScreenInteraction()
        screenPromotionRequest = nil

        if !gameSession.isSynchronized {
            _ = gameSession.process(
                physicalPlacement: gameSession.logicalPlacement,
                at: nowProvider()
            )
        }
        gameSession.startClockIfNeeded(at: nowProvider())
        gameSession.resumeClockForVirtualBoard(at: nowProvider())
        publishGameState()
        persistCurrentGameIfNeeded()

        if isEngineTurn {
            scheduleScreenEngineMoveIfNeeded()
        } else {
            gameStatus = moveCount == 0
                ? "Tablero físico desconectado. Juega directamente en el tablero de la pantalla."
                : "Turno de \(sideToMoveLabel.lowercased()). Juega directamente en la pantalla."
            scheduleStockfishPrewarmIfNeeded()
        }
    }

    private func isSelectableScreenPiece(at square: Square) -> Bool {
        gameSession.board.position.pieces.contains {
            $0.square == square && $0.color == gameSession.sideToMove
        }
    }

    private func selectScreenSource(_ source: Square) {
        guard isSelectableScreenPiece(at: source) else {
            clearScreenInteraction()
            return
        }

        invalidateTransientAssistance(turnOffLEDs: false)
        let targets = gameSession.board.legalMoves(forPieceAt: source)
        liftedSquare = source.notation
        legalTargets = targets.map(\.notation).sorted()

        guard !targets.isEmpty else {
            gameStatus = "\(source.notation) no tiene movimientos legales."
            return
        }

        refreshScreenAssistanceIfNeeded()
    }

    private func clearScreenInteraction() {
        invalidateTransientAssistance(turnOffLEDs: false)
        liftedSquare = nil
        legalTargets = []
        screenHints = []
    }

    private func refreshScreenAssistanceIfNeeded() {
        guard !isConnected,
              hasActiveGame,
              !gameSession.isFinished,
              !isEngineTurn,
              let sourceNotation = liftedSquare,
              !legalTargets.isEmpty
        else { return }

        coachingTask?.cancel()
        coachingTask = nil
        clearStockfishHints()
        screenHints = []
        activeHintSummary = ""

        let source = Square(sourceNotation)
        let targets = legalTargets.map(Square.init)
        let mode = assistanceSettings.mode(for: gameSession.sideToMove)

        guard canProvideAssistance(for: source, legalTargets: targets, mode: mode) else {
            showAssistanceLimitReached(for: source)
            return
        }

        switch mode {
        case .off:
            gameStatus = "Pieza seleccionada en \(source.notation). Ayuda desactivada para \(sideToMoveLabel.lowercased())."

        case .legalMoves:
            let hints = AssistanceHintPlanner.hints(for: targets, mode: mode)
            screenHints = hints
            activeHintSummary = hintSummary(hints)
            gameStatus = "Pieza seleccionada en \(source.notation). Puntos verdes fijos = destinos legales."

        case .stockfishQuality, .blunders:
            activeHintSummary = "Stockfish 18 analizando \(source.notation)…"
            gameStatus = "Pieza seleccionada en \(source.notation). Stockfish 18 está valorando sus destinos…"
            startScreenStockfishCoaching(
                source: source,
                legalTargets: targets,
                mode: mode
            )
        }
    }

    private func startScreenStockfishCoaching(
        source: Square,
        legalTargets: [Square],
        mode: AssistanceMode
    ) {
        coachingTask?.cancel()
        clearStockfishHints()

        let fen = logicalFEN
        let coach = stockfishCoach
        let generation = assistanceGeneration
        let thresholds = MoveQualityThresholds(
            blunderThreshold: assistanceSettings.blunderThreshold
        )

        coachingTask = Task { [weak self] in
            do {
                let result = try await coach.evaluate(
                    fen: fen,
                    source: source,
                    legalTargets: legalTargets,
                    thresholds: thresholds
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard !self.isConnected,
                      self.hasActiveGame,
                      self.assistanceGeneration == generation,
                      self.logicalFEN == fen,
                      self.liftedSquare == source.notation,
                      self.assistanceSettings.mode(for: self.gameSession.sideToMove) == mode,
                      mode.requiresStockfishAnalysis
                else { return }

                self.currentStockfishHints = result.hints
                self.currentStockfishHintFEN = fen
                self.currentStockfishHintSource = source
                self.screenHints = result.hints.compactMap { $0.ledHint(for: mode) }
                self.activeHintSummary = self.stockfishHintSummary(result.hints, mode: mode)
                self.gameStatus = self.stockfishCoachingStatus(for: mode)
            } catch is CancellationError {
                // The selection changed or a newer analysis superseded this one.
            } catch {
                guard let self, !Task.isCancelled else { return }
                guard !self.isConnected,
                      self.hasActiveGame,
                      self.assistanceGeneration == generation,
                      self.logicalFEN == fen,
                      self.liftedSquare == source.notation
                else { return }

                self.clearStockfishHints()
                self.screenHints = []
                self.activeHintSummary = ""
                self.gameStatus = "No se pudo analizar \(source.notation) con Stockfish 18: \(error.localizedDescription)"
            }
        }
    }

    private func performScreenMove(
        from source: Square,
        to target: Square,
        promotion: Piece.Kind? = nil,
        requiredMove: OTBExpectedMove? = nil
    ) {
        guard !isConnected,
              hasActiveGame,
              !gameSession.isFinished
        else { return }

        let wasEngineTurn = isEngineTurn
        var candidate = gameSession.board
        guard candidate.move(pieceAt: source, to: target) != nil else {
            gameStatus = "El movimiento \(source.notation)→\(target.notation) no es legal."
            return
        }

        if case let .promotion(promotionMove) = candidate.state {
            let promotionKind = promotion ?? requiredMove?.promotion
            guard let promotionKind else {
                screenPromotionRequest = ScreenPromotionRequest(from: source, to: target)
                gameStatus = "Elige la pieza para promocionar el peón en \(target.notation)."
                return
            }
            _ = candidate.completePromotion(of: promotionMove, to: promotionKind)
        }

        invalidateTransientAssistance(turnOffLEDs: false)
        screenPromotionRequest = nil

        let event = gameSession.process(
            physicalPlacement: candidate.position.fen,
            at: nowProvider(),
            requiredMove: requiredMove
        )

        turnAssistancePolicy.limit = assistanceSettings.maximumPiecesPerTurn
        turnAssistancePolicy.handle(event)

        publishGameState()

        if gameSession.isFinished, gameSession.result.isTimeoutResult {
            cancelEngineMoveRequest(clearSuggestion: true)
            persistCurrentGameIfNeeded()
            gameStatus = gameSession.result.displayText
            return
        }

        switch event {
        case let .moveCompleted(move):
            if wasEngineTurn {
                engineSuggestion = nil
            }
            persistCurrentGameIfNeeded()

            if gameSession.isFinished {
                returnToIdleState()
                return
            }

            gameStatus = "Registrado \(move.san) (\(move.coordinateNotation)). Turno de \(sideToMoveLabel.lowercased())."
            prepareScreenTurn()

        case let .promotionRequired(square, _):
            gameStatus = "Elige la pieza para promocionar en \(square.notation)."

        case let .invalid(message), let .intermediate(message):
            gameStatus = message

        case .synchronized:
            prepareScreenTurn()

        case let .moveUndone(move):
            persistAfterUndo()
            gameStatus = "Jugada \(move.san) deshecha. Turno de \(sideToMoveLabel.lowercased())."
            prepareScreenTurn()

        case .pieceLifted:
            break
        }
    }

    private func scheduleScreenEngineMoveIfNeeded() {
        guard !isConnected,
              isEngineTurn,
              engineMoveTask == nil
        else { return }

        if let suggestion = engineSuggestion {
            gameStatus = "\(opponentDisplayName) juega \(suggestion.displayText) automáticamente en la pantalla."
            performScreenMove(
                from: suggestion.move.from,
                to: suggestion.move.to,
                promotion: suggestion.move.promotion,
                requiredMove: suggestion.move
            )
            return
        }

        engineMoveGeneration += 1
        let generation = engineMoveGeneration
        let fen = logicalFEN
        let history = gameSession.moves.map(\.lan)
        let positionHistory = [gameSession.gameRecord.initialFEN]
            + gameSession.moves.map(\.fenAfter)
        let configuration = resolvedOpponentConfiguration
        guard let engine = currentOpponentEngine else {
            gameStatus = "No se pudo iniciar el motor rival \(opponentDisplayName)."
            return
        }
        isEngineThinking = true
        gameStatus = "\(opponentDisplayName) está calculando su jugada (\(configuration.strengthDisplayText))…"

        engineMoveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.engineMoveGeneration == generation {
                    self.engineMoveTask = nil
                    self.isEngineThinking = false
                }
            }

            do {
                let response = try await engine.move(
                    for: ChessPlayingRequest(
                        fen: fen,
                        moveHistory: history,
                        positionHistory: positionHistory,
                        configuration: configuration
                    )
                )
                let expectedMove = try OpponentMoveValidator.validatedMove(
                    uci: response.uci,
                    fen: fen
                )
                try Task.checkCancellation()
                guard !self.isConnected,
                      self.engineMoveGeneration == generation,
                      self.logicalFEN == fen,
                      self.isEngineTurn
                else { return }

                let suggestion = SoloEngineSuggestion(move: expectedMove)
                self.engineSuggestion = suggestion
                self.gameStatus = "\(self.opponentDisplayName) juega \(suggestion.displayText) automáticamente en la pantalla."
                self.performScreenMove(
                    from: expectedMove.from,
                    to: expectedMove.to,
                    promotion: expectedMove.promotion,
                    requiredMove: expectedMove
                )
            } catch is CancellationError {
                // A new game, reconnection or completed move superseded this search.
            } catch {
                guard self.engineMoveGeneration == generation else { return }
                self.gameStatus = "No se pudo obtener la jugada de \(self.opponentDisplayName): \(error.localizedDescription)"
            }
        }
    }
}
