import GRDB
import Foundation

struct FaceObservation: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "faceObservation"

    var id: String
    var mediaFileId: String
    var identityId: String?
    var embedding: Data
    var boundingBoxX: Double
    var boundingBoxY: Double
    var boundingBoxWidth: Double
    var boundingBoxHeight: Double
    var frameTimestamp: Double?
}
