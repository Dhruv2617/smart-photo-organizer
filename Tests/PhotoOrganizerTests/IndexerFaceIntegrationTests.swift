import Testing
import Foundation
@testable import PhotoOrganizer

struct IndexerFaceIntegrationTests {
    @Test func testIndexingImageWithNoFacesWritesNoFaceObservations() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceManager = SourceManager(db: db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // A 1x1 pixel PNG has no detectable face; confirms the pipeline runs
        // face detection without crashing and writes zero observations.
        let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try onePixelPNG.write(to: root.appendingPathComponent("a.png"))
        let source = try sourceManager.addSource(url: root)

        let indexer = Indexer(db: db)
        let indexed = try indexer.indexSource(source)

        #expect(indexed.count == 1)
        let observations = try db.dbPool.read { db in try FaceObservation.fetchAll(db) }
        #expect(observations.count == 0)
    }
}
