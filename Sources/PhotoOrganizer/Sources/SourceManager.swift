import Foundation
import GRDB

final class SourceManager {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func addSource(url: URL) throws -> Source {
        let volumeId = volumeUUID(for: url)
        let source = Source(
            id: UUID().uuidString,
            volumeUUID: volumeId,
            displayName: url.lastPathComponent,
            rootPath: url.path,
            isOnline: true,
            lastScannedAt: nil
        )
        try db.dbPool.write { db in
            try source.save(db)
        }
        return source
    }

    func allSources() throws -> [Source] {
        try db.dbPool.read { db in try Source.fetchAll(db) }
    }

    /// Removes a source and every row derived from it (MediaFile,
    /// FaceObservation via cascade) from the index. Never touches the
    /// original files on disk — this only forgets what was indexed.
    func removeSource(id: String) throws {
        try db.dbPool.write { db in
            _ = try Source.deleteOne(db, key: id)
        }
    }

    func refreshOnlineStatus() throws {
        let sources = try allSources()
        for source in sources {
            let online = FileManager.default.fileExists(atPath: source.rootPath)
            if online != source.isOnline {
                var updated = source
                updated.isOnline = online
                try db.dbPool.write { db in try updated.save(db) }
            }
        }
    }

    /// Returns the volume UUID for the given URL, falling back to the
    /// folder's own path when the volume reports no UUID (e.g. disk images,
    /// some network mounts). This is used later for online/offline
    /// resolution by path, not as the source's primary key.
    private func volumeUUID(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString ?? url.path
    }
}
