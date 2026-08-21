import Foundation
import CryptoKit
import CoreImage
import CoreGraphics
import ImageIO

enum HashService {
    static func sha256(fileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 8x8 average-hash style perceptual hash: downsample to 8x8 grayscale,
    /// compare each pixel to the row average, pack results into a 64-bit value.
    static func pHash(imageAt url: URL) throws -> UInt64 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HashError.unreadableImage
        }
        return pHash(cgImage: cgImage)
    }

    static func pHash(cgImage: CGImage) -> UInt64 {
        let size = 8
        var pixels = [UInt8](repeating: 0, count: size * size)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var hash: UInt64 = 0
        for row in 0..<size {
            let rowPixels = pixels[(row * size)..<((row + 1) * size)]
            let average = Double(rowPixels.reduce(0) { $0 + Int($1) }) / Double(size)
            for (col, value) in rowPixels.enumerated() {
                let bitIndex = row * size + col
                if Double(value) >= average {
                    hash |= (1 << UInt64(bitIndex))
                }
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    enum HashError: Error {
        case unreadableImage
    }
}
