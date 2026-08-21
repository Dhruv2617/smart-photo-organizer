import AVFoundation
import CoreGraphics

enum VideoFrameSampler {
    /// Samples one frame every `interval` seconds across the asset's duration.
    /// Returns an empty array (never throws for unreadable/empty assets) so
    /// callers can treat "no frames" as "skip video hashing for this file".
    static func sampleFrames(videoAt url: URL, interval: TimeInterval) throws -> [(timestamp: TimeInterval, image: CGImage)] {
        let asset = AVURLAsset(url: url)
        let durationSeconds = CMTimeGetSeconds(loadDurationSynchronously(asset))
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

    /// `AVAsset.duration` is deprecated in favor of the async `load(.duration)`,
    /// but this whole call chain (Indexer.indexSource and its test/UI callers)
    /// is synchronous. Bridges to the async API with a semaphore rather than
    /// threading `async`/`await` through every caller for one property read.
    /// Falls back to `.invalid` (treated as "no frames" by the caller) if the
    /// load fails, matching this function's "never throws" contract.
    private static func loadDurationSynchronously(_ asset: AVURLAsset) -> CMTime {
        let box = DurationBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.value = (try? await asset.load(.duration)) ?? .invalid
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    /// `semaphore.wait()` guarantees `box.value` is only read after the
    /// Task's write has happened-before it, so this is safe despite not
    /// being provably Sendable to the compiler.
    private final class DurationBox: @unchecked Sendable {
        var value: CMTime = .invalid
    }
}
