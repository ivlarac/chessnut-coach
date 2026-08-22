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
        }
        .tint(.coachAccent)
    }
}

#Preview {
    let library = GameLibrary(inMemory: true)
    ContentView(board: BoardController(library: library), library: library)
}
