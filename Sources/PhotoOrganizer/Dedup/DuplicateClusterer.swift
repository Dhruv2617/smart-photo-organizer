import Foundation
import GRDB

final class DuplicateClusterer {
    static let defaultPHashThreshold = 5
    static let pHashThresholdRange = 0...20 // exposed to the UI similarity slider

    private let db: DatabaseManager
    private let videoFrameOverlapThreshold = 0.5 // fraction of sampled frames that must match to call two videos near-duplicate

    init(db: DatabaseManager) {
        self.db = db
    }

    /// Rebuilds all duplicate clusters from scratch: groups by exact sha256
    /// first (tagged "exact"), then merges remaining ungrouped files whose
    /// pHash distance is within `pHashThreshold` (tagged "near"). Clustering
    /// is source-agnostic (files across different sources merge into the
    /// same cluster). `pHashThreshold` is the adjustable similarity knob —
    /// lower is stricter (fewer, more confident near-duplicate matches),
    /// higher is looser (more matches, more false positives).
    func rebuildClusters(pHashThreshold: Int = DuplicateClusterer.defaultPHashThreshold) throws -> [DuplicateCluster] {
        let allFiles = try db.dbPool.read { db in try MediaFile.fetchAll(db) }

        // Reset previous clustering.
        try db.dbPool.write { db in
            try MediaFile.updateAll(db, Column("clusterId").set(to: nil as String?))
            try DuplicateCluster.deleteAll(db)
        }

        var exactGroups: [[MediaFile]] = []
        var byHash: [String: [MediaFile]] = [:]
        for file in allFiles {
            byHash[file.sha256, default: []].append(file)
        }
        var ungrouped: [MediaFile] = []
        for (_, files) in byHash {
            if files.count > 1 {
                exactGroups.append(files)
            } else {
                ungrouped.append(files[0])
            }
        }

        // Near-duplicate pass over files not already grouped by exact hash,
        // split by kind since photos compare a single pHash but videos
        // compare a set of per-sampled-frame pHashes.
        let ungroupedWithHash = ungrouped.filter { $0.pHash != nil }
        var nearGroups: [[MediaFile]] = []
        nearGroups += nearDuplicatePhotoGroups(ungroupedWithHash.filter { $0.kind == "photo" }, pHashThreshold: pHashThreshold)
        nearGroups += nearDuplicateVideoGroups(ungroupedWithHash.filter { $0.kind == "video" }, pHashThreshold: pHashThreshold)

        var createdClusters: [DuplicateCluster] = []
        try db.dbPool.write { db in
            for (group, matchType) in exactGroups.map({ ($0, "exact") }) + nearGroups.map({ ($0, "near") }) {
                let keeper = group.max(by: { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) })
                let cluster = DuplicateCluster(id: UUID().uuidString, suggestedKeeperMediaFileId: keeper?.id, createdAt: Date(), matchType: matchType)
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

    /// Greedy near-duplicate grouping for photos: a single pHash per file,
    /// grouped by Hamming distance <= pHashThreshold.
    private func nearDuplicatePhotoGroups(_ photos: [MediaFile], pHashThreshold: Int) -> [[MediaFile]] {
        var groups: [[MediaFile]] = []
        var remaining = photos
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
        return groups
    }

    /// Greedy near-duplicate grouping for videos: each file's pHash column
    /// holds a comma-separated list of per-sampled-frame hashes (one per
    /// ~2 seconds of the video, from VideoFrameSampler). Two videos are
    /// near-duplicate when at least `videoFrameOverlapThreshold` of the
    /// shorter video's frames each have a matching frame (Hamming distance
    /// <= pHashThreshold) somewhere in the other video's frame set —
    /// implements the spec's "high proportion of sampled frames match".
    private func nearDuplicateVideoGroups(_ videos: [MediaFile], pHashThreshold: Int) -> [[MediaFile]] {
        let framesByFile: [(file: MediaFile, frames: [UInt64])] = videos.compactMap { file in
            let frames = file.pHash!.split(separator: ",").compactMap { UInt64($0, radix: 16) }
            return frames.isEmpty ? nil : (file, frames)
        }

        var groups: [[MediaFile]] = []
        var remaining = framesByFile
        while !remaining.isEmpty {
            let anchor = remaining.removeFirst()
            var cluster = [anchor.file]
            remaining.removeAll { candidate in
                if frameOverlapFraction(anchor.frames, candidate.frames, pHashThreshold: pHashThreshold) >= videoFrameOverlapThreshold {
                    cluster.append(candidate.file)
                    return true
                }
                return false
            }
            if cluster.count > 1 {
                groups.append(cluster)
            }
        }
        return groups
    }

    /// Fraction of the shorter frame set that has a matching frame (within
    /// pHashThreshold) somewhere in the other set.
    private func frameOverlapFraction(_ a: [UInt64], _ b: [UInt64], pHashThreshold: Int) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        let matched = shorter.filter { shortHash in
            longer.contains { longHash in HashService.hammingDistance(shortHash, longHash) <= pHashThreshold }
        }.count
        return Double(matched) / Double(shorter.count)
    }
}
