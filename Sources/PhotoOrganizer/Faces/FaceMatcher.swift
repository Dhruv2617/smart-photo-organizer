import Foundation
import GRDB
import Vision

enum FaceMatcherError: Error {
    case unarchiveFailed
}

final class FaceMatcher {
    private let db: DatabaseManager
    private let matchThreshold: Float = 0.6   // distance <= this counts as same person (lower = more similar)

    init(db: DatabaseManager) {
        self.db = db
    }

    /// Unarchives both sides back to `VNFeaturePrintObservation` and computes
    /// the Vision-provided distance between them (lower = more similar).
    static func distance(_ a: Data, _ b: Data) throws -> Float {
        guard
            let obsA = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: a),
            let obsB = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: b)
        else {
            throw FaceMatcherError.unarchiveFailed
        }

        var distance: Float = 0
        try obsA.computeDistance(&distance, to: obsB)
        return distance
    }

    /// Finds the best-matching existing identity by lowest distance; if none
    /// clears `matchThreshold` (i.e. no identity has distance <= threshold),
    /// creates a new unnamed identity with this embedding as its reference.
    func matchOrCreateUnnamedIdentity(embedding: Data) throws -> FaceIdentity {
        let allIdentities = try db.dbPool.read { db in try FaceIdentity.fetchAll(db) }

        var best: (identity: FaceIdentity, distance: Float)?
        for identity in allIdentities {
            let dist = try Self.distance(embedding, identity.referenceEmbedding)
            if dist <= matchThreshold, (best == nil || dist < best!.distance) {
                best = (identity, dist)
            }
        }

        if let best {
            return best.identity
        }

        let newIdentity = FaceIdentity(id: UUID().uuidString, label: nil, referenceEmbedding: embedding)
        try db.dbPool.write { db in try newIdentity.save(db) }
        return newIdentity
    }

    func labelIdentity(_ identityId: String, as label: String) throws {
        try db.dbPool.write { db in
            guard var identity = try FaceIdentity.fetchOne(db, key: identityId) else { return }
            identity.label = label
            try identity.save(db)
        }
    }
}
