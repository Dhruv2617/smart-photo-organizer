import Testing
import Foundation
@testable import PhotoOrganizer

struct DatabaseManagerTests {
    @Test func testMigrationsCreateAllTables() throws {
        let path = NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite"
        let manager = try DatabaseManager(path: path)

        let tableNames = try manager.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }

        for expected in ["source", "mediaFile", "duplicateCluster", "faceIdentity", "faceObservation"] {
            #expect(tableNames.contains(expected), "missing table \(expected)")
        }
    }
}
