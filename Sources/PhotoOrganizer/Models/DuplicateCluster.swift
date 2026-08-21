import GRDB
import Foundation

struct DuplicateCluster: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "duplicateCluster"

    var id: String
    var suggestedKeeperMediaFileId: String?
    var createdAt: Date
}
