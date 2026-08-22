import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import AVFoundation

enum PhotoFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic, tiff
    var id: String { rawValue }

    var displayName: String { rawValue.uppercased() }
    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }
    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        }
    }
}

enum VideoFormat: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }

    var displayName: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
    var avFileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        }
    }
}

enum MediaConverterError: Error, LocalizedError {
    case unreadableSource
    case writeFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSource: return "Could not read the source file."
        case .writeFailed: return "Could not write the converted file."
        case .exportFailed(let reason): return "Video conversion failed: \(reason)"
        }
    }
}

/// Converts photos/videos to a different format, writing to a destination
/// folder the user chose — never touches or overwrites the original file.
enum MediaConverter {
    /// Converts one photo to `format`, writing `<originalBaseName>.<ext>`
    /// into `destinationFolder`. If a file with that name already exists,
    /// appends " 2", " 3", etc. rather than overwriting.
    static func convertPhoto(at sourceURL: URL, to format: PhotoFormat, destinationFolder: URL) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw MediaConverterError.unreadableSource
        }
        let destinationURL = uniqueDestinationURL(
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            extension: format.fileExtension,
            in: destinationFolder
        )
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw MediaConverterError.writeFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaConverterError.writeFailed
        }
        return destinationURL
    }

    /// Converts one video to `format`, writing into `destinationFolder`.
    static func convertVideo(at sourceURL: URL, to format: VideoFormat, destinationFolder: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaConverterError.exportFailed("Could not create export session")
        }
        let destinationURL = uniqueDestinationURL(
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            extension: format.fileExtension,
            in: destinationFolder
        )
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = format.avFileType

        await exportSession.export()

        if let error = exportSession.error {
            throw MediaConverterError.exportFailed(error.localizedDescription)
        }
        guard exportSession.status == .completed else {
            throw MediaConverterError.exportFailed("Export did not complete (status: \(exportSession.status.rawValue))")
        }
        return destinationURL
    }

    private static func uniqueDestinationURL(baseName: String, extension ext: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(ext)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(suffix)").appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }
}
