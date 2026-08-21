import Vision
import CoreGraphics
import Foundation

/// A single detected face: its normalized bounding box (as returned by
/// `VNDetectFaceRectanglesRequest`, origin bottom-left, coordinates in
/// [0,1]) plus an archived `VNFeaturePrintObservation` computed over the
/// cropped face region. Vision has no public per-face float-embedding API;
/// `VNFeaturePrintObservation` instead supports `computeDistance(_:to:)`,
/// which yields a distance between two observations (lower = more similar).
/// `FaceMatcher` (Task 9) will unarchive `featurePrintData` and use that API.
struct DetectedFace {
    let boundingBox: CGRect
    let featurePrintData: Data
}

enum FaceDetector {
    static func detectFaces(in cgImage: CGImage) throws -> [DetectedFace] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }

        var faces: [DetectedFace] = []
        for observation in observations {
            guard let croppedImage = cropFace(from: cgImage, normalizedBoundingBox: observation.boundingBox) else {
                continue
            }
            guard let featurePrintData = try featurePrint(for: croppedImage) else {
                continue
            }
            faces.append(DetectedFace(boundingBox: observation.boundingBox, featurePrintData: featurePrintData))
        }
        return faces
    }

    /// Converts Vision's normalized, bottom-left-origin bounding box into
    /// pixel space for `cgImage` and crops that region out. Internal (not
    /// private) so UI code can reuse it to render a face-crop thumbnail from
    /// a stored `FaceObservation`'s bounding box.
    static func cropFace(from cgImage: CGImage, normalizedBoundingBox: CGRect) -> CGImage? {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        let pixelRect = CGRect(
            x: normalizedBoundingBox.origin.x * imageWidth,
            y: (1 - normalizedBoundingBox.origin.y - normalizedBoundingBox.height) * imageHeight,
            width: normalizedBoundingBox.width * imageWidth,
            height: normalizedBoundingBox.height * imageHeight
        ).integral

        let imageBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let clippedRect = pixelRect.intersection(imageBounds)

        guard !clippedRect.isEmpty, clippedRect.width > 0, clippedRect.height > 0 else {
            return nil
        }

        return cgImage.cropping(to: clippedRect)
    }

    /// Runs `VNGenerateImageFeaturePrintRequest` on the cropped face image and
    /// archives the resulting `VNFeaturePrintObservation`.
    private static func featurePrint(for croppedImage: CGImage) throws -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: croppedImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }
}
