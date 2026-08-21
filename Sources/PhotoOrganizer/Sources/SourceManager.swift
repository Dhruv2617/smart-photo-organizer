import Foundation
import GRDB

final class SourceManager {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func addSource(url: URL) throws -> Source {
        let volumeId = try volumeUUID(for: url)
        let source = Source(
            id: volumeId,
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

    private func volumeUUID(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey])
        return values.volumeUUIDString ?? url.path
    }
}
