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
