import SwiftUI

private enum AppTab: Hashable {
    case sources
    case duplicates
}

/// Replaces the plain `TabView` with an ocean background behind everything
/// and a custom glossy tab bar up top (native `.tabItem` labels can't host
/// the glossy icon look, so the tab switching is hand-rolled here).
struct RootView: View {
    @State private var selectedTab: AppTab = .sources

    var body: some View {
        ZStack {
            OceanBackground()

            VStack(alignment: .leading, spacing: 0) {
                GlassTabBar(
                    segments: [AppTab.sources, .duplicates],
                    systemImage: { $0 == .sources ? "externaldrive" : "square.on.square" },
                    title: { $0 == .sources ? "Sources" : "Duplicates" },
                    selection: $selectedTab
                )
                .frame(width: 190)
                .padding(.leading, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Group {
                    switch selectedTab {
                    case .sources:
                        SourcesView(viewModel: SourcesViewModel(db: DatabaseManager.shared))
                    case .duplicates:
                        DuplicatesView(viewModel: DuplicatesViewModel(db: DatabaseManager.shared))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
