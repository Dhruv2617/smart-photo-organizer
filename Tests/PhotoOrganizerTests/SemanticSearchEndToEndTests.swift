import Testing
import Foundation
import CoreGraphics
@testable import PhotoOrganizer

/// Real, non-mocked check that the bundled CLIP models actually load and
/// run via the real Core ML runtime (not just that the files exist) — this
/// is the thing coremltools' Python preview couldn't confirm (it hit a
/// BNNS graph compile warning on this machine; that's a different
/// execution path than Swift's MLModel, so this test is the actual proof).
struct SemanticSearchEndToEndTests {
    @Test func testTextEmbedderProducesNonDegenerate512DimVector() throws {
        let embedder = try TextEmbedder()
        let vector = try embedder.embed(query: "a photo of a dog")

        #expect(vector.count == 512)
        #expect(vector.contains { $0 != 0 })
    }

    @Test func testImageEmbedderProducesNonDegenerate512DimVector() throws {
        let embedder = try ImageEmbedder()
        let image = Self.solidColorImage(red: 200, green: 50, blue: 50, size: 224)

        let vector = try embedder.embed(cgImage: image)

        #expect(vector.count == 512)
        #expect(vector.contains { $0 != 0 })
    }

    @Test func testDifferentQueriesProduceDifferentEmbeddings() throws {
        let embedder = try TextEmbedder()
        let dog = try embedder.embed(query: "a photo of a dog")
        let beach = try embedder.embed(query: "a photo of a beach at sunset")

        let similarity = SemanticSearchService.cosineSimilarity(dog, beach)
        // Different concepts shouldn't be near-identical in embedding space.
        #expect(similarity < 0.99)
    }

    private static func solidColorImage(red: UInt8, green: UInt8, blue: UInt8, size: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            pixels[i * 4] = blue
            pixels[i * 4 + 1] = green
            pixels[i * 4 + 2] = red
            pixels[i * 4 + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = pixels.withUnsafeMutableBytes { ptr in
            CGContext(
                data: ptr.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )
        }
        return context!.makeImage()!
    }
}
