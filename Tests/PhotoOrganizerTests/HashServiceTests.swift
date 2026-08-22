import Testing
import Foundation
import CoreGraphics
@testable import PhotoOrganizer

struct HashServiceTests {
    @Test func testPHashOfIdenticalImagesIsIdentical() throws {
        let imageA = Self.solidColorImage(gray: 100)
        let imageB = Self.solidColorImage(gray: 100)

        let hashA = try HashService.pHash(cgImage: imageA)
        let hashB = try HashService.pHash(cgImage: imageB)

        #expect(hashA == hashB)
    }

    @Test func testPHashDiscriminatesStructurallyDifferentImages() throws {
        // A checkerboard has strong inter-row brightness variation that a
        // per-row-average hash would wash out; a whole-image-average hash
        // should place it far from a plain gradient.
        let checkerboard = Self.checkerboardImage()
        let gradient = Self.verticalGradientImage()

        let checkerboardHash = try HashService.pHash(cgImage: checkerboard)
        let gradientHash = try HashService.pHash(cgImage: gradient)

        let distance = HashService.hammingDistance(checkerboardHash, gradientHash)
        #expect(distance > 10, "structurally different images should hash far apart, got distance \(distance)")
    }

    private static func solidColorImage(gray: UInt8, size: Int = 64) -> CGImage {
        var pixels = [UInt8](repeating: gray, count: size * size)
        return makeGrayImage(pixels: &pixels, size: size)
    }

    private static func checkerboardImage(size: Int = 64) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: size * size)
        for row in 0..<size {
            for col in 0..<size {
                pixels[row * size + col] = ((row / 8) + (col / 8)).isMultiple(of: 2) ? 255 : 0
            }
        }
        return makeGrayImage(pixels: &pixels, size: size)
    }

    private static func verticalGradientImage(size: Int = 64) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: size * size)
        for row in 0..<size {
            let value = UInt8((row * 255) / max(size - 1, 1))
            for col in 0..<size {
                pixels[row * size + col] = value
            }
        }
        return makeGrayImage(pixels: &pixels, size: size)
    }

    private static func makeGrayImage(pixels: inout [UInt8], size: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = pixels.withUnsafeMutableBytes { ptr in
            CGContext(
                data: ptr.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }
        return context!.makeImage()!
    }

    @Test func testSHA256IsStableForIdenticalBytes() throws {
        let url1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("identical content".utf8)
        try bytes.write(to: url1)
        try bytes.write(to: url2)

        let hash1 = try HashService.sha256(fileAt: url1)
        let hash2 = try HashService.sha256(fileAt: url2)

        #expect(hash1 == hash2)
    }

    @Test func testHammingDistanceOfIdenticalHashesIsZero() {
        let distance = HashService.hammingDistance(0b1010, 0b1010)
        #expect(distance == 0)
    }

    @Test func testHammingDistanceCountsDifferingBits() {
        let distance = HashService.hammingDistance(0b1010, 0b1000)
        #expect(distance == 1)
    }
}
