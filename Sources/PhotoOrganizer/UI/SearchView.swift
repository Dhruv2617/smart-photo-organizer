import SwiftUI
import AppKit
import GRDB

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var results: [MediaFile] = []
    @Published var isSearching = false
    @Published var lastError: Error?
    @Published var hasSearched = false

    private let db: DatabaseManager
    private var sourcesById: [String: Source] = [:]

    init(db: DatabaseManager) {
        self.db = db
    }

    func fileURL(for media: MediaFile) -> URL? {
        guard let source = sourcesById[media.sourceId] else { return nil }
        return URL(fileURLWithPath: source.rootPath).appendingPathComponent(media.relativePath)
    }

    /// Moves the file to the macOS Trash (recoverable, not a permanent
    /// delete) and removes its indexed row, same as every other viewer in
    /// this app. Also drops it from the current results list so the
    /// slideshow's item count stays consistent without re-running the
    /// search.
    func moveToTrash(_ media: MediaFile) throws {
        if let url = fileURL(for: media) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        try db.dbPool.write { db in
            _ = try MediaFile.deleteOne(db, key: media.id)
        }
        results.removeAll { $0.id == media.id }
    }

    /// Runs the actual embedding + search off the main thread — loading
    /// the CLIP text model and scanning every stored embedding is real
    /// work, not something to do synchronously on the UI thread.
    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isSearching else { return }
        isSearching = true
        hasSearched = true

        let db = self.db

        Task.detached(priority: .userInitiated) {
            var searchError: Error?
            var found: [MediaFile] = []
            do {
                let service = SemanticSearchService(db: db)
                found = try service.search(query: trimmed)
            } catch {
                searchError = error
            }

            let sources = (try? await db.dbPool.read { db in try Source.fetchAll(db) }) ?? []

            await MainActor.run {
                self.sourcesById = sources.reduce(into: [:]) { $0[$1.id] = $1 }
                self.results = found
                self.isSearching = false
                if let searchError {
                    self.lastError = searchError
                }
            }
        }
    }
}

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var query = ""
    @State private var previewIndex: PreviewIndex?
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search photos and videos, e.g. \"beach at sunset\"", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.search(query: query) }
                Button("Search") { viewModel.search(query: query) }
                    .disabled(viewModel.isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()

            if viewModel.isSearching {
                ProgressView("Searching…")
                    .padding(.bottom, 8)
            }

            if !viewModel.isSearching && viewModel.hasSearched && viewModel.results.isEmpty {
                Text("No matches found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.hasSearched {
                Text("Search uses on-device AI (CLIP) to match photos/videos by what's actually in them, not just filenames.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, file in
                            MediaThumbnailView(url: viewModel.fileURL(for: file), kind: file.kind, size: 130)
                                .onTapGesture { previewIndex = PreviewIndex(value: index) }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $previewIndex) { request in
            MediaSlideshow(
                items: viewModel.results,
                startIndex: request.value,
                fileURL: { viewModel.fileURL(for: $0) },
                onTrash: { try viewModel.moveToTrash($0) },
                errorMessage: $errorMessage,
                onClose: { previewIndex = nil }
            )
        }
        .onChange(of: viewModel.lastError == nil) { _, _ in
            if let error = viewModel.lastError {
                errorMessage = error.localizedDescription
                viewModel.lastError = nil
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
    }
}

private struct PreviewIndex: Identifiable {
    let value: Int
    var id: Int { value }
}
