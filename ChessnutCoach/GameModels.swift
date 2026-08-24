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
        case .solo: "Contra Stockfish"
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
    var strength: StockfishStrength = StockfishStrength(level: 4)
    var assistance: AssistanceSettings = AssistanceSettings()
    var allowUndo: Bool = false
    var whitePlayerName: String?
    var blackPlayerName: String?
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
    var stockfishLevel = 4
    var humanPlayerName: String
    var whitePlayerName: String
    var blackPlayerName: String
    var humanAssistance: AssistanceMode
    var whiteAssistance: AssistanceMode
    var blackAssistance: AssistanceMode
    var allowUndo = false
    var automaticBoardRotation = false

    init(
        whitePlayerName: String,
        blackPlayerName: String,
        whiteAssistance: AssistanceMode,
        blackAssistance: AssistanceMode
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
    }

    var canStart: Bool {
        switch mode {
        case .twoPlayer:
            Self.isValidHumanName(whitePlayerName) && Self.isValidHumanName(blackPlayerName)
        case .solo:
            Self.isValidHumanName(humanPlayerName)
        }
    }

    func makeLaunch(randomValue: Bool = Bool.random()) -> NewGameLaunch? {
        guard canStart else { return nil }

        let humanSide = sideChoice.resolvedSide(randomValue: randomValue)
        let assistance = mode == .solo
            ? AssistanceSettings(
                white: humanSide == .white ? humanAssistance : .off,
                black: humanSide == .black ? humanAssistance : .off
            )
            : AssistanceSettings(
                white: whiteAssistance,
                black: blackAssistance
            )
        let humanName = Self.trimmed(humanPlayerName)
        let whiteName = mode == .solo
            ? (humanSide == .white ? humanName : "Stockfish 18")
            : Self.trimmed(whitePlayerName)
        let blackName = mode == .solo
            ? (humanSide == .black ? humanName : "Stockfish 18")
            : Self.trimmed(blackPlayerName)

        return NewGameLaunch(
            configuration: NewGameConfiguration(
                mode: mode,
                humanSide: humanSide,
                strength: StockfishStrength(level: stockfishLevel),
                assistance: assistance,
                allowUndo: mode == .twoPlayer && allowUndo,
                whitePlayerName: whiteName,
                blackPlayerName: blackName
            ),
            automaticBoardRotation: mode == .twoPlayer && automaticBoardRotation
        )
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
        return !value.isEmpty && !value.localizedCaseInsensitiveContains("stockfish")
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
}

extension GameEndReason {
    var displayText: String {
        switch self {
        case .checkmate: "jaque mate"
        case .resignation: "abandono"
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
        participant: MoveParticipant? = nil
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
    var engineStrength: StockfishStrength?
    var engineName: String?
    var allowUndo: Bool
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
        engineStrength: StockfishStrength? = nil,
        engineName: String? = nil,
        allowUndo: Bool = false,
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
        self.engineStrength = engineStrength
        self.engineName = engineName
        self.allowUndo = allowUndo
        self.analysisVariations = analysisVariations
    }

    var moveCount: Int { moves.count }
    var fullMoveCount: Int { (moves.count + 1) / 2 }

    var lastActivityAt: Date {
        endedAt ?? moves.last?.playedAt ?? startedAt
    }

    var duration: TimeInterval {
        max(0, lastActivityAt.timeIntervalSince(startedAt))
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
        case engineStrength
        case engineName
        case allowUndo
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
        engineStrength = try container.decodeIfPresent(StockfishStrength.self, forKey: .engineStrength)
        engineName = try container.decodeIfPresent(String.self, forKey: .engineName)
        allowUndo = try container.decodeIfPresent(Bool.self, forKey: .allowUndo) ?? false
        analysisVariations = try container.decodeIfPresent(
            [AnalysisVariationNode].self,
            forKey: .analysisVariations
        ) ?? []
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

struct AssistanceSettings: Equatable, Codable, Sendable {
    var white: AssistanceMode
    var black: AssistanceMode

    init(
        white: AssistanceMode = .stockfishQuality,
        black: AssistanceMode = .off
    ) {
        self.white = white
        self.black = black
    }

    func mode(for color: Piece.Color) -> AssistanceMode {
        color == .white ? white : black
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

struct MoveQualityThresholds: Equatable, Sendable {
    var goodMaxCentipawnLoss: Int = 50
    var acceptableMaxCentipawnLoss: Int = 200

    func classify(loss: Int) -> MoveQuality {
        let normalizedLoss = max(0, loss)
        if normalizedLoss <= goodMaxCentipawnLoss {
            return .good
        }
        if normalizedLoss <= acceptableMaxCentipawnLoss {
            return .acceptable
        }
        return .blunder
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
