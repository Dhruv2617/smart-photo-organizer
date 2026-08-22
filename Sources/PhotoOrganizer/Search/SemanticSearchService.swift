import Foundation
import GRDB

/// Ranks indexed photos/videos against a natural-language query using CLIP
/// embeddings: embed the query with `TextEmbedder`, compare via cosine
/// similarity against every stored `MediaEmbedding` (brute-force — fast
/// enough at personal-library scale, no need for an approximate-nearest-
/// neighbor index), and return the top matches best-first. A video's score
/// is the best score among its sampled frames.
final class SemanticSearchService {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    /// CLIP cosine similarities for unrelated image/text pairs still land
    /// around 0.15-0.2 (embedding space isn't zero-centered around
    /// "unrelated"), so returning "top N" unconditionally always pads the
    /// list with junk once real matches run out. Cut off anything below
    /// this, tuned against real query/library pairs during testing.
    static let minimumScore: Float = 0.24

    /// Pure ranking function, independent of the database or the embedding
    /// model — exposed so it's testable with synthetic vectors.
    static func rank(queryEmbedding: [Float], candidates: [(mediaFileId: String, embedding: [Float])], limit: Int) -> [String] {
        var bestScoreByMediaFileId: [String: Float] = [:]
        for candidate in candidates {
            let score = cosineSimilarity(queryEmbedding, candidate.embedding)
            if let existing = bestScoreByMediaFileId[candidate.mediaFileId] {
                bestScoreByMediaFileId[candidate.mediaFileId] = max(existing, score)
            } else {
                bestScoreByMediaFileId[candidate.mediaFileId] = score
            }
        }
        return bestScoreByMediaFileId
            .filter { $0.value >= minimumScore }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Searches already-indexed embeddings for `query`, returning matching
    /// `MediaFile`s ranked best-first. Throws only if the text embedder
    /// itself fails to load/run (a real setup problem); a query that
    /// matches nothing just returns an empty array.
    func search(query: String, limit: Int = 50) throws -> [MediaFile] {
        let textEmbedder = try TextEmbedder()
        let queryEmbedding = try textEmbedder.embed(query: query)

        let allEmbeddings = try db.dbPool.read { db in try MediaEmbedding.fetchAll(db) }
        let candidates = allEmbeddings.map { (mediaFileId: $0.mediaFileId, embedding: Self.decode($0.embedding)) }
        let rankedIds = Self.rank(queryEmbedding: queryEmbedding, candidates: candidates, limit: limit)

        let mediaFilesById = try db.dbPool.read { db in
            try MediaFile.filter(rankedIds.contains(Column("id"))).fetchAll(db)
        }.reduce(into: [String: MediaFile]()) { $0[$1.id] = $1 }

        return rankedIds.compactMap { mediaFilesById[$0] }
    }

    static func encode(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
