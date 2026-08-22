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
    /// compare each pixel to the WHOLE-IMAGE average, pack results into a
    /// 64-bit value. (Comparing to the per-row average instead — an earlier
    /// version of this function did that — throws away all inter-row
    /// brightness information: it guarantees close to half the bits in
    /// every row are set regardless of the image's actual content, which
    /// makes structurally different images hash closer together than they
    /// should, especially visible at looser similarity thresholds.)
    static func pHash(imageAt url: URL) throws -> UInt64 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HashError.unreadableImage
        }
        return try pHash(cgImage: cgImage)
    }

    static func pHash(cgImage: CGImage) throws -> UInt64 {
        let size = 8
        var pixels = [UInt8](repeating: 0, count: size * size)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        try pixels.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                throw HashError.unreadableImage
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        }

        let average = Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)

        var hash: UInt64 = 0
        for (bitIndex, value) in pixels.enumerated() {
            if Double(value) >= average {
                hash |= (1 << UInt64(bitIndex))
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
