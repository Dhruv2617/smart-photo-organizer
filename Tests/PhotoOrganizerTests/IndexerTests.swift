import Testing
import Foundation
import GRDB
@testable import PhotoOrganizer

struct IndexerTests {
    @Test func testIndexSourceCreatesMediaFileRowsForImages() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceManager = SourceManager(db: db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fake-jpeg-bytes".utf8).write(to: root.appendingPathComponent("a.jpg"))
        let source = try sourceManager.addSource(url: root)

        let indexer = Indexer(db: db)
        let indexed = try indexer.indexSource(source)

        #expect(indexed.count == 1)
        #expect(indexed[0].relativePath == "a.jpg")
        #expect(indexed[0].kind == "photo")
    }

    @Test func testReindexingUnchangedFileDoesNotDuplicateRow() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceManager = SourceManager(db: db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fake-jpeg-bytes".utf8).write(to: root.appendingPathComponent("a.jpg"))
        let source = try sourceManager.addSource(url: root)
        let indexer = Indexer(db: db)

        _ = try indexer.indexSource(source)
        let secondPass = try indexer.indexSource(source)

        #expect(secondPass.count == 0, "unchanged file should not be re-indexed")
        let all = try db.dbPool.read { db in try MediaFile.fetchAll(db) }
        #expect(all.count == 1)
    }

    @Test func testReindexingChangedFileClearsStaleFaceObservations() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceManager = SourceManager(db: db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fake-jpeg-bytes-v1".utf8).write(to: root.appendingPathComponent("a.jpg"))
        let source = try sourceManager.addSource(url: root)
        let indexer = Indexer(db: db)

        let firstPass = try indexer.indexSource(source)
        #expect(firstPass.count == 1)
        let mediaFileId = firstPass[0].id

        // Simulate a stale face observation left over from a prior index of
        // this same media file (e.g. from before this fix existed).
        let stale = FaceObservation(
            id: "stale-observation",
            mediaFileId: mediaFileId,
            identityId: nil,
            embedding: Data(),
            boundingBoxX: 0, boundingBoxY: 0, boundingBoxWidth: 0, boundingBoxHeight: 0,
            frameTimestamp: nil
        )
        try db.dbPool.write { db in try stale.save(db) }

        // Change the file's content so the re-index treats it as an update.
        try Data("fake-jpeg-bytes-v2-changed".utf8).write(to: root.appendingPathComponent("a.jpg"))
        let secondPass = try indexer.indexSource(source)
        #expect(secondPass.count == 1)
        #expect(secondPass[0].id == mediaFileId, "re-index should reuse the existing media file id")

        let observations = try db.dbPool.read { db in
            try FaceObservation.filter(Column("mediaFileId") == mediaFileId).fetchAll(db)
        }
        #expect(!observations.contains { $0.id == "stale-observation" }, "stale face observation must be cleared on re-index")
    }
}
