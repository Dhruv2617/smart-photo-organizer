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

    /// Merges several identities that are really the same person (a
    /// common outcome since face matching uses a generic image-similarity
    /// distance, not a face-recognition-tuned one, so the same person
    /// often splits across multiple identities). All face observations
    /// move to the surviving identity; the others are deleted. Prefers an
    /// already-labeled identity as the survivor so a merge never loses a
    /// name the user already set.
    func mergeIdentities(_ ids: Set<String>) throws {
        guard ids.count > 1 else { return }
        let selected = identities.filter { ids.contains($0.id) }
        guard let keeper = selected.first(where: { $0.label != nil }) ?? selected.first else { return }
        let othersToMerge = ids.subtracting([keeper.id])

        try db.dbPool.write { db in
            for otherId in othersToMerge {
                try FaceObservation
                    .filter(Column("identityId") == otherId)
                    .updateAll(db, Column("identityId").set(to: keeper.id))
                _ = try FaceIdentity.deleteOne(db, key: otherId)
            }
        }
        try reload()
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
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    @State private var errorMessage: String?

    private let thumbnailSize: CGFloat = 84

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(isSelecting ? "Cancel" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { selectedIds.removeAll() }
                }
                if isSelecting {
                    Spacer()
                    Text("\(selectedIds.count) selected").foregroundStyle(.secondary)
                    Button("Merge Selected") {
                        mergeSelected()
                    }
                    .disabled(selectedIds.count < 2)
                } else {
                    Spacer()
                }
            }
            .padding()

            List(viewModel.identities, id: \.id) { identity in
                HStack {
                    if isSelecting {
                        Image(systemName: selectedIds.contains(identity.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedIds.contains(identity.id) ? Color.accentColor : .secondary)
                    }
                    if let thumbnail = viewModel.thumbnails[identity.id] {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: thumbnailSize, height: thumbnailSize)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle")
                            .resizable()
                            .frame(width: thumbnailSize, height: thumbnailSize)
                            .foregroundStyle(.secondary)
                    }
                    Text(identity.label ?? "Unnamed person")
                        .font(.title3)
                    Spacer()
                    if !isSelecting {
                        Button("Rename") {
                            editingId = identity.id
                            draftName = identity.label ?? ""
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isSelecting else { return }
                    if selectedIds.contains(identity.id) {
                        selectedIds.remove(identity.id)
                    } else {
                        selectedIds.insert(identity.id)
                    }
                }
                .padding(.vertical, 6)
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
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    private func mergeSelected() {
        do {
            try viewModel.mergeIdentities(selectedIds)
            selectedIds.removeAll()
            isSelecting = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct Identified: Identifiable {
    let value: String
    var id: String { value }
}
