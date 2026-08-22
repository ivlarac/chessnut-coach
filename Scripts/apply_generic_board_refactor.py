from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def replace_between(text: str, start_marker: str, end_marker: str, replacement: str, label: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise RuntimeError(f"{label}: start marker not found")
    end = text.find(end_marker, start)
    if end < 0:
        raise RuntimeError(f"{label}: end marker not found")
    return text[:start] + replacement + text[end:]


# BoardController: remove all knowledge of EasyLink/Chessnut protocol and depend on the generic board contract.
path = Path("ChessnutCoach/BoardController.swift")
text = path.read_text()
text = text.replace("import EasyLinkSwiftSDK\n", "")
text = replace_once(
    text,
    '    @Published private(set) var batteryPercentage: Int?\n',
    '''    @Published private(set) var batteryPercentage: Int?\n    @Published private(set) var discoveredBoards: [ElectronicBoardDescriptor] = []\n    @Published private(set) var isScanningForBoards = false\n    @Published private(set) var connectedBoard: ElectronicBoardDescriptor?\n''',
    "published board discovery state",
)
text = replace_once(
    text,
    '    var currentGameID: UUID { gameSession.gameRecord.id }\n',
    '''    var currentGameID: UUID { gameSession.gameRecord.id }\n    var boardDisplayName: String { connectedBoard?.name ?? selectedBoard?.name ?? "Tablero electrónico" }\n    var supportsLEDs: Bool { client?.capabilities.contains(.leds) ?? false }\n    var supportsBattery: Bool { client?.capabilities.contains(.battery) ?? false }\n''',
    "board capability helpers",
)
text = replace_once(
    text,
    '    private var client: EasyLinkClient?\n',
    '''    private var client: (any ElectronicChessBoard)?\n    private let boardDiscovery: any ElectronicChessBoardDiscovery\n    private let adapterRegistry: ElectronicBoardAdapterRegistry\n    private let preferences: UserDefaults\n    private var selectedBoard: ElectronicBoardDescriptor?\n    private var discoveryTask: Task<Void, Never>?\n    private var discoveryTimeoutTask: Task<Void, Never>?\n    private let lastBoardPreferenceKey = "LastElectronicChessBoardID"\n''',
    "generic board dependencies",
)
text = text.replace(
    '''    // Chessnut can emit several physical snapshots while a hand is moving a\n    // piece. Never let LED writes block consumption of that realtime stream:\n''',
    '''    // Electronic boards can emit several physical snapshots while a hand is moving a\n    // piece. Never let LED writes block consumption of that realtime stream:\n''',
)
text = replace_once(
    text,
    '    init(library: GameLibrary? = nil) {\n        gameLibrary = library\n',
    '''    init(\n        library: GameLibrary? = nil,\n        boardDiscovery: any ElectronicChessBoardDiscovery = ChessnutBoardDiscovery(),\n        adapterRegistry: ElectronicBoardAdapterRegistry = .chessnutDefault,\n        preferences: UserDefaults = .standard\n    ) {\n        gameLibrary = library\n        self.boardDiscovery = boardDiscovery\n        self.adapterRegistry = adapterRegistry\n        self.preferences = preferences\n''',
    "inject board dependencies",
)
text = text.replace(
    'gameStatus = "Partida recuperada. Puedes continuar en pantalla o conectar el Chessnut."',
    'gameStatus = "Partida recuperada. Puedes continuar en pantalla o conectar un tablero físico."',
)

connection_block = '''    func connect() {
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
                    : "Se encontraron \\(self.discoveredBoards.count) tableros. Selecciona uno."
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
                        : "Se encontraron \\(self.discoveredBoards.count) tableros. Selecciona uno.")
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
            ? "Reconectando a \\(descriptor.name)…"
            : "Conectando a \\(descriptor.name)…"

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
                    ? "\\(descriptor.name) reconectado · validando posición…"
                    : "\\(descriptor.name) conectado · esperando posición…"
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
                    : "No se pudo conectar a \\(descriptor.name): \\(error.localizedDescription)"
                self.prepareScreenTurn()
            }

            self.connectionTask = nil

            if !self.isConnected, self.shouldMaintainConnection {
                self.scheduleReconnect()
            }
        }
    }

'''
text = replace_between(text, "    func connect() {", "    func disconnect() {", connection_block, "connection/discovery block")

disconnect_block = '''    func disconnect() {
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

'''
text = replace_between(text, "    func disconnect() {", "    func handleAppPhase", disconnect_block, "disconnect block")

text = replace_once(
    text,
    '''    func refreshBattery() {\n        guard let client else { return }\n\n        Task { [weak self] in\n            await self?.refreshBattery(using: client)\n        }\n    }\n''',
    '''    func refreshBattery() {\n        guard let client, client.capabilities.contains(.battery) else {\n            batteryPercentage = nil\n            return\n        }\n\n        Task { [weak self] in\n            await self?.refreshBattery(using: client)\n        }\n    }\n''',
    "battery capability guard",
)

for function in ["lightLED", "blinkLED"]:
    text = replace_once(
        text,
        f'''    func {function}(rankIndex: Int, fileIndex: Int) {{\n        guard let client else {{ return }}\n''',
        f'''    func {function}(rankIndex: Int, fileIndex: Int) {{\n        guard let client, client.capabilities.contains(.leds) else {{ return }}\n''',
        f"{function} LED guard",
    )
for function in ["demoLEDPatterns", "ledsOff"]:
    text = replace_once(
        text,
        f'''    func {function}() {{\n        guard let client else {{ return }}\n''',
        f'''    func {function}() {{\n        guard let client, client.capabilities.contains(.leds) else {{ return }}\n''',
        f"{function} LED guard",
    )

stream_block = '''    private func startDisconnectionStream(client: any ElectronicChessBoard) {
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

'''
text = replace_between(text, "    private func startDisconnectionStream(", "    private func handleUnexpectedDisconnect", stream_block, "generic disconnect stream")
text = text.replace("client disconnectedClient: EasyLinkClient", "client disconnectedClient: any ElectronicChessBoard")
text = text.replace("client failedClient: EasyLinkClient", "client failedClient: any ElectronicChessBoard")
text = text.replace("client: EasyLinkClient", "client: any ElectronicChessBoard")
text = text.replace("LEDBoard", "ElectronicBoardLEDFrame")
text = text.replace("client.fenUpdates", "client.positionUpdates")
text = text.replace('status = "Chessnut desconectado · reconectando…"', 'status = "\\(selectedBoard?.name ?? "Tablero") desconectado · reconectando…"')
text = replace_once(
    text,
    '''        self.client = nil\n        isConnected = false\n        batteryPercentage = nil\n        status = "\\(selectedBoard?.name ?? "Tablero") desconectado · reconectando…"\n''',
    '''        self.client = nil\n        connectedBoard = nil\n        isConnected = false\n        batteryPercentage = nil\n        status = "\\(selectedBoard?.name ?? "Tablero") desconectado · reconectando…"\n''',
    "clear connected board on unexpected disconnect",
)
text = text.replace(
    '"Conexión activa. Esperando la posición actual del Chessnut para recuperar la partida."',
    '"Conexión activa. Esperando la posición actual del tablero para recuperar la partida."',
)

probe_block = '''    private func probeConnectionAndRequestFreshSnapshot(shouldRequestSnapshot: Bool) {
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

'''
text = replace_between(text, "    private func probeConnectionAndRequestFreshSnapshot", "    private func startFENStream", probe_block, "capability-aware connection probe")

piece_lift_block = '''            case let .pieceLifted(source, legalTargets):
                clearStockfishHints()
                if wasEngineTurn, let suggestion = engineSuggestion {
                    gameStatus = "Jugada de Stockfish: lleva \\(suggestion.displayText)."
                    activeHintSummary = "Origen fijo · destino intermitente"
                    startEngineMoveLEDs(suggestion.move, client: client)
                } else if legalTargets.isEmpty {
                    gameStatus = "\\(source.notation) no tiene movimientos legales."
                    try await client.setLEDs(.allOff)
                } else if !client.capabilities.contains(.leds) {
                    activeHintSummary = ""
                    gameStatus = "Pieza levantada en \\(source.notation). Este tablero no dispone de LEDs; continúa sin ayuda luminosa."
                } else {
                    let mode = assistanceSettings.mode(for: gameSession.sideToMove)

                    switch mode {
                    case .off:
                        gameStatus = "Pieza levantada en \\(source.notation). Ayuda desactivada para \\(sideToMoveLabel.lowercased())."
                        try await client.setLEDs(.allOff)

                    case .legalMoves:
                        let hints = AssistanceHintPlanner.hints(for: legalTargets, mode: mode)
                        gameStatus = "Pieza levantada en \\(source.notation). LEDs fijos = destinos legales."
                        activeHintSummary = hintSummary(hints)
                        startLEDHints(hints, client: client)

                    case .stockfishQuality, .blunders:
                        gameStatus = "Pieza levantada en \\(source.notation). Stockfish 18 está valorando sus destinos…"
                        activeHintSummary = "Stockfish 18 analizando \\(source.notation)…"
                        try await client.setLEDs(.allOff)
                        startStockfishCoaching(
                            source: source,
                            legalTargets: legalTargets,
                            mode: mode,
                            client: client
                        )
                    }
                }

'''
text = replace_between(text, "            case let .pieceLifted(source, legalTargets):", "            case let .moveCompleted(move):", piece_lift_block, "no-LED piece lift behavior")

text = replace_once(
    text,
    '''        guard hasActiveGame,\n              let client,\n              let source = gameSession.liftedSquare,\n''',
    '''        guard hasActiveGame,\n              let client,\n              client.capabilities.contains(.leds),\n              let source = gameSession.liftedSquare,\n''',
    "assistance LED capability guard",
)
text = replace_once(
    text,
    '''    private func startLEDHints(_ hints: [LEDHint], client: any ElectronicChessBoard) {\n        ledTask?.cancel()\n        let generation = assistanceGeneration\n\n        guard !hints.isEmpty else {\n''',
    '''    private func startLEDHints(_ hints: [LEDHint], client: any ElectronicChessBoard) {\n        ledTask?.cancel()\n        let generation = assistanceGeneration\n\n        guard client.capabilities.contains(.leds), !hints.isEmpty else {\n''',
    "LED hint capability guard",
)
text = replace_once(
    text,
    '''        guard turnOffLEDs, let client else { return }\n''',
    '''        guard turnOffLEDs, let client, client.capabilities.contains(.leds) else { return }\n''',
    "LED invalidation capability guard",
)
text = replace_once(
    text,
    '''    private func refreshBattery(using client: any ElectronicChessBoard) async {\n        do {\n''',
    '''    private func refreshBattery(using client: any ElectronicChessBoard) async {\n        guard client.capabilities.contains(.battery) else {\n            batteryPercentage = nil\n            return\n        }\n\n        do {\n''',
    "battery helper capability guard",
)
text = replace_once(
    text,
    '''    private func resetConnectionState() {\n        isConnected = false\n''',
    '''    private func resetConnectionState() {\n        isConnected = false\n        connectedBoard = nil\n''',
    "clear board on reset",
)
text = text.replace(
    '"Tablero Chessnut desconectado. Juega directamente en el tablero de la pantalla."',
    '"Tablero físico desconectado. Juega directamente en el tablero de la pantalla."',
)
path.write_text(text)

# Current game UI: device discovery/selection and capability-aware presentation.
path = Path("ChessnutCoach/CurrentGameView.swift")
text = path.read_text()
connection_card = '''    private var connectionCard: some View {
        CoachCard(board.boardDisplayName, systemImage: "dot.radiowaves.left.and.right") {
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
                    Label("\\(battery)%", systemImage: batterySymbol(for: battery))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(battery > 20 ? Color.primary : Color.red)
                }
            }

            if board.isConnected {
                if !board.supportsLEDs {
                    Label(
                        "Este tablero no ofrece LEDs; la partida y la detección de jugadas siguen disponibles sin ayudas luminosas.",
                        systemImage: "lightbulb.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    if board.supportsBattery {
                        Button("Actualizar batería") {
                            board.refreshBattery()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Desconectar", role: .destructive) {
                        board.disconnect()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                if board.isScanningForBoards {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Buscando tableros cercanos…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !board.discoveredBoards.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(board.discoveredBoards) { device in
                            Button {
                                board.connect(to: device)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text(device.manufacturer)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "link")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Button {
                    board.discoveredBoards.isEmpty ? board.connect() : board.scanForBoards()
                } label: {
                    Label(
                        board.discoveredBoards.isEmpty ? "Buscar tableros" : "Buscar de nuevo",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(board.isScanningForBoards)
            }
        }
    }

'''
text = replace_between(text, "    private var connectionCard: some View {", "    private var screenBoardCard: some View {", connection_card, "board picker UI")
text = text.replace(
    "Inicia una partida para jugar directamente aquí mientras el Chessnut esté desconectado.",
    "Inicia una partida para jugar directamente aquí mientras el tablero físico esté desconectado.",
)
text = text.replace(
    ".disabled(board.hasActiveGame && board.isSoloGame && board.humanSide == .black)\n\n            Divider()\n\n            assistancePicker(",
    ".disabled((board.hasActiveGame && board.isSoloGame && board.humanSide == .black) || (board.isConnected && !board.supportsLEDs))\n\n            Divider()\n\n            assistancePicker(",
)
text = text.replace(
    ".disabled(board.hasActiveGame && board.isSoloGame && board.humanSide == .white)\n\n            if !board.activeHintSummary.isEmpty {",
    ".disabled((board.hasActiveGame && board.isSoloGame && board.humanSide == .white) || (board.isConnected && !board.supportsLEDs))\n\n            if board.isConnected && !board.supportsLEDs {\n                Text("Las ayudas por LED no están disponibles con el tablero conectado actualmente.")\n                    .font(.footnote)\n                    .foregroundStyle(.secondary)\n            }\n\n            if !board.activeHintSummary.isEmpty {",
)
path.write_text(text)

# Information screen: describe adapter-based compatibility instead of hard-coding Air.
path = Path("ChessnutCoach/ContentView.swift")
text = path.read_text()
text = text.replace(
    "Asistente para jugar y registrar partidas de ajedrez con un tablero Chessnut Air, con análisis y ayuda opcional mediante Stockfish 18.",
    "Asistente para jugar y registrar partidas con tableros electrónicos compatibles, con análisis y ayuda opcional mediante Stockfish 18.",
)
text = text.replace(
    "Conexión Bluetooth con Chessnut Air y seguimiento de la posición en tiempo real.",
    "Conexión mediante adaptadores de tablero y seguimiento de la posición en tiempo real.",
)
text = text.replace(
    "Movimientos legales, calidad de jugadas y aviso de blunders configurable por bando.",
    "Movimientos legales, calidad de jugadas y aviso de blunders configurable por bando cuando el tablero dispone de LEDs.",
)
text = replace_once(
    text,
    '''                Section("Compatibilidad") {\n                    LabeledContent("iOS", value: "16 o posterior")\n                    LabeledContent("Motor", value: "Stockfish 18")\n                    LabeledContent("Tablero", value: "Chessnut Air")\n                }\n''',
    '''                Section("Compatibilidad") {\n                    LabeledContent("iOS", value: "16 o posterior")\n                    LabeledContent("Motor", value: "Stockfish 18")\n                    LabeledContent("Chessnut clásico", value: "Air · Air+ · Go · Pro")\n                    LabeledContent("Chessnut Move", value: "EasyLink")\n                    Text("La comunicación con el hardware usa una capa de adaptadores preparada para añadir otros fabricantes sin acoplar la lógica de partida a su protocolo.")\n                        .font(.footnote)\n                        .foregroundStyle(.secondary)\n                }\n''',
    "compatibility information",
)
path.write_text(text)

# Package target: compile/test the vendor-neutral abstraction without the iOS/BLE adapter.
path = Path("Package.swift")
text = path.read_text()
text = replace_once(
    text,
    '                "MonitoredEasyLinkTransport.swift",\n',
    '                "MonitoredEasyLinkTransport.swift",\n                "ChessnutBoardAdapter.swift",\n',
    "exclude Chessnut adapter from core package",
)
text = replace_once(
    text,
    '''                "GameArchive.swift",\n                "GameModels.swift",\n                "OTBGameSession.swift"\n''',
    '''                "GameArchive.swift",\n                "GameModels.swift",\n                "OTBGameSession.swift",\n                "ElectronicChessBoard.swift"\n''',
    "include generic board in core package",
)
path.write_text(text)

# Xcode project: add the two new app sources and bump this PR exactly one patch version.
path = Path("ChessnutCoach.xcodeproj/project.pbxproj")
text = path.read_text()
text = replace_once(
    text,
    '\t\tA1000000000000000000000A /* MonitoredEasyLinkTransport.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10000000000000000000009 /* MonitoredEasyLinkTransport.swift */; };\n',
    '\t\tA1000000000000000000000A /* MonitoredEasyLinkTransport.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10000000000000000000009 /* MonitoredEasyLinkTransport.swift */; };\n\t\tA10000000000000000000012 /* ElectronicChessBoard.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10000000000000000000012 /* ElectronicChessBoard.swift */; };\n\t\tA10000000000000000000013 /* ChessnutBoardAdapter.swift in Sources */ = {isa = PBXBuildFile; fileRef = B10000000000000000000013 /* ChessnutBoardAdapter.swift */; };\n',
    "build file refs",
)
text = replace_once(
    text,
    '\t\tB10000000000000000000009 /* MonitoredEasyLinkTransport.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MonitoredEasyLinkTransport.swift; sourceTree = "<group>"; };\n',
    '\t\tB10000000000000000000009 /* MonitoredEasyLinkTransport.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MonitoredEasyLinkTransport.swift; sourceTree = "<group>"; };\n\t\tB10000000000000000000012 /* ElectronicChessBoard.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ElectronicChessBoard.swift; sourceTree = "<group>"; };\n\t\tB10000000000000000000013 /* ChessnutBoardAdapter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ChessnutBoardAdapter.swift; sourceTree = "<group>"; };\n',
    "source file refs",
)
text = replace_once(
    text,
    '\t\t\t\tB10000000000000000000009 /* MonitoredEasyLinkTransport.swift */,\n',
    '\t\t\t\tB10000000000000000000009 /* MonitoredEasyLinkTransport.swift */,\n\t\t\t\tB10000000000000000000012 /* ElectronicChessBoard.swift */,\n\t\t\t\tB10000000000000000000013 /* ChessnutBoardAdapter.swift */,\n',
    "group source refs",
)
text = replace_once(
    text,
    '\t\t\t\tA1000000000000000000000A /* MonitoredEasyLinkTransport.swift in Sources */,\n',
    '\t\t\t\tA1000000000000000000000A /* MonitoredEasyLinkTransport.swift in Sources */,\n\t\t\t\tA10000000000000000000012 /* ElectronicChessBoard.swift in Sources */,\n\t\t\t\tA10000000000000000000013 /* ChessnutBoardAdapter.swift in Sources */,\n',
    "sources build phase",
)
text = text.replace("CURRENT_PROJECT_VERSION = 9;", "CURRENT_PROJECT_VERSION = 10;")
text = text.replace("MARKETING_VERSION = 0.0.9;", "MARKETING_VERSION = 0.0.10;")
path.write_text(text)

# Tests: generic capability/adapter selection tests plus app-level fake-board integration tests.
path = Path("ChessnutCoachTests/OTBGameSessionTests.swift")
text = path.read_text()
generic_tests = '''    func testElectronicBoardCapabilitiesRepresentOptionalHardwareFeatures() {
        let minimal: ElectronicBoardCapabilities = [.positionReading, .realtimePosition]
        XCTAssertTrue(minimal.contains(.positionReading))
        XCTAssertTrue(minimal.contains(.realtimePosition))
        XCTAssertFalse(minimal.contains(.leds))
        XCTAssertFalse(minimal.contains(.battery))
        XCTAssertFalse(minimal.contains(.automaticMovement))

        let rich: ElectronicBoardCapabilities = [
            .positionReading, .realtimePosition, .leds, .ledColors, .battery,
            .gameStorage, .automaticMovement, .pieceIdentification,
        ]
        XCTAssertTrue(rich.contains(.ledColors))
        XCTAssertTrue(rich.contains(.pieceIdentification))
    }

    func testElectronicBoardRegistrySelectsMatchingAdapter() throws {
        let descriptor = TestElectronicChessBoard.makeDescriptor(adapterIdentifier: "test.adapter")
        let fake = TestElectronicChessBoard(descriptor: descriptor)
        let registry = ElectronicBoardAdapterRegistry(
            factories: [TestElectronicBoardFactory(board: fake)]
        )

        let selected = try registry.makeBoard(for: descriptor)
        XCTAssertEqual(selected.descriptor, descriptor)

        let unsupported = TestElectronicChessBoard.makeDescriptor(adapterIdentifier: "other.adapter")
        XCTAssertThrowsError(try registry.makeBoard(for: unsupported))
    }

'''
text = replace_once(
    text,
    '#if !SWIFT_PACKAGE\n    @MainActor\n    func testCoreDataLibraryUpsertsUpdatesAndDeletesGame() {',
    generic_tests + '#if !SWIFT_PACKAGE\n    @MainActor\n    func testCoreDataLibraryUpsertsUpdatesAndDeletesGame() {',
    "generic board tests",
)
app_tests = '''    @MainActor
    func testBoardControllerConnectsDisconnectsAndReceivesGenericBoardPositions() async throws {
        let descriptor = TestElectronicChessBoard.makeDescriptor(
            capabilities: [.positionReading, .realtimePosition, .battery]
        )
        let fake = TestElectronicChessBoard(descriptor: descriptor)
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let controller = BoardController(
            library: GameLibrary(inMemory: true),
            boardDiscovery: TestElectronicBoardDiscovery(devices: [descriptor]),
            adapterRegistry: ElectronicBoardAdapterRegistry(
                factories: [TestElectronicBoardFactory(board: fake)]
            ),
            preferences: preferences
        )

        controller.connect(to: descriptor)
        try await waitUntil { controller.isConnected }
        XCTAssertEqual(controller.connectedBoard, descriptor)
        XCTAssertTrue(controller.supportsBattery)

        let placement = Position.standard.fen.split(separator: " ").first.map(String.init)!
        fake.emitPosition(placement)
        try await waitUntil { controller.boardPlacement == placement }

        controller.disconnect()
        try await waitUntil { !controller.isConnected }
        XCTAssertNil(controller.connectedBoard)
    }

    @MainActor
    func testBoardControllerKeepsGameWorkingWhenBoardHasNoLEDs() async throws {
        let descriptor = TestElectronicChessBoard.makeDescriptor(
            capabilities: [.positionReading, .realtimePosition]
        )
        let fake = TestElectronicChessBoard(descriptor: descriptor)
        let controller = BoardController(
            library: GameLibrary(inMemory: true),
            boardDiscovery: TestElectronicBoardDiscovery(devices: [descriptor]),
            adapterRegistry: ElectronicBoardAdapterRegistry(
                factories: [TestElectronicBoardFactory(board: fake)]
            ),
            preferences: UserDefaults(suiteName: UUID().uuidString)!
        )

        controller.newGame(
            configuration: NewGameConfiguration(
                assistance: AssistanceSettings(white: .legalMoves, black: .legalMoves)
            )
        )
        controller.connect(to: descriptor)
        try await waitUntil { controller.isConnected }

        let initial = Position.standard.fen.split(separator: " ").first.map(String.init)!
        fake.emitPosition(initial)
        try await waitUntil { controller.isBoardSynchronized }

        let liftedE2 = "rnbqkbnr/pppppppp/8/8/8/8/PPPP1PPP/RNBQKBNR"
        fake.emitPosition(liftedE2)
        try await waitUntil { controller.liftedSquare == "e2" }

        XCTAssertTrue(controller.isConnected)
        XCTAssertFalse(controller.supportsLEDs)
        XCTAssertEqual(controller.legalTargets, ["e3", "e4"])
        XCTAssertTrue(controller.activeHintSummary.isEmpty)
        XCTAssertTrue(controller.gameStatus.contains("no dispone de LEDs"))
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 80,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for asynchronous board state")
    }

'''
text = replace_once(
    text,
    '    func testStockfishScoreInversionAndOrderingForCoaching() {',
    app_tests + '    func testStockfishScoreInversionAndOrderingForCoaching() {',
    "app fake-board tests",
)
text += '''

private final class TestElectronicChessBoard: ElectronicChessBoard, @unchecked Sendable {
    let descriptor: ElectronicBoardDescriptor
    let capabilities: ElectronicBoardCapabilities
    let positionUpdates: AsyncStream<String>
    let connectionEvents: AsyncStream<ElectronicBoardConnectionEvent>

    private let positionContinuation: AsyncStream<String>.Continuation
    private let connectionContinuation: AsyncStream<ElectronicBoardConnectionEvent>.Continuation

    init(descriptor: ElectronicBoardDescriptor) {
        self.descriptor = descriptor
        capabilities = descriptor.capabilities

        var positionContinuation: AsyncStream<String>.Continuation!
        positionUpdates = AsyncStream { positionContinuation = $0 }
        self.positionContinuation = positionContinuation

        var connectionContinuation: AsyncStream<ElectronicBoardConnectionEvent>.Continuation!
        connectionEvents = AsyncStream { connectionContinuation = $0 }
        self.connectionContinuation = connectionContinuation
    }

    func connect() async throws {}
    func enableRealtimeUpdates() async throws {}

    func disconnect() async {
        connectionContinuation.yield(.disconnected)
    }

    func batteryStatus(timeout: Duration) async throws -> ElectronicBoardBatteryStatus {
        _ = timeout
        guard capabilities.contains(.battery) else {
            throw ElectronicBoardError.unsupportedCapability("batería")
        }
        return ElectronicBoardBatteryStatus(percentage: 73, isCharging: false)
    }

    func emitPosition(_ placement: String) {
        positionContinuation.yield(placement)
    }

    static func makeDescriptor(
        adapterIdentifier: String = "test.adapter",
        capabilities: ElectronicBoardCapabilities = [.positionReading, .realtimePosition]
    ) -> ElectronicBoardDescriptor {
        ElectronicBoardDescriptor(
            adapterIdentifier: adapterIdentifier,
            hardwareIdentifier: UUID().uuidString,
            name: "Test Board",
            manufacturer: "Tests",
            model: "Fake",
            variantIdentifier: "fake",
            capabilities: capabilities
        )
    }
}

private struct TestElectronicBoardFactory: ElectronicBoardAdapterFactory {
    let identifier: String
    let board: any ElectronicChessBoard

    init(board: any ElectronicChessBoard) {
        self.board = board
        identifier = board.descriptor.adapterIdentifier
    }

    func canCreateBoard(for descriptor: ElectronicBoardDescriptor) -> Bool {
        descriptor.adapterIdentifier == identifier
    }

    func makeBoard(for descriptor: ElectronicBoardDescriptor) throws -> any ElectronicChessBoard {
        guard canCreateBoard(for: descriptor) else {
            throw ElectronicBoardError.noAdapter(descriptor.name)
        }
        return board
    }
}

private struct TestElectronicBoardDiscovery: ElectronicChessBoardDiscovery {
    let devices: [ElectronicBoardDescriptor]

    func scan() -> AsyncStream<ElectronicBoardDescriptor> {
        AsyncStream { continuation in
            for device in devices {
                continuation.yield(device)
            }
            continuation.finish()
        }
    }
}
'''
path.write_text(text)

print("Generic electronic board refactor applied")
