import SwiftUI

/// Safari-"Ocean"-style backdrop: blue gradient, faint wave lines, scattered
/// nautical emoji — fills the whole window behind the tab bar and content.
struct OceanBackground: View {
    private static let emojiScatter: [(String, CGFloat, CGFloat, CGFloat)] = [
        ("🥥", 0.08, 0.06, 46), ("🐡", 0.92, 0.04, 40), ("🌵", 0.32, 0.16, 34),
        ("🌴", 0.86, 0.18, 44), ("🐡", 0.02, 0.28, 36), ("🌺", 0.58, 0.30, 42),
        ("🌵", 0.95, 0.30, 30), ("⛵️", 0.10, 0.48, 38), ("🐠", 0.90, 0.46, 34),
        ("🌺", 0.06, 0.82, 36), ("🐚", 0.94, 0.72, 34), ("🌿", 0.42, 0.86, 30),
        ("🌵", 0.66, 0.90, 32), ("🥥", 0.86, 0.86, 38), ("🐡", 0.22, 0.96, 34),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.42, green: 0.58, blue: 0.92), Color(red: 0.30, green: 0.46, blue: 0.86)],
                    startPoint: .top, endPoint: .bottom
                )

                WavePattern()
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)

                ForEach(Array(Self.emojiScatter.enumerated()), id: \.offset) { _, spec in
                    let (emoji, x, y, size) = spec
                    Text(emoji)
                        .font(.system(size: size))
                        .opacity(0.9)
                        .position(x: proxy.size.width * x, y: proxy.size.height * y)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Repeating horizontal wave lines, like the Safari ocean wallpaper's water texture.
private struct WavePattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let rowSpacing: CGFloat = 28
        var y: CGFloat = rowSpacing / 2
        while y < rect.height {
            path.move(to: CGPoint(x: 0, y: y))
            var x: CGFloat = 0
            var up = true
            while x < rect.width {
                let next = x + 24
                path.addQuadCurve(
                    to: CGPoint(x: next, y: y),
                    control: CGPoint(x: x + 12, y: y + (up ? -6 : 6))
                )
                x = next
                up.toggle()
            }
            y += rowSpacing
        }
        return path
    }
}
