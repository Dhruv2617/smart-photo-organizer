import GRDB
import Foundation

final class DatabaseManager {
    nonisolated(unsafe) static let shared: DatabaseManager = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoOrganizer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("index.sqlite").path
        return try! DatabaseManager(path: path)
    }()

    let dbPool: DatabasePool

    init(path: String) throws {
        dbPool = try DatabasePool(path: path)
        try migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "source") { t in
                t.column("id", .text).primaryKey()          // unique source id (UUID)
                t.column("volumeUUID", .text).notNull()      // volume UUID, or folder path fallback
                t.column("displayName", .text).notNull()
                t.column("rootPath", .text).notNull()
                t.column("isOnline", .boolean).notNull().defaults(to: true)
                t.column("lastScannedAt", .datetime)
            }

            try db.create(table: "mediaFile") { t in
                t.column("id", .text).primaryKey()           // UUID
                t.column("sourceId", .text).notNull().references("source", onDelete: .cascade)
                t.column("relativePath", .text).notNull()
                t.column("kind", .text).notNull()            // "photo" | "video"
                t.column("sha256", .text).notNull()
                t.column("pHash", .text)                      // hex string, image or representative video hash
                t.column("captureDate", .datetime)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("clusterId", .text)
                t.uniqueKey(["sourceId", "relativePath"])
            }

            try db.create(table: "duplicateCluster") { t in
                t.column("id", .text).primaryKey()
                t.column("suggestedKeeperMediaFileId", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "faceIdentity") { t in
                t.column("id", .text).primaryKey()
                t.column("label", .text)                      // nil until user names it
                t.column("referenceEmbedding", .blob).notNull()
            }

            try db.create(table: "faceObservation") { t in
                t.column("id", .text).primaryKey()
                t.column("mediaFileId", .text).notNull().references("mediaFile", onDelete: .cascade)
                t.column("identityId", .text).references("faceIdentity", onDelete: .setNull)
                t.column("embedding", .blob).notNull()
                t.column("boundingBoxX", .double).notNull()
                t.column("boundingBoxY", .double).notNull()
                t.column("boundingBoxWidth", .double).notNull()
                t.column("boundingBoxHeight", .double).notNull()
                t.column("frameTimestamp", .double)           // nil for photos, seconds into video otherwise
            }
        }

        return migrator
    }
}
