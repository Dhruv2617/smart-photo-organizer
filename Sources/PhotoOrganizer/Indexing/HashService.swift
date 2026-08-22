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

    /// DCT-based perceptual hash (the "pHash" algorithm): downsample to
    /// 32x32 grayscale, take a 2D discrete cosine transform, keep only the
    /// top-left 8x8 block of LOW-FREQUENCY coefficients (an image's coarse
    /// structure — the part two perceptually similar photos actually
    /// share), and set each hash bit by comparing that coefficient to the
    /// block's median. This discriminates far better than a plain
    /// average-hash (comparing raw downsampled pixel brightness): two
    /// different photos that happen to have similar overall brightness/
    /// composition can still average-hash close together, but their
    /// frequency-domain structure is usually quite different.
    static func pHash(imageAt url: URL) throws -> UInt64 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HashError.unreadableImage
        }
        return try pHash(cgImage: cgImage)
    }

    static func pHash(cgImage: CGImage) throws -> UInt64 {
        let size = 32
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

        // 2D DCT-II is separable: transform rows first, then columns of the
        // result. Only the first `lowFreq` coefficients are ever needed
        // (the hash only uses the top-left 8x8 low-frequency block), so
        // both passes stop there instead of computing the full 32x32
        // transform.
        let lowFreq = 8

        var rowCoeffs = [[Double]](repeating: [Double](repeating: 0, count: lowFreq), count: size)
        for x in 0..<size {
            for v in 0..<lowFreq {
                var sum = 0.0
                for y in 0..<size {
                    let value = Double(pixels[x * size + y])
                    sum += value * cos(Double.pi / Double(size) * (Double(y) + 0.5) * Double(v))
                }
                let alpha = v == 0 ? (1.0 / Double(size)).squareRoot() : (2.0 / Double(size)).squareRoot()
                rowCoeffs[x][v] = alpha * sum
            }
        }

        var block = [Double](repeating: 0, count: lowFreq * lowFreq)
        for u in 0..<lowFreq {
            for v in 0..<lowFreq {
                var sum = 0.0
                for x in 0..<size {
                    sum += rowCoeffs[x][v] * cos(Double.pi / Double(size) * (Double(x) + 0.5) * Double(u))
                }
                let alpha = u == 0 ? (1.0 / Double(size)).squareRoot() : (2.0 / Double(size)).squareRoot()
                block[u * lowFreq + v] = alpha * sum
            }
        }

        let median = block.sorted()[block.count / 2]
        var hash: UInt64 = 0
        for (bitIndex, value) in block.enumerated() {
            if value > median {
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
