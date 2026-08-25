import ChessKit
import Foundation

enum ElectronicBoardAppPhase: Equatable, Sendable {
    case active
    case inactive
    case background
}

struct ElectronicBoardLifecycleDirective: Equatable, Sendable {
    let invalidateTransientAssistance: Bool
    let requestFreshBoardSnapshot: Bool
    let probeConnection: Bool

    static let none = ElectronicBoardLifecycleDirective(
        invalidateTransientAssistance: false,
        requestFreshBoardSnapshot: false,
        probeConnection: false
    )
}

struct ElectronicBoardSessionLifecycle: Equatable, Sendable {
    private(set) var phase: ElectronicBoardAppPhase = .active

    mutating func transition(to newPhase: ElectronicBoardAppPhase) -> ElectronicBoardLifecycleDirective {
        guard newPhase != phase else { return .none }
        phase = newPhase

        switch newPhase {
        case .inactive:
            return .none
        case .background:
            return ElectronicBoardLifecycleDirective(
                invalidateTransientAssistance: true,
                requestFreshBoardSnapshot: false,
                probeConnection: false
            )
        case .active:
            return ElectronicBoardLifecycleDirective(
                invalidateTransientAssistance: true,
                requestFreshBoardSnapshot: true,
                probeConnection: true
            )
        }
    }
}

enum GameLifecycleStatus: String, Codable, Sendable {
    case playing
    case finished
    case aborted
}

enum GameMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case twoPlayer
    case solo

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .twoPlayer: "Contra persona"
        case .solo: "Contra IA"
        }
    }
}

enum PlayerSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case white
    case black

    var id: String { rawValue }
    var pieceColor: Piece.Color { self == .white ? .white : .black }
    var displayText: String { self == .white ? "Blancas" : "Negras" }
}

enum HumanSideChoice: String, CaseIterable, Identifiable, Sendable {
    case white
    case black
    case random

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .white: "Blancas"
        case .black: "Negras"
        case .random: "Aleatorio"
        }
    }

    func resolvedSide(randomValue: Bool = Bool.random()) -> PlayerSide {
        switch self {
        case .white: .white
        case .black: .black
        case .random: randomValue ? .white : .black
        }
    }
}

enum MoveParticipant: String, Codable, Sendable {
    case player
    case human
    case engine
}

struct StockfishStrength: Equatable, Codable, Sendable {
    static let minimumElo = 1_320
    static let maximumElo = 3_190
    static let minimumLevel = 1
    static let maximumLevel = 20
    private static let maximumLimitedLevel = maximumLevel - 1
    static let full = StockfishStrength(elo: nil)

    /// `nil` disables UCI_LimitStrength and lets Stockfish use full strength.
    let elo: Int?

    init(elo: Int?) {
        self.elo = elo.map { min(max($0, Self.minimumElo), Self.maximumElo) }
    }

    init(level: Int) {
        let level = min(max(level, Self.minimumLevel), Self.maximumLevel)
        guard level < Self.maximumLevel else {
            self = .full
            return
        }

        let progress = Double(level - Self.minimumLevel)
            / Double(Self.maximumLimitedLevel - Self.minimumLevel)
        let elo = Double(Self.minimumElo)
            + progress * Double(Self.maximumElo - Self.minimumElo)
        self.init(elo: Int(elo.rounded()))
    }

    var level: Int {
        guard let elo else { return Self.maximumLevel }
        let progress = Double(elo - Self.minimumElo)
            / Double(Self.maximumElo - Self.minimumElo)
        let level = Self.minimumLevel
            + Int((progress * Double(Self.maximumLimitedLevel - Self.minimumLevel)).rounded())
        return min(max(level, Self.minimumLevel), Self.maximumLimitedLevel)
    }

    var displayText: String {
        level == Self.maximumLevel ? "Nivel 20 · Máxima" : "Nivel \(level)"
    }

    var technicalDetailText: String {
        elo.map { "Equivale aproximadamente a Elo \($0)." }
            ?? "Stockfish jugará sin limitación de fuerza."
    }
}

