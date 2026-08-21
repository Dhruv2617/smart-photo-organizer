import Testing
import Foundation
import GRDB
@testable import PhotoOrganizer

struct DuplicatesViewModelTests {
    @Test @MainActor
    func testReloadGroupsMembersUnderTheirCluster() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try Source(id: "s1", volumeUUID: "vol1", displayName: "S", rootPath: "/s", isOnline: true, lastScannedAt: nil).save(db)
            try DuplicateCluster(id: "c1", suggestedKeeperMediaFileId: "m1", createdAt: Date()).save(db)
            try MediaFile(id: "m1", sourceId: "s1", relativePath: "a.jpg", kind: "photo", sha256: "h", pHash: nil,
                          captureDate: nil, width: nil, height: nil, clusterId: "c1").save(db)
            try MediaFile(id: "m2", sourceId: "s1", relativePath: "b.jpg", kind: "photo", sha256: "h", pHash: nil,
                          captureDate: nil, width: nil, height: nil, clusterId: "c1").save(db)
        }

        let viewModel = DuplicatesViewModel(db: db)
        try viewModel.reload()

        #expect(viewModel.clusters.count == 1)
        #expect(viewModel.clusters[0].members.count == 2)
        #expect(viewModel.clusters[0].cluster.suggestedKeeperMediaFileId == "m1")
    }

    @Test @MainActor
    func testMoveToTrashRemovesFileAndItsIndexRow() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("dupe.jpg")
        try Data("fake-jpeg-bytes".utf8).write(to: fileURL)

        try db.dbPool.write { db in
            try Source(id: "s1", volumeUUID: "vol1", displayName: "S", rootPath: root.path, isOnline: true, lastScannedAt: nil).save(db)
            try DuplicateCluster(id: "c1", suggestedKeeperMediaFileId: "m1", createdAt: Date()).save(db)
            try MediaFile(id: "m2", sourceId: "s1", relativePath: "dupe.jpg", kind: "photo", sha256: "h", pHash: nil,
                          captureDate: nil, width: nil, height: nil, clusterId: "c1").save(db)
        }

        let viewModel = DuplicatesViewModel(db: db)
        try viewModel.reload()
        let toTrash = try #require(viewModel.clusters.first?.members.first { $0.id == "m2" })

        try viewModel.moveToTrash(toTrash)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let remaining = try db.dbPool.read { db in try MediaFile.fetchAll(db) }
        #expect(remaining.isEmpty)
    }
}
