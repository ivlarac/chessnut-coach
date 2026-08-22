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

            AppInformationView()
                .tabItem {
                    Label("Información", systemImage: "info.circle.fill")
                }
        }
        .tint(.coachAccent)
    }
}

private struct AppInformationView: View {
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

                    Text("Asistente para jugar y registrar partidas de ajedrez con un tablero Chessnut Air, con análisis y ayuda opcional mediante Stockfish 18.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Funciones principales") {
                    informationRow(
                        title: "Tablero físico",
                        description: "Conexión Bluetooth con Chessnut Air y seguimiento de la posición en tiempo real.",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                    informationRow(
                        title: "Modos de juego",
                        description: "Partidas contra otra persona o contra Stockfish 18.",
                        systemImage: "checkerboard.rectangle"
                    )
                    informationRow(
                        title: "Ayuda por LEDs",
                        description: "Movimientos legales, calidad de jugadas y aviso de blunders configurable por bando.",
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
                    LabeledContent("Motor", value: "Stockfish 18")
                    LabeledContent("Tablero", value: "Chessnut Air")
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
