import Foundation
import GRDB
import ImageIO

/// Safe to use from a background task: `db` is a thread-safe DatabaseManager
/// and `faceMatcher` only touches the DB through it, never shared mutable state.
final class Indexer: @unchecked Sendable {
    private let db: DatabaseManager
    private let faceMatcher: FaceMatcher

    init(db: DatabaseManager) {
        self.db = db
        self.faceMatcher = FaceMatcher(db: db)
    }

    /// Scans `source.rootPath`, indexing any new file and any file whose
    /// content hash changed since the last pass. Returns only the
    /// newly-written or updated rows (unchanged files are skipped).
    /// `onFileScanned`, if given, is called after each scanned file (whether
    /// or not it needed re-indexing) with (files processed so far, total
    /// files found), so callers can drive a progress indicator.
    func indexSource(_ source: Source, onFileScanned: ((Int, Int) -> Void)? = nil) throws -> [MediaFile] {
        guard source.isOnline else { return [] }
        let root = URL(fileURLWithPath: source.rootPath).resolvingSymlinksInPath()
        let scanned = FileScanner.scan(root: root)
        var results: [MediaFile] = []
        var processed = 0

        for file in scanned where file.kind == .photo {
            defer { processed += 1; onFileScanned?(processed, scanned.count) }

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
            let dimensions = Self.imageDimensions(at: file.url)
            let mediaFile = MediaFile(
                id: existing?.id ?? UUID().uuidString,
                sourceId: source.id,
                relativePath: relativePath,
                kind: Self.storedKind(for: file.kind),
                sha256: sha,
                pHash: pHash.map { String($0, radix: 16) },
                captureDate: nil,
                width: dimensions?.width,
                height: dimensions?.height,
                fileSizeBytes: Self.fileSize(at: file.url),
                clusterId: nil
            )
            try db.dbPool.write { db in try mediaFile.save(db) }
            results.append(mediaFile)

            if existing != nil {
                try deleteFaceObservations(mediaFileId: mediaFile.id)
            }
            if let imageSource = CGImageSourceCreateWithURL(file.url as CFURL, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                try? indexFaces(cgImage: cgImage, mediaFileId: mediaFile.id, frameTimestamp: nil)
            }
        }

        for file in scanned where file.kind == .video {
            defer { processed += 1; onFileScanned?(processed, scanned.count) }

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
            // Stores every sampled frame's pHash, comma-separated, so
            // DuplicateClusterer can compare the whole frame set (not just
            // one frame) between two videos — matches the spec's "high
            // proportion of sampled frames match" definition of near-duplicate.
            let frameHashes = frames.compactMap { try? HashService.pHash(cgImage: $0.image) }
            let pHashList = frameHashes.isEmpty ? nil : frameHashes.map { String($0, radix: 16) }.joined(separator: ",")
            let firstFrameImage = frames.first?.image

            let mediaFile = MediaFile(
                id: existing?.id ?? UUID().uuidString,
                sourceId: source.id,
                relativePath: relativePath,
                kind: Self.storedKind(for: file.kind),
                sha256: sha,
                pHash: pHashList,
                captureDate: nil,
                width: firstFrameImage.map { $0.width },
                height: firstFrameImage.map { $0.height },
                fileSizeBytes: Self.fileSize(at: file.url),
                clusterId: nil
            )
            try db.dbPool.write { db in try mediaFile.save(db) }
            results.append(mediaFile)

            if existing != nil {
                try deleteFaceObservations(mediaFileId: mediaFile.id)
            }
            for (timestamp, image) in frames {
                try? indexFaces(cgImage: image, mediaFileId: mediaFile.id, frameTimestamp: timestamp)
            }
        }

        return results
    }

    private func deleteFaceObservations(mediaFileId: String) throws {
        try db.dbPool.write { db in
            _ = try FaceObservation.filter(Column("mediaFileId") == mediaFileId).deleteAll(db)
        }
    }

    private func indexFaces(cgImage: CGImage, mediaFileId: String, frameTimestamp: Double?) throws {
        let faces = try FaceDetector.detectFaces(in: cgImage)
        for face in faces {
            let identity = try faceMatcher.matchOrCreateUnnamedIdentity(embedding: face.featurePrintData)
            let observation = FaceObservation(
                id: UUID().uuidString,
                mediaFileId: mediaFileId,
                identityId: identity.id,
                embedding: face.featurePrintData,
                boundingBoxX: face.boundingBox.origin.x,
                boundingBoxY: face.boundingBox.origin.y,
                boundingBoxWidth: face.boundingBox.width,
                boundingBoxHeight: face.boundingBox.height,
                frameTimestamp: frameTimestamp
            )
            try db.dbPool.write { db in try observation.save(db) }
        }
    }

    /// Reads pixel dimensions from image metadata without decoding the full
    /// image (cheap — just header/EXIF inspection via ImageIO).
    private static func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    private static func fileSize(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    private static func storedKind(for kind: MediaKind) -> String {
        switch kind {
        case .photo: return "photo"
        case .video: return "video"
        }
    }
}
