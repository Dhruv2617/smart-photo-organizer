import GRDB
import Foundation

struct DuplicateCluster: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "duplicateCluster"

    var id: String
    var suggestedKeeperMediaFileId: String?
    var createdAt: Date
    /// "exact" — byte-identical (SHA256 match). "near" — perceptual/frame-set
    /// match within the configurable similarity threshold, not byte-identical.
    var matchType: String = "exact"
}
