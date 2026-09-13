import SwiftUI
import AppKit
import GRDB

@MainActor
final class DuplicatesViewModel: ObservableObject {
    @Published var clusters: [(cluster: DuplicateCluster, members: [MediaFile])] = []
    @Published var similarityThreshold: Int = DuplicateClusterer.defaultPHashThreshold
    @Published var isRecalculating = false
    @Published var recalculationStatus = ""
    @Published var lastError: Error?

    private let db: DatabaseManager
    private var sourcesById: [String: Source] = [:]

    init(db: DatabaseManager) {
        self.db = db
    }

    var exactClusters: [(cluster: DuplicateCluster, members: [MediaFile])] {
        clusters.filter { $0.cluster.matchType == "exact" }
    }

    var similarClusters: [(cluster: DuplicateCluster, members: [MediaFile])] {
        clusters.filter { $0.cluster.matchType == "near" }
    }

    func reload() throws {
        sourcesById = try db.dbPool.read { db in try Source.fetchAll(db) }
            .reduce(into: [:]) { $0[$1.id] = $1 }
        let allClusters = try db.dbPool.read { db in try DuplicateCluster.fetchAll(db) }
        clusters = try allClusters.map { cluster in
            let members = try db.dbPool.read { db in
                try MediaFile.filter(Column("clusterId") == cluster.id).fetchAll(db)
            }
            return (cluster, members)
        }
    }

    /// Re-runs clustering with the current `similarityThreshold` against
    /// already-indexed files — no re-scan of the source folders needed.
    /// Runs off the main thread so the progress text and spinner actually
    /// get a chance to render instead of the UI freezing until it's done.
    func recalculateSimilarClusters() {
        guard !isRecalculating else { return }
        isRecalculating = true
        recalculationStatus = "Starting…"

        let db = self.db
        let threshold = similarityThreshold

        Task.detached(priority: .userInitiated) {
            var recalcError: Error?
            do {
                let clusterer = DuplicateClusterer(db: db)
                _ = try clusterer.rebuildClusters(pHashThreshold: threshold) { status in
                    Task { @MainActor in
                        self.recalculationStatus = status
                    }
                }
            } catch {
                recalcError = error
            }

            await MainActor.run {
                self.isRecalculating = false
                self.recalculationStatus = ""
                try? self.reload()
                if let recalcError {
                    self.lastError = recalcError
                }
            }
        }
    }

    /// The full path to a member's file on disk, resolved via its Source's
    /// rootPath — members of the same cluster can belong to different
    /// sources, so this is per-file, not per-cluster.
    func fileURL(for media: MediaFile) -> URL? {
        guard let source = sourcesById[media.sourceId] else { return nil }
        return URL(fileURLWithPath: source.rootPath).appendingPathComponent(media.relativePath)
    }

    /// Moves the file to the macOS Trash (recoverable, not a permanent
    /// delete) and removes its indexed row (and, via cascade, its
    /// FaceObservation rows). Never deletes anything the caller didn't
    /// explicitly ask to move to Trash.
    func moveToTrash(_ media: MediaFile) throws {
        if let url = fileURL(for: media) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        try db.dbPool.write { db in
            _ = try MediaFile.deleteOne(db, key: media.id)
        }
        try reload()
    }
}

private enum DuplicatesTab: String, CaseIterable, Hashable {
    case exact = "Exact Duplicates"
    case similar = "Similar Duplicates"
}

struct DuplicatesView: View {
    @ObservedObject var viewModel: DuplicatesViewModel
    @State private var previewCluster: PreviewRequest?
    @State private var errorMessage: String?
    @State private var selectedTab: DuplicatesTab = .exact

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                GlassTabBar(
                    segments: DuplicatesTab.allCases,
                    title: { $0.rawValue },
                    selection: $selectedTab
                )
                .frame(width: 260)

                if selectedTab == .similar {
                    similarityControls
                }
            }
            .padding(.leading, 16)
            .padding(.trailing)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ClusterList(
                entries: selectedTab == .exact ? viewModel.exactClusters : viewModel.similarClusters,
                viewModel: viewModel,
                onSelect: { clusterId, index in previewCluster = PreviewRequest(clusterId: clusterId, startIndex: index) }
            )
        }
        .task {
            try? viewModel.reload()
        }
        .sheet(item: $previewCluster) { request in
            if let entry = viewModel.clusters.first(where: { $0.cluster.id == request.clusterId }) {
                MediaSlideshow(
                    items: entry.members,
                    startIndex: request.startIndex,
                    fileURL: { viewModel.fileURL(for: $0) },
                    suggestedKeeperId: entry.cluster.suggestedKeeperMediaFileId,
                    onTrash: { try viewModel.moveToTrash($0) },
                    errorMessage: $errorMessage,
                    onClose: { previewCluster = nil }
                )
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    private var similarityControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(viewModel.isRecalculating
                    ? viewModel.recalculationStatus
                    : "Similarity: within \(viewModel.similarityThreshold) bits difference (0 = nearly identical, higher = looser match)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.isRecalculating {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.similarityThreshold) },
                        set: { viewModel.similarityThreshold = Int($0) }
                    ),
                    in: Double(DuplicateClusterer.pHashThresholdRange.lowerBound)...Double(DuplicateClusterer.pHashThresholdRange.upperBound),
                    step: 1,
                    onEditingChanged: { isEditing in
                        // Auto-recalculate as soon as the user releases the
                        // slider (not on every intermediate drag tick).
                        if !isEditing {
                            viewModel.recalculateSimilarClusters()
                        }
                    }
                )
                .disabled(viewModel.isRecalculating)
                Button("Recalculate") {
                    viewModel.recalculateSimilarClusters()
                }
                .disabled(viewModel.isRecalculating)
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: viewModel.lastError == nil) { _, _ in
            if let error = viewModel.lastError {
                errorMessage = error.localizedDescription
                viewModel.lastError = nil
            }
        }
    }

    static func formattedSize(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct PreviewRequest: Identifiable {
    let clusterId: String
    let startIndex: Int
    var id: String { clusterId }
}

/// The scrollable list of clusters shown under either tab — identical
/// layout, just fed a different (already-filtered) set of entries.
private struct ClusterList: View {
    let entries: [(cluster: DuplicateCluster, members: [MediaFile])]
    @ObservedObject var viewModel: DuplicatesViewModel
    let onSelect: (String, Int) -> Void

    var body: some View {
        if entries.isEmpty {
            Text("No duplicates in this category.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(entries, id: \.cluster.id) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cluster (\(entry.members.count) files)")
                        .font(.headline)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(entry.cluster.id, 0) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 110), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(entry.members, id: \.id) { file in
                            VStack(spacing: 4) {
                                MediaThumbnailView(url: viewModel.fileURL(for: file), kind: file.kind, size: 90)
                                Text(file.relativePath)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if file.id == entry.cluster.suggestedKeeperMediaFileId {
                                    Text("Keeper").font(.caption2).foregroundStyle(.green)
                                }
                            }
                            .frame(width: 90)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let index = entry.members.firstIndex(where: { $0.id == file.id }) {
                                    onSelect(entry.cluster.id, index)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(GlassRowBackground())
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 20, leading: 12, bottom: 20, trailing: 12))
            }
            .scrollContentBackground(.hidden)
        }
    }
}