struct NewGameConfiguration: Equatable, Sendable {
    var mode: GameMode = .twoPlayer
    var humanSide: PlayerSide = .white
    var opponentEngine: OpponentEngineConfiguration = .stockfish(StockfishStrength(level: 4))
    var assistance: AssistanceSettings = AssistanceSettings()
    var allowUndo: Bool = false
    var timeControl: GameTimeControl = .unlimited
    var whitePlayerName: String?
    var blackPlayerName: String?

    /// Source-compatible access for callers from the former Stockfish-only flow.
    var strength: StockfishStrength {
        opponentEngine.stockfishStrength ?? StockfishStrength(level: 4)
    }

    init(
        mode: GameMode = .twoPlayer,
        humanSide: PlayerSide = .white,
        strength: StockfishStrength = StockfishStrength(level: 4),
        opponentEngine: OpponentEngineConfiguration? = nil,
        assistance: AssistanceSettings = AssistanceSettings(),
        allowUndo: Bool = false,
        timeControl: GameTimeControl = .unlimited,
        whitePlayerName: String? = nil,
        blackPlayerName: String? = nil
    ) {
        self.mode = mode
        self.humanSide = humanSide
        self.opponentEngine = opponentEngine ?? .stockfish(strength)
        self.assistance = assistance
        self.allowUndo = allowUndo
        self.timeControl = timeControl
        self.whitePlayerName = whitePlayerName
        self.blackPlayerName = blackPlayerName
    }
}

struct NewGameLaunch: Equatable, Sendable {
    let configuration: NewGameConfiguration
    let automaticBoardRotation: Bool
}

/// Editable, UI-independent state for the complete new-game flow.
/// Keeping this separate from `BoardController` prevents the setup sheet from
/// mutating an active or archived game before the user confirms it.
struct NewGameDraft: Equatable, Sendable {
    var mode = GameMode.twoPlayer
    var sideChoice = HumanSideChoice.white
    var opponentEngineKind = OpponentEngineKind.stockfish18
    var stockfishLevel = 4
    var maia3Rating = 800
    var humanPlayerName: String
    var whitePlayerName: String
    var blackPlayerName: String
    var humanAssistance: AssistanceMode
    var whiteAssistance: AssistanceMode
    var blackAssistance: AssistanceMode
    var maximumAssistancePieces: AssistancePieceLimit
    var blunderThreshold: BlunderThreshold
    var allowUndo = false
    var automaticBoardRotation = false
    var timePreset = GameTimePreset.unlimited
    var customInitialMinutes = 5
    var customIncrementSeconds = 0

    init(
        whitePlayerName: String,
        blackPlayerName: String,
        whiteAssistance: AssistanceMode,
        blackAssistance: AssistanceMode,
        maximumAssistancePieces: AssistancePieceLimit = .unlimited,
        blunderThreshold: BlunderThreshold = .twoHundred
    ) {
        self.whitePlayerName = Self.editableName(whitePlayerName, fallback: "Blancas")
        self.blackPlayerName = Self.editableName(blackPlayerName, fallback: "Negras")
        humanPlayerName = Self.preferredHumanName(
            white: whitePlayerName,
            black: blackPlayerName
        )
        humanAssistance = Self.isSpecificHumanName(blackPlayerName)
            && !Self.isSpecificHumanName(whitePlayerName)
            ? blackAssistance
            : whiteAssistance
        self.whiteAssistance = whiteAssistance
        self.blackAssistance = blackAssistance
        self.maximumAssistancePieces = maximumAssistancePieces
        self.blunderThreshold = blunderThreshold
    }

    var canStart: Bool {
        switch mode {
        case .twoPlayer:
            Self.isValidHumanName(whitePlayerName) && Self.isValidHumanName(blackPlayerName)
        case .solo:
            Self.isValidHumanName(humanPlayerName)
        }
    }

    var canLaunch: Bool {
        canStart
            && resolvedTimeControl != nil
            && (mode != .solo || opponentEngineKind.isPlayableInThisBuild)
    }

