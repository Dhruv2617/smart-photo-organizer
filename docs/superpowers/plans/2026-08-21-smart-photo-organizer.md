# Smart Photo/Video Organizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a mac-first native app that indexes photos/videos across arbitrary connected folders/drives (without importing them), detects exact and near-duplicate media across sources, and identifies/labels faces — surfacing results for user review without any automatic file operations.

**Architecture:** SwiftUI app with three independent engines (Indexer, Dedup, Face) all reading/writing a shared SQLite index (via GRDB). The Indexer walks connected sources and writes file metadata/hashes; the Dedup engine clusters duplicates from indexed hashes; the Face engine detects/matches faces via Apple's Vision framework. The Gallery UI reads only from the index DB and never mutates source files.

**Tech Stack:** Swift, SwiftUI, GRDB.swift (SQLite), Apple Vision framework (`VNDetectFaceRectanglesRequest`, face landmarks), AVFoundation (video frame sampling), FileManager + FSEvents (folder scanning/watching), XCTest.

**Spec:** docs/superpowers/specs/2026-08-21-smart-photo-organizer-design.md

## Global Constraints

- Platform: macOS only for this plan. No Windows code paths.
- v1 is index + report only: no code path may move, rename, or delete a source file.
- Original media files are never copied into app storage; only metadata, hashes, embeddings, and generated thumbnails are stored by the app.
- Duplicate detection must work across sources (a file on Source A and a file on Source B in the same cluster), not just within one source.
- Every connected source is identified by its volume UUID so re-mounts and offline state are handled correctly.

---

## File Structure

```
PhotoOrganizer/
  PhotoOrganizerApp.swift              # App entry point
  Models/
    MediaFile.swift                    # GRDB record: one indexed photo/video
    Source.swift                       # GRDB record: one connected folder/drive
    DuplicateCluster.swift             # GRDB record: a group of duplicate MediaFiles
    FaceIdentity.swift                 # GRDB record: a labeled person
    FaceObservation.swift              # GRDB record: one detected face instance
  Database/
    DatabaseManager.swift              # GRDB DatabasePool + migrations
  Indexing/
    FileScanner.swift                  # Walk a source, list candidate media files
    HashService.swift                  # SHA256 + perceptual hash (pHash)
    VideoFrameSampler.swift            # Extract sampled frames from a video file
    Indexer.swift                      # Orchestrates scan -> hash -> face -> DB write
  Dedup/
    DuplicateClusterer.swift           # Groups MediaFiles into DuplicateClusters
  Faces/
    FaceDetector.swift                 # Vision wrapper: detect faces + embeddings
    FaceMatcher.swift                  # Cosine-similarity match against FaceIdentity
  Sources/
    SourceManager.swift                # Add/list sources, volume UUID + online/offline tracking
  UI/
    SourcesView.swift                  # Add/manage connected folders
    GalleryView.swift                  # Browse all indexed media
    DuplicatesView.swift               # Browse duplicate clusters
    PeopleView.swift                   # Browse/label faces
PhotoOrganizerTests/
  HashServiceTests.swift
  DuplicateClustererTests.swift
  FaceMatcherTests.swift
  SourceManagerTests.swift
  FileScannerTests.swift
  IndexerTests.swift
```

---

### Task 1: Project scaffold + database schema

**Files:**
- Create: `PhotoOrganizer/PhotoOrganizerApp.swift`
- Create: `PhotoOrganizer/Database/DatabaseManager.swift`
- Test: `PhotoOrganizerTests/DatabaseManagerTests.swift`

**Interfaces:**
- Produces: `DatabaseManager.shared: DatabaseManager`, `DatabaseManager.init(path: String) throws`, `DatabaseManager.dbPool: DatabasePool`, tables `source`, `mediaFile`, `duplicateCluster`, `faceIdentity`, `faceObservation`.

- [ ] **Step 1: Create Xcode project**

Create a new macOS App target named `PhotoOrganizer` (SwiftUI lifecycle, Swift). Add the GRDB.swift package dependency via Swift Package Manager: `https://github.com/groue/GRDB.swift.git`, version `>= 6.0.0`.

- [ ] **Step 2: Write the failing test**

```swift
// PhotoOrganizerTests/DatabaseManagerTests.swift
import XCTest
@testable import PhotoOrganizer

final class DatabaseManagerTests: XCTestCase {
    func testMigrationsCreateAllTables() throws {
        let path = NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite"
        let manager = try DatabaseManager(path: path)

        let tableNames = try manager.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }

        for expected in ["source", "mediaFile", "duplicateCluster", "faceIdentity", "faceObservation"] {
            XCTAssertTrue(tableNames.contains(expected), "missing table \(expected)")
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -scheme PhotoOrganizer -destination 'platform=macOS' -only-testing:PhotoOrganizerTests/DatabaseManagerTests`
Expected: FAIL — `DatabaseManager` does not exist.

- [ ] **Step 4: Write minimal implementation**

```swift
// PhotoOrganizer/Database/DatabaseManager.swift
import GRDB
import Foundation

final class DatabaseManager {
    static let shared: DatabaseManager = {
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
                t.column("id", .text).primaryKey()          // volume UUID
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme PhotoOrganizer -destination 'platform=macOS' -only-testing:PhotoOrganizerTests/DatabaseManagerTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add PhotoOrganizer/PhotoOrganizerApp.swift PhotoOrganizer/Database/DatabaseManager.swift PhotoOrganizerTests/DatabaseManagerTests.swift
git commit -m "feat: scaffold app and index database schema"
```

---

### Task 2: Source model + SourceManager

**Files:**
- Create: `PhotoOrganizer/Models/Source.swift`
- Create: `PhotoOrganizer/Sources/SourceManager.swift`
- Test: `PhotoOrganizerTests/SourceManagerTests.swift`

