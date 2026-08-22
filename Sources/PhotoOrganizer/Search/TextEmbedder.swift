import CoreML
import Foundation

/// Wraps the bundled CLIP text encoder (`TextEncoder.mlmodelc`) plus the
/// CLIP BPE tokenizer to produce a 512-dim embedding for a search query,
/// comparable via cosine similarity to `ImageEmbedder`-produced embeddings
/// — they share the same 512-dim space by construction (that's what CLIP
/// training aligns).
final class TextEmbedder {
    private let model: MLModel
    private let tokenizer: CLIPTokenizer
    private let contextLength = 77 // matches the bundled model's "text" input shape [1, 77]

    init() throws {
        guard let compiledURL = CLIPResources.textEncoderCompiledURL() else {
            throw SemanticSearchError.modelResourceMissing("TextEncoder.mlmodelc")
        }
        self.model = try MLModel(contentsOf: compiledURL)

        guard let (vocabURL, mergesURL) = CLIPResources.tokenizerURLs() else {
            throw SemanticSearchError.tokenizerResourceMissing
        }
        self.tokenizer = try CLIPTokenizer(vocabURL: vocabURL, mergesURL: mergesURL, contextLength: contextLength)
    }

    func embed(query: String) throws -> [Float] {
        let tokenIds = tokenizer.encode(query)
        let multiArray = try MLMultiArray(shape: [1, NSNumber(value: contextLength)], dataType: .int32)
        for (i, id) in tokenIds.enumerated() {
            multiArray[i] = NSNumber(value: id)
        }

        let input = try MLDictionaryFeatureProvider(dictionary: ["text": MLFeatureValue(multiArray: multiArray)])
        let output = try model.prediction(from: input)
        guard let outputArray = output.featureValue(for: "var_1317")?.multiArrayValue else {
            throw SemanticSearchError.unexpectedModelOutput
        }
        return ImageEmbedder.floatArray(from: outputArray)
    }
}
