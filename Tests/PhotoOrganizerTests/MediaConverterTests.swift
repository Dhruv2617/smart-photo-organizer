import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PhotoOrganizer

struct MediaConverterTests {
    @Test func testConvertPhotoWritesFileInRequestedFormat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("photo.png")
        try Self.writeSolidColorPNG(to: sourceURL, width: 32, height: 32)
        let destinationFolder = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let resultURL = try MediaConverter.convertPhoto(at: sourceURL, to: .jpeg, destinationFolder: destinationFolder)

        #expect(resultURL.pathExtension == "jpg")
        #expect(resultURL.deletingLastPathComponent().path == destinationFolder.path)
        #expect(FileManager.default.fileExists(atPath: resultURL.path))
        // Original untouched.
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))

        let convertedSource = CGImageSourceCreateWithURL(resultURL as CFURL, nil)
        #expect(convertedSource != nil)
    }

    @Test func testConvertPhotoAvoidsOverwritingExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("photo.png")
        try Self.writeSolidColorPNG(to: sourceURL, width: 16, height: 16)

        let firstResult = try MediaConverter.convertPhoto(at: sourceURL, to: .png, destinationFolder: root)
        let secondResult = try MediaConverter.convertPhoto(at: sourceURL, to: .png, destinationFolder: root)

        #expect(firstResult.path != secondResult.path)
        #expect(FileManager.default.fileExists(atPath: firstResult.path))
        #expect(FileManager.default.fileExists(atPath: secondResult.path))
    }

    private static func writeSolidColorPNG(to url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            struct WriteError: Error {}
            throw WriteError()
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
    }
}