    var resolvedTimeControl: GameTimeControl? {
        timePreset == .custom
            ? GameTimeLimits.customControl(
                initialMinutes: customInitialMinutes,
                incrementSeconds: customIncrementSeconds
            )
            : timePreset.timeControl
    }

    func makeLaunch(randomValue: Bool = Bool.random()) -> NewGameLaunch? {
        guard canLaunch, let timeControl = resolvedTimeControl else { return nil }

        let humanSide = sideChoice.resolvedSide(randomValue: randomValue)
        let assistance = mode == .solo
            ? AssistanceSettings(
                white: humanSide == .white ? humanAssistance : .off,
                black: humanSide == .black ? humanAssistance : .off,
                maximumPiecesPerTurn: maximumAssistancePieces,
                blunderThreshold: blunderThreshold
            )
            : AssistanceSettings(
                white: whiteAssistance,
                black: blackAssistance,
                maximumPiecesPerTurn: maximumAssistancePieces,
                blunderThreshold: blunderThreshold
            )
        let humanName = Self.trimmed(humanPlayerName)
        let opponent = opponentEngineConfiguration
        let opponentName = opponent.displayName
        let whiteName = mode == .solo
            ? (humanSide == .white ? humanName : opponentName)
            : Self.trimmed(whitePlayerName)
        let blackName = mode == .solo
            ? (humanSide == .black ? humanName : opponentName)
            : Self.trimmed(blackPlayerName)

        return NewGameLaunch(
            configuration: NewGameConfiguration(
                mode: mode,
                humanSide: humanSide,
                opponentEngine: opponent,
                assistance: assistance,
                allowUndo: mode == .twoPlayer && allowUndo,
                timeControl: timeControl,
                whitePlayerName: whiteName,
                blackPlayerName: blackName
            ),
            automaticBoardRotation: mode == .twoPlayer && automaticBoardRotation
        )
    }

    var opponentEngineConfiguration: OpponentEngineConfiguration {
        switch opponentEngineKind {
        case .stockfish18:
            .stockfish(StockfishStrength(level: stockfishLevel))
        case .maia3:
            .maia3(Maia3Strength(rating: maia3Rating))
        }
    }

    private static func preferredHumanName(white: String, black: String) -> String {
        if isSpecificHumanName(white) { return trimmed(white) }
        if isSpecificHumanName(black) { return trimmed(black) }
        return "Jugador"
    }

    private static func editableName(_ value: String, fallback: String) -> String {
        isValidHumanName(value) ? trimmed(value) : fallback
    }

    private static func isSpecificHumanName(_ value: String) -> Bool {
        guard isValidHumanName(value) else { return false }
        let value = trimmed(value)
        return value.localizedCaseInsensitiveCompare("Blancas") != .orderedSame
            && value.localizedCaseInsensitiveCompare("Negras") != .orderedSame
            && value.localizedCaseInsensitiveCompare("Jugador") != .orderedSame
    }

