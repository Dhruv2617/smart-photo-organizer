import SwiftUI
import AppKit
import GRDB

struct SourceStats {
    var photoCount = 0
    var videoCount = 0
    var totalBytes: Int64 = 0

    var totalFiles: Int { photoCount + videoCount }

    static func += (lhs: inout SourceStats, rhs: SourceStats) {
        lhs.photoCount += rhs.photoCount
        lhs.videoCount += rhs.videoCount
        lhs.totalBytes += rhs.totalBytes
    }
}

@MainActor
final class SourcesViewModel: ObservableObject {
    @Published var sources: [Source] = []
    @Published var statsBySourceId: [String: SourceStats] = [:]
    @Published var isScanning = false
    @Published var scanStatus: String = ""
    @Published var lastError: Error?
    /// The source currently being scanned, so its row can show "Scanning…"
    /// distinctly from the "Online"/"Offline" drive-availability label —
    /// those two ideas were easy to read as the same thing otherwise.
    @Published var currentlyScanningSourceId: String?
    /// Sources that have already had their turn in the current scan pass,
    /// so rows still waiting can show "Queued" instead of looking identical
    /// to ones already done.
    @Published var scannedSourceIds: Set<String> = []
    /// True for a source whose on-disk photo/video count no longer matches
    /// what's indexed (new files dropped onto the drive, or files removed)
    /// — surfaced as a per-row "Rescan" prompt instead of making the user
    /// guess whether "Rescan All" is needed.
    @Published var needsRescanBySourceId: [String: Bool] = [:]

    private let db: DatabaseManager
    private let sourceManager: SourceManager
    private let indexer: Indexer

    init(db: DatabaseManager) {
        self.db = db
        self.sourceManager = SourceManager(db: db)
        self.indexer = Indexer(db: db)
        reload()
    }

    /// Adds the folder and immediately scans it — no need for the user to
    /// separately hit "Rescan All" right after connecting a new source.
    func addSource(url: URL) throws {
        let source = try sourceManager.addSource(url: url)
        reload()
        scanSource(source)
    }

    /// Removes a source from the index only — never touches the original
    /// files on disk.
    func removeSource(_ source: Source) throws {
        try sourceManager.removeSource(id: source.id)
        reload()
    }

    func rescanAll() {
        runScan(sources)
    }

    /// Scans just one source (used right after adding it, so a freshly
    /// connected folder doesn't just sit there unindexed until the user
    /// remembers to hit "Rescan All").
    func scanSource(_ source: Source) {
        runScan([source])
    }

    /// Runs the actual scan off the main thread so the UI stays responsive,
    /// hopping back to the main actor only to publish progress/state.
    private func runScan(_ sourcesSnapshot: [Source]) {
        guard !isScanning else { return }
        isScanning = true
        scanStatus = "Starting…"
        scannedSourceIds.removeAll()

        let indexer = self.indexer
        let db = self.db

        Task.detached(priority: .userInitiated) {
            var scanError: Error?
            for (sourceIndex, source) in sourcesSnapshot.enumerated() {
                await MainActor.run { self.currentlyScanningSourceId = source.id }
                do {
                    _ = try indexer.indexSource(source) { processed, total in
                        Task { @MainActor in
                            self.scanStatus = "Source \(sourceIndex + 1)/\(sourcesSnapshot.count): \(processed)/\(total) files"
                        }
                    }
                } catch {
                    scanError = error
                    break
                }
                _ = await MainActor.run { self.scannedSourceIds.insert(source.id) }
            }
            await MainActor.run { self.currentlyScanningSourceId = nil }
            if scanError == nil {
                await MainActor.run { self.scanStatus = "Finding duplicates…" }
                do {
                    let clusterer = DuplicateClusterer(db: db)
                    _ = try clusterer.rebuildClusters()
                } catch {
                    scanError = error
                }
            }

            await MainActor.run {
                self.isScanning = false
                self.scanStatus = ""
                self.scannedSourceIds.removeAll()
                self.reload()
                if let scanError {
                    self.lastError = scanError
                }
            }
        }
    }

    var overallStats: SourceStats {
        statsBySourceId.values.reduce(into: SourceStats()) { $0 += $1 }
    }

