import Testing
import Foundation
import GRDB
@testable import PhotoOrganizer

struct DuplicateClustererTests {
    @Test func testExactHashMatchAcrossDifferentSourcesFormsOneCluster() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try Source(id: "sourceA", displayName: "A", rootPath: "/a", isOnline: true, lastScannedAt: nil).save(db)
            try Source(id: "sourceB", displayName: "B", rootPath: "/b", isOnline: true, lastScannedAt: nil).save(db)
            try MediaFile(id: "1", sourceId: "sourceA", relativePath: "x.jpg", kind: "photo",
                          sha256: "same-hash", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "2", sourceId: "sourceB", relativePath: "y.jpg", kind: "photo",
                          sha256: "same-hash", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "3", sourceId: "sourceA", relativePath: "z.jpg", kind: "photo",
                          sha256: "different-hash", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
        }

        let clusterer = DuplicateClusterer(db: db)
        let clusters = try clusterer.rebuildClusters()

        #expect(clusters.count == 1)
        let members = try db.dbPool.read { db in
            try MediaFile.filter(Column("clusterId") == clusters[0].id).fetchAll(db)
        }
        #expect(Set(members.map(\.id)) == Set(["1", "2"]))
    }

    @Test func testNearDuplicatePHashWithinThresholdFormsCluster() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try Source(id: "sourceA", displayName: "A", rootPath: "/a", isOnline: true, lastScannedAt: nil).save(db)
            // Two distinct hashes 1 bit apart -> near duplicate.
            try MediaFile(id: "1", sourceId: "sourceA", relativePath: "x.jpg", kind: "photo",
                          sha256: "hash-a", pHash: String(UInt64(0b1010), radix: 16), captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "2", sourceId: "sourceA", relativePath: "y.jpg", kind: "photo",
                          sha256: "hash-b", pHash: String(UInt64(0b1000), radix: 16), captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
        }

        let clusterer = DuplicateClusterer(db: db)
        let clusters = try clusterer.rebuildClusters()

        #expect(clusters.count == 1)
    }
}
