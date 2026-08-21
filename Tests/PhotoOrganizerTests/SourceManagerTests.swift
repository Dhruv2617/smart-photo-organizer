import Testing
import Foundation
@testable import PhotoOrganizer

struct SourceManagerTests {
    @Test func testAddSourcePersistsVolumeUUIDAndPath() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let manager = SourceManager(db: db)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let source = try manager.addSource(url: folder)

        #expect(source.rootPath == folder.path)
        #expect(source.isOnline)

        let all = try manager.allSources()
        #expect(all.count == 1)
        #expect(all[0].id == source.id)
    }

    @Test func testRefreshOnlineStatusMarksMissingFolderOffline() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let manager = SourceManager(db: db)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let source = try manager.addSource(url: folder)
        #expect(source.isOnline)

        try FileManager.default.removeItem(at: folder)

        try manager.refreshOnlineStatus()

        let all = try manager.allSources()
        #expect(all.count == 1)
        #expect(all[0].isOnline == false)
    }
}
