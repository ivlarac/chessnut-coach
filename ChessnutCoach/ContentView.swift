import SwiftUI

struct ContentView: View {
    @ObservedObject var board: BoardController
    @ObservedObject var library: GameLibrary

    var body: some View {
        TabView {
            CurrentGameView(board: board)
                .tabItem {
                    Label("Jugar", systemImage: "checkerboard.rectangle")
                }

            NavigationStack {
                GameLibraryView(library: library, board: board)
            }
            .tabItem {
                Label("Partidas", systemImage: "books.vertical.fill")
            }

            AppInformationView(supportedBoards: board.supportedBoards)
                .tabItem {
                    Label("Información", systemImage: "info.circle.fill")
                }
        }
        .tint(.coachAccent)
    }
}

private struct AppInformationView: View {
    let supportedBoards: [ElectronicBoardSupport]

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Chessnut Coach") {
                    LabeledContent("Versión", value: appVersion)
                    LabeledContent("Build", value: buildNumber)

                    Text("Asistente para jugar y registrar partidas con tableros electrónicos compatibles, con Stockfish 18 para análisis y Stockfish o Maia 3 como rival.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Funciones principales") {
                    informationRow(
                        title: "Tablero físico",
                        description: "Conexión mediante adaptadores de tablero y seguimiento de la posición en tiempo real.",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                    informationRow(
                        title: "Modos de juego",
                        description: "Partidas contra otra persona, Stockfish 18 o Maia 3 con estilo humano.",
                        systemImage: "checkerboard.rectangle"
                    )
                    informationRow(
                        title: "Ayuda por LEDs",
                        description: "Movimientos legales, calidad y blunders configurables por bando, con límite opcional de piezas consultadas por turno.",
                        systemImage: "lightbulb.max.fill"
                    )
                    informationRow(
                        title: "Deshacer jugadas",
                        description: "En partidas contra persona puede habilitarse el deshacer desde el iPhone o restaurando físicamente la posición anterior.",
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    informationRow(
                        title: "Historial y PGN",
                        description: "Guarda las partidas jugadas y permite conservar o exportar su registro en formato PGN.",
                        systemImage: "books.vertical.fill"
                    )
                }

                Section("Compatibilidad") {
                    LabeledContent("iOS", value: "16 o posterior")
                    LabeledContent("Análisis", value: "Stockfish 18")
                    LabeledContent("Rivales", value: "Stockfish 18 · Maia 3")

                    ForEach(supportedBoards) { support in
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(support.name, value: support.models)
                            Text(support.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Esta lista se obtiene de los adaptadores de tablero registrados por la aplicación.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Licencia y autoría") {
                    LabeledContent("Licencia de la aplicación", value: "AGPL-3.0-only")
                    LabeledContent("Autoría", value: "ivlarac")

                    Link(
                        "Código fuente y licencia completa",
                        destination: URL(string: "https://github.com/ivlarac/chessnut-coach")!
                    )

                    Text("© 2026 ivlarac. Esta versión se distribuye bajo GNU AGPL v3, sin garantía. Maia3-5M © University of Toronto CSSLab se incluye bajo AGPL-3.0. El código publicado anteriormente bajo Apache 2.0 conserva sus avisos y licencia originales; Stockfish conserva GPLv3.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Información")
        }
    }

    private func informationRow(
        title: String,
        description: String,
        systemImage: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.coachAccent)
        }
    }
}

#Preview {
    let library = GameLibrary(inMemory: true)
    ContentView(board: BoardController(library: library), library: library)
}
