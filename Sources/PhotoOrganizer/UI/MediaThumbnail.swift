import AppKit
import ImageIO
import CoreGraphics
import AVFoundation

/// In-memory cache so scrolling a list doesn't re-decode the same
/// thumbnail every time a row re-appears. NSCache evicts under memory
/// pressure automatically — no manual size limit needed for this scale.
/// NSCache is internally thread-safe (Apple's documented contract), so
/// this box is safe to share across the background decode tasks below
/// despite NSCache itself not being Sendable.
private final class ThumbnailCacheBox: @unchecked Sendable {
    let cache = NSCache<NSString, NSImage>()
}
private let thumbnailCacheBox = ThumbnailCacheBox()
private var thumbnailCache: NSCache<NSString, NSImage> { thumbnailCacheBox.cache }

/// Generates small preview images, cached in memory keyed by URL/crop.
/// Decoding always happens off the caller's thread via `Task.detached` —
/// see `image(for:)`/`faceCrop(fileURL:boundingBox:)` async overloads.
enum MediaThumbnail {
    /// A fast downsampled thumbnail for a photo/video file at `url`.
    /// Returns nil if the file can't be read as an image (e.g. a video —
    /// callers should fall back to a placeholder icon for those).
    static func image(for url: URL, maxPixelSize: Int = 120) -> NSImage? {
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgThumbnail, size: NSSize(width: cgThumbnail.width, height: cgThumbnail.height))
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// Off-main-thread version of `image(for:)` — decodes on a background
    /// task and hits the same cache, so scrolling doesn't block the UI
    /// thread on disk I/O + image decode.
    static func imageAsync(for url: URL, maxPixelSize: Int = 120) async -> NSImage? {
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        return await Task.detached(priority: .userInitiated) {
            image(for: url, maxPixelSize: maxPixelSize)
        }.value
    }

    /// A thumbnail for a video file, grabbed from a frame a fraction of a
    /// second in (frame 0 of many phone-shot videos is briefly black/blank
    /// while the camera settles). `image(for:)` can't decode video files
    /// at all (ImageIO is stills-only), which is why videos previously
    /// always fell back to a plain icon.
    static func videoThumbnail(for url: URL, maxPixelSize: Int = 120) -> NSImage? {
        let key = "video#\(url.path)#\(maxPixelSize)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard let cgImage = try? generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// Off-main-thread version of `videoThumbnail(for:)`.
    static func videoThumbnailAsync(for url: URL, maxPixelSize: Int = 120) async -> NSImage? {
        let key = "video#\(url.path)#\(maxPixelSize)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        return await Task.detached(priority: .userInitiated) {
            videoThumbnail(for: url, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Crops the face region described by `boundingBox` (Vision's
    /// normalized, bottom-left-origin coordinates, as stored on a
    /// `FaceObservation`) out of the full image at `fileURL`.
    static func faceCrop(fileURL: URL, boundingBox: CGRect, maxPixelSize: Int = 80) -> NSImage? {
        let key = "face#\(fileURL.path)#\(boundingBox)#\(maxPixelSize)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropped = FaceDetector.cropFace(from: fullImage, normalizedBoundingBox: boundingBox) else {
            return nil
        }
        let image = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// Off-main-thread version of `faceCrop(fileURL:boundingBox:)`.
    static func faceCropAsync(fileURL: URL, boundingBox: CGRect, maxPixelSize: Int = 80) async -> NSImage? {
        let key = "face#\(fileURL.path)#\(boundingBox)#\(maxPixelSize)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        return await Task.detached(priority: .userInitiated) {
            faceCrop(fileURL: fileURL, boundingBox: boundingBox, maxPixelSize: maxPixelSize)
        }.value
    }
}