    private static func isValidHumanName(_ value: String) -> Bool {
        let value = trimmed(value)
        return !value.isEmpty && !OpponentEngineKind.allCases.contains {
            value.localizedCaseInsensitiveContains($0.displayName)
                || value.localizedCaseInsensitiveContains($0.rawValue)
        }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WhitePositionEvaluation: Equatable, Sendable {
    case centipawns(Int)
    case mate(Int)
    case tablebase(Int)

    /// Portion of the vertical evaluation bar occupied by White.
    var whiteShare: Double {
        switch self {
        case let .centipawns(value):
            return 0.5 + 0.5 * tanh(Double(value) / 400.0)
        case let .mate(value), let .tablebase(value):
            return value >= 0 ? 1 : 0
        }
    }

    var displayText: String {
        switch self {
        case let .centipawns(value):
            return String(format: "%+.2f", Double(value) / 100.0)
                .replacingOccurrences(of: ".", with: ",")
        case let .mate(plies):
            let moves = max(1, (abs(plies) + 1) / 2)
            return plies >= 0 ? "#\(moves)" : "#-\(moves)"
        case let .tablebase(value):
            return value >= 0 ? "TB+" : "TB-"
        }
    }
}

enum GameEndReason: String, Codable, Sendable {
    case checkmate
    case resignation
    case timeout
}

enum GameDrawReason: String, Codable, Sendable {
    case stalemate
    case fiftyMoves
    case repetition
    case insufficientMaterial
    case agreement
}

enum GameResult: Equatable, Codable, Sendable {
    case unfinished
    case whiteWin(reason: GameEndReason)
    case blackWin(reason: GameEndReason)
    case draw(reason: GameDrawReason)

    var pgnValue: String {
        switch self {
        case .unfinished:
            "*"
        case .whiteWin:
            "1-0"
        case .blackWin:
            "0-1"
        case .draw:
            "1/2-1/2"
        }
    }

    var displayText: String {
        switch self {
        case .unfinished:
            "En juego"
        case let .whiteWin(reason):
            "1-0 · Blancas ganan por \(reason.displayText)"
        case let .blackWin(reason):
            "0-1 · Negras ganan por \(reason.displayText)"
        case let .draw(reason):
            "½-½ · Tablas por \(reason.displayText)"
        }
    }

    var isTimeoutResult: Bool {
        switch self {
        case .whiteWin(reason: .timeout), .blackWin(reason: .timeout): true
        default: false
        }
    }
}

extension GameEndReason {
    var displayText: String {
        switch self {
        case .checkmate: "jaque mate"
        case .resignation: "abandono"
        case .timeout: "tiempo"
        }
    }
}

extension GameDrawReason {
    var displayText: String {
        switch self {
        case .stalemate: "ahogado"
        case .fiftyMoves: "regla de 50 movimientos"
        case .repetition: "triple repetición"
        case .insufficientMaterial: "material insuficiente"
        case .agreement: "acuerdo"
        }
    }
}

struct GameMoveRecord: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let ply: Int
    let san: String
    let lan: String
    let from: String
    let to: String
    let fenBefore: String
    let fenAfter: String
    let playedAt: Date
    let promotion: String?
    let participant: MoveParticipant?
    let clockAfterMove: GameMoveClockStamp?

    init(
        id: UUID = UUID(),
        ply: Int,
        san: String,
        lan: String,
        from: String,
        to: String,
        fenBefore: String,
        fenAfter: String,
        playedAt: Date = Date(),
        promotion: String? = nil,
        participant: MoveParticipant? = nil,
        clockAfterMove: GameMoveClockStamp? = nil
    ) {
        self.id = id
        self.ply = ply
        self.san = san
        self.lan = lan
        self.from = from
        self.to = to
        self.fenBefore = fenBefore
        self.fenAfter = fenAfter
        self.playedAt = playedAt
        self.promotion = promotion
        self.participant = participant
        self.clockAfterMove = clockAfterMove
    }

    var moverSide: PlayerSide {
        let fields = fenBefore.split(separator: " ")
        return fields.count > 1 && fields[1] == "b" ? .black : .white
    }

    var moverClockRemaining: TimeInterval? {
        clockAfterMove?.remaining(for: moverSide)
    }
}

struct GameRecord: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let initialFEN: String
    var whitePlayer: String
    var blackPlayer: String
    var endedAt: Date?
    var moves: [GameMoveRecord]
    var status: GameLifecycleStatus
    var result: GameResult
    var mode: GameMode
    var humanSide: PlayerSide?
    var opponentEngine: OpponentEngineConfiguration?
    /// Legacy compatibility fields retained while old archives migrate.
    var engineStrength: StockfishStrength?
    var engineName: String?
    var allowUndo: Bool
    var timeControl: GameTimeControl
    var clockState: GameClockState?
    var analysisVariations: [AnalysisVariationNode]

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        initialFEN: String,
        whitePlayer: String = "Blancas",
        blackPlayer: String = "Negras",
        endedAt: Date? = nil,
        moves: [GameMoveRecord] = [],
        status: GameLifecycleStatus = .playing,
        result: GameResult = .unfinished,
        mode: GameMode = .twoPlayer,
        humanSide: PlayerSide? = nil,
        opponentEngine: OpponentEngineConfiguration? = nil,
        engineStrength: StockfishStrength? = nil,
        engineName: String? = nil,
        allowUndo: Bool = false,
        timeControl: GameTimeControl = .unlimited,
        clockState: GameClockState? = nil,
        analysisVariations: [AnalysisVariationNode] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.initialFEN = initialFEN
        self.whitePlayer = whitePlayer
        self.blackPlayer = blackPlayer
        self.endedAt = endedAt
        self.moves = moves
        self.status = status
        self.result = result
        self.mode = mode
        self.humanSide = humanSide
        let migratedOpponent = opponentEngine ?? Self.legacyOpponent(
            mode: mode,
            engineStrength: engineStrength,
            engineName: engineName
        )
        self.opponentEngine = migratedOpponent
        self.engineStrength = engineStrength ?? migratedOpponent?.stockfishStrength
        self.engineName = engineName ?? migratedOpponent?.displayName
        self.allowUndo = allowUndo
        self.timeControl = timeControl
        self.clockState = clockState ?? (timeControl.isTimed ? GameClockState(timeControl: timeControl) : nil)
        self.analysisVariations = analysisVariations
    }

    var moveCount: Int { moves.count }
    var fullMoveCount: Int { (moves.count + 1) / 2 }
    var allowsAnalysis: Bool { status != .playing }

    var lastActivityAt: Date {
        endedAt ?? moves.last?.playedAt ?? startedAt
    }

    var duration: TimeInterval {
        max(0, lastActivityAt.timeIntervalSince(startedAt))
    }

    func clockStamp(afterPly ply: Int) -> GameMoveClockStamp? {
        guard timeControl.isTimed else { return nil }
        if ply <= 0 {
            let initial = TimeInterval(timeControl.initialSeconds ?? 0)
            return GameMoveClockStamp(
                whiteRemaining: initial,
                blackRemaining: initial
            )
        }
        return moves.first(where: { $0.ply == min(ply, moves.count) })?.clockAfterMove
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case initialFEN
        case whitePlayer
        case blackPlayer
        case endedAt
        case moves
        case status
        case result
        case mode
        case humanSide
        case opponentEngine
        case engineStrength
        case engineName
        case allowUndo
        case timeControl
        case clockState
        case analysisVariations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        initialFEN = try container.decode(String.self, forKey: .initialFEN)
        whitePlayer = try container.decodeIfPresent(String.self, forKey: .whitePlayer) ?? "Blancas"
        blackPlayer = try container.decodeIfPresent(String.self, forKey: .blackPlayer) ?? "Negras"
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        moves = try container.decode([GameMoveRecord].self, forKey: .moves)
        status = try container.decode(GameLifecycleStatus.self, forKey: .status)
        result = try container.decode(GameResult.self, forKey: .result)
        mode = try container.decodeIfPresent(GameMode.self, forKey: .mode) ?? .twoPlayer
        humanSide = try container.decodeIfPresent(PlayerSide.self, forKey: .humanSide)
        let legacyStrength = try container.decodeIfPresent(StockfishStrength.self, forKey: .engineStrength)
        let legacyName = try container.decodeIfPresent(String.self, forKey: .engineName)
        opponentEngine = try container.decodeIfPresent(
            OpponentEngineConfiguration.self,
            forKey: .opponentEngine
        ) ?? Self.legacyOpponent(
            mode: mode,
            engineStrength: legacyStrength,
            engineName: legacyName
        )
        engineStrength = legacyStrength ?? opponentEngine?.stockfishStrength
        engineName = legacyName ?? opponentEngine?.displayName
        allowUndo = try container.decodeIfPresent(Bool.self, forKey: .allowUndo) ?? false
        timeControl = try container.decodeIfPresent(GameTimeControl.self, forKey: .timeControl) ?? .unlimited
        clockState = try container.decodeIfPresent(GameClockState.self, forKey: .clockState)
        if timeControl.isTimed, clockState == nil {
            clockState = GameClockState(timeControl: timeControl)
        }
        analysisVariations = try container.decodeIfPresent(
            [AnalysisVariationNode].self,
            forKey: .analysisVariations
        ) ?? []
    }

    private static func legacyOpponent(
        mode: GameMode,
        engineStrength: StockfishStrength?,
        engineName: String?
    ) -> OpponentEngineConfiguration? {
        guard mode == .solo else { return nil }

        // Every archive written before the generic field existed used
        // Stockfish, even if `engineName` was absent or localized differently.
        return .stockfish(engineStrength ?? .full)
    }
}

