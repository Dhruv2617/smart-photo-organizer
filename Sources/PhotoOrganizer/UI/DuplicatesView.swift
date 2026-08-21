import SwiftUI
import GRDB

@MainActor
final class DuplicatesViewModel: ObservableObject {
    @Published var clusters: [(cluster: DuplicateCluster, members: [MediaFile])] = []

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func reload() throws {
        let allClusters = try db.dbPool.read { db in try DuplicateCluster.fetchAll(db) }
        clusters = try allClusters.map { cluster in
            let members = try db.dbPool.read { db in
                try MediaFile.filter(Column("clusterId") == cluster.id).fetchAll(db)
            }
            return (cluster, members)
        }
    }
}

struct DuplicatesView: View {
    @ObservedObject var viewModel: DuplicatesViewModel

    var body: some View {
        List(viewModel.clusters, id: \.cluster.id) { entry in
            VStack(alignment: .leading) {
                Text("Cluster (\(entry.members.count) files)").font(.headline)
                ForEach(entry.members, id: \.id) { file in
                    HStack {
                        Text(file.relativePath)
                        if file.id == entry.cluster.suggestedKeeperMediaFileId {
                            Text("Suggested keeper").font(.caption).foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .task {
            try? viewModel.reload()
        }
    }
}