    /// Not private: tests call this directly to refresh stats after
    /// inserting MediaFile rows outside the normal indexSource/addSource
    /// flow.
    func reload() {
        try? sourceManager.refreshOnlineStatus()
        sources = (try? sourceManager.allSources()) ?? []
        loadStats()
    }

    private func loadStats() {
        var stats: [String: SourceStats] = [:]
        var needsRescan: [String: Bool] = [:]
        for source in sources {
            let files = (try? db.dbPool.read { db in
                try MediaFile.filter(Column("sourceId") == source.id).fetchAll(db)
            }) ?? []
            var stat = SourceStats()
            for file in files {
                if file.kind == "video" {
                    stat.videoCount += 1
                } else {
                    stat.photoCount += 1
                }
                stat.totalBytes += file.fileSizeBytes ?? 0
            }
            stats[source.id] = stat

            // Cheap directory walk (no hashing) to compare against what's
            // indexed — mismatched counts mean files were added/removed on
            // the drive since the last scan. Skipped while offline: an
            // unreachable drive enumerates as empty and would otherwise
            // always read as "needs rescan".
            if source.isOnline {
                let root = URL(fileURLWithPath: source.rootPath).resolvingSymlinksInPath()
                let diskCount = FileScanner.scan(root: root).count
                needsRescan[source.id] = diskCount != files.count
            }
        }
        statsBySourceId = stats
        needsRescanBySourceId = needsRescan
    }

    func galleryViewModel(for source: Source) -> SourceGalleryViewModel {
        SourceGalleryViewModel(db: db, source: source)
    }
}

struct SourcesView: View {
    @ObservedObject var viewModel: SourcesViewModel
    @State private var errorMessage: String?
    @State private var galleryTarget: Source?

    var body: some View {
        VStack {
            List {
                ForEach(viewModel.sources, id: \.id) { source in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName)
                            if let stats = viewModel.statsBySourceId[source.id] {
                                Text(Self.statsLine(stats))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if viewModel.currentlyScanningSourceId == source.id {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Scanning…").foregroundStyle(.orange)
                            }
                        } else if viewModel.isScanning && !viewModel.scannedSourceIds.contains(source.id) {
                            Text("Queued").foregroundStyle(.secondary)
                        } else {
                            Text(source.isOnline ? "Online" : "Offline")
                                .foregroundStyle(source.isOnline ? .green : .secondary)
                            if viewModel.needsRescanBySourceId[source.id] == true {
                                Button("Rescan (new files found)") { viewModel.scanSource(source) }
                                    .foregroundStyle(.orange)
                            }
                        }
                        Button("Rescan") { viewModel.scanSource(source) }
                            .disabled(viewModel.isScanning || !source.isOnline)
                        Button("Remove") { remove(source) }
                            .disabled(viewModel.isScanning)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        galleryTarget = source
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { remove(source) }
                    }
                    .listRowBackground(GlassRowBackground())
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
            .scrollContentBackground(.hidden)
            if viewModel.isScanning {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.scanStatus)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }
            if !viewModel.sources.isEmpty {
                Text(Self.overallStatsLine(viewModel.overallStats))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            HStack {
                Button("Add Folder…") { presentFolderPicker() }
                    .disabled(viewModel.isScanning)
                Button("Rescan All") { viewModel.rescanAll() }
                    .disabled(viewModel.isScanning || viewModel.sources.isEmpty)
            }
            .padding()
        }
        .onChange(of: viewModel.lastError == nil) { _, _ in
            if let error = viewModel.lastError {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil; viewModel.lastError = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
        .sheet(item: $galleryTarget) { source in
            SourceGalleryView(viewModel: viewModel.galleryViewModel(for: source))
        }
    }

    private static func statsLine(_ stats: SourceStats) -> String {
        "\(stats.totalFiles) files (\(stats.photoCount) photos, \(stats.videoCount) videos) · \(formattedSize(stats.totalBytes))"
    }

    private static func overallStatsLine(_ stats: SourceStats) -> String {
        "Overall: \(stats.totalFiles) files (\(stats.photoCount) photos, \(stats.videoCount) videos) · \(formattedSize(stats.totalBytes)) total"
    }

    private static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func remove(_ source: Source) {
        do {
            try viewModel.removeSource(source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try viewModel.addSource(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

}
