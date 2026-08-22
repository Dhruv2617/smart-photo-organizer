import GRDB
import Foundation

struct Source: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "source"

    var id: String
    var volumeUUID: String
    var displayName: String
    var rootPath: String
    var isOnline: Bool
    var lastScannedAt: Date?
}
