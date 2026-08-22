import SwiftUI
import AppKit
import GRDB

/// All indexed media belonging to one source, as a grid gallery — the
/// "click a folder to see everything in it" view.
@MainActor
final class SourceGalleryViewModel: ObservableObject {
    @Published var items: [MediaFile] = []
    let source: Source

    private let db: DatabaseManager

    init(db: DatabaseManager, source: Source) {
        self.db = db
        self.source = source
    }

    func reload() throws {
        items = try db.dbPool.read { db in
            try MediaFile
                .filter(Column("sourceId") == source.id)
                .order(Column("relativePath"))
                .fetchAll(db)
        }
    }

    func fileURL(for media: MediaFile) -> URL? {
        URL(fileURLWithPath: source.rootPath).appendingPathComponent(media.relativePath)
    }

    /// Moves the file to the macOS Trash (recoverable, not a permanent
    /// delete) and removes its indexed row. Never deletes anything the
    /// caller didn't explicitly ask to move to Trash.
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

struct SourceGalleryView: View {
    @ObservedObject var viewModel: SourceGalleryViewModel
    @State private var previewIndex: PreviewIndex?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    @State private var showingConvertSheet = false
    @State private var isConverting = false
    @State private var conversionStatus = ""
    @State private var conversionSummary: String?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 8)]

    private var selectedItems: [MediaFile] {
        viewModel.items.filter { selectedIds.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Close") { dismiss() }
                Text(viewModel.source.displayName).font(.headline)
                Spacer()
                Text("\(viewModel.items.count) files").foregroundStyle(.secondary)
            }
            .padding()

            HStack {
                Button(isSelecting ? "Cancel Selection" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { selectedIds.removeAll() }
                }
                if isSelecting {
                    Button("Select All") { selectedIds = Set(viewModel.items.map(\.id)) }
                    Button("Select None") { selectedIds.removeAll() }
                    Spacer()
                    Text("\(selectedIds.count) selected").foregroundStyle(.secondary)
                    Button("Convert…") { showingConvertSheet = true }
                        .disabled(selectedIds.isEmpty || isConverting)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if isConverting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(conversionStatus).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if viewModel.items.isEmpty {
                Text("No indexed photos or videos in this folder yet. Try Rescan All.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, file in
                            SelectableThumbnail(
                                url: viewModel.fileURL(for: file),
                                kind: file.kind,
                                isSelecting: isSelecting,
                                isSelected: selectedIds.contains(file.id)
                            )
                            .onTapGesture {
                                if isSelecting {
                                    if selectedIds.contains(file.id) {
                                        selectedIds.remove(file.id)
                                    } else {
                                        selectedIds.insert(file.id)
                                    }
                                } else {
                                    previewIndex = PreviewIndex(value: index)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .task {
            try? viewModel.reload()
        }
        .sheet(item: $previewIndex) { request in
            MediaSlideshow(
                items: viewModel.items,
                startIndex: request.value,
                fileURL: { viewModel.fileURL(for: $0) },
                onTrash: { try viewModel.moveToTrash($0) },
                errorMessage: $errorMessage,
                onClose: { previewIndex = nil }
            )
        }
        .sheet(isPresented: $showingConvertSheet) {
            ConvertSheet(
                items: selectedItems,
                fileURL: { viewModel.fileURL(for: $0) },
                onStart: { photoFormat, videoFormat, destination in
                    showingConvertSheet = false
                    runConversion(photoFormat: photoFormat, videoFormat: videoFormat, destination: destination)
                },
                onCancel: { showingConvertSheet = false }
            )
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
        .alert("Conversion complete", isPresented: .constant(conversionSummary != nil), actions: {
            Button("OK") { conversionSummary = nil }
        }, message: {
            Text(conversionSummary ?? "")
        })
    }

    private func runConversion(photoFormat: PhotoFormat, videoFormat: VideoFormat, destination: URL) {
        let items = selectedItems
        let resolveURL: (MediaFile) -> URL? = { viewModel.fileURL(for: $0) }
        isConverting = true
        conversionStatus = "Starting…"

        Task {
            var succeeded = 0
            var failed = 0
            for (i, item) in items.enumerated() {
                conversionStatus = "\(i + 1)/\(items.count): \(item.relativePath)"
                guard let sourceURL = resolveURL(item) else { failed += 1; continue }
                do {
                    if item.kind == "video" {
                        _ = try await MediaConverter.convertVideo(at: sourceURL, to: videoFormat, destinationFolder: destination)
                    } else {
                        _ = try await Task.detached(priority: .userInitiated) {
                            try MediaConverter.convertPhoto(at: sourceURL, to: photoFormat, destinationFolder: destination)
                        }.value
                    }
                    succeeded += 1
                } catch {
                    failed += 1
                }
            }
            isConverting = false
            conversionStatus = ""
            isSelecting = false
            selectedIds.removeAll()
            conversionSummary = failed == 0
                ? "Converted \(succeeded) file\(succeeded == 1 ? "" : "s") to \(destination.lastPathComponent)."
                : "Converted \(succeeded), failed \(failed). Saved to \(destination.lastPathComponent)."
        }
    }
}

private struct PreviewIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

/// A gallery thumbnail with a selection checkmark overlay when in select mode.
private struct SelectableThumbnail: View {
    let url: URL?
    let kind: String
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MediaThumbnailView(url: url, kind: kind, size: 130)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                )
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .white)
                    .background(Circle().fill(.black.opacity(0.4)))
                    .padding(4)
            }
        }
    }
}

/// Lets the user pick output format(s) — scoped to what's actually
/// selected (photo format only shown if photos are selected, same for
/// video) — then a destination folder, before kicking off conversion.
private struct ConvertSheet: View {
    let items: [MediaFile]
    let fileURL: (MediaFile) -> URL?
    let onStart: (PhotoFormat, VideoFormat, URL) -> Void
    let onCancel: () -> Void

    @State private var photoFormat: PhotoFormat = .jpeg
    @State private var videoFormat: VideoFormat = .mp4

    private var hasPhotos: Bool { items.contains { $0.kind == "photo" } }
    private var hasVideos: Bool { items.contains { $0.kind == "video" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Convert \(items.count) file\(items.count == 1 ? "" : "s")").font(.headline)

            if hasPhotos {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Photo format").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $photoFormat) {
                        ForEach(PhotoFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if hasVideos {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Video format").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $videoFormat) {
                        ForEach(VideoFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            HStack {
                Button("Cancel") { onCancel() }
                Spacer()
                Button("Choose Destination & Convert…") { presentFolderPickerAndStart() }
            }
        }
        .padding()
        .frame(minWidth: 400)
    }

    private func presentFolderPickerAndStart() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Converted Files"
        if panel.runModal() == .OK, let url = panel.url {
            onStart(photoFormat, videoFormat, url)
        }
    }
}