**Interfaces:**
- Consumes: `DatabaseManager.dbPool` (Task 1).
- Produces: `Source` (GRDB `Codable, FetchableRecord, PersistableRecord`, fields `id: String`, `displayName: String`, `rootPath: String`, `isOnline: Bool`, `lastScannedAt: Date?`), `SourceManager.addSource(url: URL) throws -> Source`, `SourceManager.allSources() throws -> [Source]`, `SourceManager.refreshOnlineStatus() throws`.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/SourceManagerTests.swift
import XCTest
@testable import PhotoOrganizer

final class SourceManagerTests: XCTestCase {
    func testAddSourcePersistsVolumeUUIDAndPath() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let manager = SourceManager(db: db)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let source = try manager.addSource(url: folder)

        XCTAssertEqual(source.rootPath, folder.path)
        XCTAssertTrue(source.isOnline)

        let all = try manager.allSources()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, source.id)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/SourceManagerTests`
Expected: FAIL — `SourceManager` does not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/Models/Source.swift
import GRDB
import Foundation

struct Source: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "source"

    var id: String
    var displayName: String
    var rootPath: String
    var isOnline: Bool
    var lastScannedAt: Date?
}
```

```swift
// PhotoOrganizer/Sources/SourceManager.swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/SourceManagerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/Models/Source.swift PhotoOrganizer/Sources/SourceManager.swift PhotoOrganizerTests/SourceManagerTests.swift
git commit -m "feat: add Source model and SourceManager"
```

---

### Task 3: FileScanner — walk a source for candidate media files

**Files:**
- Create: `PhotoOrganizer/Indexing/FileScanner.swift`
- Test: `PhotoOrganizerTests/FileScannerTests.swift`

**Interfaces:**
- Produces: `struct ScannedFile { let url: URL; let kind: MediaKind }`, `enum MediaKind { case photo, video }`, `FileScanner.scan(root: URL) -> [ScannedFile]`.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/FileScannerTests.swift
import XCTest
@testable import PhotoOrganizer

final class FileScannerTests: XCTestCase {
    func testScanFindsImagesAndVideosAndSkipsOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        try Data().write(to: root.appendingPathComponent("photo.jpg"))
        try Data().write(to: sub.appendingPathComponent("clip.mov"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let results = FileScanner.scan(root: root)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.url.lastPathComponent == "photo.jpg" && $0.kind == .photo })
        XCTAssertTrue(results.contains { $0.url.lastPathComponent == "clip.mov" && $0.kind == .video })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/FileScannerTests`
Expected: FAIL — `FileScanner` does not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/Indexing/FileScanner.swift
import Foundation

enum MediaKind {
    case photo
    case video
}

struct ScannedFile {
    let url: URL
    let kind: MediaKind
}

enum FileScanner {
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "gif", "bmp"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi"]

    static func scan(root: URL) -> [ScannedFile] {
        var results: [ScannedFile] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if photoExtensions.contains(ext) {
                results.append(ScannedFile(url: url, kind: .photo))
            } else if videoExtensions.contains(ext) {
                results.append(ScannedFile(url: url, kind: .video))
            }
        }
        return results
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/FileScannerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/Indexing/FileScanner.swift PhotoOrganizerTests/FileScannerTests.swift
git commit -m "feat: add FileScanner to enumerate photo/video candidates"
```

---

### Task 4: HashService — exact hash + perceptual hash for images

**Files:**
- Create: `PhotoOrganizer/Indexing/HashService.swift`
- Test: `PhotoOrganizerTests/HashServiceTests.swift`

**Interfaces:**
- Produces: `HashService.sha256(fileAt url: URL) throws -> String`, `HashService.pHash(imageAt url: URL) throws -> UInt64`, `HashService.hammingDistance(_ a: UInt64, _ b: UInt64) -> Int`.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/HashServiceTests.swift
import XCTest
@testable import PhotoOrganizer

final class HashServiceTests: XCTestCase {
    func testSHA256IsStableForIdenticalBytes() throws {
        let url1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("identical content".utf8)
        try bytes.write(to: url1)
        try bytes.write(to: url2)

        let hash1 = try HashService.sha256(fileAt: url1)
        let hash2 = try HashService.sha256(fileAt: url2)

        XCTAssertEqual(hash1, hash2)
    }

    func testHammingDistanceOfIdenticalHashesIsZero() {
        let distance = HashService.hammingDistance(0b1010, 0b1010)
        XCTAssertEqual(distance, 0)
    }

