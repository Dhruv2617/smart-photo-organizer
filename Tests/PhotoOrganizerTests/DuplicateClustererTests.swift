import Testing
import Foundation
import GRDB
@testable import PhotoOrganizer

struct DuplicateClustererTests {
    @Test func testExactHashMatchAcrossDifferentSourcesFormsOneCluster() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try Source(id: "sourceA", volumeUUID: "volA", displayName: "A", rootPath: "/a", isOnline: true, lastScannedAt: nil).save(db)
            try Source(id: "sourceB", volumeUUID: "volB", displayName: "B", rootPath: "/b", isOnline: true, lastScannedAt: nil).save(db)
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
        #expect(clusters[0].matchType == "exact")
        let members = try db.dbPool.read { db in
            try MediaFile.filter(Column("clusterId") == clusters[0].id).fetchAll(db)
        }
        #expect(Set(members.map(\.id)) == Set(["1", "2"]))
    }

    @Test func testAdjustingSimilarityThresholdChangesWhatCountsAsNearDuplicate() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try Source(id: "sourceA", volumeUUID: "volA", displayName: "A", rootPath: "/a", isOnline: true, lastScannedAt: nil).save(db)
            // Exactly 8 bits apart.
            try MediaFile(id: "1", sourceId: "sourceA", relativePath: "x.jpg", kind: "photo",
                          sha256: "hash-a", pHash: String(UInt64(0), radix: 16), captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "2", sourceId: "sourceA", relativePath: "y.jpg", kind: "photo",
                          sha256: "hash-b", pHash: String(UInt64(0xFF), radix: 16), captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
        }
        let clusterer = DuplicateClusterer(db: db)

        let strict = try clusterer.rebuildClusters(pHashThreshold: 5)
        #expect(strict.isEmpty, "8-bit distance should not cluster at threshold 5")

        let loose = try clusterer.rebuildClusters(pHashThreshold: 8)
        #expect(loose.count == 1, "8-bit distance should cluster at threshold 8")
        #expect(loose[0].matchType == "near")
    }

    @Test func testNearDuplicatePHashWithinThresholdFormsCluster() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try Source(id: "sourceA", volumeUUID: "volA", displayName: "A", rootPath: "/a", isOnline: true, lastScannedAt: nil).save(db)
            // Two distinct hashes 1 bit apart -> near duplicate.
            try MediaFile(id: "1", sourceId: "sourceA", relativePath: "x.jpg", kind: "photo",
                          sha256: "hash-a", pHash: String(UInt64(0b1010), radix: 16), captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "2", sourceId: "sourceA", relativePath: "y.jpg", kind: "photo",
                          sha256: "hash-b", pHash: String(UInt64(0b1000), radix: 16), captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
        }

        let clusterer = DuplicateClusterer(db: db)
        let clusters = try clusterer.rebuildClusters()

        #expect(clusters.count == 1)
        #expect(clusters[0].matchType == "near")
    }

    // Hamming identity used throughout: distance(x, x ^ m) == popcount(m).
    // So XOR-ing a base value with a low-popcount mask produces a value at
    // an *exact*, known distance from that base — no guessing needed.
    private static let base1: UInt64 = 0x1234_5678_9ABC_DEF0
    private static let base2: UInt64 = 0x0F0F_0F0F_0F0F_0F0F
    private static let base3: UInt64 = 0xAAAA_AAAA_AAAA_AAAA
    private static let farValueA: UInt64 = 0x5555_5555_5555_5555 // bitwise complement of base3 -> distance 64 from it

    @Test func testVideosWithMostlyMatchingFramesFormCluster() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        // 3 of 4 sampled frames match within threshold (distances 3, 5, 2),
        // 1 frame is unrelated — 75% overlap, above the 50% threshold.
        let closeToBase1 = Self.base1 ^ 0x7   // exact distance 3 (popcount(0x7) == 3)
        let closeToBase2 = Self.base2 ^ 0x1F  // exact distance 5 (popcount(0x1F) == 5)
        let closeToBase3 = Self.base3 ^ 0x3   // exact distance 2 (popcount(0x3) == 2)
        let farValueB: UInt64 = 0xDEAD_BEEF_DEAD_BEEF

        let framesA = [Self.base1, Self.base2, Self.base3, Self.farValueA]
        let framesB = [closeToBase1, closeToBase2, closeToBase3, farValueB]
        try db.dbPool.write { db in
            try Source(id: "sourceA", volumeUUID: "volA", displayName: "A", rootPath: "/a", isOnline: true, lastScannedAt: nil).save(db)
            try MediaFile(id: "v1", sourceId: "sourceA", relativePath: "v1.mp4", kind: "video",
                          sha256: "vhash-a", pHash: framesA.map { String($0, radix: 16) }.joined(separator: ","),
                          captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "v2", sourceId: "sourceA", relativePath: "v2.mp4", kind: "video",
                          sha256: "vhash-b", pHash: framesB.map { String($0, radix: 16) }.joined(separator: ","),
                          captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
        }

        let clusterer = DuplicateClusterer(db: db)
        let clusters = try clusterer.rebuildClusters()

        #expect(clusters.count == 1)
        let members = try db.dbPool.read { db in
            try MediaFile.filter(Column("clusterId") == clusters[0].id).fetchAll(db)
        }
        #expect(Set(members.map(\.id)) == Set(["v1", "v2"]))
    }

    @Test func testVideosWithMostlyDifferentFramesDoNotCluster() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        // Only 1 of 4 frames matches (distance 3) — 25% overlap, below the
        // 50% threshold. The other 3 B frames are exact-complement-style
        // values with distance ~32 from every A frame (popcount identity).
        let closeToBase1 = Self.base1 ^ 0x7 // exact distance 3
        let farB1: UInt64 = 0x0000_0000_0000_0000          // distance(x,0) == popcount(x), all A bases have popcount >> 5
        let farB2: UInt64 = 0xFFFF_FFFF_FFFF_FFFF          // distance(x,allOnes) == 64 - popcount(x)
        let farB3: UInt64 = 0xF0F0_F0F0_F0F0_F0F0          // distance to base2/base3/farValueA all == 32

        let framesA = [Self.base1, Self.base2, Self.base3, Self.farValueA]
        let framesB = [closeToBase1, farB1, farB2, farB3]
        try db.dbPool.write { db in
            try Source(id: "sourceA", volumeUUID: "volA", displayName: "A", rootPath: "/a", isOnline: true, lastScannedAt: nil).save(db)
            try MediaFile(id: "v1", sourceId: "sourceA", relativePath: "v1.mp4", kind: "video",
                          sha256: "vhash-a", pHash: framesA.map { String($0, radix: 16) }.joined(separator: ","),
                          captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "v2", sourceId: "sourceA", relativePath: "v2.mp4", kind: "video",
                          sha256: "vhash-b", pHash: framesB.map { String($0, radix: 16) }.joined(separator: ","),
                          captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
        }

        let clusterer = DuplicateClusterer(db: db)
        let clusters = try clusterer.rebuildClusters()

        #expect(clusters.isEmpty)
    }
}
