import SwiftUI

@main
struct PhotoOrganizerApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                SourcesView(viewModel: SourcesViewModel(db: DatabaseManager.shared))
                    .tabItem { Text("Sources") }
                DuplicatesView(viewModel: DuplicatesViewModel(db: DatabaseManager.shared))
                    .tabItem { Text("Duplicates") }
                PeopleView(viewModel: PeopleViewModel(db: DatabaseManager.shared))
                    .tabItem { Text("People") }
            }
        }
    }
}
