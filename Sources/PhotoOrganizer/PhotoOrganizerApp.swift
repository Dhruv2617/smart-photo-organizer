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
                // People tab disabled for now: face matching via
                // VNGenerateImageFeaturePrintRequest (the only public
                // Vision API available) isn't face-recognition-tuned like
                // Apple's private Photos.app model, so it split the same
                // person into too many identities. PeopleView/PeopleViewModel
                // and the DB tables are untouched — re-enable by uncommenting
                // this tab once a better matching approach (e.g. a bundled
                // Core ML face-recognition model) is in place.
            }
        }
    }
}
