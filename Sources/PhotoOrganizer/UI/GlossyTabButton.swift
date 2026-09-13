import SwiftUI

/// One label inside `GlassTabBar` — icon + title side by side (not stacked),
/// which is what keeps the whole bar short/horizontal instead of tall.
/// Carries no background or focus-ring styling of its own; the selected
/// segment's glossy tint pill is a separate view the bar slides underneath.
struct GlossyTabButton: View {
    let systemImage: String?
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// The single glass pill housing both tab segments — one shared
/// `.ultraThinMaterial` background, with a tinted glossy highlight that
/// slides (via `.offset` under animation, not a per-segment visibility
/// toggle) to sit behind whichever segment is selected.
struct GlassTabBar<Segment: Hashable>: View {
    let segments: [Segment]
    var systemImage: (Segment) -> String? = { _ in nil }
    let title: (Segment) -> String
    /// Same glossy tint regardless of which segment is selected — the
    /// selection should read as "moved", not "recolored".
    var tint: (Segment) -> [Color] = { _ in
        [Color(red: 0.4, green: 0.62, blue: 0.98), Color(red: 0.22, green: 0.42, blue: 0.88)]
    }
    @Binding var selection: Segment

    var body: some View {
        GeometryReader { proxy in
            let segmentWidth = proxy.size.width / CGFloat(segments.count)
            let selectedIndex = CGFloat(segments.firstIndex(of: selection) ?? 0)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(colors: tint(selection), startPoint: .top, endPoint: .bottom)
                    )
                    .overlay(
                        // Specular highlight across the top — the glossy part.
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.45), .white.opacity(0.0)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .mask(VStack(spacing: 0) { Rectangle().frame(height: 9); Spacer() })
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    .frame(width: segmentWidth)
                    .offset(x: selectedIndex * segmentWidth)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)

                HStack(spacing: 0) {
                    ForEach(segments, id: \.self) { segment in
                        GlossyTabButton(
                            systemImage: systemImage(segment),
                            title: title(segment),
                            isSelected: selection == segment
                        ) {
                            selection = segment
                        }
                    }
                }
            }
        }
        .frame(height: 24)
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}

/// Frosted-glass card background for list rows (source rows, cluster rows)
/// so they read as part of the same glossy look as the tab bar, with the
/// ocean background showing through instead of a flat opaque row.
struct GlassRowBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.55), lineWidth: 1.5)
            )
    }
}
