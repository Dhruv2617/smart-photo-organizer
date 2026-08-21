import SwiftUI
import AppKit
import AVKit
import GRDB

/// Two-finger trackpad swipes arrive as `NSEvent` scroll-wheel events with
/// horizontal delta, not as a SwiftUI `DragGesture` (that only fires for
/// click-drag / single-finger touch). A local event monitor is the
/// reliable way to catch them regardless of SwiftUI view hit-testing.
@MainActor
final class TrackpadSwipeMonitor: ObservableObject {
    var onSwipeLeft: () -> Void = {}
    var onSwipeRight: () -> Void = {}

    private var monitor: Any?
    private var accumulatedDeltaX: CGFloat = 0
    private var didTriggerThisGesture = false

    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Ignore vertical scrolling and plain mouse-wheel scroll (no phase).
        guard event.phase != [] || event.momentumPhase != [] else { return }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }

        if event.phase.contains(.began) {
            accumulatedDeltaX = 0
            didTriggerThisGesture = false
        }
        accumulatedDeltaX += event.scrollingDeltaX

        guard !didTriggerThisGesture else { return }
        let threshold: CGFloat = 60
        if accumulatedDeltaX < -threshold {
            didTriggerThisGesture = true
            onSwipeLeft()
        } else if accumulatedDeltaX > threshold {
            didTriggerThisGesture = true
            onSwipeRight()
        }
    }
}

