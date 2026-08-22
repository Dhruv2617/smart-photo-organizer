import CoreML
import CoreGraphics
import ImageIO
import Foundation

/// Wraps the bundled CLIP image encoder (`ImageEncoder.mlmodelc`, pre-
/// compiled — no runtime `MLModel.compileModel` step needed) to produce a
/// 512-dim embedding for a photo/video-frame image, comparable via cosine
/// similarity to a `TextEmbedder`-produced query embedding.
final class ImageEmbedder {
    private let model: MLModel
    private let inputSize = 224

    init() throws {
        guard let compiledURL = CLIPResources.imageEncoderCompiledURL() else {
            throw SemanticSearchError.modelResourceMissing("ImageEncoder.mlmodelc")
        }
        self.model = try MLModel(contentsOf: compiledURL)
    }

    /// Produces a 512-dim embedding for `cgImage`. The model resizes to its
    /// required 224x224 input internally via `MLFeatureValue(cgImage:...)`
    /// — callers pass images at any size.
    func embed(cgImage: CGImage) throws -> [Float] {
        let imageFeature = try MLFeatureValue(
            cgImage: cgImage,
            pixelsWide: inputSize,
            pixelsHigh: inputSize,
            pixelFormatType: kCVPixelFormatType_32ARGB,
            options: nil
        )
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": imageFeature])
        let output = try model.prediction(from: input)
        guard let multiArray = output.featureValue(for: "var_1240")?.multiArrayValue else {
            throw SemanticSearchError.unexpectedModelOutput
        }
        return Self.floatArray(from: multiArray)
    }

    static func floatArray(from multiArray: MLMultiArray) -> [Float] {
        let count = multiArray.count
        var result = [Float](repeating: 0, count: count)
        if multiArray.dataType == .float32 {
            let pointer = multiArray.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count { result[i] = pointer[i] }
        } else {
            for i in 0..<count { result[i] = multiArray[i].floatValue }
        }
        return result
    }
}

enum SemanticSearchError: Error, LocalizedError {
    case modelResourceMissing(String)
    case imageConversionFailed
    case unexpectedModelOutput
    case tokenizerResourceMissing

    var errorDescription: String? {
        switch self {
        case .modelResourceMissing(let name): return "Missing bundled model resource: \(name)"
        case .imageConversionFailed: return "Could not convert image for the embedding model."
        case .unexpectedModelOutput: return "The embedding model returned an unexpected output shape."
        case .tokenizerResourceMissing: return "Missing bundled CLIP tokenizer files."
        }
    }
}
