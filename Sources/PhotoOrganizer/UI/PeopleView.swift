import SwiftUI
import AppKit
import GRDB

@MainActor
final class PeopleViewModel: ObservableObject {
    @Published var identities: [FaceIdentity] = []
    @Published var thumbnails: [String: NSImage] = [:]

    private let db: DatabaseManager
    private let matcher: FaceMatcher

    init(db: DatabaseManager) {
        self.db = db
        self.matcher = FaceMatcher(db: db)
    }

    func reload() throws {
        identities = try db.dbPool.read { db in try FaceIdentity.fetchAll(db) }
        loadThumbnails()
    }

    func label(_ identityId: String, as name: String) throws {
        try matcher.labelIdentity(identityId, as: name)
    }

    /// Renders one representative face-crop thumbnail per identity (its
    /// first observed face), off the main thread since it decodes a full
    /// image per identity.
    private func loadThumbnails() {
        let db = self.db
        let identitiesSnapshot = identities

        Task.detached(priority: .userInitiated) {
            for identity in identitiesSnapshot {
                guard let thumbnail = try? Self.representativeThumbnail(for: identity.id, db: db) else { continue }
                await MainActor.run {
                    self.thumbnails[identity.id] = thumbnail
                }
            }
        }
    }

    private nonisolated static func representativeThumbnail(for identityId: String, db: DatabaseManager) throws -> NSImage? {
        guard let observation = try db.dbPool.read({ db in
            try FaceObservation.filter(Column("identityId") == identityId).fetchOne(db)
        }) else { return nil }
        guard let mediaFile = try db.dbPool.read({ db in try MediaFile.fetchOne(db, key: observation.mediaFileId) }) else {
            return nil
        }
        guard let source = try db.dbPool.read({ db in try Source.fetchOne(db, key: mediaFile.sourceId) }) else {
            return nil
        }
        let fileURL = URL(fileURLWithPath: source.rootPath).appendingPathComponent(mediaFile.relativePath)
        let boundingBox = CGRect(
            x: observation.boundingBoxX,
            y: observation.boundingBoxY,
            width: observation.boundingBoxWidth,
            height: observation.boundingBoxHeight
        )
        return MediaThumbnail.faceCrop(fileURL: fileURL, boundingBox: boundingBox)
    }
}

struct PeopleView: View {
    @ObservedObject var viewModel: PeopleViewModel
    @State private var editingId: String?
    @State private var draftName: String = ""

    var body: some View {
        List(viewModel.identities, id: \.id) { identity in
            HStack {
                if let thumbnail = viewModel.thumbnails[identity.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle")
                        .resizable()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.secondary)
                }
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
