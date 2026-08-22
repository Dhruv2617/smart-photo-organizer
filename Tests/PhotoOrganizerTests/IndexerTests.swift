import Testing
import Foundation
import GRDB
import CoreGraphics
import ImageIO
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

    @Test(.disabled("Face indexing is currently disabled (Indexer.faceIndexingEnabled = false) while the People tab is hidden — re-enable this test alongside that flag."))
    func testReindexingChangedFileClearsStaleFaceObservations() throws {
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

    @Test func testIndexingRealImagePopulatesDimensionsAndFileSize() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceManager = SourceManager(db: db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("photo.png")
        try Self.writeSolidColorPNG(to: fileURL, width: 64, height: 32)
        let source = try sourceManager.addSource(url: root)

        let indexer = Indexer(db: db)
        let indexed = try indexer.indexSource(source)

        #expect(indexed.count == 1)
        #expect(indexed[0].width == 64)
        #expect(indexed[0].height == 32)
        let expectedFileSize = try Int64(FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? -1)
        #expect(indexed[0].fileSizeBytes == expectedFileSize)
    }

    private static func writeSolidColorPNG(to url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            struct WriteError: Error {}
            throw WriteError()
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
    }
}
