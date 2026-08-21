import GRDB
import Foundation

struct FaceIdentity: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "faceIdentity"

    var id: String
    var label: String?
    var referenceEmbedding: Data
}
