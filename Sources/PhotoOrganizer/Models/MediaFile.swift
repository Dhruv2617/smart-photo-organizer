import GRDB
import Foundation

struct MediaFile: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mediaFile"

    var id: String
    var sourceId: String
    var relativePath: String
    var kind: String                  // "photo" | "video"
    var sha256: String
    var pHash: String?
    var captureDate: Date?
    var width: Int?
    var height: Int?
    var fileSizeBytes: Int64? = nil
    var clusterId: String?
}
