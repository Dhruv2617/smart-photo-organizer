import Foundation
import GRDB

final class DuplicateClusterer {
    private let db: DatabaseManager
    private let pHashThreshold = 5 // Hamming distance <= 5 of 64 bits counts as near-duplicate

    init(db: DatabaseManager) {
        self.db = db
    }

    /// Rebuilds all duplicate clusters from scratch: groups by exact sha256
    /// first, then merges remaining ungrouped files whose pHash distance is
    /// within threshold. Clustering is source-agnostic (files across
    /// different sources merge into the same cluster).
    func rebuildClusters() throws -> [DuplicateCluster] {
        let allFiles = try db.dbPool.read { db in try MediaFile.fetchAll(db) }

        // Reset previous clustering.
        try db.dbPool.write { db in
            try MediaFile.updateAll(db, Column("clusterId").set(to: nil as String?))
            try DuplicateCluster.deleteAll(db)
        }

        var groups: [[MediaFile]] = []
        var byHash: [String: [MediaFile]] = [:]
        for file in allFiles {
            byHash[file.sha256, default: []].append(file)
        }
        var ungrouped: [MediaFile] = []
        for (_, files) in byHash {
            if files.count > 1 {
                groups.append(files)
            } else {
                ungrouped.append(files[0])
            }
        }

        // Near-duplicate pass over files not already grouped by exact hash.
        var remaining = ungrouped.filter { $0.pHash != nil }
        while !remaining.isEmpty {
            let anchor = remaining.removeFirst()
            guard let anchorHash = UInt64(anchor.pHash!, radix: 16) else { continue }
            var cluster = [anchor]
            remaining.removeAll { candidate in
                guard let candidateHash = UInt64(candidate.pHash!, radix: 16) else { return false }
                if HashService.hammingDistance(anchorHash, candidateHash) <= pHashThreshold {
                    cluster.append(candidate)
                    return true
                }
                return false
            }
            if cluster.count > 1 {
                groups.append(cluster)
            }
        }

        var createdClusters: [DuplicateCluster] = []
        try db.dbPool.write { db in
            for group in groups {
                let keeper = group.max(by: { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) })
                let cluster = DuplicateCluster(id: UUID().uuidString, suggestedKeeperMediaFileId: keeper?.id, createdAt: Date())
                try cluster.insert(db)
                for file in group {
                    var updated = file
                    updated.clusterId = cluster.id
                    try updated.update(db)
                }
                createdClusters.append(cluster)
            }
        }
        return createdClusters
    }
}
