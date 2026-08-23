import SwiftUI

extension Color {
    static let coachAccent = Color(red: 0.93, green: 0.55, blue: 0.12)
    static let coachNavy = Color(red: 0.06, green: 0.10, blue: 0.17)
}

struct CoachCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}


struct ChessPieceView: View {
    let piece: ReplayPiece
    let squareSize: CGFloat

    var body: some View {
        Image(piece.assetName)
            .resizable()
            .scaledToFit()
            .frame(width: squareSize * 0.97, height: squareSize * 0.97)
            .accessibilityLabel(piece.assetName.replacingOccurrences(of: "_", with: " "))
    }
}
