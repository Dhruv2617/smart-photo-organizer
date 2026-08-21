import AppKit
import ImageIO
import CoreGraphics

/// Generates small preview images on demand (no cache — v1 keeps this
/// simple; a Caches-directory thumbnail cache is a documented follow-up).
enum MediaThumbnail {
    /// A fast downsampled thumbnail for a photo/video file at `url`.
    /// Returns nil if the file can't be read as an image (e.g. a video —
    /// callers should fall back to a placeholder icon for those).
    static func image(for url: URL, maxPixelSize: Int = 120) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgThumbnail, size: NSSize(width: cgThumbnail.width, height: cgThumbnail.height))
    }

    /// Crops the face region described by `boundingBox` (Vision's
    /// normalized, bottom-left-origin coordinates, as stored on a
    /// `FaceObservation`) out of the full image at `fileURL`.
    static func faceCrop(fileURL: URL, boundingBox: CGRect, maxPixelSize: Int = 80) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropped = FaceDetector.cropFace(from: fullImage, normalizedBoundingBox: boundingBox) else {
            return nil
        }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}
