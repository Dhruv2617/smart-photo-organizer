import Testing
import Foundation
@testable import PhotoOrganizer

struct OfflineSourceTests {
    @Test func testIndexSourceSkipsScanWhenSourceMarkedOffline() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let offlineSource = Source(id: "gone", displayName: "Gone Drive", rootPath: "/Volumes/DoesNotExist",
                                    isOnline: false, lastScannedAt: nil)
        let indexer = Indexer(db: db)

        let result = try indexer.indexSource(offlineSource)

        #expect(result.count == 0)
    }

    @Test func testRefreshOnlineStatusMarksMissingRootPathOffline() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let sourceManager = SourceManager(db: db)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try sourceManager.addSource(url: folder)
        try FileManager.default.removeItem(at: folder)

        try sourceManager.refreshOnlineStatus()

        let refreshed = try sourceManager.allSources().first { $0.id == source.id }
        #expect(refreshed?.isOnline == false)
    }
}
