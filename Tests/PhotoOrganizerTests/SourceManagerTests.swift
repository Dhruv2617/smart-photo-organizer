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
        #expect(!all[0].isOnline)
    }

    @Test func testTwoFoldersOnSameVolumeGetDistinctSourceIds() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let manager = SourceManager(db: db)
        let folderA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folderB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)

        let sourceA = try manager.addSource(url: folderA)
        let sourceB = try manager.addSource(url: folderB)

        // Both folders live on the same test-machine volume, so their
        // volumeUUID may coincide, but the source identity (id) must not.
        #expect(sourceA.id != sourceB.id)
        #expect(sourceA.rootPath == folderA.path)
        #expect(sourceB.rootPath == folderB.path)

        let all = try manager.allSources()
        #expect(all.count == 2)
        #expect(Set(all.map(\.id)).count == 2)
        #expect(all.first { $0.id == sourceA.id }?.rootPath == folderA.path)
        #expect(all.first { $0.id == sourceB.id }?.rootPath == folderB.path)
    }
}
