import Testing
import Foundation
import GRDB
@testable import PhotoOrganizer

struct PeopleViewModelTests {
    @Test @MainActor
    func testLabelingIdentityPersistsAndReflectsInReload() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try FaceIdentity(id: "id1", label: nil, referenceEmbedding: Data([0, 0, 0, 0])).save(db)
        }

        let viewModel = PeopleViewModel(db: db)
        try viewModel.reload()
        try viewModel.label("id1", as: "Amit")
        try viewModel.reload()

        #expect(viewModel.identities.first?.label == "Amit")
    }

    @Test @MainActor
    func testMergeIdentitiesMovesObservationsAndKeepsLabeledIdentity() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try Source(id: "s1", volumeUUID: "vol1", displayName: "S", rootPath: "/s", isOnline: true, lastScannedAt: nil).save(db)
            try MediaFile(id: "m1", sourceId: "s1", relativePath: "a.jpg", kind: "photo", sha256: "h1",
                          pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "m2", sourceId: "s1", relativePath: "b.jpg", kind: "photo", sha256: "h2",
                          pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "m3", sourceId: "s1", relativePath: "c.jpg", kind: "photo", sha256: "h3",
                          pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try FaceIdentity(id: "unnamed1", label: nil, referenceEmbedding: Data([0, 0, 0, 0])).save(db)
            try FaceIdentity(id: "named", label: "Amit", referenceEmbedding: Data([0, 0, 0, 0])).save(db)
            try FaceIdentity(id: "unnamed2", label: nil, referenceEmbedding: Data([0, 0, 0, 0])).save(db)
            try FaceObservation(id: "obs1", mediaFileId: "m1", identityId: "unnamed1", embedding: Data(),
                                 boundingBoxX: 0, boundingBoxY: 0, boundingBoxWidth: 0, boundingBoxHeight: 0, frameTimestamp: nil).save(db)
            try FaceObservation(id: "obs2", mediaFileId: "m2", identityId: "unnamed2", embedding: Data(),
                                 boundingBoxX: 0, boundingBoxY: 0, boundingBoxWidth: 0, boundingBoxHeight: 0, frameTimestamp: nil).save(db)
            try FaceObservation(id: "obs3", mediaFileId: "m3", identityId: "named", embedding: Data(),
                                 boundingBoxX: 0, boundingBoxY: 0, boundingBoxWidth: 0, boundingBoxHeight: 0, frameTimestamp: nil).save(db)
        }

        let viewModel = PeopleViewModel(db: db)
        try viewModel.reload()
        try viewModel.mergeIdentities(["unnamed1", "named", "unnamed2"])

        #expect(viewModel.identities.count == 1)
        #expect(viewModel.identities[0].id == "named")
        #expect(viewModel.identities[0].label == "Amit")

        let observations = try db.dbPool.read { db in try FaceObservation.fetchAll(db) }
        #expect(observations.count == 3)
        #expect(observations.allSatisfy { $0.identityId == "named" })
    }
}
