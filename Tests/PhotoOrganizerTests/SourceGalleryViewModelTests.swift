import Testing
import Foundation
import GRDB
@testable import PhotoOrganizer

struct SourceGalleryViewModelTests {
    @Test @MainActor func testReloadListsOnlyFilesForThisSource() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceA = Source(id: "sA", volumeUUID: "volA", displayName: "A", rootPath: "/a", isOnline: true, lastScannedAt: nil)
        let sourceB = Source(id: "sB", volumeUUID: "volB", displayName: "B", rootPath: "/b", isOnline: true, lastScannedAt: nil)
        try db.dbPool.write { db in
            try sourceA.save(db)
            try sourceB.save(db)
            try MediaFile(id: "1", sourceId: "sA", relativePath: "x.jpg", kind: "photo",
                          sha256: "h1", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "2", sourceId: "sA", relativePath: "y.jpg", kind: "photo",
                          sha256: "h2", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "3", sourceId: "sB", relativePath: "z.jpg", kind: "photo",
                          sha256: "h3", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
        }

        let viewModel = SourceGalleryViewModel(db: db, source: sourceA)
        try viewModel.reload()

        #expect(viewModel.items.count == 2)
        #expect(Set(viewModel.items.map(\.id)) == Set(["1", "2"]))
    }

    @Test @MainActor func testFileURLJoinsSourceRootPathAndRelativePath() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let source = Source(id: "sA", volumeUUID: "volA", displayName: "A", rootPath: "/a/b", isOnline: true, lastScannedAt: nil)
        let viewModel = SourceGalleryViewModel(db: db, source: source)
        let file = MediaFile(id: "1", sourceId: "sA", relativePath: "sub/x.jpg", kind: "photo",
                              sha256: "h1", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil)

        #expect(viewModel.fileURL(for: file)?.path == "/a/b/sub/x.jpg")
    }

    @Test @MainActor func testMoveToTrashRemovesFileFromDiskAndIndex() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("a.jpg")
        try Data("fake-jpeg-bytes".utf8).write(to: fileURL)

        let source = Source(id: "sA", volumeUUID: "volA", displayName: "A", rootPath: root.path, isOnline: true, lastScannedAt: nil)
        try db.dbPool.write { db in
            try source.save(db)
            try MediaFile(id: "1", sourceId: "sA", relativePath: "a.jpg", kind: "photo",
                          sha256: "h1", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
        }

        let viewModel = SourceGalleryViewModel(db: db, source: source)
        try viewModel.reload()
        try viewModel.moveToTrash(viewModel.items[0])

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(viewModel.items.isEmpty)
    }
}
