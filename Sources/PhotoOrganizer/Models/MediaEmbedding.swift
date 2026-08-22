import GRDB
import Foundation

/// A CLIP image embedding for one photo, or one sampled video frame
/// (`frameTimestamp` non-nil). Compared against a CLIP text embedding of a
/// search query via cosine similarity to power the Search tab.
struct MediaEmbedding: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mediaEmbedding"

    var id: String
    var mediaFileId: String
    var frameTimestamp: Double?
    var embedding: Data
}
