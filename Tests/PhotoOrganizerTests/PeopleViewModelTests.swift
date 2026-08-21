import Testing
import Foundation
import GRDB
@testable import PhotoOrganizer

struct PeopleViewModelTests {
    @Test @MainActor
    func testLabelingIdentityPersistsAndReflectsInReload() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        try db.dbPool.write { db in
            try FaceIdentity(id: "id1", label: nil, referenceEmbedding: Data([0, 0, 0, 0])).save(db)
        }

        let viewModel = PeopleViewModel(db: db)
        try viewModel.reload()
        try viewModel.label("id1", as: "Amit")
        try viewModel.reload()

        #expect(viewModel.identities.first?.label == "Amit")
    }
}