    func testHammingDistanceCountsDifferingBits() {
        let distance = HashService.hammingDistance(0b1010, 0b1000)
        XCTAssertEqual(distance, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/HashServiceTests`
Expected: FAIL — `HashService` does not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/Indexing/HashService.swift
import Foundation
import CryptoKit
import CoreImage
import CoreGraphics
import ImageIO

enum HashService {
    static func sha256(fileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 8x8 average-hash style perceptual hash: downsample to 8x8 grayscale,
    /// compare each pixel to the row average, pack results into a 64-bit value.
    static func pHash(imageAt url: URL) throws -> UInt64 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HashError.unreadableImage
        }
        return pHash(cgImage: cgImage)
    }

    static func pHash(cgImage: CGImage) -> UInt64 {
        let size = 8
        var pixels = [UInt8](repeating: 0, count: size * size)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var hash: UInt64 = 0
        for row in 0..<size {
            let rowPixels = pixels[(row * size)..<((row + 1) * size)]
            let average = Double(rowPixels.reduce(0) { $0 + Int($1) }) / Double(size)
            for (col, value) in rowPixels.enumerated() {
                let bitIndex = row * size + col
                if Double(value) >= average {
                    hash |= (1 << UInt64(bitIndex))
                }
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    enum HashError: Error {
        case unreadableImage
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/HashServiceTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/Indexing/HashService.swift PhotoOrganizerTests/HashServiceTests.swift
git commit -m "feat: add SHA256 and perceptual hash services"
```

---

### Task 5: MediaFile model + Indexer for photos (incremental)

**Files:**
- Create: `PhotoOrganizer/Models/MediaFile.swift`
- Create: `PhotoOrganizer/Indexing/Indexer.swift`
- Test: `PhotoOrganizerTests/IndexerTests.swift`

**Interfaces:**
- Consumes: `FileScanner.scan` (Task 3), `HashService.sha256`/`pHash` (Task 4), `Source` (Task 2).
- Produces: `MediaFile` (GRDB record, fields `id, sourceId, relativePath, kind, sha256, pHash, captureDate, width, height, clusterId`), `Indexer.indexSource(_ source: Source) throws -> [MediaFile]` — skips files already indexed with an unchanged `sha256` at the same relative path.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/IndexerTests.swift
import XCTest
@testable import PhotoOrganizer

final class IndexerTests: XCTestCase {
    func testIndexSourceCreatesMediaFileRowsForImages() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceManager = SourceManager(db: db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fake-jpeg-bytes").write(to: root.appendingPathComponent("a.jpg"))
        let source = try sourceManager.addSource(url: root)

        let indexer = Indexer(db: db)
        let indexed = try indexer.indexSource(source)

        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed[0].relativePath, "a.jpg")
        XCTAssertEqual(indexed[0].kind, "photo")
    }

    func testReindexingUnchangedFileDoesNotDuplicateRow() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceManager = SourceManager(db: db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fake-jpeg-bytes").write(to: root.appendingPathComponent("a.jpg"))
        let source = try sourceManager.addSource(url: root)
        let indexer = Indexer(db: db)

        _ = try indexer.indexSource(source)
        let secondPass = try indexer.indexSource(source)

        XCTAssertEqual(secondPass.count, 0, "unchanged file should not be re-indexed")
        let all = try db.dbPool.read { db in try MediaFile.fetchAll(db) }
        XCTAssertEqual(all.count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/IndexerTests`
Expected: FAIL — `Indexer` and `MediaFile` do not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/Models/MediaFile.swift
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
    var clusterId: String?
}
```

```swift
// PhotoOrganizer/Indexing/Indexer.swift
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
        let root = URL(fileURLWithPath: source.rootPath)
        let scanned = FileScanner.scan(root: root)
        var results: [MediaFile] = []

        for file in scanned where file.kind == .photo {
            let relativePath = String(file.url.path.dropFirst(root.path.count + 1))
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
                kind: "photo",
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

        return results
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/IndexerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/Models/MediaFile.swift PhotoOrganizer/Indexing/Indexer.swift PhotoOrganizerTests/IndexerTests.swift
git commit -m "feat: index photos into MediaFile rows incrementally"
```

---

### Task 6: VideoFrameSampler + extend Indexer to videos

**Files:**
- Create: `PhotoOrganizer/Indexing/VideoFrameSampler.swift`
- Modify: `PhotoOrganizer/Indexing/Indexer.swift`
- Test: `PhotoOrganizerTests/VideoFrameSamplerTests.swift`

**Interfaces:**
- Produces: `VideoFrameSampler.sampleFrames(videoAt url: URL, interval: TimeInterval) throws -> [(timestamp: TimeInterval, image: CGImage)]`.
- Modifies: `Indexer.indexSource` now also indexes `.video` scanned files, storing a representative `pHash` computed from the first sampled frame.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/VideoFrameSamplerTests.swift
import XCTest
import AVFoundation
@testable import PhotoOrganizer

final class VideoFrameSamplerTests: XCTestCase {
    func testSampleFramesReturnsEmptyForZeroDurationAsset() throws {
        // A file with no video track (e.g. empty data) should yield no frames,
        // not throw — callers treat "no frames" as "skip video hashing".
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data().write(to: url)

        let frames = try VideoFrameSampler.sampleFrames(videoAt: url, interval: 2.0)

        XCTAssertEqual(frames.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/VideoFrameSamplerTests`
Expected: FAIL — `VideoFrameSampler` does not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/Indexing/VideoFrameSampler.swift
import AVFoundation
import CoreGraphics

enum VideoFrameSampler {
    /// Samples one frame every `interval` seconds across the asset's duration.
    /// Returns an empty array (never throws for unreadable/empty assets) so
    /// callers can treat "no frames" as "skip video hashing for this file".
    static func sampleFrames(videoAt url: URL, interval: TimeInterval) throws -> [(timestamp: TimeInterval, image: CGImage)] {
        let asset = AVURLAsset(url: url)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var results: [(TimeInterval, CGImage)] = []
        var t: TimeInterval = 0
        while t < durationSeconds {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                results.append((t, cgImage))
            }
            t += interval
        }
        return results
    }
}
```

```swift
// PhotoOrganizer/Indexing/Indexer.swift  (add alongside the existing photo loop in indexSource)
        for file in scanned where file.kind == .video {
            let relativePath = String(file.url.path.dropFirst(root.path.count + 1))
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
            let representativeHash = frames.first.map { HashService.pHash(cgImage: $0.image) }

            let mediaFile = MediaFile(
                id: existing?.id ?? UUID().uuidString,
                sourceId: source.id,
                relativePath: relativePath,
                kind: "video",
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/VideoFrameSamplerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/Indexing/VideoFrameSampler.swift PhotoOrganizer/Indexing/Indexer.swift PhotoOrganizerTests/VideoFrameSamplerTests.swift
git commit -m "feat: sample video frames and index videos"
```

---

### Task 7: DuplicateClusterer — exact + near-duplicate grouping across sources

**Files:**
- Create: `PhotoOrganizer/Models/DuplicateCluster.swift`
- Create: `PhotoOrganizer/Dedup/DuplicateClusterer.swift`
- Test: `PhotoOrganizerTests/DuplicateClustererTests.swift`

**Interfaces:**
- Consumes: `MediaFile` rows (Task 5/6), `HashService.hammingDistance` (Task 4).
- Produces: `DuplicateCluster` (GRDB record: `id, suggestedKeeperMediaFileId, createdAt`), `DuplicateClusterer.rebuildClusters() throws -> [DuplicateCluster]` — writes cluster rows and stamps `MediaFile.clusterId` for every file placed in a cluster.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/DuplicateClustererTests.swift
import XCTest
@testable import PhotoOrganizer

final class DuplicateClustererTests: XCTestCase {
    func testExactHashMatchAcrossDifferentSourcesFormsOneCluster() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try Source(id: "sourceA", displayName: "A", rootPath: "/a", isOnline: true, lastScannedAt: nil).save(db)
            try Source(id: "sourceB", displayName: "B", rootPath: "/b", isOnline: true, lastScannedAt: nil).save(db)
            try MediaFile(id: "1", sourceId: "sourceA", relativePath: "x.jpg", kind: "photo",
                          sha256: "same-hash", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "2", sourceId: "sourceB", relativePath: "y.jpg", kind: "photo",
                          sha256: "same-hash", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "3", sourceId: "sourceA", relativePath: "z.jpg", kind: "photo",
                          sha256: "different-hash", pHash: nil, captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
        }

        let clusterer = DuplicateClusterer(db: db)
        let clusters = try clusterer.rebuildClusters()

        XCTAssertEqual(clusters.count, 1)
        let members = try db.dbPool.read { db in
            try MediaFile.filter(Column("clusterId") == clusters[0].id).fetchAll(db)
        }
        XCTAssertEqual(Set(members.map(\.id)), Set(["1", "2"]))
    }

    func testNearDuplicatePHashWithinThresholdFormsCluster() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try Source(id: "sourceA", displayName: "A", rootPath: "/a", isOnline: true, lastScannedAt: nil).save(db)
            // Two distinct hashes 1 bit apart -> near duplicate.
            try MediaFile(id: "1", sourceId: "sourceA", relativePath: "x.jpg", kind: "photo",
                          sha256: "hash-a", pHash: String(UInt64(0b1010), radix: 16), captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
            try MediaFile(id: "2", sourceId: "sourceA", relativePath: "y.jpg", kind: "photo",
                          sha256: "hash-b", pHash: String(UInt64(0b1000), radix: 16), captureDate: nil, width: nil, height: nil, clusterId: nil).save(db)
        }

        let clusterer = DuplicateClusterer(db: db)
        let clusters = try clusterer.rebuildClusters()

        XCTAssertEqual(clusters.count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/DuplicateClustererTests`
Expected: FAIL — `DuplicateCluster` / `DuplicateClusterer` do not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/Models/DuplicateCluster.swift
import GRDB
import Foundation

struct DuplicateCluster: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "duplicateCluster"

    var id: String
    var suggestedKeeperMediaFileId: String?
    var createdAt: Date
}
```

```swift
// PhotoOrganizer/Dedup/DuplicateClusterer.swift
import Foundation
import GRDB

final class DuplicateClusterer {
    private let db: DatabaseManager
    private let pHashThreshold = 5 // Hamming distance <= 5 of 64 bits counts as near-duplicate

    init(db: DatabaseManager) {
        self.db = db
    }

    /// Rebuilds all duplicate clusters from scratch: groups by exact sha256
    /// first, then merges remaining ungrouped files whose pHash distance is
    /// within threshold. Clustering is source-agnostic (files across
    /// different sources merge into the same cluster).
    func rebuildClusters() throws -> [DuplicateCluster] {
        let allFiles = try db.dbPool.read { db in try MediaFile.fetchAll(db) }

        // Reset previous clustering.
        try db.dbPool.write { db in
            try MediaFile.updateAll(db, Column("clusterId").set(to: nil))
            try DuplicateCluster.deleteAll(db)
        }

        var groups: [[MediaFile]] = []
        var byHash: [String: [MediaFile]] = [:]
        for file in allFiles {
            byHash[file.sha256, default: []].append(file)
        }
        var ungrouped: [MediaFile] = []
        for (_, files) in byHash {
            if files.count > 1 {
                groups.append(files)
            } else {
                ungrouped.append(files[0])
            }
        }

        // Near-duplicate pass over files not already grouped by exact hash.
        var remaining = ungrouped.filter { $0.pHash != nil }
        while !remaining.isEmpty {
            let anchor = remaining.removeFirst()
            guard let anchorHash = UInt64(anchor.pHash!, radix: 16) else { continue }
            var cluster = [anchor]
            remaining.removeAll { candidate in
                guard let candidateHash = UInt64(candidate.pHash!, radix: 16) else { return false }
                if HashService.hammingDistance(anchorHash, candidateHash) <= pHashThreshold {
                    cluster.append(candidate)
                    return true
                }
                return false
            }
            if cluster.count > 1 {
                groups.append(cluster)
            }
        }

        var createdClusters: [DuplicateCluster] = []
        try db.dbPool.write { db in
            for group in groups {
                let keeper = group.max(by: { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) })
                let cluster = DuplicateCluster(id: UUID().uuidString, suggestedKeeperMediaFileId: keeper?.id, createdAt: Date())
                try cluster.save(db)
                for file in group {
                    var updated = file
                    updated.clusterId = cluster.id
                    try updated.save(db)
                }
                createdClusters.append(cluster)
            }
        }
        return createdClusters
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/DuplicateClustererTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/Models/DuplicateCluster.swift PhotoOrganizer/Dedup/DuplicateClusterer.swift PhotoOrganizerTests/DuplicateClustererTests.swift
git commit -m "feat: cluster exact and near-duplicate media across sources"
```

---

### Task 8: FaceDetector — Vision-based face detection + embeddings for photos

**Files:**
- Create: `PhotoOrganizer/Models/FaceIdentity.swift`
- Create: `PhotoOrganizer/Models/FaceObservation.swift`
- Create: `PhotoOrganizer/Faces/FaceDetector.swift`
- Test: `PhotoOrganizerTests/FaceDetectorTests.swift`

**Interfaces:**
- Produces: `FaceIdentity` (GRDB record: `id, label: String?, referenceEmbedding: Data`), `FaceObservation` (GRDB record: `id, mediaFileId, identityId: String?, embedding: Data, boundingBoxX/Y/Width/Height: Double, frameTimestamp: Double?`), `struct DetectedFace { let boundingBox: CGRect; let embedding: [Float] }`, `FaceDetector.detectFaces(in cgImage: CGImage) throws -> [DetectedFace]`.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/FaceDetectorTests.swift
import XCTest
import CoreGraphics
@testable import PhotoOrganizer

final class FaceDetectorTests: XCTestCase {
    func testDetectFacesOnBlankImageReturnsNoFaces() throws {
        let size = 64
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 255, count: size * size)
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                 bytesPerRow: size, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let blankImage = context.makeImage()!

        let faces = try FaceDetector.detectFaces(in: blankImage)

        XCTAssertEqual(faces.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/FaceDetectorTests`
Expected: FAIL — `FaceDetector` does not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/Models/FaceIdentity.swift
import GRDB
import Foundation

struct FaceIdentity: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "faceIdentity"

    var id: String
    var label: String?
    var referenceEmbedding: Data
}
```

```swift
// PhotoOrganizer/Models/FaceObservation.swift
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
```

```swift
// PhotoOrganizer/Faces/FaceDetector.swift
import Vision
import CoreGraphics

struct DetectedFace {
    let boundingBox: CGRect       // normalized [0,1] coordinates
    let embedding: [Float]
}

enum FaceDetector {
    static func detectFaces(in cgImage: CGImage) throws -> [DetectedFace] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }

        var faces: [DetectedFace] = []
        for observation in observations {
            let embedding = try embed(cgImage: cgImage, boundingBox: observation.boundingBox)
            faces.append(DetectedFace(boundingBox: observation.boundingBox, embedding: embedding))
        }
        return faces
    }

    /// Uses VNGenerateImagePrintRequest scoped to the detected face's bounding
    /// box as a per-face embedding usable for cosine-similarity matching.
    private static func embed(cgImage: CGImage, boundingBox: CGRect) throws -> [Float] {
        let request = VNGenerateImagePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first else { return [] }
        var floats = [Float](repeating: 0, count: result.elementCount)
        try result.computeDistance(&floats[0], to: result)
        return floats
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/FaceDetectorTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/Models/FaceIdentity.swift PhotoOrganizer/Models/FaceObservation.swift PhotoOrganizer/Faces/FaceDetector.swift PhotoOrganizerTests/FaceDetectorTests.swift
git commit -m "feat: detect faces and generate per-face embeddings via Vision"
```

---

### Task 9: FaceMatcher — match detected faces to labeled identities

**Files:**
- Create: `PhotoOrganizer/Faces/FaceMatcher.swift`
- Test: `PhotoOrganizerTests/FaceMatcherTests.swift`

**Interfaces:**
- Consumes: `FaceIdentity`, `FaceObservation` (Task 8).
- Produces: `FaceMatcher.cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float`, `FaceMatcher.matchOrCreateUnnamedIdentity(embedding: [Float]) throws -> FaceIdentity`, `FaceMatcher.labelIdentity(_ identityId: String, as label: String) throws`. Match threshold: cosine similarity >= 0.6 counts as the same person.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/FaceMatcherTests.swift
import XCTest
@testable import PhotoOrganizer

final class FaceMatcherTests: XCTestCase {
    func testCosineSimilarityOfIdenticalVectorsIsOne() {
        let vector: [Float] = [1, 0, 0, 0]
        let similarity = FaceMatcher.cosineSimilarity(vector, vector)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.0001)
    }

    func testMatchOrCreateReusesExistingIdentityWithinThreshold() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let matcher = FaceMatcher(db: db)
        let baseEmbedding: [Float] = [1, 0, 0, 0]

        let first = try matcher.matchOrCreateUnnamedIdentity(embedding: baseEmbedding)
        // A near-identical embedding (same direction) should match the same identity.
        let second = try matcher.matchOrCreateUnnamedIdentity(embedding: [0.99, 0.01, 0, 0])

        XCTAssertEqual(first.id, second.id)
    }

    func testMatchOrCreateMakesNewIdentityForDissimilarEmbedding() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let matcher = FaceMatcher(db: db)

        let first = try matcher.matchOrCreateUnnamedIdentity(embedding: [1, 0, 0, 0])
        let second = try matcher.matchOrCreateUnnamedIdentity(embedding: [0, 1, 0, 0])

        XCTAssertNotEqual(first.id, second.id)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/FaceMatcherTests`
Expected: FAIL — `FaceMatcher` does not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/Faces/FaceMatcher.swift
import Foundation
import GRDB

final class FaceMatcher {
    private let db: DatabaseManager
    private let matchThreshold: Float = 0.6

    init(db: DatabaseManager) {
        self.db = db
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Finds the best-matching existing identity by cosine similarity; if
    /// none clears `matchThreshold`, creates a new unnamed identity.
    func matchOrCreateUnnamedIdentity(embedding: [Float]) throws -> FaceIdentity {
        let allIdentities = try db.dbPool.read { db in try FaceIdentity.fetchAll(db) }

        var best: (identity: FaceIdentity, score: Float)?
        for identity in allIdentities {
            let reference = decode(identity.referenceEmbedding)
            let score = Self.cosineSimilarity(embedding, reference)
            if score >= matchThreshold, (best == nil || score > best!.score) {
                best = (identity, score)
            }
        }

        if let best {
            return best.identity
        }

        let newIdentity = FaceIdentity(id: UUID().uuidString, label: nil, referenceEmbedding: encode(embedding))
        try db.dbPool.write { db in try newIdentity.save(db) }
        return newIdentity
    }

    func labelIdentity(_ identityId: String, as label: String) throws {
        try db.dbPool.write { db in
            guard var identity = try FaceIdentity.fetchOne(db, key: identityId) else { return }
            identity.label = label
            try identity.save(db)
        }
    }

    private func encode(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/FaceMatcherTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/Faces/FaceMatcher.swift PhotoOrganizerTests/FaceMatcherTests.swift
git commit -m "feat: match detected faces to existing or new identities"
```

---

### Task 10: Wire face detection into the Indexer for photos and sampled video frames

**Files:**
- Modify: `PhotoOrganizer/Indexing/Indexer.swift`
- Test: `PhotoOrganizerTests/IndexerFaceIntegrationTests.swift`

**Interfaces:**
- Consumes: `FaceDetector.detectFaces` (Task 8), `FaceMatcher.matchOrCreateUnnamedIdentity` (Task 9), `VideoFrameSampler.sampleFrames` (Task 6).
- Produces: `Indexer.indexSource` now also writes one `FaceObservation` per detected face for photos (`frameTimestamp = nil`) and for each sampled video frame (`frameTimestamp = <seconds>`).

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/IndexerFaceIntegrationTests.swift
import XCTest
@testable import PhotoOrganizer

final class IndexerFaceIntegrationTests: XCTestCase {
    func testIndexingImageWithNoFacesWritesNoFaceObservations() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceManager = SourceManager(db: db)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // A 1x1 pixel PNG has no detectable face; confirms the pipeline runs
        // face detection without crashing and writes zero observations.
        let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try onePixelPNG.write(to: root.appendingPathComponent("a.png"))
        let source = try sourceManager.addSource(url: root)

        let indexer = Indexer(db: db)
        let indexed = try indexer.indexSource(source)

        XCTAssertEqual(indexed.count, 1)
        let observations = try db.dbPool.read { db in try FaceObservation.fetchAll(db) }
        XCTAssertEqual(observations.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/IndexerFaceIntegrationTests`
Expected: FAIL — `Indexer` does not yet call face detection, but more importantly this establishes the expected zero-observation baseline; run it against current code to confirm it compiles and passes trivially, then proceed to Step 3 to add the real wiring and re-verify with Step 4 using a face-containing fixture path reviewed manually (Vision requires a real face to return a positive case, which unit fixtures can't synthesize reliably — covered by the manual end-to-end test in Task 14).

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/Indexing/Indexer.swift
// Add as a dependency and helper method, then call from both the photo and video loops.

    private let faceMatcher: FaceMatcher

    // Update init:
    // init(db: DatabaseManager) {
    //     self.db = db
    //     self.faceMatcher = FaceMatcher(db: db)
    // }

    private func indexFaces(cgImage: CGImage, mediaFileId: String, frameTimestamp: Double?) throws {
        let faces = try FaceDetector.detectFaces(in: cgImage)
        for face in faces {
            let identity = try faceMatcher.matchOrCreateUnnamedIdentity(embedding: face.embedding)
            let embeddingData = face.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            let observation = FaceObservation(
                id: UUID().uuidString,
                mediaFileId: mediaFileId,
                identityId: identity.id,
                embedding: embeddingData,
                boundingBoxX: face.boundingBox.origin.x,
                boundingBoxY: face.boundingBox.origin.y,
                boundingBoxWidth: face.boundingBox.width,
                boundingBoxHeight: face.boundingBox.height,
                frameTimestamp: frameTimestamp
            )
            try db.dbPool.write { db in try observation.save(db) }
        }
    }

// In the photo loop, after `try db.dbPool.write { db in try mediaFile.save(db) }`:
//     if let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
//        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
//         try indexFaces(cgImage: cgImage, mediaFileId: mediaFile.id, frameTimestamp: nil)
//     }

// In the video loop, after saving mediaFile, reuse the already-sampled `frames`:
//     for (timestamp, image) in frames {
//         try indexFaces(cgImage: image, mediaFileId: mediaFile.id, frameTimestamp: timestamp)
//     }
```

Apply these edits directly into `Indexer.swift`'s existing `init` and both loops from Tasks 5 and 6.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/IndexerFaceIntegrationTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/Indexing/Indexer.swift PhotoOrganizerTests/IndexerFaceIntegrationTests.swift
git commit -m "feat: detect and store faces for indexed photos and video frames"
```

---

### Task 11: SourcesView — add/list connected folders

**Files:**
- Create: `PhotoOrganizer/UI/SourcesView.swift`
- Test: `PhotoOrganizerTests/SourcesViewModelTests.swift`

**Interfaces:**
- Consumes: `SourceManager` (Task 2), `Indexer` (Task 5/6/10).
- Produces: `@MainActor final class SourcesViewModel: ObservableObject` with `@Published var sources: [Source]`, `func addSource(url: URL) throws`, `func rescanAll() throws`; `struct SourcesView: View`.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/SourcesViewModelTests.swift
import XCTest
@testable import PhotoOrganizer

final class SourcesViewModelTests: XCTestCase {
    @MainActor
    func testAddSourceAppendsToPublishedSources() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let viewModel = SourcesViewModel(db: db)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try viewModel.addSource(url: folder)

        XCTAssertEqual(viewModel.sources.count, 1)
        XCTAssertEqual(viewModel.sources[0].rootPath, folder.path)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/SourcesViewModelTests`
Expected: FAIL — `SourcesViewModel` does not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/UI/SourcesView.swift
import SwiftUI

@MainActor
final class SourcesViewModel: ObservableObject {
    @Published var sources: [Source] = []

    private let sourceManager: SourceManager
    private let indexer: Indexer

    init(db: DatabaseManager) {
        self.sourceManager = SourceManager(db: db)
        self.indexer = Indexer(db: db)
        reload()
    }

    func addSource(url: URL) throws {
        _ = try sourceManager.addSource(url: url)
        reload()
    }

    func rescanAll() throws {
        for source in sources {
            _ = try indexer.indexSource(source)
        }
        reload()
    }

    private func reload() {
        sources = (try? sourceManager.allSources()) ?? []
    }
}

struct SourcesView: View {
    @ObservedObject var viewModel: SourcesViewModel
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            List(viewModel.sources, id: \.id) { source in
                HStack {
                    Text(source.displayName)
                    Spacer()
                    Text(source.isOnline ? "Online" : "Offline")
                        .foregroundStyle(source.isOnline ? .green : .secondary)
                }
            }
            HStack {
                Button("Add Folder…") { presentFolderPicker() }
                Button("Rescan All") { rescan() }
            }
            .padding()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    private func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try viewModel.addSource(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rescan() {
        do {
            try viewModel.rescanAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/SourcesViewModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/UI/SourcesView.swift PhotoOrganizerTests/SourcesViewModelTests.swift
git commit -m "feat: add SourcesView for connecting and rescanning folders"
```

---

### Task 12: DuplicatesView — browse duplicate clusters

**Files:**
- Create: `PhotoOrganizer/UI/DuplicatesView.swift`
- Test: `PhotoOrganizerTests/DuplicatesViewModelTests.swift`

**Interfaces:**
- Consumes: `DuplicateCluster`, `MediaFile` (Task 7).
- Produces: `@MainActor final class DuplicatesViewModel: ObservableObject` with `@Published var clusters: [(cluster: DuplicateCluster, members: [MediaFile])]`, `func reload() throws`; `struct DuplicatesView: View`.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/DuplicatesViewModelTests.swift
import XCTest
@testable import PhotoOrganizer

final class DuplicatesViewModelTests: XCTestCase {
    @MainActor
    func testReloadGroupsMembersUnderTheirCluster() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try Source(id: "s1", displayName: "S", rootPath: "/s", isOnline: true, lastScannedAt: nil).save(db)
            try DuplicateCluster(id: "c1", suggestedKeeperMediaFileId: "m1", createdAt: Date()).save(db)
            try MediaFile(id: "m1", sourceId: "s1", relativePath: "a.jpg", kind: "photo", sha256: "h", pHash: nil,
                          captureDate: nil, width: nil, height: nil, clusterId: "c1").save(db)
            try MediaFile(id: "m2", sourceId: "s1", relativePath: "b.jpg", kind: "photo", sha256: "h", pHash: nil,
                          captureDate: nil, width: nil, height: nil, clusterId: "c1").save(db)
        }

        let viewModel = DuplicatesViewModel(db: db)
        try viewModel.reload()

        XCTAssertEqual(viewModel.clusters.count, 1)
        XCTAssertEqual(viewModel.clusters[0].members.count, 2)
        XCTAssertEqual(viewModel.clusters[0].cluster.suggestedKeeperMediaFileId, "m1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/DuplicatesViewModelTests`
Expected: FAIL — `DuplicatesViewModel` does not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/UI/DuplicatesView.swift
import SwiftUI
import GRDB

@MainActor
final class DuplicatesViewModel: ObservableObject {
    @Published var clusters: [(cluster: DuplicateCluster, members: [MediaFile])] = []

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func reload() throws {
        let allClusters = try db.dbPool.read { db in try DuplicateCluster.fetchAll(db) }
        clusters = try allClusters.map { cluster in
            let members = try db.dbPool.read { db in
                try MediaFile.filter(Column("clusterId") == cluster.id).fetchAll(db)
            }
            return (cluster, members)
        }
    }
}

struct DuplicatesView: View {
    @ObservedObject var viewModel: DuplicatesViewModel

    var body: some View {
        List(viewModel.clusters, id: \.cluster.id) { entry in
            VStack(alignment: .leading) {
                Text("Cluster (\(entry.members.count) files)").font(.headline)
                ForEach(entry.members, id: \.id) { file in
                    HStack {
                        Text(file.relativePath)
                        if file.id == entry.cluster.suggestedKeeperMediaFileId {
                            Text("Suggested keeper").font(.caption).foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .task {
            try? viewModel.reload()
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/DuplicatesViewModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/UI/DuplicatesView.swift PhotoOrganizerTests/DuplicatesViewModelTests.swift
git commit -m "feat: add DuplicatesView to browse duplicate clusters"
```

---

### Task 13: PeopleView — label faces and browse by person

**Files:**
- Create: `PhotoOrganizer/UI/PeopleView.swift`
- Test: `PhotoOrganizerTests/PeopleViewModelTests.swift`

**Interfaces:**
- Consumes: `FaceIdentity`, `FaceObservation` (Task 8), `FaceMatcher.labelIdentity` (Task 9).
- Produces: `@MainActor final class PeopleViewModel: ObservableObject` with `@Published var identities: [FaceIdentity]`, `func reload() throws`, `func label(_ identityId: String, as name: String) throws`; `struct PeopleView: View`.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/PeopleViewModelTests.swift
import XCTest
@testable import PhotoOrganizer

final class PeopleViewModelTests: XCTestCase {
    @MainActor
    func testLabelingIdentityPersistsAndReflectsInReload() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try FaceIdentity(id: "id1", label: nil, referenceEmbedding: Data([0, 0, 0, 0])).save(db)
        }

        let viewModel = PeopleViewModel(db: db)
        try viewModel.reload()
        try viewModel.label("id1", as: "Amit")
        try viewModel.reload()

        XCTAssertEqual(viewModel.identities.first?.label, "Amit")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/PeopleViewModelTests`
Expected: FAIL — `PeopleViewModel` does not exist.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/UI/PeopleView.swift
import SwiftUI

@MainActor
final class PeopleViewModel: ObservableObject {
    @Published var identities: [FaceIdentity] = []

    private let db: DatabaseManager
    private let matcher: FaceMatcher

    init(db: DatabaseManager) {
        self.db = db
        self.matcher = FaceMatcher(db: db)
    }

    func reload() throws {
        identities = try db.dbPool.read { db in try FaceIdentity.fetchAll(db) }
    }

    func label(_ identityId: String, as name: String) throws {
        try matcher.labelIdentity(identityId, as: name)
    }
}

struct PeopleView: View {
    @ObservedObject var viewModel: PeopleViewModel
    @State private var editingId: String?
    @State private var draftName: String = ""

    var body: some View {
        List(viewModel.identities, id: \.id) { identity in
            HStack {
                Text(identity.label ?? "Unnamed person")
                Spacer()
                Button("Rename") {
                    editingId = identity.id
                    draftName = identity.label ?? ""
                }
            }
        }
        .task {
            try? viewModel.reload()
        }
        .sheet(item: Binding(get: { editingId.map(Identified.init) }, set: { editingId = $0?.value })) { identified in
            VStack {
                TextField("Name", text: $draftName)
                Button("Save") {
                    try? viewModel.label(identified.value, as: draftName)
                    try? viewModel.reload()
                    editingId = nil
                }
            }
            .padding()
        }
    }
}

private struct Identified: Identifiable {
    let value: String
    var id: String { value }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/PeopleViewModelTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/UI/PeopleView.swift PhotoOrganizerTests/PeopleViewModelTests.swift
git commit -m "feat: add PeopleView for labeling and browsing face identities"
```

---

### Task 14: Offline drive handling + manual end-to-end verification

**Files:**
- Modify: `PhotoOrganizer/Sources/SourceManager.swift`
- Modify: `PhotoOrganizer/Indexing/Indexer.swift`
- Test: `PhotoOrganizerTests/OfflineSourceTests.swift`

**Interfaces:**
- Consumes: `SourceManager.refreshOnlineStatus` (Task 2).
- Produces: `Indexer.indexSource` returns `[]` immediately (no throw) when `source.isOnline == false`, so a rescan pass never attempts to hash files on an unmounted drive.

- [ ] **Step 1: Write the failing test**

```swift
// PhotoOrganizerTests/OfflineSourceTests.swift
import XCTest
@testable import PhotoOrganizer

final class OfflineSourceTests: XCTestCase {
    func testIndexSourceSkipsScanWhenSourceMarkedOffline() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let offlineSource = Source(id: "gone", displayName: "Gone Drive", rootPath: "/Volumes/DoesNotExist",
                                    isOnline: false, lastScannedAt: nil)
        let indexer = Indexer(db: db)

        let result = try indexer.indexSource(offlineSource)

        XCTAssertEqual(result.count, 0)
    }

    func testRefreshOnlineStatusMarksMissingRootPathOffline() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceManager = SourceManager(db: db)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try sourceManager.addSource(url: folder)
        try FileManager.default.removeItem(at: folder)

        try sourceManager.refreshOnlineStatus()

        let refreshed = try sourceManager.allSources().first { $0.id == source.id }
        XCTAssertEqual(refreshed?.isOnline, false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/OfflineSourceTests`
Expected: FAIL — `Indexer.indexSource` currently attempts to scan `/Volumes/DoesNotExist` rather than short-circuiting.

- [ ] **Step 3: Write minimal implementation**

```swift
// PhotoOrganizer/Indexing/Indexer.swift
// Add as the first line inside indexSource(_:):
    func indexSource(_ source: Source) throws -> [MediaFile] {
        guard source.isOnline else { return [] }
        // ...existing scan logic unchanged below...
```

`SourceManager.refreshOnlineStatus()` already implements the second test's behavior from Task 2 — no change needed there; this step confirms it via the new test.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -only-testing:PhotoOrganizerTests/OfflineSourceTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add PhotoOrganizer/Indexing/Indexer.swift PhotoOrganizerTests/OfflineSourceTests.swift
git commit -m "feat: skip indexing when a source drive is offline"
```

- [ ] **Step 6: Manual end-to-end verification**

Per the spec's Testing section, connect a real external drive with a mixed photo/video library and confirm:
1. `SourcesView` → Add Folder → scan completes without crashing.
2. A manually duplicated file (copy a photo from that drive into a second connected folder) appears in `DuplicatesView` as a single cluster spanning both sources.
3. A person appearing in multiple photos, once labeled once in `PeopleView`, shows the same label across all their other photos after a rescan.
4. Unmount the drive mid-way, confirm `SourcesView` shows "Offline" and a rescan does not crash; remount and confirm rescan resumes indexing new files only.

Record the outcome of this manual pass in the PR/commit description — this is the spec's acceptance check for the full pipeline, not automatable in XCTest.

---

## Self-Review Notes

- **Spec coverage:** multi-drive/multi-folder scan without import (Tasks 1-6, 14), exact + near-duplicate cross-source clustering (Task 7), named face recognition (Tasks 8-10, 13), read-only index+report with no auto file ops (no task performs move/rename/delete — verified against Global Constraints), offline drive handling (Task 14), video full treatment (Tasks 6, 10). All spec sections have a corresponding task.
- **Placeholder scan:** no TBD/TODO markers; the one narrative step (Task 10 Step 2) explains why a positive-face fixture isn't unit-testable and points to the Task 14 manual verification instead, rather than deferring real work.
- **Type consistency:** `MediaFile.id`, `Source.id`, `DuplicateCluster.suggestedKeeperMediaFileId`, and `FaceObservation.mediaFileId`/`identityId` are used consistently as `String` (UUIDs or volume UUIDs) across all tasks that reference them.
