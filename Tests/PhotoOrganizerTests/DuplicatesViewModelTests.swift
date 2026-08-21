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
}
