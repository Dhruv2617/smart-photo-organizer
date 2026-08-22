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

    private let db: DatabaseManager
    private let sourceManager: SourceManager
    private let indexer: Indexer

    init(db: DatabaseManager) {
        self.db = db
        self.sourceManager = SourceManager(db: db)
        self.indexer = Indexer(db: db)
        reload()
    }

    func addSource(url: URL) throws {
        _ = try sourceManager.addSource(url: url)
        reload()
    }

    /// Removes a source from the index only — never touches the original
    /// files on disk.
    func removeSource(_ source: Source) throws {
        try sourceManager.removeSource(id: source.id)
        reload()
    }

    /// Runs the actual scan off the main thread so the UI stays responsive,
    /// hopping back to the main actor only to publish progress/state.
    func rescanAll() {
        guard !isScanning else { return }
        isScanning = true
        scanStatus = "Starting…"
        scannedSourceIds.removeAll()

        let sourcesSnapshot = sources
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
        }
        statsBySourceId = stats
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
                        }
                        Button("Remove") { remove(source) }
                            .disabled(viewModel.isScanning)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        galleryTarget = source
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { remove(source) }
                    }
                }
            }
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
