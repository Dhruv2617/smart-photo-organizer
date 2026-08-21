import Testing
import Foundation
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
}