enum AssistanceMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case legalMoves
    case stockfishQuality
    case blunders

    var id: String { rawValue }

    var displayText: String {
        switch self {
        case .off:
            "Sin ayuda"
        case .legalMoves:
            "Movimientos legales"
        case .stockfishQuality:
            "Calidad Stockfish"
        case .blunders:
            "Aviso de blunders"
        }
    }

    var detailText: String {
        switch self {
        case .off:
            "No ilumina destinos al levantar una pieza."
        case .legalMoves:
            "Ilumina todos los destinos legales de forma fija."
        case .stockfishQuality:
            "Stockfish 18 compara cada destino con la mejor jugada de la posición: fijo = bueno, lento = aceptable, rápido = blunder."
        case .blunders:
            "Todos los destinos legales permanecen fijos, salvo los blunders, que parpadean rápido."
        }
    }

    var requiresStockfishAnalysis: Bool {
        switch self {
        case .stockfishQuality, .blunders:
            true
        case .off, .legalMoves:
            false
        }
    }

    func ledPattern(for quality: MoveQuality) -> LEDPattern? {
        switch self {
        case .off:
            nil
        case .legalMoves:
            .steady
        case .stockfishQuality:
            quality.ledPattern
        case .blunders:
            quality == .blunder ? .fastBlink : .steady
        }
    }
}