@MainActor
final class DuplicatesViewModel: ObservableObject {
    @Published var clusters: [(cluster: DuplicateCluster, members: [MediaFile])] = []
    @Published var similarityThreshold: Int = DuplicateClusterer.defaultPHashThreshold
    @Published var isRecalculating = false

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
    func recalculateSimilarClusters() throws {
        isRecalculating = true
        defer { isRecalculating = false }
        let clusterer = DuplicateClusterer(db: db)
        _ = try clusterer.rebuildClusters(pHashThreshold: similarityThreshold)
        try reload()
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

private enum DuplicatesTab: String, CaseIterable {
    case exact = "Exact Duplicates"
    case similar = "Similar Duplicates"
}

struct DuplicatesView: View {
    @ObservedObject var viewModel: DuplicatesViewModel
    @State private var previewCluster: PreviewRequest?
    @State private var errorMessage: String?
    @State private var selectedTab: DuplicatesTab = .exact

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(DuplicatesTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if selectedTab == .similar {
                similarityControls
            }

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
                ClusterSlideshow(
                    viewModel: viewModel,
                    cluster: entry.cluster,
                    members: entry.members,
                    startIndex: request.startIndex,
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
                Text("Similarity: within \(viewModel.similarityThreshold) bits difference (0 = nearly identical, higher = looser match)")
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
                    step: 1
                )
                Button("Recalculate") {
                    do {
                        try viewModel.recalculateSimilarClusters()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .disabled(viewModel.isRecalculating)
            }
        }
        .padding([.horizontal, .bottom])
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
                VStack(alignment: .leading) {
                    Text("Cluster (\(entry.members.count) files)")
                        .font(.headline)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(entry.cluster.id, 0) }
                    ForEach(entry.members, id: \.id) { file in
                        HStack {
                            DuplicateThumbnail(url: viewModel.fileURL(for: file), kind: file.kind)
                            VStack(alignment: .leading) {
                                Text(file.relativePath)
                                if let sizeText = DuplicatesView.formattedSize(file.fileSizeBytes) {
                                    Text(sizeText).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if file.id == entry.cluster.suggestedKeeperMediaFileId {
                                Text("Suggested keeper").font(.caption).foregroundStyle(.green)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let index = entry.members.firstIndex(where: { $0.id == file.id }) {
                                onSelect(entry.cluster.id, index)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Full-size, side-by-side-in-time comparison of every file in one
/// duplicate cluster: prev/next through members, Move to Trash right
/// there so the user can decide while looking at the enlarged photo.
private struct ClusterSlideshow: View {
    @ObservedObject var viewModel: DuplicatesViewModel
    let cluster: DuplicateCluster
    @State var members: [MediaFile]
    @State private var index: Int
    @Binding var errorMessage: String?
    let onClose: () -> Void
    @State private var pendingTrash: MediaFile?
    @FocusState private var isFocused: Bool
    @StateObject private var swipeMonitor = TrackpadSwipeMonitor()

    init(viewModel: DuplicatesViewModel, cluster: DuplicateCluster, members: [MediaFile], startIndex: Int, errorMessage: Binding<String?>, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.cluster = cluster
        self._members = State(initialValue: members)
        self._index = State(initialValue: startIndex)
        self._errorMessage = errorMessage
        self.onClose = onClose
    }

    private var current: MediaFile? {
        members.indices.contains(index) ? members[index] : nil
    }

    private func goToNext() {
        if index < members.count - 1 { index += 1 }
    }

    private func goToPrevious() {
        if index > 0 { index -= 1 }
    }

    private func trashCurrent() {
        guard let current else { return }
        pendingTrash = current
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Close") { onClose() }
                Spacer()
                if !members.isEmpty {
                    Text("\(index + 1) of \(members.count)")
                        .foregroundStyle(.secondary)
                }
            }

            if let current, let url = viewModel.fileURL(for: current) {
                Group {
                    if current.kind == "video" {
                        VideoPreview(url: url)
                    } else {
                        FullSizePhoto(url: url)
                    }
                }
                .id(current.id)
                .gesture(
                    // Click-drag fallback (mouse or single-finger touch).
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.width < -40 {
                                goToNext()
                            } else if value.translation.width > 40 {
                                goToPrevious()
                            }
                        }
                )

                HStack {
                    Text(current.relativePath)
                    if let sizeText = DuplicatesView.formattedSize(current.fileSizeBytes) {
                        Text(sizeText)
                    }
                    if let width = current.width, let height = current.height {
                        Text("\(width)×\(height)")
                    }
                    if current.id == cluster.suggestedKeeperMediaFileId {
                        Text("Suggested keeper").font(.caption).foregroundStyle(.green)
                    }
                }
                .foregroundStyle(.secondary)

                HStack {
                    Button("◀ Previous") { goToPrevious() }
                        .disabled(index == 0)
                    Spacer()
                    Button("Move to Trash", role: .destructive) { trashCurrent() }
                    Spacer()
                    Button("Next ▶") { goToNext() }
                        .disabled(index >= members.count - 1)
                }
            } else {
                Text("No files left in this cluster.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .padding()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .task {
            isFocused = true
            swipeMonitor.onSwipeLeft = { goToNext() }
            swipeMonitor.onSwipeRight = { goToPrevious() }
            swipeMonitor.start()
        }
        .onDisappear { swipeMonitor.stop() }
        .onKeyPress(.leftArrow) { goToPrevious(); return .handled }
        .onKeyPress(.rightArrow) { goToNext(); return .handled }
        .onKeyPress(.delete) { trashCurrent(); return .handled }
        .onKeyPress(.deleteForward) { trashCurrent(); return .handled }
        .confirmationDialog(
            "Move this file to Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { file in
            Button("Move to Trash", role: .destructive) {
                do {
                    try viewModel.moveToTrash(file)
                    members.removeAll { $0.id == file.id }
                    if index >= members.count { index = max(0, members.count - 1) }
                    if members.isEmpty { onClose() }
                } catch {
                    errorMessage = error.localizedDescription
                }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: { file in
            Text("\(file.relativePath) will be moved to the Trash. This can be undone from the Trash until it's emptied.")
        }
    }
}

private struct FullSizePhoto: View {
    let url: URL
    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            nsImage = NSImage(contentsOf: url)
        }
    }
}

/// Plays a video file with standard AVKit transport controls, instead of
/// trying to decode it as a still image (which silently never resolves).
private struct VideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                AVPlayerContainerView(player: player)
                    .frame(minHeight: 300)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}

/// Wraps AppKit's `AVPlayerView` directly instead of using SwiftUI's
/// `VideoPlayer` — on this toolchain, `VideoPlayer` crashes at runtime in a
/// bundle-less `swift run` executable (Swift can't resolve `AVPlayerView`'s
/// metadata via mangled-name demangling outside a proper .app bundle).
/// Going through `NSViewRepresentable` with the raw AppKit class avoids
/// whatever generic-specialization path `VideoPlayer` takes that trips it.
private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

/// Renders a photo thumbnail, or a video-camera placeholder icon for
/// videos and any file whose thumbnail couldn't be decoded.
private struct DuplicateThumbnail: View {
    let url: URL?
    let kind: String
    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: kind == "video" ? "video.fill" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .task(id: url) {
            guard let url, kind == "photo" else { return }
            nsImage = MediaThumbnail.image(for: url)
        }
    }
}
