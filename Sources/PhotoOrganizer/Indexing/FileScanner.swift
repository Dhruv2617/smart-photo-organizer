import Foundation

enum MediaKind {
    case photo
    case video
}

struct ScannedFile {
    let url: URL
    let kind: MediaKind
}

enum FileScanner {
    static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "gif", "bmp"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi"]

    static func scan(root: URL) -> [ScannedFile] {
        var results: [ScannedFile] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if photoExtensions.contains(ext) {
                results.append(ScannedFile(url: url, kind: .photo))
            } else if videoExtensions.contains(ext) {
                results.append(ScannedFile(url: url, kind: .video))
            }
        }
        return results
    }
}
