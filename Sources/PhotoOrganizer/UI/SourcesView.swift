import SwiftUI
import AppKit

@MainActor
final class SourcesViewModel: ObservableObject {
    @Published var sources: [Source] = []

    private let sourceManager: SourceManager
    private let indexer: Indexer

    init(db: DatabaseManager) {
        self.sourceManager = SourceManager(db: db)
        self.indexer = Indexer(db: db)
        reload()
    }

    func addSource(url: URL) throws {
        _ = try sourceManager.addSource(url: url)
        reload()
    }

    func rescanAll() throws {
        for source in sources {
            _ = try indexer.indexSource(source)
        }
        reload()
    }

    private func reload() {
        try? sourceManager.refreshOnlineStatus()
        sources = (try? sourceManager.allSources()) ?? []
    }
}

struct SourcesView: View {
    @ObservedObject var viewModel: SourcesViewModel
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            List(viewModel.sources, id: \.id) { source in
                HStack {
                    Text(source.displayName)
                    Spacer()
                    Text(source.isOnline ? "Online" : "Offline")
                        .foregroundStyle(source.isOnline ? .green : .secondary)
                }
            }
            HStack {
                Button("Add Folder…") { presentFolderPicker() }
                Button("Rescan All") { rescan() }
            }
            .padding()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
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

    private func rescan() {
        do {
            try viewModel.rescanAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
