import Testing
import Foundation
@testable import PhotoOrganizer

struct SourcesViewModelTests {
    @Test @MainActor func testAddSourceAppendsToPublishedSources() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let viewModel = SourcesViewModel(db: db)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try viewModel.addSource(url: folder)

        #expect(viewModel.sources.count == 1)
        #expect(viewModel.sources[0].rootPath == folder.path)
    }
}