enum AssistancePieceLimit: Int, CaseIterable, Identifiable, Codable, Sendable {
    case unlimited = 0
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    var id: Int { rawValue }
    var maximumCount: Int? { self == .unlimited ? nil : rawValue }

    var displayText: String {
        switch self {
        case .unlimited: "Sin límite"
        case .one: "1 pieza"
        case .two: "2 piezas"
        case .three: "3 piezas"
        case .four: "4 piezas"
        case .five: "5 piezas"
        }
    }
}

enum BlunderThreshold: Int, CaseIterable, Identifiable, Codable, Sendable {
    case oneHundred = 100
    case oneHundredFifty = 150
    case twoHundred = 200
    case twoHundredFifty = 250
    case threeHundred = 300
    case fourHundred = 400
    case fiveHundred = 500

    var id: Int { rawValue }
    var displayText: String { "\(rawValue) cp" }
}

struct AssistanceSettings: Equatable, Codable, Sendable {
    var white: AssistanceMode
    var black: AssistanceMode
    var maximumPiecesPerTurn: AssistancePieceLimit
    var blunderThreshold: BlunderThreshold

    init(
        white: AssistanceMode = .stockfishQuality,
        black: AssistanceMode = .off,
        maximumPiecesPerTurn: AssistancePieceLimit = .unlimited,
        blunderThreshold: BlunderThreshold = .twoHundred
    ) {
        self.white = white
        self.black = black
        self.maximumPiecesPerTurn = maximumPiecesPerTurn
        self.blunderThreshold = blunderThreshold
    }

    func mode(for color: Piece.Color) -> AssistanceMode {
        color == .white ? white : black
    }

    private enum CodingKeys: String, CodingKey {
        case white
        case black
        case maximumPiecesPerTurn
        case blunderThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        white = try container.decodeIfPresent(AssistanceMode.self, forKey: .white) ?? .stockfishQuality
        black = try container.decodeIfPresent(AssistanceMode.self, forKey: .black) ?? .off
        maximumPiecesPerTurn = try container.decodeIfPresent(
            AssistancePieceLimit.self,
            forKey: .maximumPiecesPerTurn
        ) ?? .unlimited
        blunderThreshold = try container.decodeIfPresent(
            BlunderThreshold.self,
            forKey: .blunderThreshold
        ) ?? .twoHundred
    }
}

