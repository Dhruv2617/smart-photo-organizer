import GRDB
import Foundation

struct Source: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "source"

    var id: String
    var displayName: String
    var rootPath: String
    var isOnline: Bool
    var lastScannedAt: Date?
}
