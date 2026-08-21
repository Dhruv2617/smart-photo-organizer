import Foundation
import GRDB

final class Indexer {
    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    /// Scans `source.rootPath`, indexing any new file and any file whose
    /// content hash changed since the last pass. Returns only the
    /// newly-written or updated rows (unchanged files are skipped).
    func indexSource(_ source: Source) throws -> [MediaFile] {
        let root = URL(fileURLWithPath: source.rootPath).resolvingSymlinksInPath()
        let scanned = FileScanner.scan(root: root)
        var results: [MediaFile] = []

        for file in scanned where file.kind == .photo {
            let resolvedFileURL = file.url.resolvingSymlinksInPath()
            let relativePath = String(resolvedFileURL.path.dropFirst(root.path.count + 1))
            let sha = try HashService.sha256(fileAt: file.url)

            let existing = try db.dbPool.read { db in
                try MediaFile
                    .filter(Column("sourceId") == source.id && Column("relativePath") == relativePath)
                    .fetchOne(db)
            }
            if let existing, existing.sha256 == sha {
                continue // unchanged, skip
            }

            let pHash: UInt64? = try? HashService.pHash(imageAt: file.url)
            let mediaFile = MediaFile(
                id: existing?.id ?? UUID().uuidString,
                sourceId: source.id,
                relativePath: relativePath,
                kind: Self.storedKind(for: file.kind),
                sha256: sha,
                pHash: pHash.map { String($0, radix: 16) },
                captureDate: nil,
                width: nil,
                height: nil,
                clusterId: nil
            )
            try db.dbPool.write { db in try mediaFile.save(db) }
            results.append(mediaFile)
        }

        for file in scanned where file.kind == .video {
            let resolvedFileURL = file.url.resolvingSymlinksInPath()
            let relativePath = String(resolvedFileURL.path.dropFirst(root.path.count + 1))
            let sha = try HashService.sha256(fileAt: file.url)

            let existing = try db.dbPool.read { db in
                try MediaFile
                    .filter(Column("sourceId") == source.id && Column("relativePath") == relativePath)
                    .fetchOne(db)
            }
            if let existing, existing.sha256 == sha {
                continue
            }

            let frames = try VideoFrameSampler.sampleFrames(videoAt: file.url, interval: 2.0)
            let representativeHash: UInt64? = try? frames.first.map { try HashService.pHash(cgImage: $0.image) }

            let mediaFile = MediaFile(
                id: existing?.id ?? UUID().uuidString,
                sourceId: source.id,
                relativePath: relativePath,
                kind: Self.storedKind(for: file.kind),
                sha256: sha,
                pHash: representativeHash.map { String($0, radix: 16) },
                captureDate: nil,
                width: nil,
                height: nil,
                clusterId: nil
            )
            try db.dbPool.write { db in try mediaFile.save(db) }
            results.append(mediaFile)
        }

        return results
    }

    private static func storedKind(for kind: MediaKind) -> String {
        switch kind {
        case .photo: return "photo"
        case .video: return "video"
        }
    }
}
