import AVFoundation
import CoreGraphics

enum VideoFrameSampler {
    /// Samples one frame every `interval` seconds across the asset's duration.
    /// Returns an empty array (never throws for unreadable/empty assets) so
    /// callers can treat "no frames" as "skip video hashing for this file".
    static func sampleFrames(videoAt url: URL, interval: TimeInterval) throws -> [(timestamp: TimeInterval, image: CGImage)] {
        let asset = AVURLAsset(url: url)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var results: [(TimeInterval, CGImage)] = []
        var t: TimeInterval = 0
        while t < durationSeconds {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                results.append((t, cgImage))
            }
            t += interval
        }
        return results
    }
}
