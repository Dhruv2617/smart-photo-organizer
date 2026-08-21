import Testing
import Foundation
@testable import PhotoOrganizer

struct FileScannerTests {
    @Test func testScanFindsImagesAndVideosAndSkipsOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        try Data().write(to: root.appendingPathComponent("photo.jpg"))
        try Data().write(to: sub.appendingPathComponent("clip.mov"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let results = FileScanner.scan(root: root)

        #expect(results.count == 2)
        #expect(results.contains { $0.url.lastPathComponent == "photo.jpg" && $0.kind == .photo })
        #expect(results.contains { $0.url.lastPathComponent == "clip.mov" && $0.kind == .video })
    }
}
