import SwiftUI

@main
struct PhotoOrganizerApp: App {
    var body: some Scene {
        WindowGroup {
            // People tab disabled for now: face matching via
            // VNGenerateImageFeaturePrintRequest (the only public
            // Vision API available) isn't face-recognition-tuned like
            // Apple's private Photos.app model, so it split the same
            // person into too many identities. PeopleView/PeopleViewModel
            // and the DB tables are untouched — re-enable by adding a
            // .people case to RootView's tab bar once a better matching
            // approach (e.g. a bundled Core ML face-recognition model) is
            // in place.
            RootView()
        }
    }
}
