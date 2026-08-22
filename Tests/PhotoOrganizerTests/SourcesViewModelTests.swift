import Testing
import Foundation
import GRDB
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

    @Test @MainActor func testRemoveSourceRemovesFromPublishedSources() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let viewModel = SourcesViewModel(db: db)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try viewModel.addSource(url: folder)
        let added = viewModel.sources[0]

        try viewModel.removeSource(added)

        #expect(viewModel.sources.isEmpty)
    }

    @Test @MainActor func testStatsCountPhotosVideosAndTotalSizePerSourceAndOverall() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let viewModel = SourcesViewModel(db: db)
        try viewModel.addSource(url: folder)
        let source = viewModel.sources[0]

        try db.dbPool.write { db in
            try MediaFile(id: "1", sourceId: source.id, relativePath: "a.jpg", kind: "photo", sha256: "h1",
                          pHash: nil, captureDate: nil, width: nil, height: nil, fileSizeBytes: 1000, clusterId: nil).save(db)
            try MediaFile(id: "2", sourceId: source.id, relativePath: "b.jpg", kind: "photo", sha256: "h2",
                          pHash: nil, captureDate: nil, width: nil, height: nil, fileSizeBytes: 2000, clusterId: nil).save(db)
            try MediaFile(id: "3", sourceId: source.id, relativePath: "c.mp4", kind: "video", sha256: "h3",
                          pHash: nil, captureDate: nil, width: nil, height: nil, fileSizeBytes: 5000, clusterId: nil).save(db)
        }

        viewModel.reload() // refresh stats after inserting rows directly

        let stats = viewModel.statsBySourceId[source.id]
        #expect(stats?.photoCount == 2)
        #expect(stats?.videoCount == 1)
        #expect(stats?.totalBytes == 8000)
        #expect(viewModel.overallStats.totalFiles == 3)
        #expect(viewModel.overallStats.totalBytes == 8000)
    }
}