/// Domain state for the current turn. A source square identifies the concrete
/// piece in the logical position for that turn, so equal piece kinds on b1 and
/// g1 remain separate consultations.
struct TurnAssistanceAccessPolicy: Equatable, Sendable {
    private(set) var consultedSources: Set<Square> = []
    var limit: AssistancePieceLimit

    init(limit: AssistancePieceLimit = .unlimited) {
        self.limit = limit
    }

    mutating func requestAssistance(for source: Square) -> Bool {
        if consultedSources.contains(source) {
            return true
        }

        if let maximumCount = limit.maximumCount,
           consultedSources.count >= maximumCount {
            return false
        }

        consultedSources.insert(source)
        return true
    }

    mutating func resetForNextTurn() {
        consultedSources.removeAll(keepingCapacity: true)
    }

    mutating func handle(_ event: OTBGameEvent) {
        switch event {
        case .moveCompleted, .moveUndone:
            resetForNextTurn()
        case .synchronized, .pieceLifted, .promotionRequired, .intermediate, .invalid:
            break
        }
    }
}

enum LEDPattern: String, CaseIterable, Codable, Sendable {
    case steady
    case slowBlink
    case fastBlink

    var displayText: String {
        switch self {
        case .steady: "fijo"
        case .slowBlink: "lento"
        case .fastBlink: "rápido"
        }
    }

    func isLit(at tick: Int) -> Bool {
        switch self {
        case .steady:
            true
        case .slowBlink:
            (tick / 3).isMultiple(of: 2)
        case .fastBlink:
            tick.isMultiple(of: 2)
        }
    }
}

enum MoveQuality: String, CaseIterable, Codable, Sendable {
    case good
    case acceptable
    case blunder

    var displayText: String {
        switch self {
        case .good: "bueno"
        case .acceptable: "aceptable"
        case .blunder: "blunder"
        }
    }

    var ledPattern: LEDPattern {
        switch self {
        case .good: .steady
        case .acceptable: .slowBlink
        case .blunder: .fastBlink
        }
    }
}

enum MoveEvaluationLoss: Equatable, Sendable {
    case centipawns(Int)
    case decisive
}

struct MoveQualityThresholds: Equatable, Sendable {
    var goodMaxCentipawnLoss: Int = 50
    var blunderThreshold: BlunderThreshold = .twoHundred

    func classify(loss: Int) -> MoveQuality {
        let normalizedLoss = max(0, loss)
        if normalizedLoss <= goodMaxCentipawnLoss {
            return .good
        }
        if normalizedLoss < blunderThreshold.rawValue {
            return .acceptable
        }
        return .blunder
    }

    func classify(loss: MoveEvaluationLoss) -> MoveQuality {
        switch loss {
        case let .centipawns(value): classify(loss: value)
        case .decisive: .blunder
        }
    }
}

struct LEDHint: Equatable, Sendable {
    let square: Square
    let pattern: LEDPattern
}

enum AssistanceHintPlanner {
    static func hints(
        for legalTargets: [Square],
        mode: AssistanceMode
    ) -> [LEDHint] {
        let sortedTargets = legalTargets.sorted { $0.notation < $1.notation }

        switch mode {
        case .off, .stockfishQuality, .blunders:
            return []
        case .legalMoves:
            return sortedTargets.map { LEDHint(square: $0, pattern: .steady) }
        }
    }
}

enum LEDHintFrameComposer {
    static func activeSquares(for hints: [LEDHint], tick: Int) -> [Square] {
        hints.compactMap { hint in
            hint.pattern.isLit(at: tick) ? hint.square : nil
        }
    }
}

extension Piece.Kind {
    var promotionSymbol: String? {
        switch self {
        case .queen: "Q"
        case .rook: "R"
        case .bishop: "B"
        case .knight: "N"
        case .pawn, .king: nil
        }
    }
}
