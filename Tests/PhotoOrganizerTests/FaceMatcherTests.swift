import Testing
import CoreGraphics
import Vision
import Foundation
@testable import PhotoOrganizer

struct FaceMatcherTests {
    /// Builds a solid-color image and runs Vision's feature-print request on
    /// it directly, returning the archived `VNFeaturePrintObservation` blob
    /// in the same shape `FaceDetector` produces for a cropped face region.
    private func featurePrintData(gray: UInt8) throws -> Data {
        let size = 64
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: gray, count: size * size)
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                 bytesPerRow: size, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let image = context.makeImage()!
        return try featurePrintData(for: image)
    }

    /// Builds a checkerboard pattern with the given tile size (in pixels) so
    /// two very different tile sizes produce visually distinct images.
    private func featurePrintData(checkerTile: Int) throws -> Data {
        let size = 64
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let isLight = ((x / checkerTile) + (y / checkerTile)) % 2 == 0
                pixels[y * size + x] = isLight ? 255 : 0
            }
        }
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                 bytesPerRow: size, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let image = context.makeImage()!
        return try featurePrintData(for: image)
    }

    private func featurePrintData(for image: CGImage) throws -> Data {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else {
            throw FaceMatcherError.unarchiveFailed
        }
        return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    @Test func testMatchOrCreateMakesNewIdentityForDissimilarFeaturePrints() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let matcher = FaceMatcher(db: db)

        let first = try matcher.matchOrCreateUnnamedIdentity(embedding: featurePrintData(gray: 0))
        let second = try matcher.matchOrCreateUnnamedIdentity(embedding: featurePrintData(checkerTile: 4))

        #expect(first.id != second.id)
    }

    @Test func testMatchOrCreateReusesSameIdentityForIdenticalEmbedding() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let matcher = FaceMatcher(db: db)
        let embedding = try featurePrintData(gray: 128)

        let first = try matcher.matchOrCreateUnnamedIdentity(embedding: embedding)
        let second = try matcher.matchOrCreateUnnamedIdentity(embedding: embedding)

        #expect(first.id == second.id)
    }

    @Test func testLabelIdentityPersistsLabel() throws {
        let db = try DatabaseManager(path: NSTemporaryDirectory() + "test-\(UUID().uuidString).sqlite")
        let matcher = FaceMatcher(db: db)
        let embedding = try featurePrintData(gray: 64)

        let identity = try matcher.matchOrCreateUnnamedIdentity(embedding: embedding)
        try matcher.labelIdentity(identity.id, as: "Alice")

        let reloaded = try db.dbPool.read { db in try FaceIdentity.fetchOne(db, key: identity.id) }
        #expect(reloaded?.label == "Alice")
    }
}
